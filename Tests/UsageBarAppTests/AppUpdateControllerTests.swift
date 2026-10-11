import Foundation
import XCTest
@testable import UsageBar
import UsageBarCore

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testIdleJournalDoesNotPostponeOrInvokeInstallHandler() async {
        let journal = WorkJournalController(usesPersistence: false)
        let updater = AppUpdateController(demo: true, journal: journal)
        var installCalls = 0
        XCTAssertFalse(updater.postponeRelaunchIfNeeded { installCalls += 1 })
        await drainMainRunLoop()
        XCTAssertEqual(installCalls, 0, "Sparkle owns immediate installation when postponement returns false")
        XCTAssertFalse(updater.canCheckForUpdates, "This test must not start a real updater")
    }

    func testQueuedIdlePublicationCannotInstallDuringTheNextJournalOperation() async throws {
        let journal = WorkJournalController(usesPersistence: false)
        let updater = AppUpdateController(demo: true, journal: journal)
        let startSuspended = expectation(description: "Start is waiting for its boundary snapshot")
        let finishSuspended = expectation(description: "Next operation is busy before the run loop is drained")
        let gate = UpdateJournalFetchGate { call in
            if call == 1 { startSuspended.fulfill() }
            if call == 2 { finishSuspended.fulfill() }
        }
        addTeardownBlock { await gate.cancelPending() }

        // Both calls execute in one main-actor task. When start returns it publishes
        // false, then finish publishes true before this task suspends on the next gate.
        let operations = Task { @MainActor in
            await journal.start(kind: .build, provider: .claude, fetch: gate.fetch)
            await journal.finish(fetch: gate.fetch)
        }
        await fulfillment(of: [startSuspended], timeout: 2)
        XCTAssertTrue(journal.isBusy)
        let installed = expectation(description: "Installation resumes after the final operation")
        var installCalls = 0
        XCTAssertTrue(updater.postponeRelaunchIfNeeded {
            installCalls += 1
            XCTAssertFalse(journal.isBusy, "A queued false value must not override the current busy state")
            if installCalls == 1 { installed.fulfill() }
        })
        XCTAssertEqual(installCalls, 0)

        let reset = Date().addingTimeInterval(3_600)
        gate.complete(1, with: snapshot(used: 10, reset: reset))
        await fulfillment(of: [finishSuspended], timeout: 2)
        XCTAssertTrue(journal.isBusy)
        await drainMainRunLoop()
        XCTAssertEqual(installCalls, 0, "The queued start-completion event must not trigger installation during finish")

        gate.complete(2, with: snapshot(used: 12, reset: reset))
        await operations.value
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(installCalls, 1)
        XCTAssertFalse(journal.isBusy)
        XCTAssertNil(journal.state.active)
        XCTAssertEqual(journal.state.receipts.count, 1)

        // The observer must be cancelled before invoking the installer. Later
        // transitions must not resume the same installation a second time.
        await journal.start(kind: .review, provider: .claude) { _ in self.snapshot(used: 12, reset: reset) }
        await journal.discard()
        await drainMainRunLoop()
        XCTAssertEqual(installCalls, 1)
    }

    private func drainMainRunLoop() async {
        let drained = expectation(description: "Previously queued main run-loop callbacks drained")
        RunLoop.main.perform { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    private func snapshot(used: Double, reset: Date) -> ProviderSnapshot {
        ProviderSnapshot(provider: .claude, accountKey: "update-fixture-account", windows: [
            UsageWindow(id: "session", label: "세션", usedPercent: used, resetsAt: reset, durationMinutes: 300)
        ], source: "updater-unit-test")
    }
}

@MainActor
private final class UpdateJournalFetchGate {
    private var calls = 0
    private var pending: [Int: CheckedContinuation<ProviderSnapshot, Error>] = [:]
    private let onFetch: (Int) -> Void

    init(onFetch: @escaping (Int) -> Void) { self.onFetch = onFetch }

    func fetch(_ provider: ProviderID) async throws -> ProviderSnapshot {
        calls += 1
        let call = calls
        guard call <= 2 else { throw ProviderError.unavailable("Unexpected boundary request") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
            onFetch(call)
        }
    }

    func complete(_ call: Int, with snapshot: ProviderSnapshot) {
        pending.removeValue(forKey: call)?.resume(returning: snapshot)
    }

    func cancelPending() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}
