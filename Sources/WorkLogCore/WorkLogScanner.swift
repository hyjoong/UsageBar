import Foundation

/// Where the CLIs keep their session logs on this Mac.
public enum WorkLogRoots {
    public static var claude: [URL] {
        [home.appendingPathComponent(".claude/projects", isDirectory: true)]
    }
    public static var codex: [URL] {
        [home.appendingPathComponent(".codex/sessions", isDirectory: true),
         home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)]
    }
    /// Thread names Codex keeps beside its sessions.
    public static var codexSessionIndex: URL { home.appendingPathComponent(".codex/session_index.jsonl") }
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}

public struct WorkLogScanStats: Equatable, Sendable {
    public var files = 0
    /// Bytes read in this pass (appended data only, once a file is indexed).
    public var bytes: UInt64 = 0
    public var lines = 0
    /// True when the byte budget stopped the pass before every file was read; the next pass continues.
    public var isPartial = false
    public init() {}
}

/// How far each session log has been read and what it produced. Persisted by `LogIndexStore`, so a
/// refresh reads only lines appended since the last one.
public struct LogIndex: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var source: WorkLogSource
        public var cursor: LogCursor?
        public var claude = ClaudeLogParser()
        public var codex = CodexLogParser()
        public var batch = WorkLogBatch()
        public init(source: WorkLogSource) { self.source = source }
    }

    public static let currentVersion = 1
    public var version = LogIndex.currentVersion
    public var files: [String: Entry] = [:]
    public init() {}

    /// Every indexed event and title, oldest event first.
    public var batch: WorkLogBatch {
        var all = WorkLogBatch()
        for path in files.keys.sorted() { all.append(files[path]!.batch) }
        all.events.sort { $0.time < $1.time }
        return all
    }
}

public enum WorkLogIndexer {
    /// Brings `index` up to date with the logs under `roots`: reads what was appended to each file written
    /// since `since`, drops events older than `since` and forgets files that went out of range.
    /// `maxBytes` bounds the work of one pass; cursors are kept, so the next pass continues.
    @discardableResult
    public static func refresh(_ index: inout LogIndex, source: WorkLogSource, roots: [URL], since: Date,
                               maxBytes: UInt64 = .max) -> WorkLogScanStats {
        var stats = WorkLogScanStats()
        var budget = maxBytes
        let candidates = files(in: roots, modifiedSince: since)
        let live = Set(candidates.map(\.path))
        for (path, entry) in index.files where entry.source == source && !live.contains(path) {
            index.files[path] = nil
        }
        for url in candidates {
            let path = url.path
            var entry = index.files[path] ?? LogIndex.Entry(source: source)
            guard budget > 0 else { stats.isPartial = true; break }
            var claude = entry.claude, codex = entry.codex
            var fresh = WorkLogBatch()
            var lines = 0
            func read(from cursor: LogCursor?) -> TailReadResult? {
                try? JSONLTailReader.read(url, from: cursor, maxBytes: budget) { line in
                    lines += 1
                    switch source {
                    case .claude: claude.consume(line, path: path, into: &fresh)
                    case .codex: codex.consume(line, path: path, notBefore: since, into: &fresh)
                    case .git: break
                    }
                }
            }
            guard var result = read(from: entry.cursor) else { continue }
            if result.restarted, entry.cursor != nil {
                // Replaced or truncated: start over with fresh parser state, since the old state described
                // a different file.
                entry = LogIndex.Entry(source: source)
                claude = entry.claude; codex = entry.codex; fresh = WorkLogBatch(); lines = 0
                guard let again = read(from: nil) else { index.files[path] = nil; continue }
                result = again
            }
            let bytes = result.cursor.offset - (result.restarted ? 0 : entry.cursor?.offset ?? 0)
            entry.cursor = result.cursor
            entry.claude = claude
            entry.codex = codex
            entry.batch.append(fresh)
            entry.batch.events.removeAll { $0.time < since }
            index.files[path] = entry
            stats.files += 1
            stats.lines += lines
            stats.bytes += bytes
            budget -= min(budget, bytes)
            if !result.reachedEnd { stats.isPartial = true }
        }
        return stats
    }

    /// `.jsonl` files under `roots` last written at or after `since`, newest first.
    public static func files(in roots: [URL], modifiedSince since: Date) -> [URL] {
        var found: [(URL, Date)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
                      modified >= since else { continue }
                found.append((url, modified))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Reads every session log written since a date in one pass, without a stored index.
public enum WorkLogScanner {
    public static func scan(source: WorkLogSource, roots: [URL], since: Date,
                            maxBytes: UInt64 = .max) -> (batch: WorkLogBatch, stats: WorkLogScanStats) {
        var index = LogIndex()
        let stats = WorkLogIndexer.refresh(&index, source: source, roots: roots, since: since, maxBytes: maxBytes)
        return (index.batch, stats)
    }
}

/// Thread names from `~/.codex/session_index.jsonl`, by thread ID.
public enum CodexSessionTitles {
    public static func read(_ url: URL = WorkLogRoots.codexSessionIndex, maxBytes: Int = 4_000_000) -> [String: String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return [:] }
        var titles: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = LogParsing.json(Data(line)), let id = object["id"] as? String,
                  let name = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, !name.isEmpty else { continue }
            titles[id] = String(name.prefix(120))
        }
        return titles
    }
}
