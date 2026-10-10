import XCTest
@testable import UsageBarCore

final class UsagePresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshnessDoesNotCallMissingOrOldDataCurrent() {
        XCTAssertEqual(UsageFreshness.evaluate(snapshot: nil, now: now), .unavailable)
        XCTAssertEqual(UsageFreshness.evaluate(snapshot: snapshot(age: 600), now: now), .current)
        XCTAssertEqual(UsageFreshness.evaluate(snapshot: snapshot(age: 601), now: now), .stale)
        XCTAssertEqual(UsageFreshness.evaluate(snapshot: snapshot(age: -61), now: now), .stale)
        XCTAssertEqual(UsageFreshness.evaluate(snapshot: snapshot(age: 0), hasError: true, now: now), .stale)
    }

    func testResetDueIsNotPresentedAsFreshCapacity() {
        let window = UsageWindow(id: "session", label: "세션", usedPercent: 90, resetsAt: now)
        XCTAssertEqual(UsageFreshness.evaluate(snapshot: snapshot(age: 5, windows: [window]), now: now), .resetDue)
    }

    func testSavedWindowAndFallbackAreIndependentOfResponseOrder() {
        let weekly = UsageWindow(id: "weekly", label: "주간", usedPercent: 10, resetsAt: nil, durationMinutes: 10_080)
        let session = UsageWindow(id: "session", label: "세션", usedPercent: 0, resetsAt: nil, durationMinutes: 300)
        for windows in [[weekly, session], [session, weekly]] {
            XCTAssertEqual(UsageWindowSelection.select(from: windows, preferredID: nil)?.id, "session")
            XCTAssertEqual(UsageWindowSelection.select(from: windows, preferredID: "weekly")?.id, "weekly")
            XCTAssertEqual(UsageWindowSelection.select(from: windows, preferredID: "removed")?.id, "session")
        }
    }

    func testInvalidWindowCannotBePinnedOrBecomeDefault() {
        let invalid = UsageWindow(id: "invalid", label: "잘못된 값", usedPercent: .nan, resetsAt: nil, durationMinutes: 1)
        let valid = UsageWindow(id: "valid", label: "한도", usedPercent: 100, resetsAt: nil)
        XCTAssertEqual(UsageWindowSelection.select(from: [invalid, valid], preferredID: "invalid")?.id, "valid")
        XCTAssertNil(UsageWindowSelection.select(from: [invalid], preferredID: nil))
    }

    private func snapshot(age: TimeInterval, windows: [UsageWindow] = []) -> ProviderSnapshot {
        ProviderSnapshot(provider: .claude, windows: windows, fetchedAt: now.addingTimeInterval(-age), source: "test")
    }
}
