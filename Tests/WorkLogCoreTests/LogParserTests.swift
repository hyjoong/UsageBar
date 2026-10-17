import XCTest
@testable import WorkLogCore

/// Synthetic log lines only. Field names follow what Claude Code and Codex write; the values are made up.
final class LogParserTests: XCTestCase {
    private func date(_ text: String) -> Date { LogParsing.date(text)! }

    private func parseClaude(_ lines: [String], path: String = "/logs/s1.jsonl") -> WorkLogBatch {
        var parser = ClaudeLogParser(), batch = WorkLogBatch(), offset: UInt64 = 0
        for text in lines {
            let data = Data(text.utf8)
            parser.consume(JSONLLine(offset: offset, data: data), path: path, into: &batch)
            offset += UInt64(data.count + 1)
        }
        return batch
    }

    private func parseCodex(_ lines: [String], path: String = "/logs/rollout-x.jsonl") -> WorkLogBatch {
        var parser = CodexLogParser(), batch = WorkLogBatch(), offset: UInt64 = 0
        for text in lines {
            let data = Data(text.utf8)
            parser.consume(JSONLLine(offset: offset, data: data), path: path, into: &batch)
            offset += UInt64(data.count + 1)
        }
        return batch
    }

    private func prompts(_ batch: WorkLogBatch) -> [PromptLocation] {
        batch.events.compactMap { if case .prompt(let location) = $0.kind { return location } else { return nil } }
    }

    private func edits(_ batch: WorkLogBatch) -> [String] {
        batch.events.compactMap { if case .fileEdit(let path) = $0.kind { return path } else { return nil } }
    }

    // MARK: Claude Code

