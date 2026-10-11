import CryptoKit
import Foundation

public enum WorkKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case build, refactor, debug, review, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .build: return String(localized: "기능 개발")
        case .refactor: return String(localized: "리팩터링")
        case .debug: return String(localized: "문제 해결")
        case .review: return String(localized: "코드 리뷰")
        case .other: return String(localized: "기타 작업")
        }
    }
}

public enum WorkJournalError: Error, LocalizedError, Sendable {
    case staleSnapshot, invalidSnapshot, invalidArchive, unsafePath
    public var errorDescription: String? {
        switch self {
        case .staleSnapshot: return String(localized: "사용량을 새로 확인한 후 작업을 시작해 주세요.")
        case .invalidSnapshot: return String(localized: "비교할 수 있는 한도 정보가 없어요.")
        case .invalidArchive: return String(localized: "작업 기록을 읽을 수 없어 기존 파일을 보존했어요.")
        case .unsafePath: return String(localized: "작업 기록 경로가 안전하지 않아 저장하지 않았어요.")
        }
    }
}

public struct WorkQuotaDelta: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let percentagePoints: Double?
    public let note: String?
    /// Account-wide used percent when the session started and ended; nil on receipts from older versions.
    public let usedPercentAtStart: Double?
    public let usedPercentAtEnd: Double?
    public init(id: String, label: String, percentagePoints: Double?, note: String? = nil,
                usedPercentAtStart: Double? = nil, usedPercentAtEnd: Double? = nil) {
        self.id = id; self.label = label; self.percentagePoints = percentagePoints; self.note = note
        self.usedPercentAtStart = usedPercentAtStart; self.usedPercentAtEnd = usedPercentAtEnd
    }
}

public struct WorkReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: WorkKind
    public let provider: ProviderID
    public let startedAt: Date
    public let endedAt: Date
    public let rows: [WorkQuotaDelta]
    /// Models, tokens and project folders from this Mac's local CLI session logs. Absent for older receipts.
    public var activity: SessionActivity?
    public init(id: UUID = UUID(), kind: WorkKind, provider: ProviderID, startedAt: Date,
                endedAt: Date, rows: [WorkQuotaDelta], activity: SessionActivity? = nil) {
        self.id = id; self.kind = kind; self.provider = provider
        self.startedAt = startedAt; self.endedAt = endedAt; self.rows = rows; self.activity = activity
    }
    public var duration: TimeInterval {
        let value = endedAt.timeIntervalSince(startedAt)
        return value.isFinite ? max(0, value) : 0
    }
    public var copyText: String {
        let minutes = Int(min(duration / 60, Double(Int.max / 2)))
        let durationText = minutes == 0 ? String(localized: "1분 미만") : String(localized: "\(minutes)분")
        let results = rows.map { row in
            guard let value = row.percentagePoints else { return "\(row.label): \(row.note ?? String(localized: "비교 불가"))" }
            if value == 0 { return String(localized: "\(row.label): 표시상 변화 없음 (0%p)") }
            return "\(row.label): +\(value.formatted(.number.precision(.fractionLength(0...2))))%p"
        }
        var lines = ["\(kind.title) · \(provider.title) · \(durationText)"] + results + [
            String(localized: "이 구간의 계정 전체 사용률 변화입니다. 다른 창·기기의 사용도 포함되며, 이 작업만의 사용량이나 결제 금액을 뜻하지 않습니다.")
        ]
        if let activity, !activity.isEmpty {
            lines.append(String(localized: "이 Mac의 세션 기록 (모델별)"))
            for model in activity.models {
                lines.append(String(localized: "\(model.model): 호출 \(model.calls) · 입력 \(TokenFormat.compact(model.inputTokens)) · 출력 \(TokenFormat.compact(model.outputTokens)) · 캐시 읽기 \(TokenFormat.compact(model.cacheReadTokens))"))
            }
            if !activity.projects.isEmpty {
                let projects = activity.projects.map { "\($0.name) \($0.calls)" }.joined(separator: ", ")
                lines.append(String(localized: "프로젝트: \(projects)"))
            }
            if activity.isPartial { lines.append(String(localized: "세션 기록이 커서 일부만 집계했습니다.")) }
        }
        return lines.joined(separator: "\n")
    }
}

