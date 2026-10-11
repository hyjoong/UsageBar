import AppKit
import SwiftUI
import UsageBarCore

/// One row at the bottom of the panel that starts, tracks, and closes a work interval.
struct WorkJournalPanel: View {
    @ObservedObject private var store: AppStore
    @ObservedObject private var journal: WorkJournalController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingError = false
    @State private var copiedID: UUID?
    private let openHistory: () -> Void

    init(store: AppStore, openHistory: @escaping () -> Void) {
        _store = ObservedObject(wrappedValue: store)
        _journal = ObservedObject(wrappedValue: store.workJournal)
        self.openHistory = openHistory
    }

    var body: some View {
        Group {
            if !journal.isLoaded {
                loading
            } else if let active = journal.state.active {
                card { activeContent(active) }
            } else if let receipt = journal.recentCompletion {
                card { completion(receipt) }
            } else {
                idle
            }
        }
        .font(UsageType.caption)
        .foregroundStyle(UsageTheme.ink)
        .tint(UsageTheme.accent)
        .padding(.horizontal, UsageSpacing.panelInset)
        .padding(.top, 7)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: presentationID)
        .task { await journal.load() }
        .onChange(of: journal.recentCompletion?.id) { _, _ in copiedID = nil }
        .onChange(of: journal.message) { _, message in
            if message == nil { showingError = false }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: UsageSpacing.compact, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: UsageRadius.panelCard))
    }

    // MARK: Idle

    private var idle: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.tight) {
            HStack(spacing: UsageSpacing.item) {
                Label("작업 기록", systemImage: "receipt").foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: UsageSpacing.tight)
                busyIndicator("시작 한도 확인 중")
                Button("전체 기록", action: openHistory)
                    .buttonStyle(.plain).foregroundStyle(UsageTheme.secondaryInk)
                    .help("작업 영수증 전체 기록 열기")
                startMenu
            }
            .frame(minHeight: UsageSpacing.control)
            if journal.message != nil { errorDetails("시작하지 못했어요") }
        }
    }

    private var startMenu: some View {
        Menu {
            Section("\(store.selectedProvider.title) 한도 기준") {
                ForEach(WorkKind.allCases) { kind in
                    Button(kind.title) { start(kind) }
                }
            }
        } label: {
            Text(journal.message == nil ? "작업 시작" : "다시 시작")
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
        .disabled(journal.isBusy || store.selectedState.snapshot == nil
                  || !store.activeProviders.contains(store.selectedProvider))
        .help("작업 유형을 고르면 현재 한도를 확인하고 바로 시작해요. 끝낼 때 한도 변화를 영수증으로 남겨요.")
        .accessibilityLabel("작업 시작, 작업 유형 선택")
    }

    private func start(_ kind: WorkKind) {
        let provider = store.selectedProvider
        Task {
            await journal.start(kind: kind, provider: provider) { id in try await store.workSnapshot(for: id) }
        }
    }

    // MARK: Active

    @ViewBuilder private func activeContent(_ active: WorkSession) -> some View {
        HStack(spacing: UsageSpacing.item) {
            Image(systemName: "record.circle").foregroundStyle(UsageTheme.accent).accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let label = UsageFormat.durationLabel(context.date.timeIntervalSince(active.startedAt))
                Text(label)
                    .font(UsageType.durationCompact).monospacedDigit()
                    .accessibilityLabel("기록 경과 시간 \(label)")
            }
            Text("\(active.kind.title) · \(active.provider.title)")
                .foregroundStyle(UsageTheme.secondaryInk).lineLimit(1)
            Spacer(minLength: UsageSpacing.tight)
            busyIndicator("종료 한도 확인 중")
            Menu {
                Button("전체 기록", action: openHistory)
                Divider()
                Button("기록 취소", role: .destructive) { Task { await journal.discard() } }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(journal.isBusy)
            .accessibilityLabel("진행 중인 작업 추가 메뉴")
            Button(journal.message == nil ? "작업 종료" : "다시 종료") {
                Task { await journal.finish { id in try await store.workSnapshot(for: id) } }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(journal.isBusy)
            .help("\(active.provider.title)의 종료 한도를 확인하고 영수증을 저장해요")
        }
        if journal.message != nil {
            HStack(spacing: UsageSpacing.compact) {
                errorDetails("기록을 유지했어요")
                Spacer(minLength: UsageSpacing.tight)
                Button("한도 비교 없이 종료") { Task { await journal.finishWithoutSnapshot() } }
                    .buttonStyle(.link).disabled(journal.isBusy)
                    .help("한도 수치 없이 작업 시간만 영수증에 저장해요")
            }
        }
    }

    // MARK: Completion

    @ViewBuilder private func completion(_ receipt: WorkReceipt) -> some View {
        HStack(spacing: UsageSpacing.item) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(UsageTheme.accent).accessibilityHidden(true)
            Text(UsageFormat.durationLabel(receipt.duration))
                .font(UsageType.durationCompact).monospacedDigit()
            Text("\(receipt.kind.title) · \(receipt.provider.title)")
                .foregroundStyle(UsageTheme.secondaryInk).lineLimit(1)
            Spacer(minLength: UsageSpacing.tight)
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
            Button {
                journal.dismissRecentCompletion()
            } label: {
                Image(systemName: "xmark").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(UsageTheme.secondaryInk)
            .disabled(journal.isBusy)
            .help("영수증은 전체 기록에 보관하고 이 표시를 닫아요")
            .accessibilityLabel("완료 표시 닫기")
        }
        Text(UsageFormat.receiptSummary(receipt.rows, limit: 2))
            .foregroundStyle(UsageTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .help("관측 구간의 계정 전체 사용률 변화예요. 다른 창·기기의 사용도 포함되며, 이 작업만의 사용량은 아니에요.")
        if journal.message != nil { errorDetails("기록 확인이 필요해요") }
    }

    // MARK: Shared

    private var loading: some View {
        HStack(spacing: UsageSpacing.item) {
            if journal.message != nil {
                errorDetails("기록을 읽지 못했어요")
                Spacer(minLength: UsageSpacing.tight)
                Button("다시 읽기") { Task { await journal.load() } }
                    .controlSize(.small).disabled(journal.isBusy)
            } else {
                ProgressView().controlSize(.small)
                Text("작업 기록 불러오는 중").foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: UsageSpacing.tight)
            }
        }
        .frame(minHeight: UsageSpacing.control)
    }

    private func errorDetails(_ title: String) -> some View {
        Button { showingError.toggle() } label: {
            Label(title + " · 자세히", systemImage: "exclamationmark.circle")
                .font(UsageType.micro).foregroundStyle(UsageTheme.warning)
        }
        .buttonStyle(.plain)
        .help(journal.message ?? title)
        .accessibilityLabel(title + ". " + (journal.message ?? "") + " 오류 자세히 보기")
        .popover(isPresented: $showingError, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: UsageSpacing.group) {
                Text(journal.message ?? title)
                    .font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Button("닫기") { showingError = false }
            }
            .padding(16).frame(width: 290)
        }
    }

    @ViewBuilder private func busyIndicator(_ label: String) -> some View {
        if journal.isBusy { ProgressView().controlSize(.mini).accessibilityLabel(label) }
    }

    private var presentationID: String {
        if !journal.isLoaded { return "loading" }
        if let active = journal.state.active { return "active-\(active.id)" }
        if let receipt = journal.recentCompletion { return "receipt-\(receipt.id)" }
        return "idle"
    }
}
