import CryptoKit
import Foundation

public struct HistoryPoint: Codable, Identifiable, Equatable, Sendable {
    public let provider: ProviderID
    public let date: Date
    public let remaining: Double
    public let windowName: String
    public let windowID: String
    public let resetsAt: Date?
    public var id: String { "\(provider.rawValue)|\(windowID)|\(date.timeIntervalSince1970)" }

    public init(provider: ProviderID, date: Date, remaining: Double, windowName: String,
                windowID: String, resetsAt: Date? = nil) {
        self.provider = provider; self.date = date; self.remaining = remaining
        self.windowName = windowName; self.windowID = windowID; self.resetsAt = resetsAt
    }
}

public struct HistoryState: Sendable {
    public let snapshots: [ProviderID: ProviderSnapshot]
    public let points: [HistoryPoint]
    public let accountChanged: Bool
}

/// Saves successful numeric snapshots only. Account identities are hashed; credentials and errors are never stored.
public actor HistoryStore {
    private struct Archive: Codable {
        var version = 1
        var snapshots: [ProviderID: ProviderSnapshot] = [:]
        var points: [HistoryPoint] = []
        var accountHashes: [ProviderID: String] = [:]
    }

    private let fileURL: URL
    private let retentionDays: Int
    private let maxPoints: Int
    private let maxPointsPerDay: Int
    private var archive = Archive()
    private var loaded = false

    public init(directory: URL? = nil, retentionDays: Int = 30, maxPoints: Int = 60_000,
                maxPointsPerDay: Int = 2_500) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageBar", isDirectory: true)
        self.fileURL = base.appendingPathComponent("usage-cache.json")
        self.retentionDays = max(1, retentionDays)
        self.maxPoints = max(1, maxPoints)
        self.maxPointsPerDay = max(1, maxPointsPerDay)
    }

    public func load(now: Date = Date()) throws -> HistoryState {
        if !loaded {
            loaded = true
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let decoded = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                if decoded.version == 1 { archive = decoded }
            }
        }
        prune(now: now)
        return state()
    }

    @discardableResult
    public func record(_ snapshot: ProviderSnapshot, now: Date = Date()) throws -> HistoryState {
        if !loaded { _ = try load(now: now) }
        let newHash = snapshot.accountKey.map(Self.identityHash)
        let oldHash = archive.accountHashes[snapshot.provider]
        let hadData = archive.snapshots[snapshot.provider] != nil
            || archive.points.contains { $0.provider == snapshot.provider }
        // Unknown-to-known also begins a new history, so anonymous samples cannot cross accounts.
        let changed = hadData && oldHash != newHash
        if changed { archive.points.removeAll { $0.provider == snapshot.provider } }
        archive.accountHashes[snapshot.provider] = newHash

        let safeWindows = snapshot.windows.filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
        // Persist only display metadata, never account IDs, raw responses, process paths, or error strings.
        archive.snapshots[snapshot.provider] = ProviderSnapshot(
            provider: snapshot.provider, plan: Self.safePlan(snapshot.plan), windows: safeWindows,
            resetCreditCount: snapshot.resetCreditCount,
            resetCredits: snapshot.resetCredits?.enumerated().map { index, credit in
                ResetCredit(id: "credit-\(index)", title: String(localized: "초기화권 \(index + 1)"), expiresAt: credit.expiresAt,
                            status: Self.safeStatus(credit.status))
            },
            dailyUsage: snapshot.dailyUsage?.filter { $0.tokens >= 0 }, fetchedAt: snapshot.fetchedAt,
            source: snapshot.provider == .codex ? String(localized: "Codex App Server · 저장된 기록") : String(localized: "Claude · 저장된 기록")
        )
        for window in safeWindows {
            let point = HistoryPoint(provider: snapshot.provider, date: snapshot.fetchedAt,
                                     remaining: window.remainingPercent, windowName: window.label,
                                     windowID: window.id, resetsAt: window.resetsAt)
            if !archive.points.contains(where: { $0.id == point.id }) { archive.points.append(point) }
        }
        prune(now: now)
        try persist()
        return state(accountChanged: changed)
    }

    public func clear() throws {
        archive = Archive(); loaded = true
        try persist()
    }

    private func state(accountChanged: Bool = false) -> HistoryState {
        HistoryState(snapshots: archive.snapshots, points: archive.points, accountChanged: accountChanged)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        var perDay: [String: Int] = [:]
        let recent = archive.points.filter {
            $0.date >= cutoff && $0.date <= now.addingTimeInterval(60)
                && $0.remaining.isFinite && (0...100).contains($0.remaining)
        }.sorted { $0.date > $1.date }
        archive.points = recent.filter { point in
            let day = Int(floor(point.date.timeIntervalSince1970 / 86_400))
            let key = "\(point.provider.rawValue)-\(day)"
            let count = perDay[key, default: 0]
            guard count < maxPointsPerDay else { return false }
            perDay[key] = count + 1
            return true
        }.prefix(maxPoints).sorted { $0.date < $1.date }
    }

    private func persist() throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(archive).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func identityHash(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func safePlan(_ plan: String?) -> String? {
        guard let plan, plan.count <= 64, !plan.contains("@"), !plan.contains("/") else { return nil }
        return plan
    }

    private static func safeStatus(_ status: String) -> String {
        let allowed = ["available", "active", "unused", "used", "expired", "사용 가능", "사용됨", "만료됨"]
        return allowed.contains(status) ? status : "unknown"
    }
}
