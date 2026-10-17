import XCTest
@testable import WorkLogCore

final class WorkTimeCalculatorTests: XCTestCase {
    private let day = LogParsing.date("2026-10-17T00:00:00Z")!
    private func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
    private func minutes(_ intervals: [WorkInterval]) -> Double { WorkTimeCalculator.total(intervals) / 60 }

    func testPlanExample() {
        // 09:00, 09:10, 09:40 with a 15 minute gap: [09:00–09:10] + 5 = 15, [09:40] + 5 = 5.
        let result = WorkTimeCalculator.intervals(moments: [at(540), at(550), at(580)])
        XCTAssertEqual(result, [WorkInterval(start: at(540), end: at(555)), WorkInterval(start: at(580), end: at(585))])
        XCTAssertEqual(minutes(result), 20)
    }

    func testGapBoundaryIsInclusive() {
        XCTAssertEqual(WorkTimeCalculator.intervals(moments: [at(0), at(15)]).count, 1)
        XCTAssertEqual(WorkTimeCalculator.intervals(moments: [at(0), at(15.01)]).count, 2)
    }

    func testSingleMomentCountsTailOnlyAndTailNeverExceedsGap() {
        XCTAssertEqual(minutes(WorkTimeCalculator.intervals(moments: [at(0)])), 5)
        let rules = WorkTimeRules(gap: 2 * 60, tail: 5 * 60)
        XCTAssertEqual(minutes(WorkTimeCalculator.intervals(moments: [at(0), at(3)], rules: rules)), 4)
    }

    func testSpanJoinsQuietStretchInsideIt() {
        let span = WorkInterval(start: at(0), end: at(60))
        let result = WorkTimeCalculator.intervals(moments: [at(-10), at(70)], spans: [span])
        XCTAssertEqual(result, [WorkInterval(start: at(-10), end: at(75))])
    }

    func testUnionDoesNotCountParallelSessionsTwice() {
        let claude = WorkTimeCalculator.intervals(moments: [at(0), at(10)])     // 0–15
        let codex = WorkTimeCalculator.intervals(moments: [at(5), at(20)])      // 5–25
        XCTAssertEqual(minutes(claude) + minutes(codex), 35)
        XCTAssertEqual(minutes(claude + codex), 25)
    }

    func testClipSplitsAtMidnight() {
        let late = WorkTimeCalculator.intervals(moments: [at(-20), at(-5), at(5)])   // 23:40 – 00:10
        let today = DateInterval(start: day, duration: 86_400)
        let yesterday = DateInterval(start: day.addingTimeInterval(-86_400), duration: 86_400)
        XCTAssertEqual(minutes(WorkTimeCalculator.clip(late, to: today)), 10)
        XCTAssertEqual(minutes(WorkTimeCalculator.clip(late, to: yesterday)), 20)
    }

    func testEventsMapToMomentsAndTurnSpans() {
        let events = [
            WorkLogEvent(time: at(0), source: .codex, sessionID: "t", cwd: "/w", kind: .turn(end: at(40))),
            WorkLogEvent(time: at(45), source: .codex, sessionID: "t", cwd: "/w", kind: .activity),
        ]
        XCTAssertEqual(WorkTimeCalculator.intervals(for: events), [WorkInterval(start: at(0), end: at(50))])
        XCTAssertEqual(WorkTimeCalculator.intervals(for: []), [])
    }
}

final class LogDateTests: XCTestCase {
    func testFastDateMatchesFormatter() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for text in ["2026-10-17T01:02:03.456Z", "2026-02-28T23:59:59.9Z", "2024-02-29T12:00:00.000Z", "1999-12-31T23:59:59.5Z"] {
            XCTAssertEqual(LogParsing.fastDate(Array(text.utf8))!.timeIntervalSince1970,
                           formatter.date(from: text)!.timeIntervalSince1970, accuracy: 0.0005, text)
        }
        XCTAssertEqual(LogParsing.fastDate(Array("2026-10-17T10:00:00+09:00".utf8)), LogParsing.date("2026-10-17T01:00:00Z"))
        XCTAssertEqual(LogParsing.fastDate(Array("2026-10-17T01:00:00-05:30".utf8))?.timeIntervalSince1970,
                       LogParsing.fastDate(Array("2026-10-17T06:30:00Z".utf8))?.timeIntervalSince1970)
        for bad in ["2026-13-01T00:00:00Z", "2026-10-17 01:00:00Z", "2026-10-17T01:00:00", "2026-10-17T01:00:00.Z", "x"] {
            XCTAssertNil(LogParsing.fastDate(Array(bad.utf8)), bad)
        }
    }
}
