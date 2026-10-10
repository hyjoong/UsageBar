import Foundation
import XCTest
@testable import UsageBarCore

final class WorkJournalTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)
    private func snapshot(_ used: Double = 20, at date: Date? = nil, account: String? = "private-account",
                          plan: String? = "private-plan", reset: Date? = nil, duration: Int? = 300,
                          windows: [UsageWindow]? = nil, provider: ProviderID = .claude) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, accountKey: account, plan: plan,
                         windows: windows ?? [UsageWindow(id: "window-private-id", label: "세션", usedPercent: used,
                                                         resetsAt: reset ?? start.addingTimeInterval(3_000), durationMinutes: duration)],
                         resetCreditCount: 19, dailyUsage: [DailyUsage(day: "sensitive-day", tokens: 123)],
                         fetchedAt: date ?? start, source: "sensitive-source")
    }
    private func session(_ snapshot: ProviderSnapshot? = nil) throws -> WorkSession {
        try WorkSession.start(kind: .refactor, snapshot: snapshot ?? self.snapshot(), now: start)
    }
    private func note(_ snapshot: ProviderSnapshot?, session: WorkSession? = nil, end: Date? = nil) throws -> String {
        let receipt = try (session ?? self.session()).finish(snapshot: snapshot, now: end ?? start.addingTimeInterval(120))
        XCTAssertNil(receipt.rows.first?.percentagePoints)
        return try XCTUnwrap(receipt.rows.first?.note)
    }
    func testComparesPercentagePointsAndExplainsScope() throws {
        let receipt = try session().finish(snapshot: snapshot(26, at: start.addingTimeInterval(120)), now: start.addingTimeInterval(120))
        XCTAssertEqual(receipt.rows.first?.percentagePoints, 6)
        XCTAssertEqual(receipt.duration, 120)
        XCTAssertTrue(receipt.copyText.contains("+6%p"))
        XCTAssertTrue(receipt.copyText.contains("계정 전체"))
        XCTAssertTrue(receipt.copyText.contains("다른 창·기기"))
    }
    func testReceiptTimesDescribeObservedSnapshotsInsteadOfButtonTimes() throws {
        let baseline = start.addingTimeInterval(-30)
        let work = try session(snapshot(at: baseline))
        XCTAssertEqual(work.startedAt, baseline)
        let observedEnd = start.addingTimeInterval(100)
        let receipt = work.finish(snapshot: snapshot(26, at: observedEnd), now: start.addingTimeInterval(120))
        XCTAssertEqual(receipt.startedAt, baseline)
        XCTAssertEqual(receipt.endedAt, observedEnd)
        XCTAssertEqual(receipt.duration, 130)
        XCTAssertEqual(receipt.rows.first?.percentagePoints, 6)
        let missing = work.finish(snapshot: nil, now: start.addingTimeInterval(120))
        XCTAssertEqual(missing.endedAt, start.addingTimeInterval(120))
        XCTAssertNil(missing.rows.first?.percentagePoints)
        let stale = work.finish(snapshot: snapshot(26, at: start.addingTimeInterval(59)), now: start.addingTimeInterval(120))
        XCTAssertEqual(stale.endedAt, start.addingTimeInterval(120))
        XCTAssertNil(stale.rows.first?.percentagePoints)
    }
    func testResetBoundaryUsesActualObservationTime() throws {
        let reset = start.addingTimeInterval(110)
        let work = try session(snapshot(reset: reset))
        let receipt = work.finish(snapshot: snapshot(26, at: start.addingTimeInterval(100), reset: reset),
                                  now: start.addingTimeInterval(120))
        XCTAssertEqual(receipt.endedAt, start.addingTimeInterval(100))
        XCTAssertEqual(receipt.rows.first?.percentagePoints, 6)
    }
    func testZeroMeansNoDisplayedChange() throws {
        let receipt = try session().finish(snapshot: snapshot(at: start.addingTimeInterval(120)), now: start.addingTimeInterval(120))
        XCTAssertEqual(receipt.rows.first?.percentagePoints, 0)
        XCTAssertEqual(receipt.rows.first?.note, "표시상 변화 없음")
        XCTAssertTrue(receipt.copyText.contains("표시상 변화 없음 (0%p)"))
    }
    func testStartRequiresRecentFiniteUsableSnapshot() throws {
        XCTAssertThrowsError(try session(snapshot(at: start.addingTimeInterval(-61))))
        XCTAssertThrowsError(try session(snapshot(at: start.addingTimeInterval(1))))
        XCTAssertThrowsError(try session(snapshot(.nan)))
        XCTAssertThrowsError(try session(snapshot(101)))
        XCTAssertThrowsError(try session(snapshot(windows: [])))
        XCTAssertThrowsError(try WorkSession.start(kind: .other, snapshot: snapshot(), now: Date(timeIntervalSince1970: .infinity)))
        XCTAssertNoThrow(try session(snapshot(at: start.addingTimeInterval(-60))))
    }
    func testMissingAndStaleFinishRemainRecordedWithReason() throws {
        XCTAssertTrue(try note(nil).contains("조회하지 못"))
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(59))).contains("최신 조회"))
        XCTAssertTrue(try note(snapshot(at: start)).contains("최신 조회"))
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(121))).contains("최신 조회"))
    }
    func testUnknownAndChangedAccountsCannotBeCompared() throws {
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120), account: "another")).contains("계정이 변경"))
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120), account: nil)).contains("같은 계정"))
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120), account: nil), session: session(snapshot(account: nil))).contains("같은 계정"))
    }
    func testProviderAndPlanChangesCannotBeCompared() throws {
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120), provider: .codex)).contains("다른 서비스"))
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120), plan: "other")).contains("플랜"))
    }
    func testResetBoundaryBlocksComparisonEvenIfUsageIncreases() throws {
        let work = try session(snapshot(reset: start.addingTimeInterval(60)))
        XCTAssertTrue(try note(snapshot(30, at: start.addingTimeInterval(120)), session: work).contains("리셋 시각이 포함"))
    }
    func testResetMovementToleranceAndMissingReset() throws {
        XCTAssertTrue(try note(snapshot(30, at: start.addingTimeInterval(120), reset: start.addingTimeInterval(3_091))).contains("리셋 시각이 변경"))
        let close = try session().finish(snapshot: snapshot(30, at: start.addingTimeInterval(120), reset: start.addingTimeInterval(3_090)), now: start.addingTimeInterval(120))
        XCTAssertEqual(close.rows.first?.percentagePoints, 10)
        let noReset = snapshot(windows: [UsageWindow(id: "window-private-id", label: "세션", usedPercent: 20, resetsAt: nil, durationMinutes: 300)])
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120)), session: session(noReset)).contains("리셋 시각이 없어"))
    }
    func testMissingChangedAndInvalidWindowsHaveReasons() throws {
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120), windows: [])).contains("같은 한도"))
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120), duration: 500)).contains("기간이 변경"))
        XCTAssertTrue(try note(snapshot(.nan, at: start.addingTimeInterval(120))).contains("유효하지"))
        XCTAssertTrue(try note(snapshot(19, at: start.addingTimeInterval(120))).contains("감소"))
    }
    func testReceiptWindowOrderIsIndependentOfProviderResponseOrder() throws {
        let reset = start.addingTimeInterval(3_000)
        let windows = [
            UsageWindow(id: "unknown", label: "기간 미상", usedPercent: 10, resetsAt: reset),
            UsageWindow(id: "weekly", label: "주간", usedPercent: 10, resetsAt: reset, durationMinutes: 10_080),
            UsageWindow(id: "session-b", label: "5시간 B", usedPercent: 10, resetsAt: reset, durationMinutes: 300),
            UsageWindow(id: "session-a", label: "5시간 A", usedPercent: 10, resetsAt: reset, durationMinutes: 300)
        ]
        let end = start.addingTimeInterval(120)
        let forward = try session(snapshot(windows: windows)).finish(snapshot: snapshot(at: end, windows: windows.reversed()), now: end)
        let reverse = try session(snapshot(windows: windows.reversed())).finish(snapshot: snapshot(at: end, windows: windows), now: end)
        XCTAssertEqual(forward.rows, reverse.rows)
        XCTAssertEqual(forward.rows.map(\.label), ["5시간 A", "5시간 B", "주간", "기간 미상"])
    }
    func testDuplicateWindowsAreNeverSilentlyPaired() throws {
        let window = snapshot().windows[0]
        XCTAssertThrowsError(try session(snapshot(windows: [window, window])))
        XCTAssertTrue(try note(snapshot(at: start.addingTimeInterval(120), windows: [window, window])).contains("같은 한도"))
    }
    func testSensitiveSnapshotFieldsAreNeverSerialized() throws {
        let active = try session()
        let receipt = active.finish(snapshot: snapshot(30, at: start.addingTimeInterval(120)), now: start.addingTimeInterval(120))
        let encoder = JSONEncoder()
        let activeText = String(decoding: try encoder.encode(active), as: UTF8.self)
        let completedText = String(decoding: try encoder.encode(receipt), as: UTF8.self)
        for secret in ["private-account", "private-plan", "window-private-id", "sensitive-source", "sensitive-day", "dailyUsage", "resetCreditCount"] {
            XCTAssertFalse(activeText.contains(secret), secret)
            XCTAssertFalse(completedText.contains(secret), secret)
            XCTAssertFalse(receipt.copyText.contains(secret), secret)
        }
        XCTAssertTrue(activeText.contains("accountDigest"))
        XCTAssertFalse(completedText.contains("accountDigest"))
        XCTAssertFalse(completedText.contains("planFingerprint"))
        XCTAssertFalse(completedText.contains("windowDigest"))
    }
    func testPrivatePersistenceSurvivesRelaunchAndCapsHistory() async throws {
        let directory = tempDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let work = try session()
        var receipts: [WorkReceipt] = []
        for index in 0..<105 {
            receipts.append(WorkReceipt(kind: .build, provider: .claude, startedAt: start,
                                        endedAt: start.addingTimeInterval(Double(index + 1)),
                                        rows: [WorkQuotaDelta(id: "x", label: "세션", percentagePoints: 0)]))
        }
        let store = WorkJournalStore(directory: directory)
        try await store.save(WorkJournalState(active: work, receipts: receipts))
        let restored = try await WorkJournalStore(directory: directory).load()
        XCTAssertEqual(restored.active, work)
        XCTAssertEqual(restored.receipts.count, 100)
        XCTAssertEqual(restored.receipts.first?.endedAt, start.addingTimeInterval(105))
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("work-journal.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
    }
    func testDamagedArchiveIsNotOverwritten() async throws {
        let directory = tempDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("work-journal.json")
        let original = Data("{ broken file".utf8); try original.write(to: file)
        let store = WorkJournalStore(directory: directory)
        do { _ = try await store.load(); XCTFail("Expected load failure") } catch {}
        do { try await store.save(WorkJournalState()); XCTFail("Expected preserved archive") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testOversizedArchiveIsRejectedAndPreserved() async throws {
        let directory = tempDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("work-journal.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 4_000_001)
        try handle.close()
        let store = WorkJournalStore(directory: directory)
        do { _ = try await store.load(); XCTFail("Expected size rejection") } catch {}
        do { try await store.save(WorkJournalState()); XCTFail("Expected preserved archive") } catch {}
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 4_000_001)
    }
    func testSymlinkFileAndDirectoryAreRejected() async throws {
        let root = tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let linkedDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: destination)
        do { try await WorkJournalStore(directory: linkedDirectory).save(WorkJournalState()); XCTFail("Expected path rejection") } catch {}
        let target = root.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("work-journal.json"), withDestinationURL: target)
        do { try await WorkJournalStore(directory: destination).save(WorkJournalState()); XCTFail("Expected path rejection") } catch {}
        XCTAssertEqual(try String(contentsOf: target), "unchanged")
    }
    private func tempDirectory() -> URL {
        URL(fileURLWithPath: "/private/tmp").appendingPathComponent("usagebar-journal-test-\(UUID().uuidString)")
    }
}
