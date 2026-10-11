import Foundation

public enum WorkReminderKind: String, CaseIterable, Sendable {
    /// The session has been running for a while; the user may have forgotten it.
    case checkIn
    /// The limit is about to reset; finishing now keeps the receipt comparable.
    case beforeReset

    public var notificationIdentifier: String { "work.\(rawValue)" }
    public static var allIdentifiers: [String] { allCases.map(\.notificationIdentifier) }
}

public struct WorkReminder: Equatable, Sendable {
    public let kind: WorkReminderKind
    public let fireAt: Date
    public init(kind: WorkReminderKind, fireAt: Date) { self.kind = kind; self.fireAt = fireAt }
}

/// Decides when to remind about an active work session. Pure; delivery is the app's job.
public enum WorkReminderPlan {
    public static func reminders(startedAt: Date, resetsAt: Date?, now: Date,
                                 checkInAfter: TimeInterval = 2 * 3_600,
                                 leadBeforeReset: TimeInterval = 10 * 60,
                                 minimumLead: TimeInterval = 60) -> [WorkReminder] {
        var plan: [WorkReminder] = []
        let checkIn = startedAt.addingTimeInterval(checkInAfter)
        if checkIn > now.addingTimeInterval(minimumLead) {
            plan.append(WorkReminder(kind: .checkIn, fireAt: checkIn))
        }
        if let resetsAt {
            let warning = resetsAt.addingTimeInterval(-leadBeforeReset)
            if warning > now.addingTimeInterval(minimumLead), warning > startedAt {
                plan.append(WorkReminder(kind: .beforeReset, fireAt: warning))
            }
        }
        return plan.sorted { $0.fireAt < $1.fireAt }
    }
}
