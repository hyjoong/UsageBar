import Foundation

/// A stretch of continuous work.
public struct WorkInterval: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = max(start, end) }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// How work time is counted from log moments.
public struct WorkTimeRules: Equatable, Sendable {
    /// Moments closer than this belong to the same stretch of work.
    public var gap: TimeInterval
    /// Added after the last moment of a stretch: reading the final answer and checking the result.
    public var tail: TimeInterval

    public init(gap: TimeInterval = 15 * 60, tail: TimeInterval = 5 * 60) {
        self.gap = max(0, gap); self.tail = max(0, tail)
    }
    public static let standard = WorkTimeRules()
}

/// Work time from activity moments and known busy spans (a Codex turn), following the rules in
/// docs/plans/0.10-work-log.md §6.
public enum WorkTimeCalculator {
    /// Joins moments and spans whose distance is at most `gap`, then adds the tail to each stretch.
    /// Spans join everything inside them, however quiet. The tail never exceeds the gap, so it cannot
    /// bridge two stretches the gap kept apart.
    public static func intervals(moments: [Date], spans: [WorkInterval] = [],
                                 rules: WorkTimeRules = .standard) -> [WorkInterval] {
        let segments = (moments.map { WorkInterval(start: $0, end: $0) } + spans)
            .filter { $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite }
            .sorted { $0.start < $1.start }
        let tail = min(rules.tail, rules.gap)
        var merged: [WorkInterval] = []
        for segment in segments {
            if let last = merged.last, segment.start.timeIntervalSince(last.end) <= rules.gap {
                merged[merged.count - 1] = WorkInterval(start: last.start, end: max(last.end, segment.end))
            } else {
                merged.append(segment)
            }
        }
        return merged.map { WorkInterval(start: $0.start, end: $0.end.addingTimeInterval(tail)) }
    }

    /// Overlapping or touching intervals joined, so parallel sessions are not counted twice.
    public static func union(_ intervals: [WorkInterval]) -> [WorkInterval] {
        var merged: [WorkInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = WorkInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// The parts of `intervals` that fall inside `range` (for example one local day).
    public static func clip(_ intervals: [WorkInterval], to range: DateInterval) -> [WorkInterval] {
        intervals.compactMap { interval in
            let start = max(interval.start, range.start), end = min(interval.end, range.end)
            return start < end ? WorkInterval(start: start, end: end) : nil
        }
    }

    public static func total(_ intervals: [WorkInterval]) -> TimeInterval {
        union(intervals).reduce(0) { $0 + $1.duration }
    }

    /// Moments and spans for the given events: activity, prompts, edits and commits are moments;
    /// a Codex turn is a span.
    public static func intervals(for events: [WorkLogEvent], rules: WorkTimeRules = .standard) -> [WorkInterval] {
        var moments: [Date] = []
        var spans: [WorkInterval] = []
        for event in events {
            if case .turn(let end) = event.kind { spans.append(WorkInterval(start: event.time, end: end)) }
            else { moments.append(event.time) }
        }
        return intervals(moments: moments, spans: spans, rules: rules)
    }
}
