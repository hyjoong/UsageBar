import Foundation
import XCTest
@testable import UsageBarCore

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("UsageBarHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func snapshot(account: String? = "account-a", provider: ProviderID = .codex,
                          at date: Date? = nil, used: Double = 24) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, accountKey: account, plan: "Pro",
                         windows: [UsageWindow(id: "weekly", label: "주간", usedPercent: used,
                                               resetsAt: now.addingTimeInterval(86_400), durationMinutes: 10_080)],
                         fetchedAt: date ?? now, source: "test")
    }

    func testAccountSwitchClearsOnlyThatProvidersHistory() async throws {
        let store = HistoryStore(directory: directory)
        try await store.record(snapshot(), now: now)
        try await store.record(snapshot(account: "claude-account", provider: .claude), now: now)
        let result = try await store.record(snapshot(account: "account-b", at: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        XCTAssertTrue(result.accountChanged)
        XCTAssertEqual(result.points.filter { $0.provider == .codex }.count, 1)
        XCTAssertEqual(result.points.filter { $0.provider == .claude }.count, 1)
        XCTAssertEqual(result.points.first { $0.provider == .codex }?.date, now.addingTimeInterval(1))
    }

    func testIdentityDoesNotPersistAndSameAccountSurvivesRestart() async throws {
        let identity = "person@example.com-secret-identifier"
        let store = HistoryStore(directory: directory)
        try await store.record(snapshot(account: identity), now: now)
        let raw = try String(contentsOf: directory.appendingPathComponent("usage-cache.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains(identity))
        XCTAssertFalse(raw.contains("person@example.com"))
        let reopened = HistoryStore(directory: directory)
        let loaded = try await reopened.load(now: now.addingTimeInterval(300))
        XCTAssertNil(loaded.snapshots[.codex]?.accountKey)
        let next = try await reopened.record(snapshot(account: identity, at: now.addingTimeInterval(300)), now: now.addingTimeInterval(300))
        XCTAssertFalse(next.accountChanged)
        XCTAssertEqual(next.points.count, 2)
    }

    func testLoadingCachedDataDoesNotInventNewFetchTime() async throws {
        let store = HistoryStore(directory: directory)
        try await store.record(snapshot(), now: now)
        let later = now.addingTimeInterval(3_600)
        let loaded = try await HistoryStore(directory: directory).load(now: later)
        XCTAssertEqual(loaded.snapshots[.codex]?.fetchedAt, now)
        XCTAssertEqual(loaded.points.map(\.date), [now])
    }

    func testRetentionDailyCapAndGlobalBound() async throws {
        let store = HistoryStore(directory: directory, retentionDays: 30, maxPoints: 3, maxPointsPerDay: 2)
        try await store.record(snapshot(at: now.addingTimeInterval(-31 * 86_400)), now: now)
        for offset in [-86_400, -86_300, -100, -50, 0] {
            try await store.record(snapshot(at: now.addingTimeInterval(Double(offset))), now: now)
        }
        let result = try await store.load(now: now)
        XCTAssertEqual(result.points.count, 3)
        XCTAssertEqual(result.points.suffix(2).map(\.date), [now.addingTimeInterval(-50), now])
        XCTAssertFalse(result.points.contains { $0.date < now.addingTimeInterval(-30 * 86_400) })
    }

    func testSameSnapshotIsNotDuplicatedAndInvalidPercentIsNotZero() async throws {
        let store = HistoryStore(directory: directory)
        try await store.record(snapshot(), now: now)
        try await store.record(snapshot(), now: now)
        let result = try await store.record(snapshot(at: now.addingTimeInterval(60), used: .nan), now: now.addingTimeInterval(60))
        XCTAssertEqual(result.points.count, 1)
        XCTAssertEqual(result.points[0].remaining, 76)
        XCTAssertEqual(result.snapshots[.codex]?.windows.count, 0)
    }

    func testMomentarilyUnknownIdentityKeepsKnownHistoryWithoutAddingSamples() async throws {
        let store = HistoryStore(directory: directory)
        try await store.record(snapshot(), now: now)
        let blank = try await store.record(snapshot(account: nil, at: now.addingTimeInterval(60), used: 50), now: now.addingTimeInterval(60))
        XCTAssertFalse(blank.accountChanged)
        XCTAssertEqual(blank.points.count, 1)
        XCTAssertEqual(blank.points.first?.remaining, 76)
        let back = try await store.record(snapshot(at: now.addingTimeInterval(120), used: 30), now: now.addingTimeInterval(120))
        XCTAssertFalse(back.accountChanged)
        XCTAssertEqual(back.points.count, 2)
    }

    func testUnknownIdentityDoesNotMergeWithKnownAccount() async throws {
        let store = HistoryStore(directory: directory)
        try await store.record(snapshot(account: nil), now: now)
        let result = try await store.record(snapshot(account: "new-account", at: now.addingTimeInterval(60)), now: now.addingTimeInterval(60))
        XCTAssertTrue(result.accountChanged)
        XCTAssertEqual(result.points.count, 1)
    }
}
