import XCTest
@testable import UsageBarCore

final class WorkReminderPlanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshSessionGetsCheckInAndResetWarning() {
        let reset = start.addingTimeInterval(3 * 3_600)
        let plan = WorkReminderPlan.reminders(startedAt: start, resetsAt: reset, now: start)
        XCTAssertEqual(plan.map(\.kind), [.checkIn, .beforeReset])
        XCTAssertEqual(plan[0].fireAt, start.addingTimeInterval(2 * 3_600))
        XCTAssertEqual(plan[1].fireAt, reset.addingTimeInterval(-10 * 60))
    }

    func testWithoutResetOnlyCheckIn() {
        let plan = WorkReminderPlan.reminders(startedAt: start, resetsAt: nil, now: start)
        XCTAssertEqual(plan.map(\.kind), [.checkIn])
    }

    func testRestoredOldSessionSkipsPastCheckIn() {
        let now = start.addingTimeInterval(3 * 3_600)
        let reset = now.addingTimeInterval(30 * 60)
        let plan = WorkReminderPlan.reminders(startedAt: start, resetsAt: reset, now: now)
        XCTAssertEqual(plan.map(\.kind), [.beforeReset])
    }

    func testResetTooCloseIsNotScheduled() {
        let reset = start.addingTimeInterval(10 * 60 + 30)
        let plan = WorkReminderPlan.reminders(startedAt: start, resetsAt: reset, now: start)
        XCTAssertEqual(plan.map(\.kind), [.checkIn])
    }

    func testResetWarningBeforeStartIsIgnored() {
        let plan = WorkReminderPlan.reminders(startedAt: start, resetsAt: start.addingTimeInterval(5 * 60), now: start)
        XCTAssertEqual(plan.map(\.kind), [.checkIn])
    }
}
