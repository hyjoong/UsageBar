import XCTest
@testable import UsageBarCore

final class UsagePresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMenuTitleCanIncludeResetWithoutChangingPercentageOnlyMode() {
        let window = UsageWindow(id: "session", label: "세션", usedPercent: 38,
                                 resetsAt: now.addingTimeInterval(7_800))
        XCTAssertEqual(UsageMenuBarFormatter.title(for: window, includeReset: true, now: now), "62% · 2h 10m")
        XCTAssertEqual(UsageMenuBarFormatter.title(for: window, includeReset: false, now: now), "62%")
        XCTAssertEqual(UsageMenuBarFormatter.title(for: window, includeReset: true,
                                                 now: now.addingTimeInterval(60)), "62% · 2h 9m")
    }

    func testResetCountdownMinuteHourAndDayBoundaries() {
        let cases: [(TimeInterval, String)] = [
            (-1, "↻"), (0, "↻"), (0.1, "<1m"), (59.999, "<1m"),
            (60, "1m"), (119.999, "1m"), (120, "2m"),
            (3_599, "59m"), (3_600, "1h"), (3_660, "1h 1m"),
            (86_399, "23h 59m"), (86_400, "1d"), (90_000, "1d 1h"),
            (183_600, "2d 3h")
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(UsageMenuBarFormatter.resetCountdown(until: now.addingTimeInterval(seconds), now: now),
                           expected, "Remaining seconds: \(seconds)")
        }
    }

    func testResetDueRetainsObservedPercentageAndNeverAssumesFullCapacity() {
        let window = UsageWindow(id: "session", label: "세션", usedPercent: 100, resetsAt: now)
        XCTAssertEqual(UsageMenuBarFormatter.title(for: window, includeReset: true, now: now), "0% · ↻")
    }

    func testMissingOrInvalidResetFallsBackToPercentage() {
        for reset in [nil, Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
                      Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)] as [Date?] {
            let window = UsageWindow(id: "session", label: "세션", usedPercent: 37.6, resetsAt: reset)
            XCTAssertEqual(UsageMenuBarFormatter.title(for: window, includeReset: true, now: now), "62%")
        }
        XCTAssertNil(UsageMenuBarFormatter.resetCountdown(until: now, now: Date(timeIntervalSince1970: .nan)))
    }

    func testMissingOrInvalidUsageDoesNotProduceNumericMenuTitle() {
        XCTAssertEqual(UsageMenuBarFormatter.title(for: nil, includeReset: true, now: now), "—")
        for used in [Double.nan, .infinity, -.infinity, -1, 101] {
            let window = UsageWindow(id: "invalid", label: "잘못된 값", usedPercent: used,
                                     resetsAt: now.addingTimeInterval(60))
            XCTAssertEqual(UsageMenuBarFormatter.title(for: window, includeReset: true, now: now), "—")
        }
    }

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
