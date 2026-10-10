import Foundation
import CryptoKit

public actor ClaudeProvider: UsageProvider {
    public nonisolated let id: ProviderID = .claude
    private let executablePath: String?
    private var inFlight: Task<ProviderSnapshot, Error>?

    public init(executablePath: String? = nil) { self.executablePath = executablePath }

    public static var connectionDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageBar/ClaudeConnection", isDirectory: true)
    }

    @discardableResult
    public static func prepareConnectionDirectory() throws -> URL {
        try prepareConnectionDirectory(at: connectionDirectoryURL)
    }

    /// Creates a user-opened Terminal launcher containing paths only, never credentials.
    /// The explicit executable keeps Terminal's PATH from selecting a different install.
    public static func prepareConnectionScript(scriptURL: URL) throws -> URL {
        try prepareConnectionScript(scriptURL: scriptURL, directory: connectionDirectoryURL,
                                    environment: ProcessInfo.processInfo.environment,
                                    home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func prepareConnectionScript(scriptURL: URL, directory: URL,
                                        environment: [String: String], home: URL,
                                        knownPaths: [String]? = nil) throws -> URL {
        let manager = FileManager.default
        guard let executable = resolveExecutable(preferred: nil, environment: environment, home: home,
                                                 knownPaths: knownPaths) else {
            throw ProviderError.setupRequired("Claude Code가 필요해요. 설치 후 터미널에서 로그인해 주세요.")
        }
        guard scriptURL.isFileURL, !scriptURL.path.utf8.contains(0),
              scriptURL.resolvingSymlinksInPath().standardizedFileURL.path == scriptURL.standardizedFileURL.path,
              manager.isReadableFile(atPath: scriptURL.path),
              (try? scriptURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw ProviderError.setupRequired("Claude 연결 설정 파일을 사용할 수 없어요. build 폴더의 UsageBar.app을 다시 실행해 주세요.")
        }
        let folder = try prepareConnectionDirectory(at: directory)
        let launcher = folder.appendingPathComponent("ConnectClaude.command")
        guard (try? manager.destinationOfSymbolicLink(atPath: launcher.path)) == nil else {
            throw ProviderError.setupRequired("Claude 연결 실행 파일이 다른 위치로 연결되어 있어요.")
        }
        if manager.fileExists(atPath: launcher.path) {
            let values = try launcher.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ProviderError.setupRequired("Claude 연결 실행 파일의 경로를 확인해 주세요.")
            }
        }
        let arguments = ["/bin/zsh", scriptURL.standardizedFileURL.path, "--claude-executable", executable]
        let command = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        try ("#!/bin/zsh\nset -euo pipefail\nexec " + command + "\n")
            .write(to: launcher, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return launcher
    }

    static func prepareConnectionDirectory(at directory: URL) throws -> URL {
        let manager = FileManager.default
        let path = directory.standardizedFileURL.path
        func validatePath() throws {
            // Foundation may leave symlinked ancestors unresolved when the final folder
            // does not exist yet. Check every component before creating anything.
            var component = URL(fileURLWithPath: "/", isDirectory: true)
            for name in directory.standardizedFileURL.pathComponents.dropFirst() {
                component.appendPathComponent(name, isDirectory: true)
                if (try? manager.destinationOfSymbolicLink(atPath: component.path)) != nil {
                    throw ProviderError.setupRequired("Claude 연결 폴더가 다른 위치로 연결되어 있어요. 연결 폴더의 경로를 확인해 주세요.")
                }
            }
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path == path else {
                throw ProviderError.setupRequired("Claude 연결 폴더가 다른 위치로 연결되어 있어요. 연결 폴더의 경로를 확인해 주세요.")
            }
        }
        try validatePath()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try validatePath()
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ProviderError.setupRequired("Claude 연결 폴더를 사용할 수 없어요. 연결 폴더의 경로를 확인해 주세요.")
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return directory
        } catch let error as ProviderError { throw error }
        catch { throw ProviderError.setupRequired("Claude 연결 폴더를 만들지 못했어요. 연결 폴더의 권한을 확인해 주세요.") }
    }

    public func fetch() async throws -> ProviderSnapshot {
        if let inFlight { return try await inFlight.value }
        let executablePath = self.executablePath
        let task = Task { try await Self.fetchSnapshot(executablePath: executablePath) }
        inFlight = task
        defer { inFlight = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private static func fetchSnapshot(executablePath: String?) async throws -> ProviderSnapshot {
        var environment = ProcessInfo.processInfo.environment
        guard let executable = resolveExecutable(preferred: executablePath, environment: environment) else {
            throw ProviderError.setupRequired("Claude Code가 필요해요. 설치 후 터미널에서 로그인해 주세요.")
        }
        // Run the installed CLI under its own stored login. Never inspect credential values.
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        environment.removeValue(forKey: "CLAUDECODE")
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["TERM"] = "xterm-256color"
        // The user confirms only this app-owned connection folder in the setup terminal.
        // Preserve the normal CLI config and authentication directories.
        let directory = try prepareConnectionDirectory()
        environment["PWD"] = directory.path
        let processEnvironment = environment
        let capture = ClaudePTYCapture()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let started = Date()
                let metadata = try capture.authMetadata(executable: executable, directory: directory, environment: processEnvironment)
                let windows = try capture.run(executable: executable, directory: directory, environment: processEnvironment,
                                              timeout: max(0.1, 25 - Date().timeIntervalSince(started)))
                return (windows, metadata)
            }.value
        } onCancel: { capture.cancel() }
        try Task.checkCancellation()
        return ProviderSnapshot(provider: .claude, accountKey: result.1?.accountKey, plan: result.1?.plan,
                                windows: result.0, source: "Claude Code /usage")
    }

    static func resolveExecutable(preferred: String?, environment: [String: String],
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  knownPaths: [String]? = nil) -> String? {
        let manager = FileManager.default
        func executable(_ path: String) -> String? {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            // Homebrew and native installs commonly use symlinks. Pin their executable
            // target, but never treat an executable directory as a CLI.
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard manager.isExecutableFile(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return url.path
        }
        if let preferred, !preferred.isEmpty {
            let expanded = (preferred as NSString).expandingTildeInPath
            return executable(expanded)
        }
        let known = knownPaths ?? [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/claude" }
        return (known + fromPath).lazy.compactMap(executable).first
    }
}

struct ClaudeAuthMetadata: Sendable {
    let accountKey: String?
    let plan: String?

    static func parse(_ data: Data) -> Self? {
        struct Status: Decodable {
            let loggedIn: Bool?
            let authMethod: String?
            let accountId: String?
            let email: String?
            let orgId: String?
            let subscriptionType: String?
        }
        guard data.count <= 64 * 1024, let status = try? JSONDecoder().decode(Status.self, from: data),
              status.loggedIn == true, status.authMethod == "claude.ai" else { return nil }
        let identifier = status.accountId ?? status.email?.lowercased()
        let accountKey = identifier.flatMap { value -> String? in
            guard !value.isEmpty, value.count <= 512 else { return nil }
            let identity = "claude:" + value + ":" + (status.orgId ?? "")
            return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let plans = ["pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"]
        return Self(accountKey: accountKey, plan: status.subscriptionType.flatMap { plans[$0.lowercased()] })
    }
}

enum ClaudeProbeInspection {
    case pending
    case usage([UsageWindow])
    case failure(ProviderError)
}

enum ClaudeStartupPrompt: String, Sendable {
    case folderTrust
    case terminalStyle
    case termsAcceptance

    var message: String {
        switch self {
        case .folderTrust:
            return "처음 한 번 Claude 연결 폴더를 확인해야 해요. 연결 설정을 연 뒤 안내를 완료해 주세요."
        case .terminalStyle:
            return "Claude Code가 터미널 화면 스타일 선택을 기다리고 있어요. 터미널에서 Claude를 열어 스타일을 선택해 주세요."
        case .termsAcceptance:
            return "Claude Code가 약관 확인을 기다리고 있어요. 터미널에서 Claude를 열어 약관을 직접 확인해 주세요."
        }
    }

    static func detect(in text: String) -> Self? {
        let lower = text.lowercased()
        if ["do you trust the files in this folder", "yes, i trust this folder", "quick safety check", "ready to code here"]
            .contains(where: lower.contains) { return .folderTrust }
        if ["select a text style", "choose the text style", "select a theme", "choose a theme"]
            .contains(where: lower.contains) { return .terminalStyle }
        if ["accept the terms", "accept our terms", "accept the updated terms", "agree to the terms"]
            .contains(where: lower.contains) { return .termsAcceptance }
        return nil
    }
}

enum ClaudeUsageParser {
    static func inspect(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> ClaudeProbeInspection {
        let lower = text.lowercased()
        if let prompt = ClaudeStartupPrompt.detect(in: text) { return .failure(.setupRequired(prompt.message)) }
        if ["please run /login", "login expired", "not logged in", "please log in", "authentication required",
            "oauth token has expired", "invalid oauth token", "select login method", "how would you like to log in"].contains(where: lower.contains) {
            return .failure(.authenticationRequired("Claude Code에 다시 로그인해야 해요. 터미널에서 /login을 실행해 주세요."))
        }
        if lower.contains("keychain"), ["denied", "locked", "permission", "password"].contains(where: lower.contains) {
            return .failure(.authenticationRequired("Claude Code가 로그인 정보에 접근하지 못했어요. 터미널에서 Claude를 열어 확인해 주세요."))
        }
        if ["rate limited", "rate_limit_error", "too many requests", "http 429", "error 429"].contains(where: lower.contains) {
            return .failure(.rateLimited(retryAfter: 5 * 60))
        }
        if lower.contains("failed to load usage data") {
            return .failure(.unavailable("Claude가 사용량을 불러오지 못했어요. 잠시 후 다시 시도해 주세요."))
        }
        if lower.range(of: #"(?:loading|fetching)\s+(?:usage|limits)|(?m)^\s*loading(?:\.{3}|…)\s*$"#, options: .regularExpression) != nil {
            return .pending
        }
        let quotaText: String
        if let range = text.range(of: "What's contributing to your limits usage?", options: .caseInsensitive) {
            quotaText = String(text[..<range.lowerBound])
        } else { quotaText = text }
        let lines = quotaText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var windows: [UsageWindow] = []
        for (index, line) in lines.enumerated() {
            guard let heading = heading(line) else { continue }
            var section: [String] = [line]
            for subsequent in lines.dropFirst(index + 1).prefix(12) {
                if self.heading(subsequent) != nil || subsequent.lowercased().hasPrefix("extra usage") { break }
                section.append(subsequent)
            }
            guard let percent = section.compactMap(usedPercent).first else { continue }
            let reset = section.first { $0.range(of: #"^resets?\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
            let resetAt = reset.flatMap { ClaudeResetDate.parse($0, now: now, timeZone: timeZone, windowMinutes: heading.minutes) }
            let window = UsageWindow(id: heading.id, label: heading.label, usedPercent: percent,
                                     resetsAt: resetAt, durationMinutes: heading.minutes,
                                     resetDescription: reset.flatMap(safeResetDescription))
            // The current screen can legitimately repeat headings; the last complete row wins.
            windows.removeAll { $0.id == window.id }; windows.append(window)
        }
        if !windows.isEmpty { return .usage(windows) }
        if lower.contains("only available for subscription plans") || lower.contains("api billing") {
            return .failure(.unsupported("Claude Code에서 구독 한도를 확인할 수 없어요. 구독 계정으로 로그인했는지 확인해 주세요."))
        }
        return .pending
    }

    private static func heading(_ line: String) -> (id: String, label: String, minutes: Int)? {
        if line.range(of: #"^Current\s+session\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return ("session", "5시간 한도", 300)
        }
        guard let match = captures(#"^Current\s+week\b(?:\s*\(([^)]+)\))?"#, in: line) else { return nil }
        let scope = match.count > 1 ? match[1].trimmingCharacters(in: .whitespaces) : ""
        if scope.isEmpty || scope.lowercased() == "all models" { return ("weekly", "주간 한도", 10080) }
        let slug = scope.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return nil }
        return ("weekly-\(slug)", "주간 한도 · \(scope)", 10080)
    }

    private static func usedPercent(_ line: String) -> Double? {
        guard let match = captures(#"(?<![-+\d.])([0-9]+(?:\.[0-9]+)?)\s*%\s*(used|spent|consumed|left|remaining|available)\b"#, in: line),
              let value = Double(match[1]), value.isFinite, (0...100).contains(value) else { return nil }
        return ["left", "remaining", "available"].contains(match[2].lowercased()) ? 100 - value : value
    }

    private static func safeResetDescription(_ line: String) -> String? {
        guard line.count <= 160, !line.contains("@"), !line.contains("://"),
              !line.lowercased().contains("token"), !line.lowercased().contains("bearer"),
              line.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return line
    }

    static func captures(_ pattern: String, in string: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: string) else { return "" }
            return String(string[range])
        }
    }
}

enum ClaudeResetDate {
    static func parse(_ text: String, now: Date, timeZone: TimeZone, windowMinutes: Int) -> Date? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^resets?\s*(?:at\s+|on\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
        var zone = timeZone
        if let match = ClaudeUsageParser.captures(#"\s*\(([^)]+)\)\s*$"#, in: value) {
            guard let parsed = TimeZone(identifier: match[1]) ?? TimeZone(abbreviation: match[1]) else { return nil }
            zone = parsed; value = String(value.dropLast(match[0].count)).trimmingCharacters(in: .whitespaces)
        }
        func bounded(_ date: Date?) -> Date? {
            guard let date, date >= now.addingTimeInterval(-60),
                  date.timeIntervalSince(now) <= Double(windowMinutes * 60 + 60) else { return nil }
            return date
        }
        if value.lowercased().hasPrefix("in ") {
            let duration = String(value.dropFirst(3))
            let pattern = #"([0-9]+)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            let matches = regex.matches(in: duration, range: NSRange(duration.startIndex..., in: duration))
            guard !matches.isEmpty else { return nil }
            let remainder = regex.stringByReplacingMatches(in: duration, range: NSRange(duration.startIndex..., in: duration), withTemplate: "")
            guard remainder.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))).isEmpty else { return nil }
            var seconds: Double = 0
            for match in matches {
                guard let numberRange = Range(match.range(at: 1), in: duration), let unitRange = Range(match.range(at: 2), in: duration),
                      let number = Double(duration[numberRange]) else { return nil }
                let unit = duration[unitRange].lowercased()
                seconds += number * (unit.hasPrefix("d") ? 86400 : unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
            }
            return seconds.isFinite ? bounded(now.addingTimeInterval(seconds)) : nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return bounded(date) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return bounded(date) }

        guard let time = ClaudeUsageParser.captures(#"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*$"#, in: value),
              var hour = Int(time[1]), let minute = Int(time[2].isEmpty ? "0" : time[2]), minute < 60 else { return nil }
        if !time[3].isEmpty {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (time[3].lowercased() == "pm" ? 12 : 0)
        } else { guard !time[2].isEmpty, (0...23).contains(hour) else { return nil } }
        let dateText = String(value.dropLast(time[0].count)).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"(?:,|\bat)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; calendar.locale = Locale(identifier: "en_US_POSIX")
        if dateText.isEmpty {
            let matching = DateComponents(hour: hour, minute: minute, second: 0)
            return bounded(calendar.nextDate(after: now.addingTimeInterval(-1), matching: matching, matchingPolicy: .strict))
        }
        let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        if let weekday = weekdays.firstIndex(of: String(dateText.lowercased().prefix(3))),
           dateText.range(of: #"^(sun(day)?|mon(day)?|tue(sday)?|wed(nesday)?|thu(rsday)?|fri(day)?|sat(urday)?)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return bounded(calendar.nextDate(after: now.addingTimeInterval(-1), matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday + 1), matchingPolicy: .strict))
        }
        guard let day = ClaudeUsageParser.captures(#"^(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+(\d{1,2})(?:,?\s+(\d{4}))?$"#, in: dateText),
              let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(day[1].lowercased().prefix(3))),
              let dayNumber = Int(day[2]), (1...31).contains(dayNumber) else { return nil }
        let year = Int(day[3]) ?? calendar.component(.year, from: now)
        for candidateYear in (day[3].isEmpty ? [year, year + 1] : [year]) {
            let parts = DateComponents(year: candidateYear, month: month + 1, day: dayNumber, hour: hour, minute: minute, second: 0)
            guard let candidate = calendar.date(from: parts), calendar.component(.month, from: candidate) == month + 1,
                  calendar.component(.day, from: candidate) == dayNumber else { continue }
            if let date = bounded(candidate) { return date }
        }
        return nil
    }
}
