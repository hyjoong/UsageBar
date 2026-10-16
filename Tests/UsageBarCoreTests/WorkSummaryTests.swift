import XCTest
@testable import UsageBarCore

final class WorkSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(_ kind: WorkKind, provider: ProviderID = .claude, endedHoursAgo: Double, minutes: Double,
                         rows: [WorkQuotaDelta], output: Int64 = 0) -> WorkReceipt {
        let end = now.addingTimeInterval(-endedHoursAgo * 3_600)
        return WorkReceipt(kind: kind, provider: provider, startedAt: end.addingTimeInterval(-minutes * 60), endedAt: end, rows: rows,
                           activity: output > 0 ? SessionActivity(models: [ModelActivity(model: "m", calls: 1, outputTokens: output)], projects: []) : nil)
    }

    private func row(_ label: String, _ points: Double?, estimate: Double? = nil) -> WorkQuotaDelta {
        WorkQuotaDelta(id: label, label: label, percentagePoints: points, note: points == nil ? "n/a" : nil,
                       estimatedPercentagePoints: estimate)
    }

    func testTotalsSessionsTimeTokensLimitsAndKinds() throws {
        let receipts = [
            receipt(.refactor, endedHoursAgo: 1, minutes: 30, rows: [row("5h", 3), row("weekly", 1)], output: 1_000),
            receipt(.refactor, endedHoursAgo: 5, minutes: 20, rows: [row("5h", nil, estimate: 4), row("weekly", 0)], output: 500),
            receipt(.build, endedHoursAgo: 30, minutes: 60, rows: [row("5h", nil), row("weekly", 2)]),
            receipt(.debug, provider: .codex, endedHoursAgo: 2, minutes: 10, rows: [row("weekly", 5)]),
            receipt(.review, endedHoursAgo: 24 * 8, minutes: 90, rows: [row("5h", 50)]), // outside the 7 days
        ]
        let summary = try XCTUnwrap(WorkSummary.make(receipts: receipts, from: now.addingTimeInterval(-7 * 86_400), to: now))
        XCTAssertEqual(summary.sessions, 4)
        XCTAssertEqual(summary.duration, 120 * 60)
        XCTAssertEqual(summary.outputTokens, 1_500)
        XCTAssertEqual(summary.limits.map(\.id), ["claude|5h", "claude|weekly", "codex|weekly"])
        let session = summary.limits[0]
        XCTAssertEqual(session.percentagePoints, 7)
        XCTAssertTrue(session.includesEstimate)
        XCTAssertEqual(session.comparedSessions, 2)
        XCTAssertEqual(session.sessions, 3)
        XCTAssertEqual(summary.limits[1].percentagePoints, 3)
        XCTAssertFalse(summary.limits[1].includesEstimate)
        XCTAssertEqual(summary.limits[2].percentagePoints, 5)
        XCTAssertEqual(summary.kinds.map(\.kind), [.build, .refactor, .debug])
        XCTAssertEqual(summary.kinds[1].sessions, 2)
        XCTAssertEqual(summary.kinds[1].duration, 50 * 60)
    }

    func testNoReceiptsInPeriodGivesNil() {
        XCTAssertNil(WorkSummary.make(receipts: [], from: now.addingTimeInterval(-86_400), to: now))
        let old = receipt(.other, endedHoursAgo: 48, minutes: 5, rows: [])
        XCTAssertNil(WorkSummary.make(receipts: [old], from: now.addingTimeInterval(-86_400), to: now))
    }
}
