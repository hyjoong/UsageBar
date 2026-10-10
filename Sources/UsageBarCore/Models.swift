import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
}

public struct UsageWindow: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetDescription: String?
    public let durationMinutes: Int?
    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?, durationMinutes: Int? = nil, resetDescription: String? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.durationMinutes = durationMinutes
    }
}

public struct ResetCredit: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let expiresAt: Date?
    public let status: String
    public init(id: String, title: String, expiresAt: Date?, status: String) {
        self.id = id; self.title = title; self.expiresAt = expiresAt; self.status = status
    }
}

public struct DailyUsage: Codable, Identifiable, Equatable, Sendable {
    public var id: String { day }
    public let day: String
    public let tokens: Int64
    public init(day: String, tokens: Int64) { self.day = day; self.tokens = tokens }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let accountKey: String?
    public let plan: String?
    public let windows: [UsageWindow]
    public let resetCreditCount: Int?
    public let resetCredits: [ResetCredit]?
    public let dailyUsage: [DailyUsage]?
    public let fetchedAt: Date
    public let source: String

    public init(provider: ProviderID, accountKey: String? = nil, plan: String? = nil, windows: [UsageWindow], resetCreditCount: Int? = nil,
                resetCredits: [ResetCredit]? = nil, dailyUsage: [DailyUsage]? = nil, fetchedAt: Date = Date(), source: String) {
        self.provider = provider; self.accountKey = accountKey; self.plan = plan; self.windows = windows
        self.resetCreditCount = resetCreditCount; self.resetCredits = resetCredits
        self.dailyUsage = dailyUsage; self.fetchedAt = fetchedAt; self.source = source
    }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case setupRequired(String)
    case authenticationRequired(String)
    case unavailable(String)
    case rateLimited(retryAfter: TimeInterval?)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .setupRequired(let message), .authenticationRequired(let message), .unavailable(let message), .unsupported(let message): return message
        case .rateLimited: return "요청이 잠시 제한됐어요. 마지막 기록을 보여드릴게요."
        }
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
}
