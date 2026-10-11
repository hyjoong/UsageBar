import Foundation
import XCTest
@testable import UsageBarCore

final class QuotaAlertPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRelativeResetJitterDoesNotSuppressThresholdCrossing() throws {
        let reset = now.addingTimeInterval(3_600)
        let previous = QuotaAlertState(remaining: 21, periodResetAt: reset)
        let result = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: previous, remaining: 19,
            resetsAt: reset.addingTimeInterval(37), observedAt: now.addingTimeInterval(300)))
        XCTAssertTrue(result.shouldNotify)
        XCTAssertEqual(result.state.periodResetAt, reset)
    }

    func testRelativeResetJitterDoesNotRearmDeliveredAlert() throws {
        let reset = now.addingTimeInterval(3_600)
        let previous = QuotaAlertState(remaining: 19, periodResetAt: reset, hasNotified: true)
        let next = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: previous, remaining: 18,
            resetsAt: reset.addingTimeInterval(-28), observedAt: now.addingTimeInterval(300)))
        XCTAssertFalse(next.shouldNotify)
        XCTAssertTrue(next.state.hasNotified)
        XCTAssertEqual(next.state.periodResetAt, reset)
    }

    func testRepeatedCrossingWithinSameKnownPeriodDoesNotNotifyTwice() throws {
        let reset = now.addingTimeInterval(3_600)
        let notified = QuotaAlertState(remaining: 19, periodResetAt: reset, hasNotified: true)
        let rise = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: notified, remaining: 21,
            resetsAt: reset.addingTimeInterval(40), observedAt: now.addingTimeInterval(300)))
        let fall = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: rise.state, remaining: 19,
            resetsAt: reset.addingTimeInterval(10), observedAt: now.addingTimeInterval(600)))
        XCTAssertFalse(fall.shouldNotify)
        XCTAssertTrue(fall.state.hasNotified)
    }

    func testActualPeriodRolloverRearmsForNextCrossing() throws {
        let expiredReset = now.addingTimeInterval(-60)
        let nextReset = now.addingTimeInterval(5 * 3_600)
        let notified = QuotaAlertState(remaining: 10, periodResetAt: expiredReset, hasNotified: true)
        let renewed = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: notified, remaining: 95,
            resetsAt: nextReset, observedAt: now))
        XCTAssertFalse(renewed.state.hasNotified)
        let fall = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: renewed.state, remaining: 20,
            resetsAt: nextReset.addingTimeInterval(20), observedAt: now.addingTimeInterval(300)))
        XCTAssertTrue(fall.shouldNotify)
    }

    func testEarlyResetRequiresCapacityRecoveryToRearm() throws {
        let reset = now.addingTimeInterval(3_600)
        let notified = QuotaAlertState(remaining: 10, periodResetAt: reset, hasNotified: true)
        let shifted = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: notified, remaining: 9,
            resetsAt: reset.addingTimeInterval(3_600), observedAt: now))
        XCTAssertTrue(shifted.state.hasNotified)
        let recovered = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: notified, remaining: 90,
            resetsAt: reset.addingTimeInterval(3_600), observedAt: now))
        XCTAssertFalse(recovered.state.hasNotified)
    }

    func testMissingResetClockRearmsOnlyAfterCapacityRecovery() throws {
        let notified = QuotaAlertState(remaining: 10, periodResetAt: nil, hasNotified: true)
        let recovered = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: notified, remaining: 90,
            resetsAt: nil, observedAt: now))
        let fall = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: recovered.state, remaining: 19,
            resetsAt: nil, observedAt: now.addingTimeInterval(300)))
        XCTAssertTrue(fall.shouldNotify)
    }

    func testFirstObservationAndInvalidValuesDoNotTriggerAlert() throws {
        let first = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: nil, remaining: 10,
            resetsAt: nil, observedAt: now))
        XCTAssertFalse(first.shouldNotify)
        XCTAssertNil(QuotaAlertPolicy.evaluate(previous: first.state, remaining: .nan,
            resetsAt: nil, observedAt: now))
    }

    func testRecoveryNotifiesWhenLowLimitRollsOverToNewPeriod() throws {
        let expiredReset = now.addingTimeInterval(-60)
        let nextReset = now.addingTimeInterval(5 * 3_600)
        let low = QuotaAlertState(remaining: 12, periodResetAt: expiredReset, hasNotified: true)
        let result = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: low, remaining: 100,
            resetsAt: nextReset, observedAt: now))
        XCTAssertTrue(result.shouldNotifyRecovery)
        XCTAssertFalse(result.shouldNotify)
        XCTAssertFalse(result.state.hasNotified)
    }

    func testRecoveryStaysQuietWhenLimitWasNotLow() throws {
        let expiredReset = now.addingTimeInterval(-60)
        let fine = QuotaAlertState(remaining: 64, periodResetAt: expiredReset)
        let result = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: fine, remaining: 100,
            resetsAt: now.addingTimeInterval(5 * 3_600), observedAt: now))
        XCTAssertFalse(result.shouldNotifyRecovery)
    }

    func testRecoveryIgnoresResetJitterWithinSamePeriod() throws {
        let reset = now.addingTimeInterval(3_600)
        let low = QuotaAlertState(remaining: 15, periodResetAt: reset, hasNotified: true)
        let result = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: low, remaining: 16,
            resetsAt: reset.addingTimeInterval(45), observedAt: now.addingTimeInterval(300)))
        XCTAssertFalse(result.shouldNotifyRecovery)
    }

    func testRecoveryWithoutClockNotifiesOnceCapacityReturns() throws {
        let low = QuotaAlertState(remaining: 5, periodResetAt: nil, hasNotified: true)
        let result = try XCTUnwrap(QuotaAlertPolicy.evaluate(previous: low, remaining: 97,
            resetsAt: nil, observedAt: now))
        XCTAssertTrue(result.shouldNotifyRecovery)
    }
}
