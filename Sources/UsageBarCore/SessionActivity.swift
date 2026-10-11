import Foundation

/// Tokens and calls attributed to one model during a work session, aggregated from local CLI session logs.
public struct ModelActivity: Codable, Equatable, Sendable, Identifiable {
    public let model: String
    public var calls: Int
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var id: String { model }

    public init(model: String, calls: Int = 0, inputTokens: Int64 = 0, outputTokens: Int64 = 0,
                cacheReadTokens: Int64 = 0, cacheWriteTokens: Int64 = 0) {
        self.model = model; self.calls = calls; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
    }
}

/// Calls attributed to one project folder (last path component of the CLI's working directory).
public struct ProjectActivity: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public var calls: Int
    public var outputTokens: Int64
    public var id: String { name }
    public init(name: String, calls: Int = 0, outputTokens: Int64 = 0) {
        self.name = name; self.calls = calls; self.outputTokens = outputTokens
    }
}

/// What this Mac's CLI did during a session: models, token counts and project folders only. No message content.
public struct SessionActivity: Codable, Equatable, Sendable {
    public var models: [ModelActivity]
    public var projects: [ProjectActivity]
    /// True when scanning stopped early (time budget or oversized logs); totals are a lower bound.
    public var isPartial: Bool

    public init(models: [ModelActivity], projects: [ProjectActivity], isPartial: Bool = false) {
        self.models = models; self.projects = projects; self.isPartial = isPartial
    }
    public var isEmpty: Bool { models.isEmpty }
    public var calls: Int { models.reduce(0) { $0 + $1.calls } }
    public var inputTokens: Int64 { models.reduce(0) { $0 + $1.inputTokens } }
    public var outputTokens: Int64 { models.reduce(0) { $0 + $1.outputTokens } }
    public var cacheReadTokens: Int64 { models.reduce(0) { $0 + $1.cacheReadTokens } }

    public static let demo = SessionActivity(
        models: [ModelActivity(model: "claude-fable-5-1", calls: 42, inputTokens: 1_240_000, outputTokens: 48_300,
                               cacheReadTokens: 910_000, cacheWriteTokens: 122_000)],
        projects: [ProjectActivity(name: "UsageBar", calls: 38, outputTokens: 44_000),
                   ProjectActivity(name: "docs", calls: 4, outputTokens: 4_300)])
}

/// One API call seen in a session log.
public struct ActivitySample: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let project: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public init(timestamp: Date, model: String, project: String, inputTokens: Int64, outputTokens: Int64,
                cacheReadTokens: Int64 = 0, cacheWriteTokens: Int64 = 0) {
        self.timestamp = timestamp; self.model = model; self.project = project; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
    }
}

public enum SessionActivityAggregator {
    public static func aggregate(_ samples: [ActivitySample], between start: Date, and end: Date,
                                 isPartial: Bool = false) -> SessionActivity {
        var models: [String: ModelActivity] = [:]
        var projects: [String: ProjectActivity] = [:]
        for sample in samples where sample.timestamp >= start && sample.timestamp <= end {
            var model = models[sample.model] ?? ModelActivity(model: sample.model)
            model.calls += 1
            model.inputTokens += sample.inputTokens
            model.outputTokens += sample.outputTokens
            model.cacheReadTokens += sample.cacheReadTokens
            model.cacheWriteTokens += sample.cacheWriteTokens
            models[sample.model] = model
            var project = projects[sample.project] ?? ProjectActivity(name: sample.project)
            project.calls += 1
            project.outputTokens += sample.outputTokens
            projects[sample.project] = project
        }
        return SessionActivity(
            models: models.values.sorted { ($0.outputTokens, $0.calls, $1.model) > ($1.outputTokens, $1.calls, $0.model) },
            projects: projects.values.sorted { ($0.calls, $0.outputTokens, $1.name) > ($1.calls, $1.outputTokens, $0.name) },
            isPartial: isPartial)
    }
}

