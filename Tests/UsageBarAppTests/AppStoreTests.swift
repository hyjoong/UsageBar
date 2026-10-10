import XCTest
import Combine
@testable import UsageBar
import UsageBarCore

private actor StubProvider: UsageProvider {
    nonisolated let id: ProviderID
    private(set) var calls = 0
    let failure: ProviderError?
    init(_ id: ProviderID, failure: ProviderError? = nil) { self.id = id; self.failure = failure }
    func fetch() async throws -> ProviderSnapshot {
        calls += 1
        if let failure { throw failure }
        return ProviderSnapshot(provider: id, windows: [], source: "test")
    }
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
