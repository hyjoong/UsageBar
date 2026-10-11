import Combine
import Foundation
import UsageBarCore

/// Owns one user-started work interval. Boundary queries reuse AppStore's normal refresh safeguards.
@MainActor
final class WorkJournalController: ObservableObject {
    @Published private(set) var state = WorkJournalState()
    @Published private(set) var isBusy = false
    @Published private(set) var isLoaded = false
    @Published private(set) var message: String?
    /// Shown only for a completion in this process; historical receipts never trigger the panel.
    @Published private(set) var recentCompletion: WorkReceipt?
    private let persistence: WorkJournalStore?

    init(demo: Bool = false, persistence: WorkJournalStore? = nil, usesPersistence: Bool = true) {
        self.persistence = demo || !usesPersistence ? nil : (persistence ?? WorkJournalStore())
        isLoaded = demo || !usesPersistence
        if demo {
            state = Self.demoState()
            #if DEBUG
            if CommandLine.arguments.contains("--ui-journal-active"), let active = Self.demoActiveSession() {
                state = WorkJournalState(active: active, receipts: state.receipts)
            }
            if CommandLine.arguments.contains("--ui-journal-receipt") { recentCompletion = state.receipts.first }
            #endif
        }
    }

    func load() async {
        guard !isLoaded, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            state = try await persistence?.load() ?? WorkJournalState()
            isLoaded = true
            message = nil
        } catch {
            message = "작업 기록을 읽지 못했어요. 기존 파일은 보존했어요. 다시 읽기를 눌러 주세요."
        }
    }

    func start(kind: WorkKind, provider: ProviderID,
               fetch: @escaping (ProviderID) async throws -> ProviderSnapshot) async {
        guard isLoaded, !isBusy, state.active == nil else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            let snapshot = try await fetch(provider)
            try Task.checkCancellation()
            guard snapshot.provider == provider else { throw ProviderError.unavailable("선택한 서비스의 사용량을 확인하지 못했어요.") }
            let active = try WorkSession.start(kind: kind, snapshot: snapshot, now: Date())
            try await save(WorkJournalState(active: active, receipts: state.receipts))
            recentCompletion = nil
        } catch {
            message = "시작 전 사용량을 확인하지 못했어요. " + Self.reason(error)
        }
    }

    func finish(fetch: @escaping (ProviderID) async throws -> ProviderSnapshot) async {
        guard isLoaded, !isBusy, let active = state.active else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        var fetched = false
        do {
            let snapshot = try await fetch(active.provider)
            try Task.checkCancellation()
            fetched = true
            let receipt = active.finish(snapshot: snapshot, now: Date())
            try await save(WorkJournalState(active: nil, receipts: [receipt] + state.receipts))
            recentCompletion = receipt
        } catch {
            message = fetched
                ? "작업 영수증을 저장하지 못했어요. 진행 중인 기록은 유지했어요. 다시 시도해 주세요."
                : "종료 시 사용량을 확인하지 못했어요. 다시 시도하거나 한도 비교 없이 종료할 수 있어요. " + Self.reason(error)
        }
    }

    func finishWithoutSnapshot() async {
        guard isLoaded, !isBusy, let active = state.active else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            let receipt = active.finish(snapshot: nil, now: Date())
            try await save(WorkJournalState(active: nil, receipts: [receipt] + state.receipts))
            recentCompletion = receipt
        } catch { message = "작업 기록을 저장하지 못했어요. 진행 중인 기록은 유지했어요." }
    }

    func discard() async {
        guard isLoaded, !isBusy, state.active != nil else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            try await save(WorkJournalState(active: nil, receipts: state.receipts))
            recentCompletion = nil
        }
        catch { message = "진행 중인 기록을 취소하지 못했어요. 다시 시도해 주세요." }
    }

    func deleteReceipt(_ id: UUID) async {
        guard isLoaded, !isBusy else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            try await save(WorkJournalState(active: state.active, receipts: state.receipts.filter { $0.id != id }))
            if recentCompletion?.id == id { recentCompletion = nil }
        }
        catch { message = "작업 영수증을 지우지 못했어요. 다시 시도해 주세요." }
    }

    func dismissRecentCompletion() {
        guard !isBusy, recentCompletion != nil else { return }
        recentCompletion = nil
        message = nil
    }

    private func save(_ next: WorkJournalState) async throws {
        let bounded = WorkJournalState(active: next.active, receipts: Array(next.receipts.prefix(100)))
        try await persistence?.save(bounded)
        state = bounded
    }

    private static func reason(_ error: Error) -> String {
        if error is CancellationError { return "조회가 중단됐어요." }
        return (error as? LocalizedError)?.errorDescription ?? "잠시 후 다시 시도해 주세요."
    }

    #if DEBUG
    private static func demoActiveSession() -> WorkSession? {
        let start = Date().addingTimeInterval(-47 * 60)
        let snapshot = ProviderSnapshot(provider: .claude, accountKey: "demo-only", plan: "예시",
            windows: [UsageWindow(id: "session", label: "5시간 한도", usedPercent: 22,
                                  resetsAt: start.addingTimeInterval(3 * 3_600), durationMinutes: 300)],
            fetchedAt: start, source: "예시")
        return try? WorkSession.start(kind: .debug, snapshot: snapshot, now: start)
    }
    #endif

    private static func demoState() -> WorkJournalState {
        let now = Date()
        let start = now.addingTimeInterval(-47 * 60)
        let end = now.addingTimeInterval(-5 * 60)
        let reset = now.addingTimeInterval(3 * 3_600)
        let before = ProviderSnapshot(provider: .claude, accountKey: "demo-only", plan: "예시",
            windows: [UsageWindow(id: "session", label: "5시간 한도", usedPercent: 22, resetsAt: reset, durationMinutes: 300),
                      UsageWindow(id: "weekly", label: "주간 한도", usedPercent: 10, resetsAt: reset.addingTimeInterval(4 * 86_400), durationMinutes: 10_080)],
            fetchedAt: start, source: "예시")
        let after = ProviderSnapshot(provider: .claude, accountKey: "demo-only", plan: "예시",
            windows: [UsageWindow(id: "session", label: "5시간 한도", usedPercent: 28, resetsAt: reset, durationMinutes: 300),
                      UsageWindow(id: "weekly", label: "주간 한도", usedPercent: 11, resetsAt: reset.addingTimeInterval(4 * 86_400), durationMinutes: 10_080)],
            fetchedAt: end, source: "예시")
        guard let session = try? WorkSession.start(kind: .refactor, snapshot: before, now: start) else { return WorkJournalState() }
        return WorkJournalState(receipts: [session.finish(snapshot: after, now: end)])
    }
}
