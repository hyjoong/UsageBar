import Foundation
import XCTest
@testable import UsageBarCore

final class UsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(used: Double = 50, durationMinutes: Int? = 60, resetOffset: TimeInterval? = 1_800) -> UsageWindow {
        UsageWindow(id: "test", label: "Test", usedPercent: used,
                    resetsAt: resetOffset.map { now.addingTimeInterval($0) }, durationMinutes: durationMinutes)
    }

    func testComparisonUsesObservationTimeWithoutAdvancingRecordedUsage() throws {
        let result = try XCTUnwrap(UsagePace.evaluate(window: window(used: 60), observedAt: now, now: now.addingTimeInterval(300)))
        XCTAssertEqual(result.elapsedPercent, 50, accuracy: 0.000_001)
        XCTAssertEqual(result.usedPercent, 60)
        XCTAssertEqual(result.difference, 10, accuracy: 0.000_001)
        XCTAssertEqual(result.position, .ahead)
    }

    func testFivePercentagePointToleranceIsInclusive() throws {
        let cases: [(Double, UsagePace.Position)] = [
            (44.999, .behind), (45, .onTrack), (50, .onTrack), (55, .onTrack), (55.001, .ahead)
        ]
        for (used, expected) in cases {
            let result = try XCTUnwrap(UsagePace.evaluate(window: window(used: used), observedAt: now, now: now))
            XCTAssertEqual(result.position, expected, "Used: \(used)")
        }
    }

    func testZeroAndFullUsageAreValidAtWindowStart() throws {
        for used in [0.0, 100.0] {
            let result = try XCTUnwrap(UsagePace.evaluate(window: window(used: used, resetOffset: 3_600), observedAt: now, now: now))
            XCTAssertEqual(result.elapsedPercent, 0)
            XCTAssertEqual(result.usedPercent, used)
            XCTAssertEqual(result.difference, used)
            XCTAssertEqual(result.position, used == 0 ? .onTrack : .ahead)
        }
    }

    func testMissingDurationOrResetCannotBeCompared() {
        XCTAssertNil(UsagePace.evaluate(window: window(durationMinutes: nil), observedAt: now, now: now))
        XCTAssertNil(UsagePace.evaluate(window: window(resetOffset: nil), observedAt: now, now: now))
    }

    func testInvalidOrUnboundedDurationsCannotBeCompared() {
        for minutes in [-1, 0, 527_041, Int.max] {
            XCTAssertNil(UsagePace.evaluate(window: window(durationMinutes: minutes), observedAt: now, now: now))
        }
        XCTAssertNotNil(UsagePace.evaluate(window: window(durationMinutes: 527_040), observedAt: now, now: now))
    }

    func testUsageMustBeFiniteAndWithinPercentageBounds() {
        for used in [Double.nan, .infinity, -.infinity, -0.001, 100.001] {
            XCTAssertNil(UsagePace.evaluate(window: window(used: used), observedAt: now, now: now))
        }
    }

    func testObservationExpiresAfterTenMinutes() {
        XCTAssertNotNil(UsagePace.evaluate(window: window(), observedAt: now.addingTimeInterval(-600), now: now))
        XCTAssertNil(UsagePace.evaluate(window: window(), observedAt: now.addingTimeInterval(-600.001), now: now))
    }

    func testObservationAllowsAtMostOneMinuteOfFutureClockSkew() {
        XCTAssertNotNil(UsagePace.evaluate(window: window(), observedAt: now.addingTimeInterval(60), now: now))
        XCTAssertNil(UsagePace.evaluate(window: window(), observedAt: now.addingTimeInterval(60.001), now: now))
    }

    func testResetMustStillBeAheadOfCurrentAndObservationTimes() {
        for offset in [-1.0, 0] {
            XCTAssertNil(UsagePace.evaluate(window: window(resetOffset: offset), observedAt: now.addingTimeInterval(-30), now: now))
        }
        XCTAssertNil(UsagePace.evaluate(window: window(resetOffset: 30), observedAt: now.addingTimeInterval(30), now: now))
        XCTAssertNil(UsagePace.evaluate(window: window(resetOffset: 20), observedAt: now.addingTimeInterval(30), now: now))
    }

    func testResetBeyondWindowDurationOnlyAllowsOneMinuteOfRounding() throws {
        let result = try XCTUnwrap(UsagePace.evaluate(window: window(resetOffset: 3_660), observedAt: now, now: now))
        XCTAssertEqual(result.elapsedPercent, 0)
        XCTAssertNil(UsagePace.evaluate(window: window(resetOffset: 3_660.001), observedAt: now, now: now))
    }

    func testWindowStartMustAlsoBeNearCurrentTimeWhenObservationIsInFuture() {
        XCTAssertNil(UsagePace.evaluate(window: window(resetOffset: 3_690), observedAt: now.addingTimeInterval(60), now: now))
    }

    func testWindowStartMustBeNearObservationEvenWhenCurrentTimeIsInsideWindow() {
        XCTAssertNil(UsagePace.evaluate(window: window(resetOffset: 3_600), observedAt: now.addingTimeInterval(-61), now: now))
    }

    func testNonFiniteTimestampsCannotBeCompared() {
        for seconds in [Double.nan, .infinity, -.infinity] {
            let invalidDate = Date(timeIntervalSince1970: seconds)
            XCTAssertNil(UsagePace.evaluate(window: window(), observedAt: invalidDate, now: now))
            XCTAssertNil(UsagePace.evaluate(window: window(), observedAt: now, now: invalidDate))
            let invalidWindow = UsageWindow(id: "test", label: "Test", usedPercent: 50, resetsAt: invalidDate, durationMinutes: 60)
            XCTAssertNil(UsagePace.evaluate(window: invalidWindow, observedAt: now, now: now))
        }
    }
}
