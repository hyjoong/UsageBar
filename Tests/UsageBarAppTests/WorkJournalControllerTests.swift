import XCTest
@testable import UsageBar
import UsageBarCore

@MainActor
private final class WorkJournalFetchGate {
    private(set) var providers: [ProviderID] = []
    private var continuation: CheckedContinuation<ProviderSnapshot, Error>?
    var onFetch: (() -> Void)?

    func fetch(_ provider: ProviderID) async throws -> ProviderSnapshot {
        providers.append(provider)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onFetch?()
        }
    }

    func complete(_ snapshot: ProviderSnapshot) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: snapshot)
    }
}

@MainActor
final class WorkJournalControllerTests: XCTestCase {
    private func snapshot(_ provider: ProviderID = .claude, used: Double = 10,
                          reset: Date = Date().addingTimeInterval(3_600)) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, accountKey: "known-test-account", windows: [
            UsageWindow(id: "session", label: "5시간 한도", usedPercent: used,
                        resetsAt: reset, durationMinutes: 300)
        ], source: "controller-test")
    }

    func testDuplicateStartWhileSnapshotIsPendingIsIgnored() async throws {
        let controller = WorkJournalController(usesPersistence: false)
        await controller.load()
        let gate = WorkJournalFetchGate()
        let started = expectation(description: "Start snapshot requested")
        gate.onFetch = { started.fulfill() }
        let kind = try XCTUnwrap(WorkKind.allCases.first)
        let task = Task { await controller.start(kind: kind, provider: .claude, fetch: gate.fetch) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.isBusy)

        await controller.start(kind: kind, provider: .codex, fetch: gate.fetch)
        XCTAssertEqual(gate.providers, [.claude])
        gate.complete(snapshot())
        await task.value

        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.state.active?.provider, .claude)
        XCTAssertTrue(controller.state.receipts.isEmpty)
    }

    func testDuplicateFinishProducesOnlyOneReceiptAndUsesOriginalProvider() async throws {
        let controller = WorkJournalController(usesPersistence: false)
        await controller.load()
        let kind = try XCTUnwrap(WorkKind.allCases.first)
        let reset = Date().addingTimeInterval(3_600)
        await controller.start(kind: kind, provider: .claude) { provider in
            self.snapshot(provider, reset: reset)
        }
        XCTAssertNotNil(controller.state.active)
        let gate = WorkJournalFetchGate()
        let started = expectation(description: "Finish snapshot requested")
        gate.onFetch = { started.fulfill() }
        let task = Task { await controller.finish(fetch: gate.fetch) }
        await fulfillment(of: [started], timeout: 2)

        await controller.finish(fetch: gate.fetch)
        XCTAssertEqual(gate.providers, [.claude])
        gate.complete(snapshot(used: 22, reset: reset))
        await task.value

        XCTAssertNil(controller.state.active)
        XCTAssertEqual(controller.state.receipts.count, 1)
        XCTAssertEqual(controller.state.receipts.first?.provider, .claude)
        XCTAssertEqual(controller.state.receipts.first?.rows.first?.percentagePoints, 12)
        XCTAssertEqual(controller.recentCompletion?.id, controller.state.receipts.first?.id)
        XCTAssertFalse(controller.isBusy)
    }

    func testFailedFinishRetainsActiveUntilExplicitFinishWithoutSnapshot() async throws {
        let controller = WorkJournalController(usesPersistence: false)
        await controller.load()
        let kind = try XCTUnwrap(WorkKind.allCases.first)
        await controller.start(kind: kind, provider: .codex) { provider in self.snapshot(provider) }
        let activeID = try XCTUnwrap(controller.state.active?.id)
        var requestedProvider: ProviderID?
        await controller.finish { provider in
            requestedProvider = provider
            throw ProviderError.unavailable("offline")
        }

        XCTAssertEqual(requestedProvider, .codex)
        XCTAssertEqual(controller.state.active?.id, activeID)
        XCTAssertTrue(controller.state.receipts.isEmpty)
        XCTAssertNotNil(controller.message)
        XCTAssertNil(controller.recentCompletion)
        XCTAssertFalse(controller.isBusy)

        await controller.finishWithoutSnapshot()
        XCTAssertNil(controller.state.active)
        let receipt = try XCTUnwrap(controller.state.receipts.first)
        XCTAssertEqual(receipt.provider, .codex)
        XCTAssertTrue(receipt.rows.allSatisfy { $0.percentagePoints == nil },
                      "Failed endpoint measurements must never become numeric usage claims")
        XCTAssertEqual(controller.recentCompletion?.id, receipt.id)
    }

    func testFailedStartDoesNotCreateAnActiveSessionOrReceipt() async throws {
        let controller = WorkJournalController(usesPersistence: false)
        await controller.load()
        let kind = try XCTUnwrap(WorkKind.allCases.first)
        await controller.start(kind: kind, provider: .claude) { _ in
            throw ProviderError.rateLimited(retryAfter: 300)
        }
        XCTAssertNil(controller.state.active)
        XCTAssertTrue(controller.state.receipts.isEmpty)
        XCTAssertNotNil(controller.message)
        XCTAssertFalse(controller.isBusy)
    }

    func testActiveSessionRestoresAcrossControllerInstances() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/UsageBar-WorkController-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WorkJournalController(persistence: WorkJournalStore(directory: directory))
        await first.load()
        let kind = try XCTUnwrap(WorkKind.allCases.first)
        await first.start(kind: kind, provider: .claude) { provider in self.snapshot(provider) }
        let active = try XCTUnwrap(first.state.active, first.message ?? "No active session after start")

        let restored = WorkJournalController(persistence: WorkJournalStore(directory: directory))
        await restored.load()
        XCTAssertTrue(restored.isLoaded)
        XCTAssertEqual(restored.state.active, active)
        XCTAssertTrue(restored.state.receipts.isEmpty)
        XCTAssertNil(restored.recentCompletion)

        await restored.finishWithoutSnapshot()
        let third = WorkJournalController(persistence: WorkJournalStore(directory: directory))
        await third.load()
        XCTAssertNil(third.state.active)
        XCTAssertEqual(third.state.receipts.count, 1)
        XCTAssertEqual(third.state.receipts.first?.id, active.id)
        XCTAssertTrue(third.state.receipts.first?.rows.allSatisfy { $0.percentagePoints == nil } ?? false)
        XCTAssertNil(third.recentCompletion, "Loading old receipts must not replay a completion panel")
    }

    func testDemoHistoryDoesNotShowARecentCompletionAtLaunch() {
        let controller = WorkJournalController(demo: true)
        XCTAssertFalse(controller.state.receipts.isEmpty)
        XCTAssertNil(controller.recentCompletion)
    }

    func testDismissPreservesHistoryAndSuccessfulStartClearsRecentCompletion() async throws {
        let controller = WorkJournalController(usesPersistence: false)
        await controller.start(kind: .refactor, provider: .claude) { self.snapshot($0) }
        await controller.finishWithoutSnapshot()
        let first = try XCTUnwrap(controller.recentCompletion)

        controller.dismissRecentCompletion()
        XCTAssertNil(controller.recentCompletion)
        XCTAssertEqual(controller.state.receipts.map(\.id), [first.id])

        await controller.start(kind: .debug, provider: .codex) { self.snapshot($0) }
        await controller.finishWithoutSnapshot()
        let second = try XCTUnwrap(controller.recentCompletion)
        XCTAssertNotEqual(first.id, second.id)
        await controller.deleteReceipt(first.id)
        XCTAssertEqual(controller.recentCompletion?.id, second.id,
                       "Deleting another historical receipt must not dismiss the current completion")

        await controller.start(kind: .review, provider: .claude) { self.snapshot($0) }
        XCTAssertNil(controller.recentCompletion)
        XCTAssertEqual(controller.state.active?.kind, .review)
        XCTAssertEqual(controller.state.receipts.map(\.id), [second.id])
    }

    func testFailedSaveRetainsActiveWithoutShowingCompletionUntilRecovery() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/UsageBar-WorkSaveFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WorkJournalController(persistence: WorkJournalStore(directory: directory))
        await controller.load()
        await controller.start(kind: .build, provider: .claude) { self.snapshot($0) }
        let activeID = try XCTUnwrap(controller.state.active?.id)
        let archive = directory.appendingPathComponent("work-journal.json")
        let intact = try Data(contentsOf: archive)
        let corrupt = Data("invalid archive".utf8)
        try corrupt.write(to: archive)

        await controller.finish { self.snapshot($0, used: 20) }
        XCTAssertEqual(controller.state.active?.id, activeID)
        XCTAssertTrue(controller.state.receipts.isEmpty)
        XCTAssertNil(controller.recentCompletion)
        XCTAssertTrue(controller.message?.contains("저장하지 못했어요") ?? false)
        XCTAssertEqual(try Data(contentsOf: archive), corrupt)

        await controller.finishWithoutSnapshot()
        XCTAssertEqual(controller.state.active?.id, activeID)
        XCTAssertNil(controller.recentCompletion)

        try intact.write(to: archive)
        await controller.finishWithoutSnapshot()
        XCTAssertNil(controller.state.active)
        XCTAssertEqual(controller.recentCompletion?.id, activeID)
        XCTAssertEqual(controller.state.receipts.count, 1)
    }

    func testFailedDeleteKeepsCompletionUntilReceiptIsActuallyDeleted() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/UsageBar-WorkDeleteFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WorkJournalController(persistence: WorkJournalStore(directory: directory))
        await controller.load()
        await controller.start(kind: .build, provider: .claude) { self.snapshot($0) }
        await controller.finishWithoutSnapshot()
        let receiptID = try XCTUnwrap(controller.recentCompletion?.id)
        let archive = directory.appendingPathComponent("work-journal.json")
        let intact = try Data(contentsOf: archive)
        try Data("invalid archive".utf8).write(to: archive)

        await controller.deleteReceipt(receiptID)
        XCTAssertEqual(controller.recentCompletion?.id, receiptID)
        XCTAssertEqual(controller.state.receipts.count, 1)
        XCTAssertNotNil(controller.message)

        try intact.write(to: archive)
        await controller.deleteReceipt(receiptID)
        XCTAssertNil(controller.recentCompletion)
        XCTAssertTrue(controller.state.receipts.isEmpty)
    }
}

