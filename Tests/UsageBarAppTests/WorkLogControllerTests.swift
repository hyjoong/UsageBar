import Foundation
import XCTest
import UsageBarCore
import WorkLogCore
@testable import UsageBar

@MainActor
final class WorkLogControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "WorkLogControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private final class Calls: @unchecked Sendable {
        var requests: [WorkLogRequest] = []
        var clears = 0
    }

    private func day(_ offset: Int = 0) -> DateInterval {
        let start = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))!
        return DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 1, to: start)!)
    }

    private func log(projects: Int = 1, partial: Bool = false, git: GitReadState = .off, offset: Int = 0) -> DailyWorkLog {
        let day = day(offset)
        let events = (0..<projects).map { index in
            WorkLogEvent(time: day.start.addingTimeInterval(3_600 + Double(index) * 60), source: .claude,
                         sessionID: "s\(index)", cwd: "/work/p\(index)", kind: .activity)
        }
        let gitState = Dictionary(uniqueKeysWithValues: (0..<projects).map { ("/work/p\($0)", ProjectGit(state: git)) })
        return DailyWorkLogBuilder().build(day: day, batch: WorkLogBatch(events: events), git: gitState, isPartial: partial)
    }

    private func controller(result: WorkLogResult, calls: Calls) -> WorkLogController {
        WorkLogController(defaults: defaults, loader: { request in
            calls.requests.append(request)
            return result
        }, clearIndex: { calls.clears += 1 })
    }

    func testOffByDefaultAndReadsNothing() async {
        let calls = Calls()
        let controller = controller(result: WorkLogResult(logs: [log()]), calls: calls)
        XCTAssertFalse(controller.settings.isEnabled)
        XCTAssertFalse(controller.settings.includesGit)
        XCTAssertTrue(controller.settings.showsPrompts)
        await controller.refresh()
        await controller.runWhileVisible()
        XCTAssertTrue(calls.requests.isEmpty)
        XCTAssertTrue(controller.logs.isEmpty)
    }

    func testEnablingRefreshesAndPersistsDisablingClearsTheIndex() async {
        let calls = Calls()
        let controller = controller(result: WorkLogResult(logs: [log(), log(offset: 1)]), calls: calls)
        await controller.setEnabled(true)
        XCTAssertEqual(calls.requests.count, 1)
        XCTAssertEqual(calls.requests.first?.days, WorkLogController.days)
        XCTAssertEqual(controller.logs.count, 2)
        XCTAssertEqual(controller.selectedLog?.projects.count, 1)
        XCTAssertTrue(defaults.bool(forKey: "workLogEnabled"))

        await controller.setEnabled(false)
        XCTAssertEqual(calls.clears, 1)
        XCTAssertTrue(controller.logs.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: "workLogEnabled"))
    }

    func testSettingsAndTabSurviveANewController() async {
        let calls = Calls()
        let first = controller(result: WorkLogResult(logs: []), calls: calls)
        await first.setEnabled(true)
        await first.setIncludesGit(true)
        first.setShowsPrompts(false)
        await first.setExcludedProjects([" secret ", "Secret", "", "other"])
        first.tab = .week
        XCTAssertEqual(first.settings.excludedProjects, ["secret", "other"])
        XCTAssertEqual(calls.requests.last?.settings.includesGit, true)

        let second = controller(result: WorkLogResult(logs: []), calls: calls)
        XCTAssertEqual(second.settings, first.settings)
        XCTAssertEqual(second.tab, .week)
    }

    func testPartialPassIsShownAndGitFailureKeepsTheRest() async {
        let calls = Calls()
        let controller = controller(result: WorkLogResult(logs: [log(projects: 2, partial: true, git: .failed)], isPartial: true),
                                    calls: calls)
        await controller.setEnabled(true)
        let selected = controller.selectedLog
        XCTAssertEqual(selected?.isPartial, true)
        XCTAssertEqual(selected?.projects.count, 2)
        XCTAssertEqual(selected?.projects.map(\.git.state), [.failed, .failed])
        XCTAssertGreaterThan(selected?.duration ?? 0, 0)
    }

    func testDayStepsStayInsideTheLoadedWeek() async {
        let calls = Calls()
        let controller = controller(result: WorkLogResult(logs: [log(), log(offset: 1)]), calls: calls)
        await controller.setEnabled(true)
        XCTAssertFalse(controller.canGoForward)
        XCTAssertTrue(controller.canGoBack)
        controller.step(-1)
        XCTAssertEqual(controller.selectedDay, day(1).start)
        XCTAssertFalse(controller.canGoBack)
        controller.step(-1)
        XCTAssertEqual(controller.selectedDay, day(1).start)
        controller.tab = .week
        controller.show(day(0).start.addingTimeInterval(3_600))
        XCTAssertEqual(controller.selectedDay, day(0).start)
        XCTAssertEqual(controller.tab, .today)
    }

    func testTurningOffWhileAPassRunsStartsNoNewPassAndClearsLast() async {
        final class Gate: @unchecked Sendable { var loads = 0; var clears = 0; var clearedAfterLoad = true }
        let gate = Gate()
        let controller = WorkLogController(defaults: defaults, loader: { _ in
            gate.loads += 1
            try? await Task.sleep(nanoseconds: 200_000_000)
            if gate.clears > 0 { gate.clearedAfterLoad = false }
            return WorkLogResult(logs: [])
        }, clearIndex: { gate.clears += 1 })
        await controller.setEnabled(true)
        XCTAssertEqual(gate.loads, 1)
        async let first: Void = controller.refresh()
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let waiter: Void = controller.refresh()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await controller.setEnabled(false)
        _ = await (first, waiter)
        XCTAssertEqual(gate.loads, 2, "the waiting refresh must not start a pass after the log was turned off")
        XCTAssertEqual(gate.clears, 1)
        XCTAssertTrue(gate.clearedAfterLoad, "no pass may finish after the index was cleared")
    }

    func testNewestDayIsFollowedAcrossMidnight() async {
        final class Results: @unchecked Sendable { var next: [DailyWorkLog] = [] }
        let results = Results()
        results.next = [log(offset: 1), log(offset: 2), log(offset: 3)]
        let controller = WorkLogController(defaults: defaults, loader: { _ in WorkLogResult(logs: results.next) },
                                           clearIndex: {})
        await controller.setEnabled(true)
        XCTAssertEqual(controller.selectedDay, day(1).start)
        // Midnight passes: the newest day moves on, and so does the selection.
        results.next = [log(offset: 0), log(offset: 1), log(offset: 2)]
        await controller.refresh()
        XCTAssertEqual(controller.selectedDay, day(0).start)
        // A day the person stepped back to stays selected.
        controller.step(-1)
        controller.step(-1)
        await controller.refresh()
        XCTAssertEqual(controller.selectedDay, day(2).start)
    }

    func testHiddenPromptsReadNothing() async throws {
        let controller = WorkLogController(demo: true, defaults: defaults)
        let location = try XCTUnwrap(controller.logs.flatMap(\.projects).flatMap(\.prompts).first?.location)
        let shown = await controller.excerpts([location])
        XCTAssertEqual(shown.count, 1)
        controller.setShowsPrompts(false)
        let hidden = await controller.excerpts([location])
        XCTAssertTrue(hidden.isEmpty)
    }

    func testReceiptsAttachWhenTheyOverlapTheProjectsWork() {
        let project = log().projects[0]
        let interval = project.intervals[0]
        let inside = WorkReceipt(kind: .build, provider: .claude, startedAt: interval.start.addingTimeInterval(-600),
                                 endedAt: interval.start.addingTimeInterval(60), rows: [])
        let outside = WorkReceipt(kind: .debug, provider: .claude, startedAt: interval.end.addingTimeInterval(60),
                                  endedAt: interval.end.addingTimeInterval(600), rows: [])
        XCTAssertEqual(WorkLogController.receipts([outside, inside], overlapping: project).map(\.id), [inside.id])
    }

    func testDemoWeekHasProjectsCommitsAndAnExclusion() async throws {
        let controller = WorkLogController(demo: true, defaults: defaults)
        XCTAssertEqual(controller.logs.count, WorkLogController.days)
        // Demo sessions are relative to now; just after midnight most belong to yesterday.
        let projects = controller.logs.flatMap(\.projects)
        XCTAssertGreaterThanOrEqual(Set(projects.map(\.name)).count, 2)
        XCTAssertGreaterThan(controller.logs.reduce(0) { $0 + $1.commitCount }, 0)
        XCTAssertFalse(controller.weekMarkdown().isEmpty)
        let name = try XCTUnwrap(projects.first).name
        await controller.setExcludedProjects([name.uppercased()])
        XCTAssertFalse(controller.logs.flatMap(\.projects).contains { $0.name == name })
        XCTAssertNil(defaults.object(forKey: "workLogExcludedProjects"))
    }

    /// The real pipeline over a temporary folder: index written, logs built, no git.
    func testPipelineIndexesTemporaryLogs() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("usagebar-worklog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = folder.appendingPathComponent("claude/project", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date().addingTimeInterval(-600)
        let lines = (0..<3).map { index in
            #"{"type":"user","sessionId":"s1","cwd":"/work/app","timestamp":"\#(formatter.string(from: start.addingTimeInterval(Double(index) * 60)))","message":{"role":"user","content":"요청 번호 \#(index) 내용을 길게 적어 둡니다"}}"#
        }
        try (lines.joined(separator: "\n") + "\n").write(to: claude.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let store = LogIndexStore(directory: folder.appendingPathComponent("support"))
        let request = WorkLogRequest(now: Date(), days: 7, settings: WorkLogSettings(isEnabled: true))
        let result = await WorkLogController.load(request, store: store, claudeRoots: [folder.appendingPathComponent("claude")],
                                                  codexRoots: [], codexTitles: folder.appendingPathComponent("none.jsonl"),
                                                  gitRunner: nil)
        XCTAssertTrue(result.savedIndex)
        XCTAssertEqual(result.logs.count, 7)
        let today = result.logs.first { $0.day.contains(start) }
        XCTAssertEqual(today?.projects.first?.name, "app")
        XCTAssertEqual(today?.projects.first?.git.state, .off)
        let indexPath = folder.appendingPathComponent("support/worklog-index/index.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexPath))

        // Nothing new in the logs: the index file is left as it is (an atomic save would replace it).
        let fileNumber = { (try? FileManager.default.attributesOfItem(atPath: indexPath)[.systemFileNumber]) as? NSNumber }
        let before = fileNumber()
        let again = await WorkLogController.load(request, store: store, claudeRoots: [folder.appendingPathComponent("claude")],
                                                 codexRoots: [], codexTitles: folder.appendingPathComponent("none.jsonl"),
                                                 gitRunner: nil)
        XCTAssertTrue(again.savedIndex)
        XCTAssertEqual(fileNumber(), before)
        try await store.clear()
    }
}
