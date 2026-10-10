import Foundation
import XCTest
@testable import UsageBarCore

final class UsageCSVTests: XCTestCase {
    func testLimitsIncludeISO8601DatesAndNumericPercentOnlyForRequestedProvider() {
        let point = HistoryPoint(provider: .codex, date: Date(timeIntervalSince1970: 0),
                                 remaining: 72.5, windowName: "주간 한도", windowID: "internal-window-id",
                                 resetsAt: Date(timeIntervalSince1970: 3_661.25))
        let other = HistoryPoint(provider: .claude, date: point.date,
                                 remaining: 10, windowName: "다른 제공자", windowID: "other")
        let csv = UsageCSV.limits([point, other], provider: .codex)
        XCTAssertEqual(csv, "provider,observed_at,window,remaining_percent,resets_at\r\n"
            + "\"codex\",\"1970-01-01T00:00:00.000Z\",\"주간 한도\",72.5,\"1970-01-01T01:01:01.250Z\"\r\n")
        XCTAssertFalse(csv.contains("internal-window-id"))
        XCTAssertFalse(csv.contains("다른 제공자"))
        XCTAssertNotNil(csv.data(using: .utf8))
    }

    func testQuotesCommasAndLineBreaksRemainInsideQuotedCell() {
        let point = makePoint(name: "주간, \"추가\"\n한도\r\n끝")
        let csv = UsageCSV.limits([point], provider: .claude)
        XCTAssertEqual(csv, "provider,observed_at,window,remaining_percent,resets_at\r\n"
            + "\"claude\",\"1970-01-01T00:00:00.000Z\",\"주간, \"\"추가\"\"\n한도\r\n끝\",25.0,\"\"\r\n")
    }

    func testSpreadsheetFormulaPrefixesAreInertEvenAfterWhitespaceOrControls() {
        for prefix in ["", " ", "\t", "\r\n", "\u{00A0}", "\u{FEFF}", "\u{0000}"] {
            for formula in ["=1+1", "+SUM(1,2)", "-1+2", "@SUM(1,2)"] {
                let input = prefix + formula
                let csv = UsageCSV.limits([makePoint(name: input)], provider: .claude)
                XCTAssertTrue(csv.contains("\"'\(input)\",25.0,"), "Unescaped formula: \(input.debugDescription)")
            }
        }
    }

    func testPlainAndEmptyTextAreNotPrefixed() {
        for input in ["", "  주간 한도", "사용량 + 추가", "'이미 인용함"] {
            let csv = UsageCSV.limits([makePoint(name: input)], provider: .claude)
            XCTAssertTrue(csv.contains("\"\(input)\",25.0,\"\"\r\n"))
        }
    }

    func testDailyExportPreservesSelectedRowsAndExactInt64Values() {
        let records = [DailyUsage(day: "2026-10-09", tokens: Int64.max),
                       DailyUsage(day: "2026-10-10", tokens: 0)]
        XCTAssertEqual(UsageCSV.dailyUsage(records, provider: .codex),
            "provider,day,tokens\r\n\"codex\",\"2026-10-09\",9223372036854775807\r\n"
            + "\"codex\",\"2026-10-10\",0\r\n")
    }

    func testDailyTextCellsAlsoNeutralizeFormulaInjection() {
        let csv = UsageCSV.dailyUsage([DailyUsage(day: "\t=1+1", tokens: 7)], provider: .codex)
        XCTAssertEqual(csv, "provider,day,tokens\r\n\"codex\",\"'\t=1+1\",7\r\n")
    }

    func testEmptyDatasetsExportOnlyHeaders() {
        XCTAssertEqual(UsageCSV.limits([], provider: .claude),
                       "provider,observed_at,window,remaining_percent,resets_at\r\n")
        XCTAssertEqual(UsageCSV.dailyUsage([], provider: .codex), "provider,day,tokens\r\n")
    }

    private func makePoint(name: String) -> HistoryPoint {
        HistoryPoint(provider: .claude, date: Date(timeIntervalSince1970: 0), remaining: 25,
                     windowName: name, windowID: "window")
    }
}
