import Foundation

/// Totals over finished work sessions in a period: how many, how long, and how much of each limit they used.
/// Sessions never overlap, so their limit changes add up. A session whose change could not be compared
/// is left out of that limit's total and counted separately, so a total never hides a gap.
public struct WorkSummary: Equatable, Sendable {
    public struct LimitTotal: Equatable, Sendable, Identifiable {
        public let provider: ProviderID
        public let label: String
        public let percentagePoints: Double
        /// At least one session crossed a reset and contributed an estimate.
        public let includesEstimate: Bool
        public let comparedSessions: Int
        public let sessions: Int
        public var id: String { provider.rawValue + "|" + label }
    }

    public struct KindTotal: Equatable, Sendable, Identifiable {
        public let kind: WorkKind
        public let sessions: Int
        public let duration: TimeInterval
        public var id: String { kind.rawValue }
    }

    public let sessions: Int
    public let duration: TimeInterval
    public let outputTokens: Int64
    public let limits: [LimitTotal]
    public let kinds: [KindTotal]

    /// Receipts that ended within `start...end`, or nil when there are none.
    public static func make(receipts: [WorkReceipt], from start: Date, to end: Date) -> WorkSummary? {
        let included = receipts.filter { (start...end).contains($0.endedAt) }.sorted { $0.endedAt < $1.endedAt }
        guard !included.isEmpty else { return nil }

        struct Accumulator { var points = 0.0; var estimate = false; var compared = 0; var sessions = 0 }
        var order: [String] = []
        var limits: [String: (ProviderID, String, Accumulator)] = [:]
        var kinds: [WorkKind: (Int, TimeInterval)] = [:]
        for receipt in included {
            let current = kinds[receipt.kind] ?? (0, 0)
            kinds[receipt.kind] = (current.0 + 1, current.1 + receipt.duration)
            for row in receipt.rows {
                let key = receipt.provider.rawValue + "|" + row.label
                if limits[key] == nil { order.append(key); limits[key] = (receipt.provider, row.label, Accumulator()) }
                var value = limits[key]!.2
                value.sessions += 1
                if let points = row.percentagePoints, points.isFinite {
                    value.points += points; value.compared += 1
                } else if let estimate = row.estimatedPercentagePoints, estimate.isFinite {
                    value.points += estimate; value.compared += 1; value.estimate = true
                }
                limits[key]!.2 = value
            }
        }
        let providerRank = Dictionary(uniqueKeysWithValues: ProviderID.allCases.enumerated().map { ($1, $0) })
        let orderedKeys = order.enumerated().sorted { lhs, rhs in
            let left = providerRank[limits[lhs.element]!.0] ?? 0, right = providerRank[limits[rhs.element]!.0] ?? 0
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        return WorkSummary(
            sessions: included.count,
            duration: included.reduce(0) { $0 + $1.duration },
            outputTokens: included.reduce(0) { $0 + ($1.activity?.outputTokens ?? 0) },
            limits: orderedKeys.map { key in
                let (provider, label, value) = limits[key]!
                return LimitTotal(provider: provider, label: label, percentagePoints: value.points,
                                  includesEstimate: value.estimate, comparedSessions: value.compared, sessions: value.sessions)
            },
            kinds: kinds.map { KindTotal(kind: $0.key, sessions: $0.value.0, duration: $0.value.1) }
                .sorted { ($0.duration, $1.kind.rawValue) > ($1.duration, $0.kind.rawValue) })
    }
}
