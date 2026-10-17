import XCTest
@testable import WorkLogCore

final class JSONLTailReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func readAll(_ url: URL, from cursor: LogCursor?, chunkSize: Int = 4,
                         maxBytes: UInt64 = .max) throws -> (TailReadResult, [String], [UInt64]) {
        var lines: [String] = [], offsets: [UInt64] = []
        let result = try JSONLTailReader.read(url, from: cursor, chunkSize: chunkSize, maxBytes: maxBytes) { line in
            lines.append(String(decoding: line.data, as: UTF8.self)); offsets.append(line.offset)
        }
        return (result, lines, offsets)
    }

    func testReadsCompleteLinesAcrossSmallChunksAndLeavesUnfinishedLine() throws {
        let url = directory.appendingPathComponent("a.jsonl")
        try Data("one\r\n\ntwo\nthr".utf8).write(to: url)
        let (result, lines, offsets) = try readAll(url, from: nil)
        XCTAssertEqual(lines, ["one", "two"])
        XCTAssertEqual(offsets, [0, 6])
        XCTAssertEqual(result.cursor.offset, 10)
        XCTAssertTrue(result.restarted)
        XCTAssertTrue(result.reachedEnd)
    }

    func testResumesFromCursorAfterAppend() throws {
        let url = directory.appendingPathComponent("a.jsonl")
        try Data("one\ntw".utf8).write(to: url)
        let first = try readAll(url, from: nil).0
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("o\nthree\n".utf8)); try handle.close()
        let (second, lines, offsets) = try readAll(url, from: first.cursor)
        XCTAssertFalse(second.restarted)
        XCTAssertEqual(lines, ["two", "three"])
        XCTAssertEqual(offsets, [4, 8])
        XCTAssertEqual(second.cursor.offset, 14)
    }

    func testRestartsWhenFileShrinksOrIsReplaced() throws {
        let url = directory.appendingPathComponent("a.jsonl")
        try Data("one\ntwo\n".utf8).write(to: url)
        let first = try readAll(url, from: nil).0
        try Data("x\n".utf8).write(to: url)   // atomic write: new file, smaller
        let (second, lines, _) = try readAll(url, from: first.cursor)
        XCTAssertTrue(second.restarted)
        XCTAssertEqual(lines, ["x"])

        let stale = LogCursor(fileID: second.cursor.fileID &+ 1, offset: 0)
        XCTAssertTrue(try readAll(url, from: stale).0.restarted)
    }

    func testByteBudgetStopsAtLineBoundary() throws {
        let url = directory.appendingPathComponent("a.jsonl")
        try Data("aaaa\nbbbb\ncccc\n".utf8).write(to: url)
        let (result, lines, _) = try readAll(url, from: nil, chunkSize: 5, maxBytes: 6)
        XCTAssertFalse(result.reachedEnd)
        XCTAssertEqual(lines, ["aaaa", "bbbb"])
        XCTAssertEqual(result.cursor.offset, 10)
        let (rest, more, _) = try readAll(url, from: result.cursor)
        XCTAssertTrue(rest.reachedEnd)
        XCTAssertEqual(more, ["cccc"])
    }

    func testEmptyFileAndNothingNew() throws {
        let url = directory.appendingPathComponent("a.jsonl")
        try Data().write(to: url)
        let (result, lines, _) = try readAll(url, from: nil)
        XCTAssertEqual(lines, [])
        XCTAssertEqual(result.cursor.offset, 0)
        XCTAssertTrue(try readAll(url, from: result.cursor).0.reachedEnd)
    }
}
