import Foundation

public enum UsageFreshness: Equatable, Sendable {
    case unavailable, current, stale, resetDue

    public static func evaluate(snapshot: ProviderSnapshot?, hasError: Bool = false, now: Date) -> Self {
        guard let snapshot else { return .unavailable }
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        guard age.isFinite, age >= -60, age <= 600, !hasError else { return .stale }
        if snapshot.windows.contains(where: { $0.resetsAt.map { $0 <= now } ?? false }) { return .resetDue }
        return .current
    }
}

public enum UsageWindowSelection {
    public static func validWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
    }

    /// A saved choice wins. Otherwise show the shortest reported window, independent of response order.
    public static func select(from windows: [UsageWindow], preferredID: String?) -> UsageWindow? {
        let valid = validWindows(windows)
        if let preferredID, let selected = valid.first(where: { $0.id == preferredID }) { return selected }
        return valid.sorted {
            let lhs = $0.durationMinutes.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
            let rhs = $1.durationMinutes.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }.first
    }
}
