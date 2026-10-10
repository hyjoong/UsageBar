import Foundation

/// Compact menu bar copy. The caller supplies the clock so all displays share the same instant.
public enum UsageMenuBarFormatter {
    public static func title(for window: UsageWindow?, includeReset: Bool, now: Date) -> String {
        guard let window, window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { return "—" }
        let percentage = "\(Int(window.remainingPercent.rounded()))%"
        guard includeReset, let countdown = resetCountdown(until: window.resetsAt, now: now) else {
            return percentage
        }
        return "\(percentage) · \(countdown)"
    }

    /// Uses whole remaining minutes (days/hours for long windows), never a negative duration.
    /// A due reset is not evidence that fresh capacity has already arrived.
    public static func resetCountdown(until resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining.isFinite else { return nil }
        if remaining <= 0 { return "↻" }
        if remaining < 60 { return "<1m" }
        let wholeMinutes = (remaining / 60).rounded(.down)
        guard wholeMinutes < Double(Int.max) else { return nil }
        let minutes = Int(wholeMinutes)
        if minutes >= 1_440 {
            let days = minutes / 1_440
            let hours = (minutes % 1_440) / 60
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return "\(minutes)m"
    }
}

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
