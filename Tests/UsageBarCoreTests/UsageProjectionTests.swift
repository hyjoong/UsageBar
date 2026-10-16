import XCTest
@testable import UsageBarCore

final class UsageProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var reset: Date { now.addingTimeInterval(3 * 3_600) }

    private func window(remaining: Double, resetsAt: Date? = nil, minutes: Int = 300) -> UsageWindow {
        UsageWindow(id: "session", label: "5h", usedPercent: 100 - remaining, resetsAt: resetsAt ?? reset, durationMinutes: minutes)
    }

    private func point(minutesAgo: Double, remaining: Double, resetsAt: Date? = nil, id: String = "session") -> HistoryPoint {
        HistoryPoint(provider: .claude, date: now.addingTimeInterval(-minutesAgo * 60), remaining: remaining,
                     windowName: "5h", windowID: id, resetsAt: resetsAt ?? reset)
    }

    func testFastUseRunsOutBeforeReset() throws {
        // 30 points in the last hour, 20 left: out in 40 minutes, well before the 3-hour reset.
        let projection = try XCTUnwrap(UsageProjection.evaluate(window: window(remaining: 20),
            history: [point(minutesAgo: 90, remaining: 60), point(minutesAgo: 60, remaining: 50), point(minutesAgo: 30, remaining: 35)],
            observedAt: now, now: now))
        XCTAssertEqual(projection.ratePerHour, 30, accuracy: 0.001)
        XCTAssertEqual(projection.outcome, .runsOut(at: now.addingTimeInterval(40 * 60)))
        XCTAssertTrue(projection.shouldWarn(resetsAt: reset, now: now))
    }

    func testSlowUseLastsUntilReset() throws {
        let projection = try XCTUnwrap(UsageProjection.evaluate(window: window(remaining: 70),
            history: [point(minutesAgo: 60, remaining: 75)], observedAt: now, now: now))
        XCTAssertEqual(projection.outcome, .lastsUntilReset)
        XCTAssertFalse(projection.shouldWarn(resetsAt: reset, now: now))
    }

    func testIdleOrRecoveredUsageLasts() throws {
        let idle = try XCTUnwrap(UsageProjection.evaluate(window: window(remaining: 40),
            history: [point(minutesAgo: 120, remaining: 40)], observedAt: now, now: now))
        XCTAssertEqual(idle.outcome, .lastsUntilReset)
        XCTAssertEqual(idle.ratePerHour, 0)
    }

    func testTooShortOrOtherPeriodSamplesAreIgnored() {
        XCTAssertNil(UsageProjection.evaluate(window: window(remaining: 20),
            history: [point(minutesAgo: 10, remaining: 40)], observedAt: now, now: now))
        // A sample from the previous period (different reset) must not count as use.
        XCTAssertNil(UsageProjection.evaluate(window: window(remaining: 20),
            history: [point(minutesAgo: 60, remaining: 90, resetsAt: now.addingTimeInterval(-3_600))], observedAt: now, now: now))
        XCTAssertNil(UsageProjection.evaluate(window: window(remaining: 20),
            history: [point(minutesAgo: 60, remaining: 90, id: "weekly")], observedAt: now, now: now))
    }

    func testLongWindowsAndExhaustedLimitsAreNotProjected() {
        XCTAssertNil(UsageProjection.evaluate(window: window(remaining: 20, minutes: 10_080),
            history: [point(minutesAgo: 60, remaining: 50)], observedAt: now, now: now))
        XCTAssertNil(UsageProjection.evaluate(window: window(remaining: 0),
            history: [point(minutesAgo: 60, remaining: 30)], observedAt: now, now: now))
    }

    func testWarningNeedsNearRunOutClearOfReset() {
        let soon = UsageProjection(outcome: .runsOut(at: now.addingTimeInterval(50 * 60)), ratePerHour: 10, sampledSince: now)
        XCTAssertTrue(soon.shouldWarn(resetsAt: reset, now: now))
        XCTAssertFalse(soon.shouldWarn(resetsAt: now.addingTimeInterval(55 * 60), now: now))
        let later = UsageProjection(outcome: .runsOut(at: now.addingTimeInterval(2 * 3_600)), ratePerHour: 10, sampledSince: now)
        XCTAssertFalse(later.shouldWarn(resetsAt: reset, now: now))
    }
}
