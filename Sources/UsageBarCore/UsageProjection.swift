import Foundation

/// Projects when a short limit runs out if the recent rate of use continues.
/// Windows longer than a day are skipped: use there comes in bursts, and one busy hour
/// stretched across several days would overstate the risk. Those keep the plain pace comparison.
public struct UsageProjection: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case lastsUntilReset
        case runsOut(at: Date)
    }

    public let outcome: Outcome
    /// Percentage points used per hour over the sampled interval.
    public let ratePerHour: Double
    /// Start of the sampled interval; the end is the observation time.
    public let sampledSince: Date

    public static func evaluate(window: UsageWindow, history: [HistoryPoint], observedAt: Date, now: Date = Date(),
                                lookback: TimeInterval = 3_600, minimumSpan: TimeInterval = 15 * 60,
                                maximumWindowMinutes: Int = 24 * 60,
                                resetTolerance: TimeInterval = 120) -> UsageProjection? {
        guard let duration = window.durationMinutes, (1...maximumWindowMinutes).contains(duration),
              let resetsAt = window.resetsAt, resetsAt > now,
              window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
              (-60...600).contains(now.timeIntervalSince(observedAt)) else { return nil }
        let remaining = window.remainingPercent
        guard remaining > 0 else { return nil }

        // Only samples from this same period: a reset in between would read as negative use.
        let samples = history.filter { point in
            point.windowID == window.id && point.date < observedAt
                && point.remaining.isFinite && (0...100).contains(point.remaining)
                && point.resetsAt.map { abs($0.timeIntervalSince(resetsAt)) <= resetTolerance } == true
        }.sorted { $0.date < $1.date }
        let cutoff = observedAt.addingTimeInterval(-lookback)
        // The last sample at or before the cutoff covers the full lookback; otherwise use the oldest inside it.
        guard let baseline = samples.last(where: { $0.date <= cutoff }) ?? samples.first else { return nil }
        let span = observedAt.timeIntervalSince(baseline.date)
        guard span >= minimumSpan else { return nil }

        let rate = max(0, baseline.remaining - remaining) / span
        var outcome = Outcome.lastsUntilReset
        if rate > 0 {
            let runsOutAt = observedAt.addingTimeInterval(remaining / rate)
            if runsOutAt < resetsAt { outcome = .runsOut(at: runsOutAt) }
        }
        return UsageProjection(outcome: outcome, ratePerHour: rate * 3_600, sampledSince: baseline.date)
    }

    /// Worth a notification: the limit would run out within the hour and clearly before it resets.
    public func shouldWarn(resetsAt: Date, now: Date, within: TimeInterval = 3_600,
                           margin: TimeInterval = 10 * 60) -> Bool {
        guard case .runsOut(let at) = outcome else { return false }
        return at > now && at.timeIntervalSince(now) <= within && resetsAt.timeIntervalSince(at) >= margin
    }
}
