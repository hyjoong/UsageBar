import Foundation

/// Where a work log event was read from.
public enum WorkLogSource: String, Codable, CaseIterable, Sendable {
    case claude, codex, git
}

/// Where a user prompt sits in its session log. The prompt text itself is never stored: it is read back
/// from the original log only when the journal is drawn, so deleting the log removes it from the journal too.
public struct PromptLocation: Codable, Hashable, Sendable {
    public let path: String
    public let offset: UInt64
    public let length: Int
    /// Characters in the prompt after injected context is removed. Lets selection skip short replies
    /// ("ok", "계속") without reading the text again.
    public let characterCount: Int

    public init(path: String, offset: UInt64, length: Int, characterCount: Int) {
        self.path = path; self.offset = offset; self.length = length; self.characterCount = characterCount
    }
}

public enum WorkLogEventKind: Codable, Hashable, Sendable {
    /// The agent or the user did something at this moment (a message, a tool call, a tool result).
    case activity
    /// A prompt the person typed. Injected context, slash commands and subagent instructions are excluded.
    case prompt(PromptLocation)
    /// The agent changed this file (absolute path as logged).
    case fileEdit(path: String)
    /// A Codex turn ran from the event time until `end`; quiet stretches inside it still count as work.
    case turn(end: Date)
    /// The agent reported a git commit.
    case commit(sha: String)
    /// The agent opened or linked a pull request.
    case pullRequest(url: String)
}

/// One normalized moment from a Claude Code or Codex session log.
public struct WorkLogEvent: Codable, Hashable, Sendable {
    public let time: Date
    public let source: WorkLogSource
    public let sessionID: String
    /// The working directory the CLI reported at that moment. Nil when the log line carried none.
    public let cwd: String?
    /// Work done by a subagent on the person's behalf. Counts toward time, never toward prompts.
    public let isSubagent: Bool
    public let kind: WorkLogEventKind

    public init(time: Date, source: WorkLogSource, sessionID: String, cwd: String?, isSubagent: Bool = false,
                kind: WorkLogEventKind) {
        self.time = time; self.source = source; self.sessionID = sessionID; self.cwd = cwd
        self.isSubagent = isSubagent; self.kind = kind
    }
}

/// What parsing a stretch of log produced.
public struct WorkLogBatch: Codable, Equatable, Sendable {
    public var events: [WorkLogEvent]
    /// Session titles the CLI generated or the person set, by session ID.
    public var titles: [String: String]

    public init(events: [WorkLogEvent] = [], titles: [String: String] = [:]) {
        self.events = events; self.titles = titles
    }

    public mutating func append(_ other: WorkLogBatch) {
        events.append(contentsOf: other.events)
        titles.merge(other.titles) { _, new in new }
    }
}
