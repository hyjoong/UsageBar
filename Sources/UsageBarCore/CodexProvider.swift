import CoreFoundation
import CryptoKit
import Foundation

public actor CodexProvider: UsageProvider {
    public nonisolated let id: ProviderID = .codex
    private let executablePath: String?

    public init(executablePath: String? = nil) { self.executablePath = executablePath }

    public func fetch() async throws -> ProviderSnapshot {
        let cancellation = CodexCancellation()
        let path = executablePath
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try Self.fetchSync(path: path, cancellation: cancellation)) }
                    catch is CancellationError { continuation.resume(throwing: CancellationError()) }
                    catch let error as ProviderError { continuation.resume(throwing: error) }
                    catch { continuation.resume(throwing: ProviderError.unavailable(String(localized: "Codex 사용량을 읽지 못했어요. 잠시 후 새로고침해 주세요."))) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private nonisolated static func fetchSync(path: String?, cancellation: CodexCancellation) throws -> ProviderSnapshot {
        try cancellation.check()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        let executable = try resolveExecutable(path: path, cancellation: cancellation, deadline: deadline)

        let connection = try CodexRPC(executable: executable, arguments: ["app-server", "--listen", "stdio://"],
                                      cancellation: cancellation, deadline: deadline)
        defer { connection.close() }
        try connection.initialize()
        let account = try connection.request("account/read", params: ["refreshToken": false])
        _ = try CodexSnapshotParser.accountPlan(account)
        let limits = try connection.request("account/rateLimits/read")
        let fetchedAt = Date()
        var usage: [String: Any]?
        do { usage = try connection.request("account/usage/read", timeout: 4) }
        catch is CancellationError { throw CancellationError() }
        catch { usage = nil } // An older CLI or unavailable activity service must not hide valid quotas.
        try cancellation.check()
        return try CodexSnapshotParser.snapshot(account: account, limits: limits, usage: usage, fetchedAt: fetchedAt)
    }

    nonisolated static func resolveExecutable(path: String?, candidates: [String]? = nil,
                                              cancellation: CodexCancellation, deadline: TimeInterval) throws -> URL {
        try cancellation.check()
        let manager = FileManager.default
        let versionError = ProviderError.setupRequired(String(localized: "Codex CLI 버전을 확인하지 못했어요. 실행 파일 경로와 설치 상태를 확인해 주세요."))
        var searchCandidates: [String]
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: path).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw ProviderError.setupRequired(String(localized: "Codex CLI의 절대 경로를 선택해 주세요.")) }
            searchCandidates = [expanded]
        } else if let candidates {
            searchCandidates = candidates
        } else {
            let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            searchCandidates = searchPath.split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
            searchCandidates += [
                "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            ]
        }
        var seen = Set<String>()
        var executables: [URL] = []
        for candidate in searchCandidates {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw versionError }
            guard candidate.hasPrefix("/"), !candidate.utf8.contains(0) else { continue }
            let executable = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(executable.path).inserted,
                  manager.isExecutableFile(atPath: executable.path),
                  (try? executable.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            executables.append(executable)
        }
        guard !executables.isEmpty else {
            throw ProviderError.setupRequired(String(localized: "Codex CLI를 찾지 못했어요. Codex를 설치하거나 실행 파일 경로를 지정해 주세요."))
        }
        // An outdated CLI earlier on PATH (an old nvm global, say) answers --version but cannot serve the
        // usage methods, so every runnable candidate is compared and the newest wins; ties keep PATH order.
        var best: (executable: URL, version: [Int])?
        for (index, executable) in executables.enumerated() {
            try cancellation.check()
            let now = ProcessInfo.processInfo.systemUptime
            // Once one candidate works, later probes are short and must leave time for the usage query.
            let reserve: TimeInterval = best == nil ? 0 : 8
            guard now + reserve < deadline else { break }
            // Share the remaining budget so stalled PATH installs leave time for bundled candidates.
            let share = (deadline - reserve - now) / Double(executables.count - index)
            let probeBudget = min(best == nil ? 3 : 1, share)
            do {
                let version = try CodexRPC.version(executable: executable, cancellation: cancellation,
                                                   deadline: min(deadline, now + probeBudget))
                try cancellation.check()
                let key = versionKey(version)
                if best.map({ key.lexicographicallyPrecedes($0.version) || key == $0.version }) != true {
                    best = (executable, key)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        try cancellation.check()
        guard let best, ProcessInfo.processInfo.systemUptime < deadline else { throw versionError }
        return best.executable
    }

    /// "0.160.1" or "0.47.0-alpha.2" → [0, 160, 1] / [0, 47, 0]; anything after the numeric core is ignored.
    static func versionKey(_ version: String) -> [Int] {
        let core = version.prefix { $0.isNumber || $0 == "." }
        return core.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
    }
}

/// Parse sanitized display data only. Neither raw account identifiers nor email enter a snapshot.
enum CodexSnapshotParser {
    static func accountPlan(_ response: [String: Any]) throws -> String? {
        guard let account = response["account"] as? [String: Any] else {
            throw ProviderError.authenticationRequired(String(localized: "Codex에 ChatGPT 계정으로 로그인해 주세요."))
        }
        guard account["type"] as? String == "chatgpt" else {
            throw ProviderError.unsupported(String(localized: "ChatGPT 로그인으로 사용하는 Codex 구독 한도만 지원해요. API 키 계정의 요금은 제공되지 않아요."))
        }
        return account["planType"] as? String
    }

    static func snapshot(account: [String: Any], limits: [String: Any], usage: [String: Any]?, fetchedAt: Date = Date()) throws -> ProviderSnapshot {
        let accountPlan = try accountPlan(account)
        let legacy = limits["rateLimits"] as? [String: Any] ?? [:]
        let scoped = limits["rateLimitsByLimitId"] as? [String: Any]
        let buckets: [(String, [String: Any])]
        if let scoped, !scoped.isEmpty {
            buckets = scoped.keys.sorted().compactMap { key in (scoped[key] as? [String: Any]).map { (key, $0) } }
        } else {
            buckets = [(legacy["limitId"] as? String ?? "codex", legacy)]
        }
        let windows = buckets.flatMap { key, bucket -> [UsageWindow] in
            ["primary", "secondary"].compactMap { slot in
                guard let window = bucket[slot] as? [String: Any],
                      let used = number(window["usedPercent"]), used >= 0 else { return nil }
                let duration = integer(window["windowDurationMins"]).flatMap { $0 > 0 ? Int(exactly: $0) : nil }
                let durationLabel = duration.map(windowLabel) ?? (slot == "primary" ? String(localized: "기본 한도") : String(localized: "추가 한도"))
                let scopeLabel = bucket["limitName"] as? String ?? key
                return UsageWindow(id: key + "." + slot,
                                   label: buckets.count > 1 ? scopeLabel + " · " + durationLabel : durationLabel,
                                   usedPercent: used, resetsAt: timestamp(window["resetsAt"]), durationMinutes: duration)
            }
        }
        let credits = limits["rateLimitResetCredits"] as? [String: Any]
        let count = integer(credits?["availableCount"]).flatMap { $0 >= 0 ? Int(exactly: $0) : nil }
        let rows = (credits?["credits"] as? [Any]).map { entries in
            entries.compactMap { entry -> ResetCredit? in
                guard let credit = entry as? [String: Any], let id = credit["id"] as? String, !id.isEmpty,
                      let status = credit["status"] as? String else { return nil }
                // Invalid non-null dates must not accidentally become "no expiry".
                if let raw = credit["expiresAt"], !(raw is NSNull), timestamp(raw) == nil { return nil }
                return ResetCredit(id: id, title: credit["title"] as? String ?? String(localized: "저장된 리셋"),
                                   expiresAt: timestamp(credit["expiresAt"]), status: status)
            }
        }
        let accountKey = (limits["accountId"] as? String).flatMap { id -> String? in
            guard !id.isEmpty else { return nil }
            return SHA256.hash(data: Data(("codex:" + id).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        // The current limit snapshot can be fresher than the cached account plan.
        let limitPlan = (legacy["planType"] as? String) ?? buckets.compactMap { $0.1["planType"] as? String }.first
        return ProviderSnapshot(provider: .codex, accountKey: accountKey, plan: limitPlan ?? accountPlan,
                                windows: windows, resetCreditCount: count, resetCredits: rows,
                                dailyUsage: dailyUsage(usage), fetchedAt: fetchedAt, source: "Codex CLI")
    }

    private static func windowLabel(_ minutes: Int) -> String {
        if minutes == 10_080 { return String(localized: "주간 한도") }
        if minutes % 1_440 == 0 { return String(localized: "\(minutes / 1_440)일 한도") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60)시간 한도") }
        if minutes > 60 { return String(localized: "\(minutes / 60)시간 \(minutes % 60)분 한도") }
        return String(localized: "\(minutes)분 한도")
    }

    private static func dailyUsage(_ response: [String: Any]?) -> [DailyUsage]? {
        guard let rows = response?["dailyUsageBuckets"] as? [Any] else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        var days: [String: Int64] = [:]
        for case let row as [String: Any] in rows {
            guard let day = row["startDate"] as? String, day.count == 10,
                  let date = formatter.date(from: day), formatter.string(from: date) == day,
                  let tokens = integer(row["tokens"]), tokens >= 0 else { continue }
            // Duplicate snapshots of the same bucket are not additive.
            days[day] = tokens
        }
        return days.keys.sorted().map { DailyUsage(day: $0, tokens: days[$0]!) }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        // Preserve integral JSON values above Double's exact-integer range.
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
           let exact = Int64(value.stringValue) { return exact }
        guard let number = number(value), number.rounded(.towardZero) == number else { return nil }
        return Int64(exactly: number)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let seconds = integer(value), seconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
