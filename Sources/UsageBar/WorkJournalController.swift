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
    /// Gathers model and token details for a finished interval; nil or a nil result leaves the receipt without them.
    var activityCollector: (@MainActor (ProviderID, Date, Date) async -> SessionActivity?)?
    /// Polled history for a provider, used to estimate a change across a reset.
    var historyProvider: (@MainActor (ProviderID) -> [HistoryPoint])?
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
            if CommandLine.arguments.contains("--ui-journal-receipt-reset"), let base = state.receipts.first {
                // A session that crossed the 5-hour reset: the primary row can't be compared, tokens carry the headline.
                var rows = base.rows
                rows[0] = WorkQuotaDelta(id: rows[0].id, label: rows[0].label, percentagePoints: nil,
                                         note: String(localized: "리셋 통과 · 추정 (리셋 전 +3%p, 리셋 후 +2%p)"),
                                         usedPercentAtStart: rows[0].usedPercentAtStart,
                                         estimatedPercentagePoints: 5, estimatedBeforeReset: 3, estimatedAfterReset: 2)
                recentCompletion = WorkReceipt(id: base.id, kind: .review, provider: base.provider, startedAt: base.startedAt,
                                               endedAt: base.endedAt, rows: rows,
                                               activity: SessionActivity(models: [ModelActivity(model: "claude-fable-5-1", calls: 3, inputTokens: 66, outputTokens: 2_700, cacheReadTokens: 410_000)],
                                                                         projects: [ProjectActivity(name: "UsageBar", calls: 3, outputTokens: 2_700)]))
            }
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
            message = String(localized: "작업 기록을 읽지 못했어요. 기존 파일은 보존했어요. 다시 읽기를 눌러 주세요.")
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
            guard snapshot.provider == provider else { throw ProviderError.unavailable(String(localized: "선택한 서비스의 사용량을 확인하지 못했어요.")) }
            let active = try WorkSession.start(kind: kind, snapshot: snapshot, now: Date())
            try await save(WorkJournalState(active: active, receipts: state.receipts))
            recentCompletion = nil
        } catch {
            message = String(localized: "시작 전 사용량을 확인하지 못했어요. ") + Self.reason(error)
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
            var receipt = active.finish(snapshot: snapshot, now: Date(), samples: historyProvider?(active.provider) ?? [])
            receipt.activity = await activityCollector?(active.provider, active.startedAt, receipt.endedAt)
            try await save(WorkJournalState(active: nil, receipts: [receipt] + state.receipts))
            recentCompletion = receipt
        } catch {
            message = fetched
                ? String(localized: "작업 영수증을 저장하지 못했어요. 진행 중인 기록은 유지했어요. 다시 시도해 주세요.")
                : String(localized: "종료 시 사용량을 확인하지 못했어요. 다시 시도하거나 한도 비교 없이 종료할 수 있어요. ") + Self.reason(error)
        }
    }

    func finishWithoutSnapshot() async {
        guard isLoaded, !isBusy, let active = state.active else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            var receipt = active.finish(snapshot: nil, now: Date())
            receipt.activity = await activityCollector?(active.provider, active.startedAt, receipt.endedAt)
            try await save(WorkJournalState(active: nil, receipts: [receipt] + state.receipts))
            recentCompletion = receipt
        } catch { message = String(localized: "작업 기록을 저장하지 못했어요. 진행 중인 기록은 유지했어요.") }
    }

    func discard() async {
        guard isLoaded, !isBusy, state.active != nil else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            try await save(WorkJournalState(active: nil, receipts: state.receipts))
            recentCompletion = nil
        }
        catch { message = String(localized: "진행 중인 기록을 취소하지 못했어요. 다시 시도해 주세요.") }
    }

    func deleteReceipt(_ id: UUID) async {
        guard isLoaded, !isBusy else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            try await save(WorkJournalState(active: state.active, receipts: state.receipts.filter { $0.id != id }))
            if recentCompletion?.id == id { recentCompletion = nil }
        }
        catch { message = String(localized: "작업 영수증을 지우지 못했어요. 다시 시도해 주세요.") }
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
        if error is CancellationError { return String(localized: "조회가 중단됐어요.") }
        return (error as? LocalizedError)?.errorDescription ?? String(localized: "잠시 후 다시 시도해 주세요.")
    }

    #if DEBUG
    /// Scripted demo for recordings: idle → active session → receipt, without any clicks.
    func runDemoFlow(fetch: @escaping (ProviderID) async throws -> ProviderSnapshot) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            if let active = Self.demoActiveSession() {
                state = WorkJournalState(active: active, receipts: state.receipts)
            }
            try? await Task.sleep(for: .seconds(2.5))
            await finish(fetch: fetch)
        }
    }

    /// Matches the demo snapshot (plan, reset times, window ids) so finishing yields real deltas.
    private static func demoActiveSession() -> WorkSession? {
        let now = Date()
        let start = now.addingTimeInterval(-47 * 60)
        let snapshot = ProviderSnapshot(provider: .claude, accountKey: "demo-only", plan: String(localized: "Max · 예시"),
            windows: [UsageWindow(id: "weekly", label: String(localized: "주간 한도"), usedPercent: 10,
                                  resetsAt: now.addingTimeInterval(5 * 86_400), durationMinutes: 10_080),
                      UsageWindow(id: "session", label: String(localized: "5시간 한도"), usedPercent: 22,
                                  resetsAt: now.addingTimeInterval(3 * 3_600), durationMinutes: 300)],
            fetchedAt: start, source: String(localized: "예시 데이터"))
        return try? WorkSession.start(kind: .debug, snapshot: snapshot, now: start)
    }
    #endif

    private static func demoState() -> WorkJournalState {
        let now = Date()
        let start = now.addingTimeInterval(-47 * 60)
        let end = now.addingTimeInterval(-5 * 60)
        let reset = now.addingTimeInterval(3 * 3_600)
        let before = ProviderSnapshot(provider: .claude, accountKey: "demo-only", plan: String(localized: "예시"),
            windows: [UsageWindow(id: "session", label: String(localized: "5시간 한도"), usedPercent: 22, resetsAt: reset, durationMinutes: 300),
                      UsageWindow(id: "weekly", label: String(localized: "주간 한도"), usedPercent: 10, resetsAt: reset.addingTimeInterval(4 * 86_400), durationMinutes: 10_080)],
            fetchedAt: start, source: String(localized: "예시"))
        let after = ProviderSnapshot(provider: .claude, accountKey: "demo-only", plan: String(localized: "예시"),
            windows: [UsageWindow(id: "session", label: String(localized: "5시간 한도"), usedPercent: 28, resetsAt: reset, durationMinutes: 300),
                      UsageWindow(id: "weekly", label: String(localized: "주간 한도"), usedPercent: 11, resetsAt: reset.addingTimeInterval(4 * 86_400), durationMinutes: 10_080)],
            fetchedAt: end, source: String(localized: "예시"))
        guard let session = try? WorkSession.start(kind: .refactor, snapshot: before, now: start) else { return WorkJournalState() }
        var receipt = session.finish(snapshot: after, now: end)
        receipt.activity = .demo
        return WorkJournalState(receipts: [receipt])
    }
}