public struct WorkSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: WorkKind
    public let provider: ProviderID
    public let startedAt: Date
    private let sampledAt: Date
    private let accountDigest: String?
    private let planFingerprint: String?
    private let checkpoints: [Checkpoint]

    private struct Checkpoint: Codable, Equatable, Sendable {
        let windowDigest: String
        let label: String
        let usedPercent: Double
        let resetsAt: Date?
        let durationMinutes: Int?
    }

    public static func start(kind: WorkKind, snapshot: ProviderSnapshot, now: Date = Date()) throws -> Self {
        guard fresh(snapshot.fetchedAt, at: now) else { throw WorkJournalError.staleSnapshot }
        let windows = snapshot.windows.filter(validWindow).sorted { lhs, rhs in
            switch (lhs.durationMinutes, rhs.durationMinutes) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
        guard !windows.isEmpty, windows.count <= 128,
              Set(windows.map(\.id)).count == windows.count else { throw WorkJournalError.invalidSnapshot }
        return Self(id: UUID(), kind: kind, provider: snapshot.provider, startedAt: snapshot.fetchedAt,
                    sampledAt: snapshot.fetchedAt, accountDigest: identity(snapshot.accountKey),
                    planFingerprint: snapshot.plan.map(hash), checkpoints: windows.enumerated().map { index, window in
            Checkpoint(windowDigest: hash(window.id), label: safeLabel(window.label, index: index),
                       usedPercent: window.usedPercent, resetsAt: window.resetsAt, durationMinutes: window.durationMinutes)
        })
    }

    public func finish(snapshot: ProviderSnapshot?, now: Date = Date()) -> WorkReceipt {
        let timeValid = now.timeIntervalSince1970.isFinite && now > startedAt
        // Receipt boundaries describe observations, not button-click time. A fresh poll
        // can predate this action by up to 60 seconds.
        let observedEnd = snapshot.flatMap { value -> Date? in
            guard timeValid, value.provider == provider, Self.fresh(value.fetchedAt, at: now),
                  value.fetchedAt > startedAt else { return nil }
            return value.fetchedAt
        }
        let end = observedEnd ?? (timeValid ? now : startedAt)
        let generalIssue: String?
        if !timeValid { generalIssue = String(localized: "작업 종료 시각을 확인할 수 없어요.") }
        else if let snapshot {
            if snapshot.provider != provider { generalIssue = String(localized: "다른 서비스의 조회 결과예요.") }
            else if !Self.fresh(snapshot.fetchedAt, at: now) || snapshot.fetchedAt <= startedAt {
                generalIssue = String(localized: "작업 종료 후의 최신 조회가 없어요.")
            } else if accountDigest == nil || Self.identity(snapshot.accountKey) == nil {
                generalIssue = String(localized: "같은 계정인지 확인할 수 없어요.")
            } else if accountDigest != Self.identity(snapshot.accountKey) {
                generalIssue = String(localized: "작업 중 계정이 변경됐어요.")
            } else if planFingerprint != snapshot.plan.map(Self.hash) {
                generalIssue = String(localized: "작업 중 플랜 정보가 변경됐어요.")
            } else { generalIssue = nil }
        } else { generalIssue = String(localized: "종료 시 사용량을 조회하지 못했어요.") }

        let rows = checkpoints.enumerated().map { index, checkpoint -> WorkQuotaDelta in
            func unavailable(_ note: String) -> WorkQuotaDelta {
                WorkQuotaDelta(id: "quota-\(index)", label: checkpoint.label, percentagePoints: nil, note: note,
                               usedPercentAtStart: checkpoint.usedPercent)
            }
            if let generalIssue { return unavailable(generalIssue) }
            let matches = snapshot?.windows.filter { Self.hash($0.id) == checkpoint.windowDigest } ?? []
            guard matches.count == 1, let window = matches.first else { return unavailable(String(localized: "같은 한도 정보를 찾을 수 없어요.")) }
            guard Self.validWindow(window) else { return unavailable(String(localized: "한도 값이 유효하지 않아요.")) }
            guard checkpoint.durationMinutes == window.durationMinutes else { return unavailable(String(localized: "한도의 기간이 변경됐어요.")) }
            guard let startReset = checkpoint.resetsAt, let endReset = window.resetsAt else {
                return unavailable(String(localized: "리셋 시각이 없어 같은 기간인지 확인할 수 없어요."))
            }
            guard end < startReset, end < endReset, sampledAt < startReset else {
                return unavailable(String(localized: "작업 구간에 한도 리셋 시각이 포함돼요."))
            }
            guard abs(endReset.timeIntervalSince(startReset)) <= 90 else { return unavailable(String(localized: "리셋 시각이 변경됐어요.")) }
            guard window.usedPercent >= checkpoint.usedPercent else { return unavailable(String(localized: "사용률이 감소해 단순 비교할 수 없어요.")) }
            let delta = window.usedPercent - checkpoint.usedPercent
            return WorkQuotaDelta(id: "quota-\(index)", label: checkpoint.label, percentagePoints: delta,
                                  note: delta == 0 ? String(localized: "표시상 변화 없음") : nil,
                                  usedPercentAtStart: checkpoint.usedPercent, usedPercentAtEnd: window.usedPercent)
        }
        return WorkReceipt(id: id, kind: kind, provider: provider, startedAt: startedAt, endedAt: end, rows: rows)
    }

    fileprivate var isValid: Bool {
        Self.fresh(sampledAt, at: startedAt) && !checkpoints.isEmpty && checkpoints.count <= 128
            && Set(checkpoints.map(\.windowDigest)).count == checkpoints.count
            && [accountDigest, planFingerprint].compactMap { $0 }.allSatisfy(Self.validDigest)
            && checkpoints.allSatisfy { point in
                Self.validDigest(point.windowDigest) && !point.label.isEmpty && point.label.count <= 80
                    && point.usedPercent.isFinite && (0...100).contains(point.usedPercent)
                    && (point.resetsAt.map { $0.timeIntervalSince1970.isFinite } ?? true)
                    && (point.durationMinutes.map { $0 > 0 } ?? true)
            }
    }
    private static func fresh(_ sampled: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(sampled)
        return now.timeIntervalSince1970.isFinite && sampled.timeIntervalSince1970.isFinite && age >= 0 && age <= 60
    }
    private static func validWindow(_ window: UsageWindow) -> Bool {
        !window.id.isEmpty && window.usedPercent.isFinite && (0...100).contains(window.usedPercent)
            && (window.resetsAt.map { $0.timeIntervalSince1970.isFinite } ?? true)
            && (window.durationMinutes.map { $0 > 0 } ?? true)
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func identity(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return hash(value)
    }
    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func safeLabel(_ label: String, index: Int) -> String {
        guard !label.isEmpty, label.count <= 80, !label.contains("@"), !label.contains("/"),
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return String(localized: "한도 \(index + 1)") }
        return label
    }
}

