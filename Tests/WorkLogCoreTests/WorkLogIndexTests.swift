import XCTest
@testable import WorkLogCore

final class WorkLogIndexTests: XCTestCase {
    private var directory: URL!
    private let since = LogParsing.date("2026-10-17T00:00:00Z")!

    override func setUpWithError() throws {
        // /private/tmp, not the temporary directory: /var is a symbolic link the index store refuses.
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("worklog-index-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var logs: URL { directory.appendingPathComponent("logs") }

    private func claudeLine(_ time: String, _ text: String = "please plan the work log") -> String {
        #"{"type":"user","sessionId":"s1","cwd":"/w/app","timestamp":"\#(time)","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func append(_ lines: [String], to url: URL) throws {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        } else {
            try data.write(to: url)
        }
    }

    func testRefreshReadsOnlyAppendedLines() throws {
        let file = logs.appendingPathComponent("s1.jsonl")
        try append([claudeLine("2026-10-16T23:00:00Z"), claudeLine("2026-10-17T01:00:00Z")], to: file)
        var index = LogIndex()
        let first = WorkLogIndexer.refresh(&index, source: .claude, roots: [logs], since: since)
        XCTAssertEqual(first.files, 1)
        XCTAssertEqual(index.batch.events.count, 2, "activity and prompt from the line inside the window")

        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber
        try append([claudeLine("2026-10-17T03:00:00Z")], to: file)
        let second = WorkLogIndexer.refresh(&index, source: .claude, roots: [logs], since: since)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber
        XCTAssertEqual(second.bytes, after.uint64Value - before.uint64Value)
        XCTAssertEqual(second.lines, 1)
        XCTAssertEqual(index.batch.events.filter { if case .prompt = $0.kind { return true } else { return false } }.count, 2)
    }

    func testReplacedFileStartsOverAndOldFilesAreForgotten() throws {
        let file = logs.appendingPathComponent("s1.jsonl")
        try append([claudeLine("2026-10-17T01:00:00Z"), claudeLine("2026-10-17T02:00:00Z")], to: file)
        var index = LogIndex()
        WorkLogIndexer.refresh(&index, source: .claude, roots: [logs], since: since)
        XCTAssertEqual(index.batch.events.count, 4)

        try Data((claudeLine("2026-10-17T05:00:00Z") + "\n").utf8).write(to: file, options: .atomic)
        let replaced = WorkLogIndexer.refresh(&index, source: .claude, roots: [logs], since: since)
        XCTAssertEqual(replaced.lines, 1, "a replaced file is parsed from the start with fresh state")
        XCTAssertEqual(index.batch.events.map(\.time), [LogParsing.date("2026-10-17T05:00:00Z")!, LogParsing.date("2026-10-17T05:00:00Z")!])

        try FileManager.default.setAttributes([.modificationDate: LogParsing.date("2026-10-10T00:00:00Z")!], ofItemAtPath: file.path)
        WorkLogIndexer.refresh(&index, source: .claude, roots: [logs], since: since)
        XCTAssertTrue(index.files.isEmpty)
    }

    func testByteBudgetLeavesTheRestForTheNextPass() throws {
        let file = logs.appendingPathComponent("s1.jsonl")
        try append((0..<10).map { claudeLine("2026-10-17T0\($0):00:00Z") }, to: file)
        var index = LogIndex()
        let first = WorkLogIndexer.refresh(&index, source: .claude, roots: [logs], since: since, maxBytes: 300)
        XCTAssertTrue(first.isPartial)
        XCTAssertLessThan(first.lines, 10)
        let second = WorkLogIndexer.refresh(&index, source: .claude, roots: [logs], since: since)
        XCTAssertFalse(second.isPartial)
        XCTAssertEqual(first.lines + second.lines, 10)
    }

    func testCodexKeepsStateFromLinesBeforeTheWindow() throws {
        let file = logs.appendingPathComponent("rollout-1.jsonl")
        try append([
            #"{"timestamp":"2026-10-15T09:00:00Z","type":"session_meta","payload":{"id":"t1","cwd":"/w/api"}}"#,
            #"{"timestamp":"2026-10-15T09:01:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"an old request from two days ago"}]}}"#,
            #"{"timestamp":"2026-10-17T09:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"today's request for the api"}]}}"#,
        ], to: file)
        var index = LogIndex()
        WorkLogIndexer.refresh(&index, source: .codex, roots: [logs], since: since)
        let events = index.batch.events
        XCTAssertTrue(events.allSatisfy { $0.time >= since && $0.sessionID == "t1" && $0.cwd == "/w/api" })
        XCTAssertEqual(events.filter { if case .prompt = $0.kind { return true } else { return false } }.count, 1)
    }

    func testStoreRoundTripsPrivatelyAndTreatsDamageAsEmpty() async throws {
        let file = logs.appendingPathComponent("s1.jsonl")
        try append([claudeLine("2026-10-17T01:00:00Z")], to: file)
        var index = LogIndex()
        WorkLogIndexer.refresh(&index, source: .claude, roots: [logs], since: since)

        let store = LogIndexStore(directory: directory.appendingPathComponent("support"))
        try await store.save(index)
        let loaded = await store.load()
        XCTAssertEqual(loaded, index)
        let stored = directory.appendingPathComponent("support/worklog-index/index.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue, 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: stored), as: UTF8.self).contains("please plan"),
                       "prompt text never reaches the index")

        try Data("{broken".utf8).write(to: stored)
        let damaged = await store.load()
        XCTAssertEqual(damaged, LogIndex())

        try await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    }

    func testStoreRefusesSymbolicLinks() async throws {
        let real = directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = LogIndexStore(directory: link)
        do {
            try await store.save(LogIndex())
            XCTFail("saved through a symbolic link")
        } catch {
            XCTAssertEqual(error as? LogIndexStoreError, .unsafePath)
        }
    }

    func testCodexSessionTitles() throws {
        let file = directory.appendingPathComponent("session_index.jsonl")
        try append([#"{"id":"t1","thread_name":" Fix login ","updated_at":"x"}"#, #"{"id":"t2","thread_name":""}"#, "junk"], to: file)
        XCTAssertEqual(CodexSessionTitles.read(file), ["t1": "Fix login"])
        XCTAssertEqual(CodexSessionTitles.read(directory.appendingPathComponent("missing.jsonl")), [:])
    }
}
