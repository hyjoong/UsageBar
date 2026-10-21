import Foundation

/// The short, redacted line of a prompt that the work log shows. Read from the original session log at
/// display time, so the journal never keeps a copy of what the person typed.
public enum PromptExcerpt {
    public static let maxCharacters = 80

    /// Reads the prompt at `location` and returns its first meaningful line, shortened and with
    /// secrets masked. Nil when the log is gone, changed, or the line is no longer a prompt.
    public static func read(_ location: PromptLocation) -> String? {
        guard location.length > 0, location.length <= 8_000_000,
              let handle = FileHandle(forReadingAtPath: location.path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: location.offset)) != nil,
              let data = try? handle.read(upToCount: location.length), data.count == location.length,
              let object = LogParsing.json(data) else { return nil }
        let parts: [String]?
        if let payload = object["payload"] as? [String: Any] {
            parts = LogParsing.codexParts(payload)
        } else {
            parts = LogParsing.claudeParts(object["message"] as? [String: Any])
        }
        guard let parts, let text = LogParsing.typedText(parts) else { return nil }
        return excerpt(text)
    }

    /// First non-empty line, whitespace collapsed, secrets masked, at most `maxCharacters` characters.
    /// Text that opens with a code block or is mostly pasted output becomes a placeholder.
    public static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { return String(localized: "(붙여넣은 내용)") }
        // Only 80 characters are shown, so a huge single line (minified JSON, base64) is cut before the
        // patterns run; their lookaheads would otherwise rescan it for every match attempt.
        let first = trimmed.split(whereSeparator: \.isNewline).first.map { String($0.prefix(Self.redactionLimit)) } ?? ""
        let collapsed = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let masked = redact(collapsed)
        guard masked.count > maxCharacters else { return masked }
        return String(masked.prefix(maxCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static let redactionLimit = 2_000

    private static let patterns: [(NSRegularExpression, String)] = [
        // URL query strings often carry tokens; keep the address, drop the query.
        (#"(https?://[^\s?#]+)\?[^\s#]*"#, "$1?•••"),
        // A password in a connection string: postgres://admin:secret@host keeps the user, hides the rest.
        (#"(\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]+):[^\s@/]+@"#, "$1:•••@"),
        // NAME=value where the name says secret: DB_PASSWORD=..., api_key: "...", GITHUB_TOKEN=...
        (#"(?i)\b([A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Z0-9_]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;]+)"#, "$1$2•••"),
        // Authorization header values.
        (#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/\-]{8,}=*"#, "$1 •••"),
        (#"\b(sk|pk|rk)-[A-Za-z0-9_\-]{16,}"#, "•••"),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "•••"),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "•••"),
        (#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, "•••"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "•••"),
        (#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]*"#, "•••"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "•••"),
        // Long runs of key-like characters mixing letters and digits (hex or base64 secrets). Paths and
        // long identifiers survive: "/" and "." break a run, and plain words have no digits.
        (#"\b(?=[A-Za-z0-9+_\-]*[0-9])(?=[A-Za-z0-9+_\-]*[A-Za-z])[A-Za-z0-9+_\-]{32,}={0,2}"#, "•••"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Masks API keys, tokens, passwords, email addresses and URL query strings.
    public static func redact(_ text: String) -> String {
        patterns.reduce(text) { value, rule in
            rule.0.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: rule.1)
        }
    }
}
