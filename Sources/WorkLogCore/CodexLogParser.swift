import Foundation

/// Turns Codex rollout lines (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) into work log events.
/// One rollout is one thread; `session_meta` and `turn_context` set the session and working directory that
/// later lines belong to, so the parser carries them as state between reads.
public struct CodexLogParser: Codable, Equatable, Sendable {
    /// Turns longer than this are cut: a turn left waiting overnight is not three hours of work.
    public static let maxTurn: TimeInterval = 3 * 3600

    private var sessionID: String?
    private var cwd: String?
    private var isSubagent = false
    private var lastActivity: Date?

    public init() {}

    private static let detailNeedles = ["\"session_meta\"", "\"turn_context\"", "\"task_complete\"", "\"turn_aborted\"",
                                        #""role":"user""#, "\"FileChange\""].map { Array($0.utf8) }

    public mutating func consume(_ line: JSONLLine, path: String, into batch: inout WorkLogBatch) {
        let data = line.data
        // Record types sit in the first few hundred bytes; tool output later in a line can be megabytes long.
        let detailed = Self.detailNeedles.contains { LogParsing.contains(data, $0, within: 512) }
        if !detailed {
            // Plain activity only needs the timestamp, so the line (often a large tool output) is never decoded.
            guard let time = LogParsing.leadingTimestamp(data) else { return }
            if let last = lastActivity, abs(time.timeIntervalSince(last)) < ClaudeLogParser.activityResolution { return }
            lastActivity = time
            append(.activity, at: time, path: path, into: &batch)
            return
        }
        guard let object = LogParsing.json(data), let payload = object["payload"] as? [String: Any],
              let time = LogParsing.date(object["timestamp"]) else { return }
        let type = object["type"] as? String
        let payloadType = payload["type"] as? String

        switch (type, payloadType) {
        case ("session_meta", _):
            if let id = (payload["id"] ?? payload["session_id"]) as? String, !id.isEmpty { sessionID = id }
            if let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }
            let source = payload["source"] as? [String: Any]
            isSubagent = source?["subagent"] != nil || payload["parent_thread_id"] is String
        case ("turn_context", _):
            if let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }
        case ("event_msg", "task_complete"?), ("event_msg", "turn_aborted"?):
            guard let milliseconds = LogParsing.int(payload["duration_ms"]), milliseconds > 0 else { break }
            let length = min(Double(milliseconds) / 1000, Self.maxTurn)
            append(.turn(end: time), at: time.addingTimeInterval(-length), path: path, into: &batch)
        case ("response_item", "message"?) where payload["role"] as? String == "user":
            let parts = (payload["content"] as? [[String: Any]] ?? []).compactMap { item in
                item["type"] as? String == "input_text" ? item["text"] as? String : nil
            }
            if !isSubagent, let text = LogParsing.typedText(parts) {
                append(.prompt(PromptLocation(path: path, offset: line.offset, length: data.count, characterCount: text.count)),
                       at: time, path: path, into: &batch)
            }
        case ("event_msg", "item_completed"?):
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "FileChange",
                  let changes = item["changes"] as? [String: Any] else { break }
            for file in changes.keys.sorted() where !file.isEmpty {
                append(.fileEdit(path: file), at: time, path: path, into: &batch)
            }
        default:
            break
        }
        if lastActivity.map({ abs(time.timeIntervalSince($0)) >= ClaudeLogParser.activityResolution }) ?? true {
            lastActivity = time
            append(.activity, at: time, path: path, into: &batch)
        }
    }

    private func append(_ kind: WorkLogEventKind, at time: Date, path: String, into batch: inout WorkLogBatch) {
        let session = sessionID ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        batch.events.append(WorkLogEvent(time: time, source: .codex, sessionID: session, cwd: cwd,
                                         isSubagent: isSubagent, kind: kind))
    }
}
