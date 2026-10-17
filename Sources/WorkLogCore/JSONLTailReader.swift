import Foundation

/// One complete line of a JSONL file and where it starts.
public struct JSONLLine: Sendable {
    public let offset: UInt64
    public let data: Data
    public init(offset: UInt64, data: Data) { self.offset = offset; self.data = data }
}

/// How far a log file has been read. A file that was replaced or shrank is read again from the start.
public struct LogCursor: Codable, Equatable, Sendable {
    public let fileID: UInt64
    public let offset: UInt64
    public init(fileID: UInt64, offset: UInt64) { self.fileID = fileID; self.offset = offset }
}

public struct TailReadResult: Equatable, Sendable {
    public let cursor: LogCursor
    /// The file was read from the start because it was new, replaced or truncated.
    public let restarted: Bool
    /// Every complete line was read. False when `maxBytes` stopped the read early.
    public let reachedEnd: Bool
}

/// Reads only what was appended to a JSONL file since the last cursor, in fixed-size chunks, so a log of
/// hundreds of megabytes never sits in memory at once. A trailing line without a newline is left for the
/// next read, since the CLI may still be writing it.
public enum JSONLTailReader {
    public static func read(_ url: URL, from cursor: LogCursor?, chunkSize: Int = 1 << 20,
                            maxBytes: UInt64 = .max, line handle: (JSONLLine) -> Void) throws -> TailReadResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var start: UInt64 = 0
        var restarted = true
        if let cursor, cursor.fileID == fileID, cursor.offset <= size {
            start = cursor.offset
            restarted = false
        }
        guard start < size else {
            return TailReadResult(cursor: LogCursor(fileID: fileID, offset: start), restarted: restarted, reachedEnd: true)
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: start)

        var pending = Data()
        var pendingOffset = start      // file offset of pending[0]
        var consumed = start           // offset just past the last complete line
        var searched = 0               // bytes of pending already known to hold no newline
        var read: UInt64 = 0
        // Stop at the budget, but always finish at least one line so a line longer than the budget
        // cannot stall the reader forever.
        while consumed < size, read < maxBytes || consumed == start {
            var wanted = min(UInt64(chunkSize), size - (pendingOffset + UInt64(pending.count)))
            if read < maxBytes { wanted = min(wanted, maxBytes - read) }
            guard wanted > 0, let chunk = try file.read(upToCount: Int(wanted)), !chunk.isEmpty else { break }
            read += UInt64(chunk.count)
            pending.append(chunk)
            let breaks = Self.newlines(in: pending, from: searched)
            var lineStart = 0
            for end in breaks {
                var stop = end
                if stop > lineStart, pending[stop - 1] == UInt8(ascii: "\r") { stop -= 1 }
                if stop > lineStart {
                    handle(JSONLLine(offset: pendingOffset + UInt64(lineStart), data: pending.subdata(in: lineStart..<stop)))
                }
                lineStart = end + 1
            }
            consumed = pendingOffset + UInt64(lineStart)
            if lineStart > 0 { pending = pending.subdata(in: lineStart..<pending.count) }
            pendingOffset = consumed
            searched = pending.count
        }
        return TailReadResult(cursor: LogCursor(fileID: fileID, offset: consumed), restarted: restarted,
                              reachedEnd: pendingOffset + UInt64(pending.count) >= size)
    }

    /// Indexes of every newline in `data` at or after `from`, found with memchr.
    private static func newlines(in data: Data, from: Int) -> [Int] {
        data.withUnsafeBytes { raw -> [Int] in
            guard let base = raw.baseAddress else { return [] }
            var found: [Int] = []
            var index = from
            while index < raw.count, let hit = memchr(base + index, Int32(UInt8(ascii: "\n")), raw.count - index) {
                let position = base.distance(to: UnsafeRawPointer(hit))
                found.append(position)
                index = position + 1
            }
            return found
        }
    }
}
