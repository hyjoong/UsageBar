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
        return fastDate(Array(text.utf8)) ?? fractional.date(from: text) ?? whole.date(from: text)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` parsed with integer arithmetic. Both CLIs write every
    /// timestamp this way, and ISO8601DateFormatter (ICU) was most of the time spent reading large logs.
    /// Anything else returns nil and falls back to the formatter.
    static func fastDate(_ bytes: [UInt8]) -> Date? {
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for index in start..<(start + count) {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes.count >= 20, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84 || bytes[10] == 116,
              bytes[13] == 58, bytes[16] == 58,
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var index = 19
        var fraction = 0.0
        if bytes[index] == 46 {
            var scale = 0.1
            index += 1
            let start = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
            guard index > start else { return nil }
        }
        guard index < bytes.count else { return nil }
        var offset = 0
        switch bytes[index] {
        case 90, 122:   // Z
            guard index + 1 == bytes.count else { return nil }
        case 43, 45:    // + or -
            guard index + 6 == bytes.count, bytes[index + 3] == 58,
                  let hours = digits(index + 1, 2), let minutes = digits(index + 4, 2) else { return nil }
            offset = (hours * 3600 + minutes * 60) * (bytes[index] == 43 ? 1 : -1)
        default:
            return nil
        }
        // Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
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
            return fastDate(Array(raw[start..<end])) ?? date(String(decoding: raw[start..<end], as: UTF8.self))
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

    /// Text blocks of a Claude Code user message, or nil when it carries a tool result.
    static func claudeParts(_ message: [String: Any]?) -> [String]? {
        switch message?["content"] {
        case let text as String:
            return [text]
        case let blocks as [[String: Any]]:
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        default:
            return nil
        }
    }

    /// Text items of a Codex user message payload.
    static func codexParts(_ payload: [String: Any]) -> [String] {
        (payload["content"] as? [[String: Any]] ?? []).compactMap { item in
            item["type"] as? String == "input_text" ? item["text"] as? String : nil
        }
    }
}
