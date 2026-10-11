import XCTest
@testable import UsageBarCore

final class SessionActivityTests: XCTestCase {
    private let start = LocalSessionLogs.date("2026-10-11T09:00:00Z")!
    private let end = LocalSessionLogs.date("2026-10-11T10:00:00Z")!

    private let claudeLines = [
        #"{"type":"assistant","timestamp":"2026-10-11T09:10:00.100Z","cwd":"/Users/me/Desktop/UsageBar","message":{"model":"claude-fable-5-1","usage":{"input_tokens":12,"output_tokens":400,"cache_read_input_tokens":9000,"cache_creation_input_tokens":300}}}"#,
        #"{"type":"assistant","timestamp":"2026-10-11T09:20:00Z","cwd":"/Users/me/Desktop/UsageBar","message":{"model":"claude-fable-5-1","usage":{"input_tokens":8,"output_tokens":100}}}"#,
        #"{"type":"assistant","timestamp":"2026-10-11T09:30:00Z","cwd":"/Users/me/Desktop/other","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":5,"output_tokens":900}}}"#,
        #"{"type":"assistant","timestamp":"2026-10-11T11:00:00Z","cwd":"/Users/me/Desktop/UsageBar","message":{"model":"claude-fable-5-1","usage":{"input_tokens":1,"output_tokens":5000}}}"#,
        #"{"type":"user","timestamp":"2026-10-11T09:15:00Z","message":{"content":"hello"}}"#,
        "not json at all",
    ]

    func testClaudeSamplesSkipNonAssistantAndMalformedLines() {
        let samples = LocalSessionLogs.claudeSamples(claudeLines)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0].project, "UsageBar")
        XCTAssertEqual(samples[0].cacheReadTokens, 9000)
        XCTAssertEqual(samples[0].cacheWriteTokens, 300)
    }

    func testAggregateFiltersIntervalAndSortsByOutput() {
        let activity = SessionActivityAggregator.aggregate(LocalSessionLogs.claudeSamples(claudeLines), between: start, and: end)
        XCTAssertEqual(activity.models.map(\.model), ["claude-haiku-5-5", "claude-fable-5-1"])
        XCTAssertEqual(activity.models[1].calls, 2)
        XCTAssertEqual(activity.models[1].outputTokens, 500)
        XCTAssertEqual(activity.projects.map(\.name), ["UsageBar", "other"])
        XCTAssertEqual(activity.calls, 3)
        XCTAssertFalse(activity.isPartial)
    }

    func testCodexSamplesCarryModelAndProjectFromContext() {
        let lines = [
            #"{"timestamp":"2026-10-11T09:00:00Z","type":"session_meta","payload":{"cwd":"/Users/me/Desktop/techgom"}}"#,
            #"{"timestamp":"2026-10-11T09:01:00Z","type":"turn_context","payload":{"model":"gpt-6-astra","cwd":"/Users/me/Desktop/techgom"}}"#,
            #"{"timestamp":"2026-10-11T09:02:00.391Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":11587,"cached_input_tokens":4864,"cache_write_input_tokens":0,"output_tokens":171,"reasoning_output_tokens":107}}}}"#,
            #"{"timestamp":"2026-10-11T09:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
        ]
        let samples = LocalSessionLogs.codexSamples(lines)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].model, "gpt-6-astra")
        XCTAssertEqual(samples[0].project, "techgom")
        XCTAssertEqual(samples[0].outputTokens, 278)
        XCTAssertEqual(samples[0].cacheReadTokens, 4864)
    }

    func testScanReadsFilesUnderRootAndSkipsOldOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-logs-\(UUID().uuidString)")
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fresh = project.appendingPathComponent("fresh.jsonl")
        try claudeLines.joined(separator: "\n").write(to: fresh, atomically: true, encoding: .utf8)
        let stale = project.appendingPathComponent("stale.jsonl")
        try claudeLines[0].write(to: stale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-3_600)], ofItemAtPath: stale.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let activity = try XCTUnwrap(LocalSessionLogs.activity(for: .claude, between: start, and: end, root: root))
        XCTAssertEqual(activity.calls, 3)
        XCTAssertNil(LocalSessionLogs.activity(for: .claude, between: start, and: end,
                                               root: root.appendingPathComponent("missing")))
    }

    func testTokenFormat() {
        XCTAssertEqual(TokenFormat.compact(950), "950")
        XCTAssertEqual(TokenFormat.compact(1_240), "1.2K")
        XCTAssertEqual(TokenFormat.compact(48_300), "48K")
        XCTAssertEqual(TokenFormat.compact(1_240_000), "1.2M")
    }
}
