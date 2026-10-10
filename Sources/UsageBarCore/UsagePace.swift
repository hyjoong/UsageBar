import Foundation

/// Compares recorded usage with an even distribution across the current window.
/// This is a reference comparison at the observation time, not a usage forecast.
public struct UsagePace: Sendable {
    public enum Position: Sendable {
        case behind, onTrack, ahead
    }

    public let elapsedPercent: Double
    public let usedPercent: Double
    /// Percentage points of usage above (positive) or below (negative) elapsed time.
    public let difference: Double
    public let position: Position

    public static func evaluate(window: UsageWindow, observedAt: Date, now: Date = Date()) -> UsagePace? {
        // Reject implausible periods before converting minutes into seconds.
        let maximumDurationMinutes = 366 * 24 * 60
        guard let durationMinutes = window.durationMinutes,
              (1...maximumDurationMinutes).contains(durationMinutes),
              let resetsAt = window.resetsAt,
              window.usedPercent.isFinite,
              (0...100).contains(window.usedPercent),
              observedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite,
              resetsAt.timeIntervalSince1970.isFinite else { return nil }

        let observationAge = now.timeIntervalSince(observedAt)
        guard (-60...600).contains(observationAge),
              resetsAt > now,
              resetsAt > observedAt else { return nil }

        let duration = Double(durationMinutes) * 60
        let startsAt = resetsAt.addingTimeInterval(-duration)
        // Allow minor timestamp rounding or clock skew near a window's start.
        guard startsAt.timeIntervalSince(observedAt) <= 60,
              startsAt.timeIntervalSince(now) <= 60 else { return nil }

        let elapsedPercent = max(0, min(100, observedAt.timeIntervalSince(startsAt) / duration * 100))
        let difference = window.usedPercent - elapsedPercent
        let position: Position = difference < -5 ? .behind : difference > 5 ? .ahead : .onTrack
        return UsagePace(elapsedPercent: elapsedPercent, usedPercent: window.usedPercent,
                         difference: difference, position: position)
    }
}
