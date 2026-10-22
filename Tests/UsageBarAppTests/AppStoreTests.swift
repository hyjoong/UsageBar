import XCTest
import Combine
@testable import UsageBar
import UsageBarCore

private actor StubProvider: UsageProvider {
    nonisolated let id: ProviderID
    private(set) var calls = 0
    var failure: ProviderError?
    private var snapshot: ProviderSnapshot?
    init(_ id: ProviderID, failure: ProviderError? = nil, snapshot: ProviderSnapshot? = nil) {
        self.id = id; self.failure = failure; self.snapshot = snapshot
    }
    func fetch() async throws -> ProviderSnapshot {
        calls += 1
        if let failure { throw failure }
        return snapshot ?? ProviderSnapshot(provider: id, windows: [], source: "test")
    }
    func setFailure(_ failure: ProviderError?) { self.failure = failure }
    func setSnapshot(_ snapshot: ProviderSnapshot) { self.snapshot = snapshot }
}

/// Intentionally ignores cancellation until the test releases its suspended response.
private actor SuspendedProvider: UsageProvider {
    nonisolated let id: ProviderID = .claude
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<ProviderSnapshot, Error>] = [:]
    private let onFetch: @Sendable (Int) -> Void

    init(onFetch: @escaping @Sendable (Int) -> Void) { self.onFetch = onFetch }

    func fetch() async throws -> ProviderSnapshot {
        calls += 1
        let call = calls
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
            onFetch(call)
        }
    }

    func complete(_ call: Int, with result: Result<ProviderSnapshot, Error>) {
        pending.removeValue(forKey: call)?.resume(with: result)
    }

    func cancelPending() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class AppStoreTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let suite = "UsageBar.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRapidProviderToggleDiscardsCancelledLateSuccess() async {
        let old = ProviderSnapshot(provider: .claude, windows: [], source: "cancelled-old-response")
        await exerciseRapidToggle(oldResult: .success(old))
    }

    func testRapidProviderToggleDiscardsCancelledLateAuthenticationError() async {
        await exerciseRapidToggle(oldResult: .failure(ProviderError.authenticationRequired("cancelled-old-error")))
    }

    private func exerciseRapidToggle(oldResult: Result<ProviderSnapshot, Error>) async {
        let firstStarted = expectation(description: "Initial request suspended")
        let replacementStarted = expectation(description: "Replacement request suspended")
        let replacementFinished = expectation(description: "Only the replacement result is published")
        let provider = SuspendedProvider { call in
            if call == 1 { firstStarted.fulfill() }
            if call == 2 { replacementStarted.fulfill() }
        }
        addTeardownBlock { await provider.cancelPending() }
        let store = AppStore(providerOverrides: [.claude: provider], preferences: preferences())
        let observation = store.$states.first { states in
            states[.claude]?.snapshot?.source == "new-response" && states[.claude]?.isRefreshing == false
        }.sink { _ in replacementFinished.fulfill() }
        defer { observation.cancel(); store.stop() }

        store.start()
        await fulfillment(of: [firstStarted], timeout: 2)
        for _ in 0..<3 {
            store.setProviderEnabled(false, for: .claude)
            XCTAssertEqual(store.connectionStatus(for: .claude), "조회 꺼짐")
            store.setProviderEnabled(true, for: .claude)
        }

        await provider.complete(1, with: oldResult)
        await fulfillment(of: [replacementStarted], timeout: 2)
        XCTAssertNil(store.states[.claude]?.snapshot, "A cancelled response must not restore old capacity")
        XCTAssertNil(store.states[.claude]?.errorMessage, "A cancelled failure must not poison the new connection")
        XCTAssertFalse(store.states[.claude]?.requiresConnection ?? true)
        XCTAssertNil(store.states[.claude]?.connectionIssue)
        XCTAssertTrue(store.states[.claude]?.isRefreshing ?? false, "Old cleanup must not clear the new request's progress")
        XCTAssertNil(store.retryMessage(for: .claude))

        let fresh = ProviderSnapshot(provider: .claude, windows: [
            UsageWindow(id: "session", label: "세션", usedPercent: 15, resetsAt: nil)
        ], source: "new-response")
        await provider.complete(2, with: .success(fresh))
        await fulfillment(of: [replacementFinished], timeout: 2)
        XCTAssertEqual(store.states[.claude]?.snapshot, fresh)
        let calls = await provider.calls
        XCTAssertEqual(calls, 2, "Rapid re-enabling must coalesce into one replacement request")
    }

    func testDisabledProviderIsNeverQueriedAndSelectionMoves() async {
        let claude = StubProvider(.claude), codex = StubProvider(.codex)
        let settings = preferences()
        let store = AppStore(providerOverrides: [.claude: claude, .codex: codex], preferences: settings)
        store.setProviderEnabled(false, for: .claude)
        XCTAssertEqual(store.selectedProvider, .codex)
        XCTAssertEqual(store.activeProviders, [.codex])
        XCTAssertEqual(store.connectionStatus(for: .claude), "조회 꺼짐")
        XCTAssertFalse(store.canRefresh(.claude))
        await store.refresh(.claude, force: true)
        await store.refreshAll()
        let claudeCalls = await claude.calls, codexCalls = await codex.calls
        XCTAssertEqual(claudeCalls, 0)
        XCTAssertEqual(codexCalls, 1)
        XCTAssertEqual(settings.stringArray(forKey: "enabledProviders"), ["codex"])
    }

    func testCannotDisableFinalServiceAndAllMenuOmitsDisabledProvider() {
        let store = AppStore(demo: true, preferences: preferences())
        store.setProviderEnabled(false, for: .codex)
        store.setProviderEnabled(false, for: .claude)
        store.menuBarDisplayMode = .all
        XCTAssertEqual(store.enabledProviders, [.claude])
        XCTAssertEqual(store.menuProviders, [.claude])
        XCTAssertNotNil(store.states[.codex]?.snapshot, "Turning off queries must retain existing history/snapshots")
    }

    func testUnsupportedAccountKeepsConnectionRecoveryAvailable() async {
        for id in ProviderID.allCases {
            let provider = StubProvider(id, failure: .unsupported("Subscription login required"))
            let store = AppStore(providerOverrides: [id: provider], preferences: preferences())
            await store.refresh(id, force: true)
            XCTAssertNil(store.states[id]?.snapshot)
            XCTAssertTrue(store.states[id]?.requiresConnection ?? false,
                          "An API account needs login recovery, not only a retry countdown")
            XCTAssertEqual(store.states[id]?.connectionIssue, .unsupported)
            XCTAssertTrue(store.canRefresh(id), "Manual retry must remain available after correcting login")
        }
    }

    func testAuthenticationFailureOffersLoginRecoveryForBothProviders() async {
        for id in ProviderID.allCases {
            let provider = StubProvider(id, failure: .authenticationRequired("Please sign in"))
            let store = AppStore(providerOverrides: [id: provider], preferences: preferences())
            await store.refresh(id, force: true)
            XCTAssertNil(store.states[id]?.snapshot)
            XCTAssertEqual(store.states[id]?.connectionIssue, .authentication)
            XCTAssertTrue(store.states[id]?.requiresConnection ?? false)
            XCTAssertEqual(store.connectionStatus(for: id), "로그인 확인 필요")
            XCTAssertTrue(store.canRefresh(id), "Login recovery must allow an immediate manual retry")

            await provider.setFailure(.unavailable("offline"))
            await store.refresh(id, force: true)
            XCTAssertNil(store.states[id]?.connectionIssue, "A later unknown failure must not claim login is required")
            XCTAssertEqual(store.connectionStatus(for: id), "조회 실패")

            await provider.setFailure(.setupRequired("Update CLI"))
            await store.refresh(id, force: true)
            XCTAssertEqual(store.states[id]?.connectionIssue, .setup)
            XCTAssertEqual(store.connectionStatus(for: id), "다시 연결 필요")
        }
    }

    func testMissingAccountKeyIsCarriedOverBrieflyButNeverAcrossAccountsOrLongGaps() {
        let now = Date()
        let known = ProviderSnapshot(provider: .claude, accountKey: "account-a", plan: "Max", windows: [], fetchedAt: now, source: "test")
        let blank = ProviderSnapshot(provider: .claude, windows: [], fetchedAt: now.addingTimeInterval(300), source: "test")
        let carried = AppStore.carryingAccount(into: blank, from: known)
        XCTAssertEqual(carried.accountKey, "account-a")
        XCTAssertEqual(carried.plan, "Max")
        // A different, known account is reported as is.
        let other = ProviderSnapshot(provider: .claude, accountKey: "account-b", windows: [], fetchedAt: blank.fetchedAt, source: "test")
        XCTAssertEqual(AppStore.carryingAccount(into: other, from: known).accountKey, "account-b")
        // After a long gap, or with nothing known before, unknown stays unknown.
        let late = ProviderSnapshot(provider: .claude, windows: [], fetchedAt: now.addingTimeInterval(31 * 60), source: "test")
        XCTAssertNil(AppStore.carryingAccount(into: late, from: known).accountKey)
        XCTAssertNil(AppStore.carryingAccount(into: blank, from: nil).accountKey)
        let codex = ProviderSnapshot(provider: .codex, accountKey: "account-a", windows: [], fetchedAt: now, source: "test")
        XCTAssertNil(AppStore.carryingAccount(into: blank, from: codex).accountKey)
    }

    func testStatusLineSummarizesTheLastSessionForTenMinutes() {
        let now = Date()
        func receipt(endedAgo: TimeInterval, rows: [WorkQuotaDelta], output: Int64? = nil) -> WorkReceipt {
            var receipt = WorkReceipt(kind: .refactor, provider: .claude, startedAt: now.addingTimeInterval(-endedAgo - 25 * 60),
                                      endedAt: now.addingTimeInterval(-endedAgo), rows: rows)
            if let output { receipt.activity = SessionActivity(models: [ModelActivity(model: "m", calls: 1, outputTokens: output)], projects: []) }
            return receipt
        }
        let used = WorkQuotaDelta(id: "quota-0", label: "5시간 한도", percentagePoints: 3)
        XCTAssertEqual(AppStore.lastSessionSegment(receipts: [receipt(endedAgo: 60, rows: [used])], now: now)?.text, "방금 작업 25분 · +3%p")
        let unknown = WorkQuotaDelta(id: "quota-0", label: "5시간 한도", percentagePoints: nil, note: "x")
        XCTAssertEqual(AppStore.lastSessionSegment(receipts: [receipt(endedAgo: 60, rows: [unknown], output: 1_240)], now: now)?.text,
                       "방금 작업 25분 · 출력 1.2K")
        XCTAssertEqual(AppStore.lastSessionSegment(receipts: [receipt(endedAgo: 60, rows: [])], now: now)?.text, "방금 작업 25분")
        XCTAssertNil(AppStore.lastSessionSegment(receipts: [receipt(endedAgo: 11 * 60, rows: [used])], now: now))
        XCTAssertNil(AppStore.lastSessionSegment(receipts: [], now: now))
    }

    func testTransientMissingAccountKeyDoesNotLookLikeAnAccountChange() async {
        let provider = StubProvider(.claude, snapshot: ProviderSnapshot(provider: .claude, accountKey: "account-a", windows: [], source: "test"))
        let store = AppStore(providerOverrides: [.claude: provider], preferences: preferences())
        await store.refresh(.claude, force: true)
        await provider.setSnapshot(ProviderSnapshot(provider: .claude, windows: [], source: "test"))
        await store.refresh(.claude, force: true)
        XCTAssertEqual(store.states[.claude]?.snapshot?.accountKey, "account-a")
    }

    func testFailedCheckIsRetriedWhenThePanelShowsIt() async {
        let provider = StubProvider(.claude)
        let store = AppStore(providerOverrides: [.claude: provider], preferences: preferences())
        await provider.setFailure(.unavailable("Claude had a problem"))
        await store.refresh(.claude, force: true)
        XCTAssertNotNil(store.states[.claude]?.errorMessage)
        let now = Date()
        XCTAssertFalse(store.shouldRetryOnDisplay(.claude, now: now), "an attempt seconds ago is not repeated")
        XCTAssertTrue(store.shouldRetryOnDisplay(.claude, now: now.addingTimeInterval(11)),
                      "opening the panel later retries instead of waiting out the backoff")
        XCTAssertTrue(store.providersDueForRetry(now: now).isEmpty, "still inside the retry wait")
        XCTAssertEqual(store.providersDueForRetry(now: now.addingTimeInterval(301)), [.claude],
                       "the minute poll picks the service up as soon as the wait ends")

        await provider.setFailure(nil)
        await store.refresh(.claude, force: true)
        XCTAssertNil(store.states[.claude]?.errorMessage)
        XCTAssertFalse(store.shouldRetryOnDisplay(.claude, now: now.addingTimeInterval(60)))
        XCTAssertTrue(store.providersDueForRetry(now: now.addingTimeInterval(400)).isEmpty)
    }

    func testRateLimitIsNotRetriedOnDisplay() async {
        let provider = StubProvider(.codex)
        let store = AppStore(providerOverrides: [.codex: provider], preferences: preferences())
        await provider.setFailure(.rateLimited(retryAfter: 600))
        await store.refresh(.codex, force: true)
        XCTAssertFalse(store.shouldRetryOnDisplay(.codex, now: Date().addingTimeInterval(60)))
    }

    func testExpiredAuthenticationKeepsPreviousSnapshotAndClearsAfterRecovery() async {
        let provider = StubProvider(.claude)
        let store = AppStore(providerOverrides: [.claude: provider], preferences: preferences())
        await store.refresh(.claude, force: true)
        let previous = store.states[.claude]?.snapshot
        XCTAssertNotNil(previous)

        await provider.setFailure(.authenticationRequired("Session expired"))
        await store.refresh(.claude, force: true)
        XCTAssertEqual(store.states[.claude]?.snapshot, previous, "Keep existing usage visible as a previous record")
        XCTAssertEqual(store.states[.claude]?.connectionIssue, .authentication)
        XCTAssertEqual(store.connectionStatus(for: .claude), "로그인 확인 필요")
        XCTAssertNotEqual(store.freshness(for: .claude), .current)
        XCTAssertEqual(store.menuTitle(for: .claude), "!", "A signed-out CLI must not show the old value as a percentage")
        XCTAssertFalse(store.menuIsLow(for: .claude))

        await provider.setFailure(nil)
        await store.refresh(.claude, force: true)
        XCTAssertNotEqual(store.menuTitle(for: .claude), "!")
        XCTAssertNil(store.states[.claude]?.connectionIssue)
        XCTAssertNil(store.states[.claude]?.errorMessage)
        XCTAssertFalse(store.states[.claude]?.requiresConnection ?? true)
        XCTAssertEqual(store.connectionStatus(for: .claude), "연결됨")
    }

    func testCodexSetupFailureRetainsOldFullCapacityUntilSuccessfulManualRefresh() async {
        let previous = ProviderSnapshot(provider: .codex, accountKey: "fixture-account", plan: "Pro", windows: [
            UsageWindow(id: "session", label: "5시간 한도", usedPercent: 0,
                        resetsAt: Date().addingTimeInterval(-18 * 3_600), durationMinutes: 300)
        ], fetchedAt: Date().addingTimeInterval(-23 * 3_600), source: "cached-fixture")
        let provider = StubProvider(.codex, snapshot: previous)
        let store = AppStore(providerOverrides: [.codex: provider], preferences: preferences())
        await store.refresh(.codex, force: true)
        XCTAssertEqual(store.states[.codex]?.snapshot, previous)
        XCTAssertEqual(store.freshness(for: .codex), .stale)

        await provider.setFailure(.setupRequired("Unable to verify CLI version"))
        await store.refresh(.codex, force: true)
        XCTAssertEqual(store.states[.codex]?.snapshot, previous, "A setup failure must preserve the last observed value and timestamp")
        XCTAssertEqual(store.primaryWindow(for: .codex)?.remainingPercent, 100)
        XCTAssertEqual(store.freshness(for: .codex), .stale, "Cached full capacity must never be presented as a current reading")
        XCTAssertEqual(store.states[.codex]?.connectionIssue, .setup)
        XCTAssertNotNil(store.states[.codex]?.errorMessage)
        XCTAssertTrue(store.canRefresh(.codex), "Fixing the CLI must permit immediate manual retry")

        let fresh = ProviderSnapshot(provider: .codex, accountKey: "fixture-account", plan: "Pro", windows: [
            UsageWindow(id: "session", label: "5시간 한도", usedPercent: 37,
                        resetsAt: Date().addingTimeInterval(2 * 3_600), durationMinutes: 300)
        ], source: "recovered-fixture")
        await provider.setSnapshot(fresh)
        await provider.setFailure(nil)
        await store.refresh(.codex, force: true)
        XCTAssertEqual(store.states[.codex]?.snapshot, fresh, "A forced retry must replace cached capacity despite automatic backoff")
        XCTAssertEqual(store.primaryWindow(for: .codex)?.remainingPercent, 63)
        XCTAssertEqual(store.freshness(for: .codex), .current)
        XCTAssertNil(store.states[.codex]?.connectionIssue)
        XCTAssertNil(store.states[.codex]?.errorMessage)
        XCTAssertFalse(store.states[.codex]?.requiresConnection ?? true)
        XCTAssertNil(store.retryMessage(for: .codex))
    }

    func testCodexSetupFailureWithoutSnapshotKeepsManualRecoveryAvailable() async {
        let provider = StubProvider(.codex, failure: .setupRequired("Unable to verify CLI version"))
        let store = AppStore(providerOverrides: [.codex: provider], preferences: preferences())
        await store.refresh(.codex, force: true)

        XCTAssertNil(store.states[.codex]?.snapshot)
        XCTAssertEqual(store.freshness(for: .codex), .unavailable)
        XCTAssertEqual(store.states[.codex]?.connectionIssue, .setup)
        XCTAssertNotNil(store.states[.codex]?.errorMessage)
        XCTAssertTrue(store.states[.codex]?.requiresConnection ?? false)
        XCTAssertTrue(store.canRefresh(.codex), "A first-fetch setup error must offer recovery rather than requiring cached usage")
    }

    func testRateLimitCannotBeBypassedByForceOrToggle() async {
        let claude = StubProvider(.claude, failure: .rateLimited(retryAfter: 600))
        let store = AppStore(providerOverrides: [.claude: claude], preferences: preferences())
        await store.refresh(.claude, force: true)
        XCTAssertFalse(store.canRefresh(.claude))
        XCTAssertEqual(store.retryMessage(for: .claude), "약 10분 후 다시 확인할 수 있어요")
        XCTAssertEqual(store.connectionStatus(for: .claude), "요청 제한 · 대기 중")
        store.setProviderEnabled(false, for: .claude)
        store.setProviderEnabled(true, for: .claude)
        await store.refresh(.claude, force: true)
        let calls = await claude.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(store.canRefresh(.claude))
    }

    func testOrdinaryFailureAllowsManualRetry() async {
        let claude = StubProvider(.claude, failure: .unavailable("offline"))
        let store = AppStore(providerOverrides: [.claude: claude], preferences: preferences())
        await store.refresh(.claude, force: true)
        XCTAssertTrue(store.canRefresh(.claude))
        await store.refresh(.claude, force: true)
        let calls = await claude.calls
        XCTAssertEqual(calls, 2)
    }

    func testSavedProviderSettingsRestoreAndInvalidEmptySelectionRecovers() {
        let settings = preferences()
        settings.set(["codex"], forKey: "enabledProviders")
        settings.set("claude", forKey: "selectedProvider")
        settings.set(true, forKey: "showResetCountdown")
        let store = AppStore(providerOverrides: [:], preferences: settings)
        XCTAssertEqual(store.selectedProvider, .codex)
        XCTAssertEqual(store.activeProviders, [.codex])
        XCTAssertTrue(store.showResetCountdown)
        settings.set(["unknown"], forKey: "enabledProviders")
        let recovered = AppStore(providerOverrides: [:], preferences: settings)
        XCTAssertEqual(recovered.activeProviders, [.claude])
        XCTAssertEqual(recovered.selectedProvider, .claude)
    }

    func testMissingPinnedWindowShowsFallbackNoticeUntilDisplayedWindowIsPinned() throws {
        let store = AppStore(demo: true, preferences: preferences())
        store.trackedWindowIDs[.claude] = "missing"
        let displayed = try XCTUnwrap(store.trackedWindow(for: .claude))
        XCTAssertNotEqual(displayed.id, "missing")
        XCTAssertTrue(try XCTUnwrap(store.selectionNotice(for: .claude)).contains(displayed.label))
        XCTAssertEqual(store.trackedWindowIDs[.claude], "missing", "A temporary fallback must preserve the saved pin")
        store.selectWindow(displayed.id, for: .claude)
        XCTAssertEqual(store.trackedWindowIDs[.claude], displayed.id)
        XCTAssertNil(store.selectionNotice(for: .claude))
    }

    func testMenuDisplayOptionsPreserveCompleteAccessibleDescription() throws {
        let store = AppStore(demo: true, preferences: preferences())
        let window = try XCTUnwrap(store.trackedWindow(for: .claude))
        let reset = try XCTUnwrap(window.resetsAt)
        let percentage = Int(window.remainingPercent.rounded())
        let description = store.menuDescription(for: .claude)
        XCTAssertTrue(description.contains("\(percentage)퍼센트 남음"))
        XCTAssertTrue(description.contains(reset.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertTrue(description.contains(window.label))
        for countdown in [false, true, false] {
            store.showResetCountdown = countdown
            let title = store.menuTitle(for: .claude)
            if countdown {
                XCTAssertTrue(title.hasPrefix("\(percentage)% · "))
            } else {
                XCTAssertEqual(title, "\(percentage)%")
            }
            XCTAssertEqual(store.menuDescription(for: .claude), description)
        }
        store.showPercentage = false
        XCTAssertEqual(store.menuTitle(for: .claude), "")
        XCTAssertEqual(store.menuDescription(for: .claude), description)
        XCTAssertFalse(description.contains(" · 남음"))
        let empty = AppStore(providerOverrides: [:], preferences: preferences())
        empty.showPercentage = false
        XCTAssertEqual(empty.menuTitle(for: .claude), "")
        XCTAssertFalse(empty.menuDescription(for: .claude).contains("남음"))
    }
}
