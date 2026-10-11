import XCTest
@testable import UsageBarCore

final class HistoryLineSegmentsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ minutes: Double, name: String = "weekly", remaining: Double = 50) -> HistoryPoint {
        HistoryPoint(provider: .claude, date: base.addingTimeInterval(minutes * 60), remaining: remaining,
                     windowName: name, windowID: name)
    }

    func testSplitsAtGapsLongerThanMaxGap() {
        let runs = HistoryLineSegments.split([point(0), point(5), point(10), point(200), point(205)], maxGap: 90 * 60)
        XCTAssertEqual(runs.map { $0.points.count }, [3, 2])
        XCTAssertEqual(runs.map(\.id), ["weekly#0", "weekly#1"])
    }

    func testGapExactlyAtLimitStaysJoined() {
        let runs = HistoryLineSegments.split([point(0), point(90)], maxGap: 90 * 60)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].points.count, 2)
    }

    func testSingleObservationsProduceNoRun() {
        XCTAssertTrue(HistoryLineSegments.split([point(0)]).isEmpty)
        XCTAssertTrue(HistoryLineSegments.split([point(0), point(500)]).isEmpty)
    }

    func testSeriesAreSplitSeparatelyAndSortedByTime() {
        let runs = HistoryLineSegments.split([point(10, name: "b"), point(0, name: "b"), point(0, name: "a"), point(1, name: "a")])
        XCTAssertEqual(runs.map(\.windowName), ["a", "b"])
        XCTAssertEqual(runs[1].points.map { $0.date }, [base, base.addingTimeInterval(600)])
    }
}
