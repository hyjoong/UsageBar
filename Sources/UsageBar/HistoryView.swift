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

    private struct WindowChoice: Identifiable {
        let id: String
        let label: String
    }

    init(store: AppStore) {
        self.store = store
        _selectedProvider = State(initialValue: store.selectedProvider)
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
        let records = tokenRecords(now: now)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        UsageBrandMark().frame(width: 15, height: 15)
                        Text("UsageBar").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(UsageTheme.secondaryInk)
                    Text("사용 기록").font(.system(size: 24, weight: .semibold))
                    Text("\(selectedProvider.title) · 계정 전체")
                        .font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
                }
                Spacer()
                Picker("서비스", selection: $selectedProvider) {
                    ForEach(ProviderID.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 170)
            }
            Rectangle().fill(UsageTheme.separator).frame(height: 1)
            HStack {
                Picker("기록 종류", selection: $kind) {
                    Text("잔여 한도").tag("limits")
                    Text(selectedProvider == .claude ? "일별 토큰 (미지원)" : "일별 토큰").tag("tokens")
                }.pickerStyle(.segmented).frame(width: 260)
                Spacer()
                Picker("기간", selection: $days) {
                    Text(kind == "tokens" ? "오늘" : "24시간").tag(1)
                    Text("7일").tag(7)
                    Text("30일").tag(30)
                }.pickerStyle(.segmented).frame(width: 200)
            }
            HStack(alignment: .top) {
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
                .controlSize(.regular)
                .disabled(isExporting || (kind == "tokens" ? records.isEmpty : points.isEmpty))
                .help("현재 서비스, 기간, 기록 종류와 한도 필터에 해당하는 기록을 저장해요.")
            }
            if kind == "tokens" { tokens(records) } else { limits(points) }
            Rectangle().fill(UsageTheme.separator).frame(height: 1)
            if let message = store.storageNotice {
                Text(message).font(.system(size: 12)).foregroundStyle(UsageTheme.warning)
            }
            HStack {
                Label(kind == "tokens" ? "제공자가 반환한 일별 토큰" : "확인된 기록만 표시 · 조회 사이의 사용량은 추정하지 않아요", systemImage: "info.circle")
                Spacer()
                if store.isDemo { Text("예시 데이터") }
            }.font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
        }
        .font(.system(size: 13))
        .foregroundStyle(UsageTheme.ink)
        .padding(28).frame(minWidth: 650, minHeight: 620)
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

    @ViewBuilder private func tokens(_ records: [DailyUsage]) -> some View {
        if records.isEmpty {
            emptyState(title: "토큰 기록이 없어요", symbol: "chart.bar",
                       detail: selectedProvider == .claude
                        ? "Claude의 사용 흐름은 잔여 한도 기록에서 확인할 수 있어요."
                        : "선택한 기간에 제공된 기록이 없어요. 계정과 Codex 버전에 따라 지원 여부가 달라요.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("선택한 기간의 토큰").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UsageTheme.secondaryInk)
                // Several valid Int64 buckets can exceed Int64.max; accumulate in Double for display.
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(Self.tokenLabel(records.reduce(0.0) { $0 + Double($1.tokens) }))
                        .font(.system(size: 30, weight: .medium)).monospacedDigit()
                    Text("tokens").font(.system(size: 13)).foregroundStyle(UsageTheme.secondaryInk)
                }
                Text("일별 기록 \(records.count)개 · \(records.first!.day) ~ \(records.last!.day)")
                    .font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
            }
            Chart(records) { record in
                BarMark(x: .value("날짜", String(record.day.suffix(5))), y: .value("토큰", record.tokens))
                    .foregroundStyle(UsageTheme.accent).cornerRadius(3)
                    .accessibilityLabel("\(record.day), \(record.tokens) 토큰")
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let day = value.as(String.self) {
                            Text(day).font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(UsageTheme.separator)
                    AxisValueLabel {
                        if let count = value.as(Double.self) {
                            Text(Self.tokenLabel(count)).font(.system(size: 11))
                                .foregroundStyle(UsageTheme.secondaryInk)
                        }
                    }
                }
            }
            .chartYAxisLabel {
                Text("토큰").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
            }
            .frame(minHeight: 200)
        }
    }

    @ViewBuilder private func limits(_ points: [HistoryPoint]) -> some View {
        if points.isEmpty {
            emptyState(title: "선택한 범위에 기록이 없어요", symbol: "clock.arrow.circlepath",
                       detail: "연결 후 확인된 한도가 기록돼요. 기간이나 한도를 바꿔 확인해 보세요.")
        } else {
            let allSeries = Array(Set(validHistory.map(\.windowName))).sorted()
            let seriesIndices = Dictionary(uniqueKeysWithValues: allSeries.enumerated().map { ($0.element, $0.offset) })
            let visibleSeries = Array(Set(points.map(\.windowName))).sorted()
            let usesTimeLabels = points.last!.date.timeIntervalSince(points.first!.date) <= 48 * 3_600
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("잔여 한도 추이").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("관측값 \(points.count)개").font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(UsageTheme.secondaryInk)
                }
                Text("\(Self.observationDate(points.first!.date)) ~ \(Self.observationDate(points.last!.date))")
                    .font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
            }
            Chart(points) { point in
                let seriesIndex = seriesIndices[point.windowName] ?? 0
                PointMark(x: .value("확인 시각", point.date), y: .value("남은 한도", point.remaining))
                    .foregroundStyle(seriesColor(seriesIndex))
                    .symbol { seriesSymbol(seriesIndex) }
                    .accessibilityLabel("\(Self.observationDate(point.date)), \(point.windowName), \(Int(point.remaining))퍼센트 남음")
            }
            // The custom legend below lists observed series once, using the same explicit
            // color and symbol mapping as the marks. Snapshot-only windows are not series.
            .chartLegend(.hidden)
            .chartXScale(range: .plotDimension(startPadding: 24, endPadding: 24))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel(collisionResolution: .automatic) {
                        if let date = value.as(Date.self) {
                            Text(Self.chartAxisLabel(date, timeOnly: usesTimeLabels))
                                .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(UsageTheme.separator)
                    AxisValueLabel {
                        if let percent = value.as(Int.self) {
                            Text("\(percent)%").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .font(.system(size: 11))
            .frame(minHeight: 220)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(visibleSeries, id: \.self) { name in
                    HStack(spacing: 6) {
                        seriesSymbol(seriesIndices[name] ?? 0)
                        Text(name.isEmpty ? "이름 없는 한도" : name)
                            .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

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
        VStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light))
                .foregroundStyle(UsageTheme.secondaryInk)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
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

    private func tokenRecords(now: Date) -> [DailyUsage] {
        let formatter = Self.dayFormatter()
        let calendar = formatter.calendar!
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: 1 - days, to: today) ?? today
        let first = formatter.string(from: cutoff)
        let last = formatter.string(from: today)
        return (snapshot?.dailyUsage ?? []).filter {
            guard $0.tokens >= 0, $0.day.count == 10, $0.day >= first, $0.day <= last,
                  let date = formatter.date(from: $0.day) else { return false }
            return formatter.string(from: date) == $0.day
        }.sorted { $0.day < $1.day }
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
