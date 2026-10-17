import Foundation

/// Small helpers shared by the Claude Code and Codex log parsers.
enum LogParsing {
    /// Byte search before JSON decoding, so the many lines a parser does not need are skipped cheaply.
    /// `within` limits the search to the start of the line, where both CLIs put the record type.
    static func contains(_ data: Data, _ needle: [UInt8], within limit: Int = .max) -> Bool {
        guard !needle.isEmpty, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { pattern in
                memmem(haystack.baseAddress, min(haystack.count, limit), pattern.baseAddress, pattern.count) != nil
            }
        }
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }

    private static let timestampKey = Array(#""timestamp":""#.utf8)

    /// The first `"timestamp":"…"` value in a line, read without decoding the JSON. Only used to decide
    /// whether a line is worth decoding at all.
    static func leadingTimestamp(_ data: Data) -> Date? {
        data.withUnsafeBytes { raw -> Date? in
            guard let base = raw.baseAddress,
                  let hit = memmem(base, min(raw.count, 512), timestampKey, timestampKey.count) else { return nil }
            let start = base.distance(to: hit) + timestampKey.count
            var end = start
            while end < raw.count, end - start < 40, raw[end] != UInt8(ascii: "\"") { end += 1 }
            guard end < raw.count, raw[end] == UInt8(ascii: "\"") else { return nil }
            return date(String(decoding: raw[start..<end], as: UTF8.self))
        }
    }

    static func int(_ value: Any?) -> Int64? {
        (value as? NSNumber).map(\.int64Value)
    }

    /// Text the person typed, or nil for injected context (`<environment_context>`, `<command-name>` …)
    /// and slash commands.
    static func typedText(_ parts: [String]) -> String? {
        let kept = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") }
        let text = kept.joined(separator: "\n")
        guard !text.isEmpty, !text.hasPrefix("/") else { return nil }
        return text
    }
}