private actor WorkBoundarySequenceProvider: UsageProvider {
    nonisolated let id: ProviderID = .claude
    private(set) var calls = 0
    private var results: [Result<ProviderSnapshot, ProviderError>]
    init(_ results: [Result<ProviderSnapshot, ProviderError>]) { self.results = results }
    func fetch() async throws -> ProviderSnapshot {
        calls += 1
        guard !results.isEmpty else { throw ProviderError.unavailable("unexpected request") }
        return try results.removeFirst().get()
    }
}

private actor WorkBoundarySuspendedProvider: UsageProvider {
    nonisolated let id: ProviderID = .claude
    private(set) var calls = 0
    private var continuation: CheckedContinuation<ProviderSnapshot, Error>?
    private let onFetch: @Sendable () -> Void
    init(onFetch: @escaping @Sendable () -> Void) { self.onFetch = onFetch }
    func fetch() async throws -> ProviderSnapshot {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onFetch()
        }
    }
    func complete(_ snapshot: ProviderSnapshot) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: snapshot)
    }
}

@MainActor
final class AppStoreWorkBoundaryTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let suite = "UsageBar.WorkBoundaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func snapshot(source: String) -> ProviderSnapshot {
        ProviderSnapshot(provider: .claude, accountKey: "test", windows: [
            UsageWindow(id: "session", label: "5시간 한도", usedPercent: 10,
                        resetsAt: Date().addingTimeInterval(3_600), durationMinutes: 300)
        ], source: source)
    }

    func testWorkBoundaryJoinsAnInflightSuccessfulRefresh() async throws {
        let fetched = expectation(description: "Provider request is suspended")
        let provider = WorkBoundarySuspendedProvider { fetched.fulfill() }
        let store = AppStore(providerOverrides: [.claude: provider], preferences: preferences())
        defer { store.stop() }
        let refresh = Task { await store.refresh(.claude, force: true) }
        await fulfillment(of: [fetched], timeout: 2)
        let joined = expectation(description: "Boundary joins the request")
        let boundary = Task {
            joined.fulfill()
            return try await store.workSnapshot(for: .claude)
        }
        await fulfillment(of: [joined], timeout: 2)
        let fresh = snapshot(source: "fresh-inflight")
        await provider.complete(fresh)
        let result = try await boundary.value
        await refresh.value
        XCTAssertEqual(result, fresh)
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
    }

    func testRateLimitedBoundaryRejectsCachedSnapshotWithoutAnotherRequest() async {
        let cached = snapshot(source: "cached-before-rate-limit")
        let provider = WorkBoundarySequenceProvider([
            .success(cached), .failure(.rateLimited(retryAfter: 600))
        ])
        let store = AppStore(providerOverrides: [.claude: provider], preferences: preferences())
        defer { store.stop() }
        await store.refresh(.claude, force: true)
        await store.refresh(.claude, force: true)
        do {
            _ = try await store.workSnapshot(for: .claude)
            XCTFail("A rate-limited work boundary must not reuse the cached value")
        } catch { }
        XCTAssertEqual(store.states[.claude]?.snapshot, cached)
        let calls = await provider.calls
        XCTAssertEqual(calls, 2)
    }

    func testFailedBoundaryRefreshDoesNotReturnPreviousSuccessfulSnapshot() async {
        let cached = snapshot(source: "old-success")
        let provider = WorkBoundarySequenceProvider([
            .success(cached), .failure(.unavailable("offline"))
        ])
        let store = AppStore(providerOverrides: [.claude: provider], preferences: preferences())
        defer { store.stop() }
        await store.refresh(.claude, force: true)
        do {
            _ = try await store.workSnapshot(for: .claude)
            XCTFail("A failed endpoint measurement must reject the earlier snapshot")
        } catch { }
        XCTAssertEqual(store.states[.claude]?.snapshot, cached)
        let calls = await provider.calls
        XCTAssertEqual(calls, 2)
    }
}
