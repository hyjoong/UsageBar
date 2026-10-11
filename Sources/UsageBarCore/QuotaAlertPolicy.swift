import Foundation

public struct QuotaAlertState: Equatable, Sendable {
    public let remaining: Double
    /// Stable within a quota period, including minute-rounded relative reset descriptions.
    public let periodResetAt: Date?
    public var hasNotified: Bool

    public init(remaining: Double, periodResetAt: Date?, hasNotified: Bool = false) {
        self.remaining = remaining
        self.periodResetAt = periodResetAt
        self.hasNotified = hasNotified
    }
}

public struct QuotaAlertDecision: Sendable {
    public let state: QuotaAlertState
    /// The limit just crossed below the threshold in this period.
    public let shouldNotify: Bool
    /// The limit was at or below the threshold and a new period brought it back above.
    public let shouldNotifyRecovery: Bool
}

public enum QuotaAlertPolicy {
    /// Evaluates observed crossings only. Permission and delivery remain the caller's responsibility.
    public static func evaluate(previous: QuotaAlertState?, remaining: Double, resetsAt: Date?,
                                observedAt: Date, threshold: Double = 20,
                                resetTolerance: TimeInterval = 90) -> QuotaAlertDecision? {
        guard remaining.isFinite, (0...100).contains(remaining) else { return nil }
        let anchor = previous?.periodResetAt
        var newPeriod = false
        if let anchor, let resetsAt, let previous {
            // A relative "in 2h 30m" estimate can move slightly at every poll. A new future
            // reset alone is insufficient: the old period must end or capacity must recover.
            newPeriod = resetsAt.timeIntervalSince(anchor) > resetTolerance
                && (anchor <= observedAt || remaining > previous.remaining)
        }
        let recoveredWithoutClock = anchor == nil && resetsAt == nil
            && (previous?.remaining ?? 100) <= threshold && remaining > threshold
        let notified = (newPeriod || recoveredWithoutClock) ? false : (previous?.hasNotified ?? false)
        let crossed = previous.map { $0.remaining > threshold && remaining <= threshold } ?? false
        let recovered = (newPeriod || recoveredWithoutClock)
            && (previous?.remaining ?? 100) <= threshold && remaining > threshold
        let state = QuotaAlertState(remaining: remaining,
                                   periodResetAt: newPeriod ? resetsAt : (anchor ?? resetsAt),
                                   hasNotified: notified)
        return QuotaAlertDecision(state: state, shouldNotify: crossed && !notified, shouldNotifyRecovery: recovered)
    }
}
