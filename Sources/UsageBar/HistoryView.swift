import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers
import UsageBarCore

@MainActor
struct HistoryView: View {
    @ObservedObject var store: AppStore
    @State private var selectedProvider: ProviderID
    @State private var kind = "limits"
    @State private var days = 7
    @State private var selectedWindowID: String?
    @State private var isExporting = false
    @State private var exportError: String?

    /// Observations further apart than this are not joined by a line; the app was likely closed or asleep.
    static let lineGap: TimeInterval = 90 * 60

    private struct WindowChoice: Identifiable {
        let id: String
        let label: String
    }

    private struct Segment: Identifiable {
        let id: String
        let seriesIndex: Int
        let points: [HistoryPoint]
    }

    init(store: AppStore) {
        self.store = store
        _selectedProvider = State(initialValue: store.selectedProvider)
        #if DEBUG
        if store.isDemo, CommandLine.arguments.contains("--ui-history-tokens") { _kind = State(initialValue: "tokens") }
        #endif
    }

    private var snapshot: ProviderSnapshot? { store.states[selectedProvider]?.snapshot }

    private var validHistory: [HistoryPoint] {
        store.history(for: selectedProvider).filter {
            $0.remaining.isFinite && (0...100).contains($0.remaining)
                && $0.date.timeIntervalSince1970.isFinite && !$0.windowID.isEmpty
        }
    }

    private var availableWindows: [WindowChoice] {
        var labels: [String: String] = [:]
        for point in validHistory.sorted(by: { $0.date < $1.date }) {
            labels[point.windowID] = point.windowName
        }
        for window in snapshot?.windows ?? [] where window.usedPercent.isFinite
            && (0...100).contains(window.usedPercent) && !window.id.isEmpty {
            labels[window.id] = window.label
        }
        return labels.map { WindowChoice(id: $0.key, label: $0.value.isEmpty ? "이름 없는 한도" : $0.value) }
            .sorted { $0.label == $1.label ? $0.id < $1.id : $0.label < $1.label }
    }

    private var activeWindowID: String? {
        guard let selectedWindowID, availableWindows.contains(where: { $0.id == selectedWindowID }) else { return nil }
        return selectedWindowID
    }

    var body: some View {
        let now = Date()
        let points = limitPoints(now: now)
        let tokenDays = tokenDayDomain(now: now)
        let records = tokenRecords(in: tokenDays)
        VStack(alignment: .leading, spacing: UsageSpacing.section) {
            toolbar(points: points, records: records, now: now)
            if kind == "tokens" { tokens(records, dayDomain: tokenDays) } else { limits(points) }
            Spacer(minLength: 0)
            footer(records: records)
        }
        .font(UsageType.body)
        .foregroundStyle(UsageTheme.ink)
        .padding(UsageSpacing.windowInset).frame(minWidth: 620, minHeight: 480)
        .background(UsageTheme.canvas)
        .tint(UsageTheme.accent)
        .onChange(of: selectedProvider) { _, _ in selectedWindowID = nil }
        .onChange(of: availableWindows.map(\.id)) { _, ids in
            if let selectedWindowID, !ids.contains(selectedWindowID) { self.selectedWindowID = nil }
        }
        .alert("CSV를 저장하지 못했어요", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("확인", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "다른 저장 위치를 선택해 다시 시도해 주세요.")
        }
    }

    // MARK: Toolbar

