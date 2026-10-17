import Foundation

/// Turns Claude Code session log lines (`~/.claude/projects/<folder>/<session>.jsonl`) into work log events.
/// Reads timestamps, the working directory, tool names, edited file paths, commit and PR references and
/// session titles. Prompt text is inspected only to tell typed prompts from injected context; it is not kept.
///
/// The parser is a value with a little state so a file can be read in pieces across app launches.
public struct ClaudeLogParser: Codable, Equatable, Sendable {
    /// Consecutive activity closer than this is recorded once. Far below the work gap, so time is unaffected.
    public static let activityResolution: TimeInterval = 60
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private var lastActivity: [String: Date] = [:]
    private var customTitled: Set<String> = []

    public init() {}

    private static let needles = [#""type":"user""#, #""type":"assistant""#, #""type":"ai-title""#,
                                  #""type":"custom-title""#, #""type":"pr-link""#].map { Array($0.utf8) }

    public mutating func consume(_ line: JSONLLine, path: String, into batch: inout WorkLogBatch) {
        guard Self.needles.contains(where: { LogParsing.contains(line.data, $0) }),
              let object = LogParsing.json(line.data), let type = object["type"] as? String else { return }
        let session = (object["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent

        switch type {
        case "ai-title":
            if !customTitled.contains(session), let title = Self.title(object["aiTitle"]) { batch.titles[session] = title }
        case "custom-title":
            if let title = Self.title(object["customTitle"]) { batch.titles[session] = title; customTitled.insert(session) }
        case "pr-link":
            guard let time = LogParsing.date(object["timestamp"]), let url = object["prUrl"] as? String else { return }
            batch.events.append(WorkLogEvent(time: time, source: .claude, sessionID: session, cwd: nil,
                                             kind: .pullRequest(url: url)))
        case "user", "assistant":
            guard let time = LogParsing.date(object["timestamp"]) else { return }
            let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let subagent = object["isSidechain"] as? Bool ?? false
            func add(_ kind: WorkLogEventKind) {
                batch.events.append(WorkLogEvent(time: time, source: .claude, sessionID: session, cwd: cwd,
                                                 isSubagent: subagent, kind: kind))
            }
            if lastActivity[session].map({ abs(time.timeIntervalSince($0)) >= Self.activityResolution }) ?? true {
                lastActivity[session] = time
                add(.activity)
            }
            let message = object["message"] as? [String: Any]
            if type == "assistant" {
                for block in message?["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    guard let name = block["name"] as? String, Self.editTools.contains(name),
                          let input = block["input"] as? [String: Any],
                          let file = (input["file_path"] ?? input["notebook_path"]) as? String, !file.isEmpty else { continue }
                    add(.fileEdit(path: file))
                }
            } else if let result = object["toolUseResult"] as? [String: Any] {
                for file in Self.shellEditedFiles(result) { add(.fileEdit(path: file)) }
                if let git = result["gitOperation"] as? [String: Any] {
                    if let sha = (git["commit"] as? [String: Any])?["sha"] as? String, !sha.isEmpty { add(.commit(sha: sha)) }
                    if let url = (git["pr"] as? [String: Any])?["url"] as? String, !url.isEmpty { add(.pullRequest(url: url)) }
                }
            } else if !subagent, let count = Self.promptLength(object, message: message) {
                add(.prompt(PromptLocation(path: path, offset: line.offset, length: line.data.count, characterCount: count)))
            }
        default:
            return
        }
    }

    /// Files a shell command changed, as Claude Code reports them after running it.
    private static func shellEditedFiles(_ result: [String: Any]) -> [String] {
        guard let diff = result["bashEditDiff"] as? [String: Any] else { return [] }
        var files = (diff["changedFiles"] as? [String]) ?? []
        for entry in diff["files"] as? [[String: Any]] ?? [] {
            if let path = entry["filePath"] as? String { files.append(path) }
        }
        var seen = Set<String>()
        return files.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Character count of a prompt the person typed, or nil for tool results, meta lines, compaction
    /// summaries, messages from other sessions and injected context.
    private static func promptLength(_ object: [String: Any], message: [String: Any]?) -> Int? {
        if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return nil }
        if let origin = object["origin"] as? [String: Any], origin["kind"] as? String != "human" { return nil }
        if object["promptSource"] as? String == "system" { return nil }
        guard let parts = LogParsing.claudeParts(message) else { return nil }
        return LogParsing.typedText(parts)?.count
    }

    private static func title(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(120))
    }
}