    func testClaudeKeepsTypedPromptsOnly() {
        let base = #""sessionId":"s1","cwd":"/work/app","timestamp":"2026-10-17T01:00:0"#
        let batch = parseClaude([
            #"{"type":"user",\#(base)0Z","origin":{"kind":"human"},"message":{"role":"user","content":"작업 기록 기능을 기획해 줘"}}"#,
            #"{"type":"user",\#(base)1Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user",\#(base)2Z","message":{"role":"user","content":"/compact"}}"#,
            #"{"type":"user",\#(base)3Z","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"user",\#(base)4Z","origin":{"kind":"peer","from":"x"},"message":{"role":"user","content":"from a peer"}}"#,
            #"{"type":"user",\#(base)5Z","isSidechain":true,"message":{"role":"user","content":"subagent brief"}}"#,
            #"{"type":"user",\#(base)6Z","toolUseResult":{"stdout":""},"message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user",\#(base)7Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"},{"type":"text","text":"ok"}]}}"#,
        ])
        let found = prompts(batch)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].offset, 0)
        XCTAssertEqual(found[0].characterCount, "작업 기록 기능을 기획해 줘".count)
        XCTAssertEqual(found[1].characterCount, 2)
        XCTAssertEqual(found[0].path, "/logs/s1.jsonl")
        XCTAssertTrue(batch.events.allSatisfy { $0.sessionID == "s1" && $0.cwd == "/work/app" && $0.source == .claude })
    }

    func testClaudeCollectsEditsCommitsPullRequestsAndTitles() {
        let batch = parseClaude([
            #"{"type":"assistant","sessionId":"s1","cwd":"/work/app","timestamp":"2026-10-17T01:00:00Z","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/work/app/a.swift"}},{"type":"tool_use","name":"Read","input":{"file_path":"/work/app/b.swift"}},{"type":"tool_use","name":"Write","input":{"file_path":"/work/app/c.md"}}]}}"#,
            #"{"type":"user","sessionId":"s1","cwd":"/work/app","timestamp":"2026-10-17T01:00:30Z","toolUseResult":{"bashEditDiff":{"changedFiles":["/work/app/d.swift"],"files":[{"filePath":"/work/app/d.swift","hunks":[]},{"filePath":"/work/app/e.swift","hunks":[]}],"moreFiles":0},"gitOperation":{"commit":{"kind":"commit","sha":"abc1234"},"pr":{"action":"create","number":7,"url":"https://example.com/pr/7"}}},"message":{"content":[{"type":"tool_result"}]}}"#,
            #"{"type":"pr-link","sessionId":"s1","timestamp":"2026-10-17T01:01:00Z","prUrl":"https://example.com/pr/8","prNumber":8}"#,
            #"{"type":"ai-title","sessionId":"s1","aiTitle":"Plan the work log"}"#,
            #"{"type":"custom-title","sessionId":"s2","customTitle":"Mine"}"#,
            #"{"type":"ai-title","sessionId":"s2","aiTitle":"Generated"}"#,
        ])
        XCTAssertEqual(edits(batch), ["/work/app/a.swift", "/work/app/c.md", "/work/app/d.swift", "/work/app/e.swift"])
        XCTAssertTrue(batch.events.contains { $0.kind == .commit(sha: "abc1234") })
        XCTAssertTrue(batch.events.contains { $0.kind == .pullRequest(url: "https://example.com/pr/7") })
        XCTAssertTrue(batch.events.contains { $0.kind == .pullRequest(url: "https://example.com/pr/8") })
        XCTAssertEqual(batch.titles, ["s1": "Plan the work log", "s2": "Mine"])
    }

    func testClaudeActivityIsRecordedOncePerMinutePerSession() {
        let line = { (time: String) in
            #"{"type":"assistant","sessionId":"s1","cwd":"/w","timestamp":"\#(time)","message":{"content":[]}}"#
        }
        let batch = parseClaude([line("2026-10-17T01:00:00Z"), line("2026-10-17T01:00:40Z"),
                                 line("2026-10-17T01:01:05Z"), "not json", #"{"type":"assistant"}"#])
        XCTAssertEqual(batch.events.filter { $0.kind == .activity }.map(\.time),
                       [date("2026-10-17T01:00:00Z"), date("2026-10-17T01:01:05Z")])
    }

    // MARK: Codex

    func testCodexCarriesSessionAndDirectoryAndFiltersInjectedPrompts() {
        let batch = parseCodex([
            #"{"timestamp":"2026-10-17T02:00:00Z","type":"session_meta","payload":{"id":"t1","cwd":"/work/api","source":"vscode"}}"#,
            #"{"timestamp":"2026-10-17T02:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"timestamp":"2026-10-17T02:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"},{"type":"input_text","text":"로그인 오류 고쳐줘"}]}}"#,
            #"{"timestamp":"2026-10-17T02:00:03Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
            #"{"timestamp":"2026-10-17T02:05:00Z","type":"turn_context","payload":{"cwd":"/work/api/server"}}"#,
            #"{"timestamp":"2026-10-17T02:06:00Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","changes":{"/work/api/server/b.ts":{"type":"update"},"/work/api/server/a.ts":{"type":"add"}}}}}"#,
        ])
        let found = prompts(batch)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].characterCount, "로그인 오류 고쳐줘".count)
        XCTAssertEqual(edits(batch), ["/work/api/server/a.ts", "/work/api/server/b.ts"])
        XCTAssertTrue(batch.events.allSatisfy { $0.sessionID == "t1" && $0.source == .codex && !$0.isSubagent })
        XCTAssertEqual(batch.events.first { $0.kind == .fileEdit(path: "/work/api/server/a.ts") }?.cwd, "/work/api/server")
    }

    func testCodexSubagentPromptsAreNotPrompts() {
        let batch = parseCodex([
            #"{"timestamp":"2026-10-17T02:00:00Z","type":"session_meta","payload":{"id":"t2","cwd":"/w","source":{"subagent":{"other":"x"}},"parent_thread_id":"t1"}}"#,
            #"{"timestamp":"2026-10-17T02:01:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"look into the bug"}]}}"#,
        ])
        XCTAssertTrue(prompts(batch).isEmpty)
        XCTAssertFalse(batch.events.isEmpty)
        XCTAssertTrue(batch.events.allSatisfy(\.isSubagent))
    }

    func testCodexTurnBecomesSpanCappedAtThreeHours() {
        let batch = parseCodex([
            #"{"timestamp":"2026-10-17T03:00:00Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":1200000,"turn_id":"u"}}"#,
            #"{"timestamp":"2026-10-17T09:00:00Z","type":"event_msg","payload":{"type":"turn_aborted","duration_ms":36000000,"turn_id":"v"}}"#,
        ])
        let turns = batch.events.compactMap { event -> WorkInterval? in
            if case .turn(let end) = event.kind { return WorkInterval(start: event.time, end: end) } else { return nil }
        }
        XCTAssertEqual(turns, [WorkInterval(start: date("2026-10-17T02:40:00Z"), end: date("2026-10-17T03:00:00Z")),
                               WorkInterval(start: date("2026-10-17T06:00:00Z"), end: date("2026-10-17T09:00:00Z"))])
        XCTAssertEqual(batch.events.first?.sessionID, "rollout-x", "falls back to the file name without session_meta")
    }

    func testCodexPlainLinesBecomeThrottledActivityWithoutDecoding() {
        let batch = parseCodex([
            #"{"timestamp":"2026-10-17T04:00:00.120Z","type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"timestamp":"2026-10-17T04:00:30Z","type":"response_item","payload":{"type":"function_call"}}"#,
            #"{"timestamp":"2026-10-17T04:02:00Z","type":"event_msg","payload":{"type":"token_count"} BROKEN"#,
            #"{"type":"response_item","payload":{}}"#,
        ])
        XCTAssertEqual(batch.events.map(\.time), [date("2026-10-17T04:00:00.120Z"), date("2026-10-17T04:02:00Z")])
        XCTAssertTrue(batch.events.allSatisfy { $0.kind == .activity })
    }

    func testParserStateSurvivesEncoding() throws {
        var parser = CodexLogParser(), batch = WorkLogBatch()
        parser.consume(JSONLLine(offset: 0, data: Data(#"{"timestamp":"2026-10-17T02:00:00Z","type":"session_meta","payload":{"id":"t9","cwd":"/w"}}"#.utf8)),
                       path: "/r.jsonl", into: &batch)
        var restored = try JSONDecoder().decode(CodexLogParser.self, from: JSONEncoder().encode(parser))
        var later = WorkLogBatch()
        restored.consume(JSONLLine(offset: 99, data: Data(#"{"timestamp":"2026-10-17T03:00:00Z","type":"x"}"#.utf8)),
                         path: "/r.jsonl", into: &later)
        XCTAssertEqual(later.events.first?.sessionID, "t9")
        XCTAssertEqual(later.events.first?.cwd, "/w")
    }
}
