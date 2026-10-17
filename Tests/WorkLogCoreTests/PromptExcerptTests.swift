import XCTest
@testable import WorkLogCore

final class PromptExcerptTests: XCTestCase {
    func testExcerptTakesFirstLineCollapsedAndShortened() {
        XCTAssertEqual(PromptExcerpt.excerpt("\n  작업   기록을\t만들어 줘\n두 번째 줄"), "작업 기록을 만들어 줘")
        let long = String(repeating: "가", count: 100)
        let short = PromptExcerpt.excerpt(long)
        XCTAssertEqual(short.count, PromptExcerpt.maxCharacters)
        XCTAssertTrue(short.hasSuffix("…"))
        XCTAssertEqual(PromptExcerpt.excerpt("```\nlet x = 1\n```"), "(붙여넣은 내용)")
    }

    func testRedactsSecretsButKeepsPathsAndWords() {
        let cases: [(String, String)] = [
            ("use sk-ant-api03-abcdefghijklmnop1234 now", "use ••• now"),
            ("token ghp_abcdefghijklmnopqrstuvwxyz12 ok", "token ••• ok"),
            ("mail henry@example.com please", "mail ••• please"),
            ("open https://example.com/cb?code=abc&state=1 now", "open https://example.com/cb?••• now"),
            ("hash 3f2a9c0d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f", "hash •••"),
            ("key AKIAABCDEFGHIJKLMNOP end", "key ••• end"),
            ("edit Sources/WorkLogCore/JSONLTailReaderPerformance.swift", "edit Sources/WorkLogCore/JSONLTailReaderPerformance.swift"),
            ("rename veryLongFunctionNameWithoutAnyDigitsInIt", "rename veryLongFunctionNameWithoutAnyDigitsInIt"),
        ]
        for (input, expected) in cases { XCTAssertEqual(PromptExcerpt.redact(input), expected, input) }
    }

    func testReadsPromptBackFromLogAndGivesUpWhenItChanged() throws {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("worklog-excerpt-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","sessionId":"s1","cwd":"/w","timestamp":"2026-10-17T01:00:00Z","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#,
            #"{"type":"user","sessionId":"s1","cwd":"/w","timestamp":"2026-10-17T01:01:00Z","message":{"role":"user","content":[{"type":"text","text":"로그 화면을 고쳐 줘 key sk-abcdefghijklmnopqrstu"}]}}"#,
            #"{"timestamp":"2026-10-17T02:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context/>"},{"type":"input_text","text":"API 테스트 추가"}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)

        var claude = ClaudeLogParser(), codex = CodexLogParser(), batch = WorkLogBatch()
        _ = try JSONLTailReader.read(url, from: nil) { line in
            if line.offset == 0 || LogParsing.contains(line.data, Array(#""type":"user""#.utf8)) {
                claude.consume(line, path: url.path, into: &batch)
            } else {
                codex.consume(line, path: url.path, into: &batch)
            }
        }
        let locations = batch.events.compactMap { event -> PromptLocation? in
            if case .prompt(let location) = event.kind { return location } else { return nil }
        }
        XCTAssertEqual(locations.map { PromptExcerpt.read($0) }, ["로그 화면을 고쳐 줘 key •••", "API 테스트 추가"])

        try Data("{}\n".utf8).write(to: url)
        XCTAssertNil(PromptExcerpt.read(locations[0]))
        let missing = PromptLocation(path: "/private/tmp/does-not-exist.jsonl", offset: 0, length: 5, characterCount: 5)
        XCTAssertNil(PromptExcerpt.read(missing))
    }
}
