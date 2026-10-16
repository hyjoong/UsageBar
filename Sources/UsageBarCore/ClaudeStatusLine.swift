import Foundation

/// The optional Claude Code status line. UsageBar writes the rendered line to a file, a tiny script
/// prints it, and `statusLine` in the user's Claude Code settings points at that script.
/// Claude Code already passes its own rate limits to status line scripts; this adds what only UsageBar
/// knows: a running work session, the run-out estimate and Codex.
public enum ClaudeStatusLine {
    public struct Segment: Equatable, Sendable {
        public enum Tone: Sendable { case normal, warning, dim, recording }
        public let text: String
        public let tone: Tone
        public init(_ text: String, tone: Tone = .normal) { self.text = text; self.tone = tone }
    }

    public enum State: Equatable, Sendable {
        case notConfigured
        case installed
        /// Another status line is configured; UsageBar never replaces it.
        case otherStatusLine
    }

    public enum Failure: Error, Equatable {
        case invalidSettings
        case otherStatusLine
    }

    /// A line older than this means UsageBar is closed or asleep, so the script prints nothing.
    public static let maximumAge: TimeInterval = 600
    public static let refreshInterval = 60
    private static let marker = "UsageBar/statusline.sh"

    /// Joins segments with a middle dot. Claude Code passes ANSI colors through to the terminal.
    public static func render(_ segments: [Segment], ansi: Bool = true) -> String {
        segments.map { segment in
            guard ansi else { return segment.tone == .recording ? "● " + segment.text : segment.text }
            switch segment.tone {
            case .normal: return segment.text
            case .warning: return "\u{1B}[38;5;208m" + segment.text + "\u{1B}[0m"
            case .dim: return "\u{1B}[2m" + segment.text + "\u{1B}[0m"
            case .recording: return "\u{1B}[31m●\u{1B}[0m " + segment.text
            }
        }.joined(separator: " · ")
    }

    public static func script(lineFile: URL) -> String {
        """
        #!/bin/sh
        # UsageBar status line for Claude Code. Prints the line UsageBar last wrote, or nothing when
        # UsageBar has not updated it for \(Int(maximumAge / 60)) minutes (the app is closed or the Mac slept).
        f=\(shellQuote(lineFile.path))
        [ -f "$f" ] || exit 0
        age=$(( $(date +%s) - $(stat -f %m "$f") ))
        [ "$age" -le \(Int(maximumAge)) ] && cat "$f"
        exit 0

        """
    }

    public static func command(script: URL) -> String { "sh " + shellQuote(script.path) }

    public static func state(settings: URL) -> State {
        guard let object = try? readSettings(settings), let statusLine = object["statusLine"] else { return .notConfigured }
        return isOurs(statusLine) ? .installed : .otherStatusLine
    }

    /// Writes the script, backs up the settings file, then adds only the `statusLine` key.
    /// Refuses to touch a settings file it cannot parse or one with another status line.
    public static func install(settings: URL, script: URL, lineFile: URL) throws {
        var object = try readSettings(settings)
        if let existing = object["statusLine"], !isOurs(existing) { throw Failure.otherStatusLine }
        let manager = FileManager.default
        try manager.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.script(lineFile: lineFile).write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        if manager.fileExists(atPath: settings.path) {
            let backup = settings.appendingPathExtension("usagebar-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: settings, to: backup)
        }
        object["statusLine"] = ["type": "command", "command": command(script: script), "refreshInterval": refreshInterval]
        try writeSettings(object, to: settings)
    }

    /// Removes the `statusLine` key only when it is UsageBar's.
    public static func uninstall(settings: URL) throws {
        var object = try readSettings(settings)
        guard let existing = object["statusLine"], isOurs(existing) else { return }
        object["statusLine"] = nil
        try writeSettings(object, to: settings)
    }

    // MARK: Helpers

    private static func isOurs(_ statusLine: Any) -> Bool {
        ((statusLine as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ [0x20, 0x09, 0x0a, 0x0d].contains($0) }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidSettings }
        return object
    }

    private static func writeSettings(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
