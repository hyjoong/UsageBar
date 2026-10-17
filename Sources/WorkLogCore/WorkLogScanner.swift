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
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}

public struct WorkLogScanStats: Equatable, Sendable {
    public var files = 0
    public var bytes: UInt64 = 0
    public var lines = 0
    /// True when the byte budget stopped the scan before every file was read.
    public var isPartial = false
}

/// Reads every session log written since a date, from the start of each file. The persistent cursor
/// index that makes later refreshes read only appended lines comes in the next step; this is the
/// stateless version used by the doctor tool and tests.
public enum WorkLogScanner {
    public static func scan(source: WorkLogSource, roots: [URL], since: Date,
                            maxBytes: UInt64 = .max) -> (batch: WorkLogBatch, stats: WorkLogScanStats) {
        var batch = WorkLogBatch()
        var stats = WorkLogScanStats()
        var budget = maxBytes
        for url in files(in: roots, modifiedSince: since) {
            guard budget > 0 else { stats.isPartial = true; break }
            var local = WorkLogBatch()
            var claude = ClaudeLogParser(), codex = CodexLogParser()
            let path = url.path
            guard let result = try? JSONLTailReader.read(url, from: nil, maxBytes: budget, line: { line in
                stats.lines += 1
                switch source {
                case .claude: claude.consume(line, path: path, into: &local)
                case .codex: codex.consume(line, path: path, into: &local)
                case .git: break
                }
            }) else { continue }
            stats.files += 1
            stats.bytes += result.cursor.offset
            budget -= min(budget, result.cursor.offset)
            if !result.reachedEnd { stats.isPartial = true }
            local.events.removeAll { $0.time < since }
            batch.append(local)
        }
        return (batch, stats)
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