    @ViewBuilder private func toolbar(points: [HistoryPoint], records: [DailyUsage], now: Date) -> some View {
        HStack(spacing: UsageSpacing.group) {
            Picker("서비스", selection: $selectedProvider) {
                ForEach(ProviderID.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            Picker("기록 종류", selection: $kind) {
                Text("잔여 한도").tag("limits")
                Text(selectedProvider == .claude ? "일별 토큰 (미지원)" : "일별 토큰").tag("tokens")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            Spacer()
            Picker("기간", selection: $days) {
                Text(kind == "tokens" ? "오늘" : "24시간").tag(1)
                Text("7일").tag(7)
                Text("30일").tag(30)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
        }
        HStack(spacing: UsageSpacing.group) {
            if kind == "limits" {
                Picker("한도", selection: $selectedWindowID) {
                    Text("모든 한도").tag(nil as String?)
                    ForEach(availableWindows) { window in
                        Text(window.label).tag(Optional(window.id))
                    }
                }.frame(maxWidth: 240)
            }
            Spacer()
            Button {
                let csv = kind == "tokens"
                    ? UsageCSV.dailyUsage(records, provider: selectedProvider)
                    : UsageCSV.limits(points, provider: selectedProvider)
                export(csv: csv, now: now)
            } label: {
                Label("CSV 내보내기", systemImage: "square.and.arrow.up")
            }
            .disabled(isExporting || (kind == "tokens" ? records.isEmpty : points.isEmpty))
            .help("현재 서비스, 기간, 기록 종류와 한도 필터에 해당하는 기록을 저장해요.")
        }
    }

    private func footer(records: [DailyUsage]) -> some View {
        HStack {
            Label(kind == "tokens"
                  ? (records.isEmpty ? "제공자가 반환한 일별 토큰" : "빈 날짜: 기록 없음 · 점과 0: 제공된 0 토큰")
                  : "확인된 기록만 표시 · 조회 사이의 사용량은 추정하지 않아요", systemImage: "info.circle")
            Spacer()
            if let message = store.storageNotice {
                Text(message).foregroundStyle(UsageTheme.warning)
            } else if store.isDemo {
                Text("예시 데이터")
            }
        }.font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
    }

    // MARK: Limits

    @ViewBuilder private func limits(_ points: [HistoryPoint]) -> some View {
        if points.isEmpty {
            emptyState(title: "선택한 범위에 기록이 없어요", symbol: "clock.arrow.circlepath",
                       detail: "연결 후 확인된 한도가 기록돼요. 기간이나 한도를 바꿔 확인해 보세요.")
        } else {
            let allSeries = Array(Set(validHistory.map(\.windowName))).sorted()
            let seriesIndices = Dictionary(uniqueKeysWithValues: allSeries.enumerated().map { ($0.element, $0.offset) })
            let visibleSeries = Array(Set(points.map(\.windowName))).sorted()
            let usesTimeLabels = points.last!.date.timeIntervalSince(points.first!.date) <= 48 * 3_600
            let segments = Self.segments(points, seriesIndices: seriesIndices)
            VStack(alignment: .leading, spacing: UsageSpacing.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text("잔여 한도 추이").font(UsageType.title)
                    Spacer()
                    Text("관측값 \(points.count)개").font(UsageType.secondary).monospacedDigit()
                        .foregroundStyle(UsageTheme.secondaryInk)
                }
                Text("\(Self.observationDate(points.first!.date)) ~ \(Self.observationDate(points.last!.date))")
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
            }
            Chart {
                ForEach(segments) { segment in
                    ForEach(segment.points) { point in
                        LineMark(x: .value("확인 시각", point.date), y: .value("남은 한도", point.remaining),
                                 series: .value("구간", segment.id))
                            .foregroundStyle(seriesColor(segment.seriesIndex).opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.linear)
                    }
                }
                ForEach(points) { point in
                    let seriesIndex = seriesIndices[point.windowName] ?? 0
                    PointMark(x: .value("확인 시각", point.date), y: .value("남은 한도", point.remaining))
                        .foregroundStyle(seriesColor(seriesIndex))
                        .symbol { seriesSymbol(seriesIndex) }
                        .accessibilityLabel("\(Self.observationDate(point.date)), \(point.windowName), \(Int(point.remaining))퍼센트 남음")
                }
            }
            // The custom legend below lists observed series once, using the same explicit
            // color and symbol mapping as the marks. Snapshot-only windows are not series.
            .chartLegend(.hidden)
            .chartXScale(range: .plotDimension(startPadding: 24, endPadding: 24))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel(collisionResolution: .automatic) {
                        if let date = value.as(Date.self) {
                            Text(Self.chartAxisLabel(date, timeOnly: usesTimeLabels))
                                .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(UsageTheme.separator)
                    AxisValueLabel {
                        if let percent = value.as(Int.self) {
                            Text("\(percent)%").font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .font(UsageType.caption)
            .frame(minHeight: 220)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)],
                      alignment: .leading, spacing: UsageSpacing.item) {
                ForEach(visibleSeries, id: \.self) { name in
                    HStack(spacing: UsageSpacing.compact) {
                        seriesSymbol(seriesIndices[name] ?? 0)
                        Text(name.isEmpty ? "이름 없는 한도" : name)
                            .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Splits each series into runs of observations close enough in time to draw a line between.
    private static func segments(_ points: [HistoryPoint], seriesIndices: [String: Int]) -> [Segment] {
        var result: [Segment] = []
        for (name, group) in Dictionary(grouping: points, by: \.windowName).sorted(by: { $0.key < $1.key }) {
            var run: [HistoryPoint] = []
            var runIndex = 0
            func flush() {
                guard run.count > 1 else { run = []; return }
                result.append(Segment(id: "\(name)#\(runIndex)", seriesIndex: seriesIndices[name] ?? 0, points: run))
                runIndex += 1
                run = []
            }
            for point in group.sorted(by: { $0.date < $1.date }) {
                if let last = run.last, point.date.timeIntervalSince(last.date) > lineGap { flush() }
                run.append(point)
            }
            flush()
        }
        return result
    }

    // MARK: Tokens

    @ViewBuilder private func tokens(_ records: [DailyUsage], dayDomain: [String]) -> some View {
        if records.isEmpty {
            emptyState(title: "토큰 기록이 없어요", symbol: "chart.bar",
                       detail: selectedProvider == .claude
                        ? "Claude의 사용 흐름은 잔여 한도 기록에서 확인할 수 있어요."
                        : "선택한 기간에 제공된 기록이 없어요. 계정과 Codex 버전에 따라 지원 여부가 달라요.")
        } else {
            VStack(alignment: .leading, spacing: UsageSpacing.tight) {
                Text("선택한 기간의 토큰").font(UsageType.title)
                // Several valid Int64 buckets can exceed Int64.max; accumulate in Double for display.
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(Self.tokenLabel(records.reduce(0.0) { $0 + Double($1.tokens) }))
                        .font(UsageType.metric).monospacedDigit()
                    Text("tokens").font(UsageType.body).foregroundStyle(UsageTheme.secondaryInk)
                }
                Text("일별 기록 \(records.count)개 · \(records.first!.day) ~ \(records.last!.day)")
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
            }
            Chart(records) { record in
                if record.tokens == 0 {
                    PointMark(x: .value("날짜", record.day), y: .value("토큰", record.tokens))
                        .foregroundStyle(UsageTheme.accent)
                        .symbolSize(24)
                        .annotation(position: .top, spacing: 4) {
                            Text("0").font(UsageType.micro).foregroundStyle(UsageTheme.secondaryInk)
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel("\(record.day), \(record.tokens) 토큰")
                } else {
                    BarMark(x: .value("날짜", record.day), y: .value("토큰", record.tokens))
                        .foregroundStyle(UsageTheme.accent).cornerRadius(3)
                        .accessibilityLabel("\(record.day), \(record.tokens) 토큰")
                }
            }
            // Reserve calendar slots without inventing zero-valued records for absent days.
            .chartXScale(domain: dayDomain)
            .chartXAxis {
                AxisMarks(values: Self.tokenAxisDays(dayDomain)) { value in
                    AxisValueLabel(anchor: dayDomain.count > 7
                                   ? (value.as(String.self) == dayDomain.first ? .topLeading
                                      : value.as(String.self) == dayDomain.last ? .topTrailing : .top)
                                   : nil) {
                        if let day = value.as(String.self) {
                            Text(String(day.suffix(5))).font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(UsageTheme.separator)
                    AxisValueLabel {
                        if let count = value.as(Double.self) {
                            Text(Self.tokenLabel(count)).font(UsageType.caption)
                                .foregroundStyle(UsageTheme.secondaryInk)
                        }
                    }
                }
            }
            .chartYAxisLabel {
                Text("토큰").font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
            }
            .frame(minHeight: 200)
        }
    }

    // MARK: Helpers

    private func seriesColor(_ index: Int) -> Color {
        UsageTheme.chartColors[index % UsageTheme.chartColors.count]
    }

    private func seriesSymbol(_ index: Int) -> some View {
        let symbols = ["circle.fill", "square.fill", "diamond.fill", "triangle.fill", "plus"]
        return Image(systemName: symbols[index % symbols.count])
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(seriesColor(index))
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private func emptyState(title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: UsageSpacing.group) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light))
                .foregroundStyle(UsageTheme.secondaryInk)
            Text(title).font(UsageType.title)
            Text(detail).font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(.vertical, 35)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func limitPoints(now: Date) -> [HistoryPoint] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let windowID = activeWindowID
        return validHistory.filter {
            $0.date >= cutoff && $0.date <= now && (windowID == nil || $0.windowID == windowID)
        }.sorted { $0.date == $1.date ? $0.windowID < $1.windowID : $0.date < $1.date }
    }

    private func tokenDayDomain(now: Date) -> [String] {
        let formatter = Self.dayFormatter()
        let calendar = formatter.calendar!
        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: 1 - days + offset, to: today)
                .map { formatter.string(from: $0) }
        }
    }

    private func tokenRecords(in dayDomain: [String]) -> [DailyUsage] {
        guard let first = dayDomain.first, let last = dayDomain.last else { return [] }
        let formatter = Self.dayFormatter()
        return (snapshot?.dailyUsage ?? []).filter {
            guard $0.tokens >= 0, $0.day.count == 10, $0.day >= first, $0.day <= last,
                  let date = formatter.date(from: $0.day) else { return false }
            return formatter.string(from: date) == $0.day
        }.sorted { $0.day < $1.day }
    }

    private static func tokenAxisDays(_ days: [String]) -> [String] {
        guard days.count > 7, let last = days.last else { return days }
        // Weekly labels plus the final date; avoid adjacent labels at the right edge.
        let weekly = stride(from: 0, to: days.count - 1, by: 7)
            .filter { days.count - 1 - $0 >= 4 }
            .map { days[$0] }
        return weekly + [last]
    }

    private func export(csv: String, now: Date) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.title = "사용 기록 내보내기"
        let filter = kind == "limits" ? (activeWindowID == nil ? "-all-windows" : "-selected-window") : ""
        panel.nameFieldStringValue = "UsageBar-\(selectedProvider.rawValue)-\(kind)-\(days)d\(filter)-\(Self.dayFormatter().string(from: now)).csv"
        exportError = nil
        isExporting = true
        panel.begin { response in
            isExporting = false
            guard response == .OK, let url = panel.url else { return }
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = "선택한 위치에 파일을 저장할 수 없어요. \(error.localizedDescription)" }
        }
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func observationDate(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }

    private static func chartAxisLabel(_ date: Date, timeOnly: Bool) -> String {
        let formatter = dayFormatter()
        // The full date range is already shown above the plot. Short time labels avoid
        // repeating the same date and keep endpoint labels inside narrow windows.
        formatter.dateFormat = timeOnly ? "HH:mm" : "M/d"
        return formatter.string(from: date)
    }

    private static func tokenLabel(_ number: Double) -> String {
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return number.formatted(.number.precision(.fractionLength(0)))
    }
}
