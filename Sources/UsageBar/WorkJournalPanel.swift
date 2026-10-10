import AppKit
import SwiftUI
import UsageBarCore

/// Keeps a work interval's start, finish, and receipt in the same menu-bar location.
struct WorkJournalPanel: View {
    @ObservedObject private var store: AppStore
    @ObservedObject private var journal: WorkJournalController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kind: WorkKind = .build
    @State private var showingError = false
    @State private var copiedID: UUID?
    private let openHistory: () -> Void

    init(store: AppStore, openHistory: @escaping () -> Void) {
        _store = ObservedObject(wrappedValue: store)
        _journal = ObservedObject(wrappedValue: store.workJournal)
        self.openHistory = openHistory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !journal.isLoaded {
                loading
            } else if let active = journal.state.active {
                activeContent(active)
            } else if let receipt = journal.recentCompletion {
                completion(receipt)
            } else {
                idle
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(UsageTheme.ink)
        .tint(UsageTheme.accent)
        .padding(.horizontal, 22)
        .padding(.top, 7)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: presentationID)
        .task { await journal.load() }
        .onChange(of: journal.recentCompletion?.id) { _, _ in copiedID = nil }
        .onChange(of: journal.message) { _, message in
            if message == nil { showingError = false }
        }
    }

    private var idle: some View {
        Group {
            HStack(spacing: 7) {
                Label("작업 영수증", systemImage: "receipt")
                    .fontWeight(.medium)
                Text(store.selectedProvider.title)
                    .foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: 4)
                historyButton
            }
            HStack(spacing: 8) {
                Picker("작업 유형", selection: $kind) {
                    ForEach(WorkKind.allCases) { item in Text(item.title).tag(item) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
                .disabled(journal.isBusy)
                Spacer(minLength: 4)
                busyIndicator("시작 한도 확인 중")
                Button(journal.message == nil ? "작업 시작" : "다시 시작") {
                    let selected = store.selectedProvider
                    let selectedKind = kind
                    Task {
                        await journal.start(kind: selectedKind, provider: selected) { id in
                            try await store.workSnapshot(for: id)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(journal.isBusy || !store.activeProviders.contains(store.selectedProvider))
                .help("선택한 서비스의 현재 한도를 확인하고 시작합니다. 같은 계정의 다른 창·기기에서 사용한 양도 포함돼요.")
            }
            if journal.message != nil { errorDetails("시작하지 못했어요") }
        }
    }

    private func activeContent(_ active: WorkSession) -> some View {
        Group {
            HStack(spacing: 7) {
                Image(systemName: "record.circle").foregroundStyle(UsageTheme.accent)
                    .accessibilityHidden(true)
                Text(active.kind.title).fontWeight(.medium)
                Text(active.provider.title).foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: 4)
                historyButton
            }
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.durationLabel(context.date.timeIntervalSince(active.startedAt)))
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .accessibilityLabel("기록 경과 시간 \(Self.durationLabel(context.date.timeIntervalSince(active.startedAt)))")
                }
                Text("기록 중").foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: 4)
                busyIndicator("종료 한도 확인 중")
                Menu {
                    Button("기록 취소", role: .destructive) { Task { await journal.discard() } }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(journal.isBusy)
                .accessibilityLabel("진행 중인 작업 추가 메뉴")
                Button(journal.message == nil ? "작업 종료" : "다시 종료") {
                    Task {
                        await journal.finish { id in try await store.workSnapshot(for: id) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(journal.isBusy)
                .help("\(active.provider.title)의 종료 한도를 확인하고 영수증을 저장합니다")
            }
            if journal.message != nil {
                HStack(spacing: 6) {
                    errorDetails("기록을 유지했어요")
                    Spacer(minLength: 4)
                    Button("한도 비교 없이 종료") { Task { await journal.finishWithoutSnapshot() } }
                        .buttonStyle(.link)
                        .disabled(journal.isBusy)
                        .help("한도 수치 없이 작업 시간만 영수증에 저장합니다")
                }
            }
        }
    }

    private func completion(_ receipt: WorkReceipt) -> some View {
        Group {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark").foregroundStyle(UsageTheme.accent)
                    .accessibilityHidden(true)
                Text(receipt.kind.title).fontWeight(.medium)
                Text(receipt.provider.title).foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: 4)
                Text(Self.durationLabel(receipt.duration))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            PanelReceiptPerforation()
                .stroke(UsageTheme.secondaryInk.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(height: 1)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                ForEach(Array(receipt.rows.prefix(2))) { row in
                    receiptRow(row)
                }
            }
            Text("계정 전체 변화 · 다른 창·기기 사용 포함")
                .font(.system(size: 10))
                .foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                historyButton
                Spacer(minLength: 4)
                Button("다음 작업") { journal.dismissRecentCompletion() }
                    .buttonStyle(.plain)
                    .disabled(journal.isBusy)
                    .help("영수증을 기록에 보관하고 다음 작업을 준비합니다")
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(receipt.copyText, forType: .string) { copiedID = receipt.id }
                } label: {
                    Label(copiedID == receipt.id ? "복사됨" : "요약 복사",
                          systemImage: copiedID == receipt.id ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .accessibilityLabel("작업 영수증 요약 복사")
                .accessibilityValue(copiedID == receipt.id ? "복사 완료" : "")
            }
            if journal.message != nil { errorDetails("기록 확인이 필요해요") }
        }
    }

    private func receiptRow(_ row: WorkQuotaDelta) -> some View {
        let delta = Self.deltaLabel(row.percentagePoints)
        let explanation = row.note.map { ". " + $0 } ?? ""
        return HStack {
            Text(row.label).foregroundStyle(UsageTheme.secondaryInk).lineLimit(1)
            Spacer(minLength: 6)
            Text(delta).monospacedDigit().fixedSize()
        }
        .help(row.label + ": " + (row.note ?? "계정 전체에서 관측된 한도 변화입니다"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label + ", " + delta + explanation)
    }

    private var loading: some View {
        HStack(spacing: 8) {
            if journal.message != nil {
                errorDetails("기록을 읽지 못했어요")
                Spacer(minLength: 4)
                Button("다시 읽기") { Task { await journal.load() } }
                    .controlSize(.small)
                    .disabled(journal.isBusy)
            } else {
                ProgressView().controlSize(.small)
                Text("작업 기록 불러오는 중").foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: 4)
            }
            historyButton
        }
        .frame(minHeight: 26)
    }

    private var historyButton: some View {
        Button("전체 기록", action: openHistory)
            .buttonStyle(.plain)
            .foregroundStyle(UsageTheme.secondaryInk)
            .help("작업 영수증 전체 기록 열기")
            .accessibilityLabel("작업 영수증 전체 기록 열기")
    }

    private func errorDetails(_ title: String) -> some View {
        Button { showingError.toggle() } label: {
            Label(title + " · 자세히", systemImage: "exclamationmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(UsageTheme.warning)
        }
        .buttonStyle(.plain)
        .help(journal.message ?? title)
        .accessibilityLabel(title + ". " + (journal.message ?? "") + " 오류 자세히 보기")
        .popover(isPresented: $showingError, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text(journal.message ?? title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("닫기") { showingError = false }
            }
            .padding(16)
            .frame(width: 290)
        }
    }

    @ViewBuilder
    private func busyIndicator(_ label: String) -> some View {
        if journal.isBusy { ProgressView().controlSize(.mini).accessibilityLabel(label) }
    }

    private var presentationID: String {
        if !journal.isLoaded { return "loading" }
        if let active = journal.state.active { return "active-\(active.id)" }
        if let receipt = journal.recentCompletion { return "receipt-\(receipt.id)" }
        return "idle"
    }

    private static func durationLabel(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "시간 확인 불가" }
        let minutes = Int(min(max(0, interval / 60), Double(Int.max / 2)))
        if minutes == 0 { return "1분 미만" }
        if minutes < 60 { return "\(minutes)분" }
        return minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes / 60)시간 \(minutes % 60)분"
    }

    private static func deltaLabel(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "비교 불가" }
        if value == 0 { return "표시상 변화 없음" }
        return "+\(value.formatted(.number.precision(.fractionLength(0...2))))%p"
    }
}

private struct PanelReceiptPerforation: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