public struct WorkJournalState: Codable, Equatable, Sendable {
    public var active: WorkSession?
    public var receipts: [WorkReceipt]
    public init(active: WorkSession? = nil, receipts: [WorkReceipt] = []) {
        self.active = active; self.receipts = receipts
    }
}

public actor WorkJournalStore {
    private struct Archive: Codable { let version: Int; let state: WorkJournalState }
    private let fileURL: URL
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageBar", isDirectory: true)
        fileURL = base.appendingPathComponent("work-journal.json")
    }
    public func load() throws -> WorkJournalState {
        try guardPath()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return WorkJournalState() }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= 4_000_000 else {
                throw WorkJournalError.invalidArchive
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 4_000_000 else { throw WorkJournalError.invalidArchive }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, Self.valid(archive.state) else { throw WorkJournalError.invalidArchive }
            return Self.normalized(archive.state)
        } catch { throw WorkJournalError.invalidArchive }
    }
    public func save(_ state: WorkJournalState) throws {
        // Revalidate an existing archive on every write, including after external changes.
        _ = try load()
        guard Self.valid(state) else { throw WorkJournalError.invalidArchive }
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try guardPath()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(version: 1, state: Self.normalized(state)))
        // The containing directory is private before the atomic temporary file is created.
        try data.write(to: fileURL, options: .atomic)
        try guardPath()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    private func guardPath() throws {
        // Do not standardize: Foundation can rewrite an existing /private/tmp path to /tmp.
        var candidate = fileURL
        while candidate.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw WorkJournalError.unsafePath
            }
            candidate.deleteLastPathComponent()
        }
    }
    private static func normalized(_ state: WorkJournalState) -> WorkJournalState {
        WorkJournalState(active: state.active, receipts: Array(state.receipts.sorted {
            if $0.endedAt != $1.endedAt { return $0.endedAt > $1.endedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(100)))
    }
    private static func valid(_ state: WorkJournalState) -> Bool {
        (state.active?.isValid ?? true) && Set(state.receipts.map(\.id)).count == state.receipts.count
            && state.receipts.allSatisfy { receipt in
                receipt.startedAt.timeIntervalSince1970.isFinite && receipt.endedAt.timeIntervalSince1970.isFinite
                    && receipt.endedAt >= receipt.startedAt && !receipt.rows.isEmpty && receipt.rows.count <= 128
                    && Set(receipt.rows.map(\.id)).count == receipt.rows.count
                    && receipt.rows.allSatisfy { row in
                        !row.id.isEmpty && !row.label.isEmpty && row.label.count <= 80
                            && (row.percentagePoints.map { $0.isFinite && (0...100).contains($0) } ?? (row.note != nil))
                    }
                    && (receipt.activity.map(validActivity) ?? true)
            }
    }

    private static func validActivity(_ activity: SessionActivity) -> Bool {
        activity.models.count <= 64 && activity.projects.count <= 64
            && activity.models.allSatisfy { !$0.model.isEmpty && $0.model.count <= 120 && $0.calls >= 0 && $0.inputTokens >= 0 && $0.outputTokens >= 0 }
            && activity.projects.allSatisfy { !$0.name.isEmpty && $0.name.count <= 120 && $0.calls >= 0 }
    }
}