/// Reads the JSONL session logs that Claude Code and Codex keep on this Mac. Only timestamps, model names,
/// token counts and the working directory's last path component are taken from each line.
public enum LocalSessionLogs {
    public static var claudeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }
    public static var codexRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static func activity(for provider: ProviderID, between start: Date, and end: Date,
                                root: URL? = nil, timeBudget: TimeInterval = 4) -> SessionActivity? {
        let directory = root ?? (provider == .claude ? claudeRoot : codexRoot)
        let parser: ([String]) -> [ActivitySample] = provider == .claude ? claudeSamples : codexSamples
        return scan(directory: directory, between: start, and: end, timeBudget: timeBudget, parser: parser)
    }

    static func scan(directory: URL, between start: Date, and end: Date, timeBudget: TimeInterval,
                     parser: ([String]) -> [ActivitySample]) -> SessionActivity? {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let deadline = Date().addingTimeInterval(timeBudget)
        var samples: [ActivitySample] = []
        var partial = false
        var sawFiles = false
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            sawFiles = true
            if Date() > deadline { partial = true; break }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // A file last written before the session started cannot contain calls from it.
            if let modified = values?.contentModificationDate, modified < start { continue }
            if let size = values?.fileSize, size > 256 * 1024 * 1024 { partial = true; continue }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            var lines: [String] = []
            text.enumerateLines { line, _ in lines.append(line) }
            samples.append(contentsOf: parser(lines))
        }
        guard sawFiles else { return nil }
        return SessionActivityAggregator.aggregate(samples, between: start, and: end, isPartial: partial)
    }

    // MARK: Claude Code: ~/.claude/projects/<project>/<session>.jsonl

    public static func claudeSamples(_ lines: [String]) -> [ActivitySample] {
        var samples: [ActivitySample] = []
        for line in lines where line.contains("\"usage\"") && line.contains("\"assistant\"") {
            guard let object = json(line), object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = (object["timestamp"] as? String).flatMap(date) else { continue }
            samples.append(ActivitySample(
                timestamp: timestamp,
                model: (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Claude",
                project: projectName(object["cwd"] as? String),
                inputTokens: int(usage["input_tokens"]), outputTokens: int(usage["output_tokens"]),
                cacheReadTokens: int(usage["cache_read_input_tokens"]), cacheWriteTokens: int(usage["cache_creation_input_tokens"])))
        }
        return samples
    }

    // MARK: Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl

    public static func codexSamples(_ lines: [String]) -> [ActivitySample] {
        var samples: [ActivitySample] = []
        var model = "Codex"
        var project = "—"
        for line in lines {
            guard line.contains("token_count") || line.contains("turn_context") || line.contains("session_meta"),
                  let object = json(line), let payload = object["payload"] as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "session_meta":
                if let cwd = payload["cwd"] as? String { project = projectName(cwd) }
            case "turn_context":
                if let name = payload["model"] as? String, !name.isEmpty { model = name }
                if let cwd = payload["cwd"] as? String { project = projectName(cwd) }
            case "event_msg" where payload["type"] as? String == "token_count":
                guard let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any],
                      let timestamp = (object["timestamp"] as? String).flatMap(date) else { continue }
                let output = int(last["output_tokens"]) + int(last["reasoning_output_tokens"])
                samples.append(ActivitySample(timestamp: timestamp, model: model, project: project,
                                              inputTokens: int(last["input_tokens"]), outputTokens: output,
                                              cacheReadTokens: int(last["cached_input_tokens"]),
                                              cacheWriteTokens: int(last["cache_write_input_tokens"])))
            default: continue
            }
        }
        return samples
    }

    // MARK: Helpers

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func date(_ text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber: return max(0, number.int64Value)
        default: return 0
        }
    }

    static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "—" : String(name.prefix(80))
    }
}

/// Compact token counts: 48K, 1.2M.
public enum TokenFormat {
    public static func compact(_ number: Int64) -> String {
        if number >= 1_000_000 { return String(format: "%.1fM", Double(number) / 1_000_000) }
        if number >= 10_000 { return String(format: "%.0fK", Double(number) / 1_000) }
        if number >= 1_000 { return String(format: "%.1fK", Double(number) / 1_000) }
        return String(number)
    }
}
