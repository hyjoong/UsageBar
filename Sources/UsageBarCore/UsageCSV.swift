import Foundation

/// Exports usage measurements only; credentials, account identities and raw responses
/// are deliberately absent from this API.
public enum UsageCSV {
    public static func limits(_ points: [HistoryPoint], provider: ProviderID) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var rows = ["provider,observed_at,window,remaining_percent,resets_at"]
        for point in points where point.provider == provider {
            rows.append([
                textCell(provider.rawValue),
                textCell(formatter.string(from: point.date)),
                textCell(point.windowName),
                String(point.remaining),
                textCell(point.resetsAt.map { formatter.string(from: $0) } ?? "")
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    public static func dailyUsage(_ records: [DailyUsage], provider: ProviderID) -> String {
        let rows = ["provider,day,tokens"] + records.map { record in
            [textCell(provider.rawValue), textCell(record.day), String(record.tokens)].joined(separator: ",")
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private static func textCell(_ value: String) -> String {
        // CSV quoting does not prevent spreadsheet formula evaluation. Check past leading
        // whitespace and controls; retain the original value after an inert apostrophe.
        let ignoredPrefix = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters).union(CharacterSet(charactersIn: "\u{FEFF}"))
        let first = value.unicodeScalars.first { !ignoredPrefix.contains($0) }
        let startsFormula = first.map { CharacterSet(charactersIn: "=+-@").contains($0) } ?? false
        let safe = (startsFormula ? "'" : "") + value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
