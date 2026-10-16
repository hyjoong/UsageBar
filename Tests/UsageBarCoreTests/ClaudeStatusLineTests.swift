import XCTest
@testable import UsageBarCore

final class ClaudeStatusLineTests: XCTestCase {
    private var root: URL!
    private var settings: URL { root.appendingPathComponent(".claude/settings.json") }
    private var script: URL { root.appendingPathComponent("Support/UsageBar/statusline.sh") }
    private var lineFile: URL { root.appendingPathComponent("Support/UsageBar/statusline.txt") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testRenderJoinsSegmentsWithColorsOrPlain() {
        let segments = [ClaudeStatusLine.Segment("기록 중 12분", tone: .recording),
                        ClaudeStatusLine.Segment("Claude 12%", tone: .warning),
                        ClaudeStatusLine.Segment("Codex 90%", tone: .dim)]
        XCTAssertEqual(ClaudeStatusLine.render(segments, ansi: false), "● 기록 중 12분 · Claude 12% · Codex 90%")
        XCTAssertEqual(ClaudeStatusLine.render(segments),
                       "\u{1B}[31m●\u{1B}[0m 기록 중 12분 · \u{1B}[38;5;208mClaude 12%\u{1B}[0m · \u{1B}[2mCodex 90%\u{1B}[0m")
        XCTAssertEqual(ClaudeStatusLine.render([]), "")
    }

    func testInstallKeepsOtherKeysBacksUpAndUninstallRemovesOnlyOurs() throws {
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model":"opus","permissions":{"allow":["Bash(ls)"]}}"#.write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeStatusLine.state(settings: settings), .notConfigured)

        try ClaudeStatusLine.install(settings: settings, script: script, lineFile: lineFile)
        let installed = try json(settings)
        XCTAssertEqual(installed["model"] as? String, "opus")
        XCTAssertNotNil(installed["permissions"])
        let statusLine = try XCTUnwrap(installed["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, "sh '\(script.path)'")
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, 60)
        XCTAssertEqual(ClaudeStatusLine.state(settings: settings), .installed)
        XCTAssertNil(try json(settings.appendingPathExtension("usagebar-backup"))["statusLine"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))

        try ClaudeStatusLine.install(settings: settings, script: script, lineFile: lineFile) // idempotent
        try ClaudeStatusLine.uninstall(settings: settings)
        let removed = try json(settings)
        XCTAssertNil(removed["statusLine"])
        XCTAssertEqual(removed["model"] as? String, "opus")
    }

    func testOtherStatusLineAndInvalidSettingsAreNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = #"{"statusLine":{"type":"command","command":"~/.claude/mine.sh"}}"#
        try other.write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeStatusLine.state(settings: settings), .otherStatusLine)
        XCTAssertThrowsError(try ClaudeStatusLine.install(settings: settings, script: script, lineFile: lineFile)) {
            XCTAssertEqual($0 as? ClaudeStatusLine.Failure, .otherStatusLine)
        }
        try ClaudeStatusLine.uninstall(settings: settings)
        XCTAssertEqual(try String(contentsOf: settings), other)

        try "{ not json".write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeStatusLine.install(settings: settings, script: script, lineFile: lineFile)) {
            XCTAssertEqual($0 as? ClaudeStatusLine.Failure, .invalidSettings)
        }
        XCTAssertEqual(try String(contentsOf: settings), "{ not json")
    }

    func testInstallCreatesMissingSettingsFile() throws {
        try ClaudeStatusLine.install(settings: settings, script: script, lineFile: lineFile)
        XCTAssertEqual(ClaudeStatusLine.state(settings: settings), .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.appendingPathExtension("usagebar-backup").path))
    }

    func testScriptPrintsFreshLineAndStaysSilentWhenStale() throws {
        try ClaudeStatusLine.install(settings: settings, script: script, lineFile: lineFile)
        func run() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try run(), "")   // no line yet
        try "Claude 92%".write(to: lineFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(), "Claude 92%")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ClaudeStatusLine.maximumAge - 60)],
                                              ofItemAtPath: lineFile.path)
        XCTAssertEqual(try run(), "")
    }
}
