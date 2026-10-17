import XCTest
@testable import WorkLogCore

final class DailyWorkLogTests: XCTestCase {
    private let day = DateInterval(start: LogParsing.date("2026-10-17T00:00:00Z")!, duration: 86_400)
    private func at(_ hour: Double) -> Date { day.start.addingTimeInterval(hour * 3600) }

    private func prompt(_ hour: Double, session: String = "s1", cwd: String? = "/w/app", characters: Int = 30,
                        offset: UInt64 = 0, source: WorkLogSource = .claude) -> WorkLogEvent {
        WorkLogEvent(time: at(hour), source: source, sessionID: session, cwd: cwd,
                     kind: .prompt(PromptLocation(path: "/logs/\(session).jsonl", offset: offset, length: 10, characterCount: characters)))
    }

    private func event(_ hour: Double, _ kind: WorkLogEventKind = .activity, session: String = "s1",
                       cwd: String? = "/w/app", source: WorkLogSource = .claude) -> WorkLogEvent {
        WorkLogEvent(time: at(hour), source: source, sessionID: session, cwd: cwd, kind: kind)
    }

    private func offsets(_ project: ProjectDay) -> [UInt64] { project.prompts.map(\.location.offset) }

    func testBuildsProjectsWithTimeRequestsFilesAndPullRequests() {
        let batch = WorkLogBatch(events: [
            prompt(9, offset: 1),                                   // first of session
            prompt(9.05, characters: 3, offset: 2),                 // "ok": too short
            event(9.1, .fileEdit(path: "/w/app/Sources/A.swift")),
            event(9.15, .fileEdit(path: "/w/app/Sources/A.swift")),
            event(9.2, .fileEdit(path: "/elsewhere/B.swift")),      // outside the project
            prompt(9.25, offset: 3),                                // not chosen: no pause, no commit
            prompt(10, offset: 4),                                  // after a 45 minute pause
            event(10.1, .pullRequest(url: "https://example.com/pr/1"), cwd: nil),  // takes the session's folder
            event(10.2, .pullRequest(url: "https://example.com/pr/1")),
            prompt(11, session: "t1", cwd: "/w/api", offset: 5, source: .codex),
            event(11, .turn(end: at(11.5)), session: "t1", cwd: "/w/api", source: .codex),
            event(23.95, session: "late", cwd: "/w/app"),           // 23:57, runs past midnight
        ], titles: ["s1": "Plan the log"])
        let log = DailyWorkLogBuilder().build(day: day, batch: batch)

        XCTAssertEqual(log.projects.map(\.name), ["app", "api"])
        let app = log.projects[0]
        XCTAssertEqual(offsets(app), [1, 4])
        XCTAssertEqual(app.editedFiles, ["Sources/A.swift"])
        XCTAssertEqual(app.pullRequests, ["https://example.com/pr/1"])
        XCTAssertEqual(app.sources, [.claude])
        XCTAssertEqual(app.sessions.first?.title, "Plan the log")
        XCTAssertEqual(app.sessions.first?.promptCount, 4)
        // 9:00–9:15 + 5 → 20 min, 10:00–10:12 + 5 → 17 min, 23:57 → 3 min before midnight.
        XCTAssertEqual(app.duration / 60, 20 + 17 + 3, accuracy: 0.01)

        let api = log.projects[1]
        XCTAssertEqual(api.sources, [.codex])
        XCTAssertEqual(api.duration / 60, 35, accuracy: 0.01)
        XCTAssertEqual(log.duration, app.duration + api.duration, accuracy: 0.01)
        XCTAssertEqual(log.changedFileCount, 1)
    }

    func testParallelProjectsCountOnceInTotal() {
        let batch = WorkLogBatch(events: [event(9), event(9.25), event(9, cwd: "/w/api"), event(9.25, cwd: "/w/api")])
        let log = DailyWorkLogBuilder().build(day: day, batch: batch)
        XCTAssertEqual(log.projects.count, 2)
        XCTAssertEqual(log.duration / 60, 20, accuracy: 0.01)
    }

    func testCommitsAddTimeAndPickTheRequestBeforeThem() {
        let batch = WorkLogBatch(events: [prompt(9, offset: 1), prompt(9.1, offset: 2), prompt(9.2, offset: 3), event(9.3)])
        let commit = GitCommit(sha: "abcdef1234", time: at(9.4), subject: "Add log", files: ["Sources/A.swift", "README.md"])
        let yesterday = GitCommit(sha: "0000000aaa", time: at(-2), subject: "Old", files: [])
        let git = ["/w/app": ProjectGit(state: .ok, commits: [commit, yesterday], uncommittedFiles: ["README.md", "Notes.md"])]
        let log = DailyWorkLogBuilder().build(day: day, batch: batch, git: git)
        let app = log.projects[0]
        XCTAssertEqual(offsets(app), [1, 3])
        XCTAssertEqual(app.commits.map(\.subject), ["Add log"])
        XCTAssertEqual(app.changedFiles, ["Sources/A.swift", "README.md", "Notes.md"])
        // 9:00–9:24 (commit) + 5
        XCTAssertEqual(app.duration / 60, 29, accuracy: 0.01)
    }

    func testCommitOnlyProjectAndExclusion() {
        let commit = GitCommit(sha: "abcdef1234", time: at(15), subject: "Fix", files: ["a"])
        let builder = DailyWorkLogBuilder(excludedNames: ["Secret"])
        let batch = WorkLogBatch(events: [event(14.99, cwd: "/w/secret"), event(-3, cwd: "/w/app")])
        let log = builder.build(day: day, batch: batch, git: ["/w/app": ProjectGit(state: .ok, commits: [commit])])
        XCTAssertEqual(log.projects.map(\.name), ["app"])
        XCTAssertEqual(log.projects[0].duration / 60, 5, accuracy: 0.01)
        XCTAssertTrue(DailyWorkLogBuilder().build(day: day, batch: WorkLogBatch()).isEmpty)
    }

    // MARK: Formatter

    private var formatter: WorkLogFormatter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return WorkLogFormatter(calendar: calendar, locale: Locale(identifier: "ko_KR")) { location in
            ["/logs/s1.jsonl": "작업 기록 기획 문서 작성", "/logs/t1.jsonl": "로그인 오류 고치기"][location.path]
        }
    }

    private func sampleLog() -> DailyWorkLog {
        let batch = WorkLogBatch(events: [
            prompt(9), event(9.5), event(9.6, .fileEdit(path: "/w/app/Sources/A.swift")),
            prompt(13, session: "t1", cwd: "/w/api", source: .codex), event(13.1, session: "t1", cwd: "/w/api"),
        ], titles: ["t1": "Login"])
        let git = [
            "/w/app": ProjectGit(state: .ok, commits: [
                GitCommit(sha: "a636106aaa", time: at(9.55), subject: "Color the low service", files: ["Sources/A.swift"]),
                GitCommit(sha: "ca0fcf1bbb", time: at(9.7), subject: "Release 0.9.1", files: ["CHANGELOG.md"]),
            ], uncommittedFiles: ["docs/plan.md"]),
            "/w/api": ProjectGit(state: .ok, commits: [], uncommittedFiles: ["server.ts", "auth.ts"]),
        ]
        return DailyWorkLogBuilder().build(day: day, batch: batch, git: git)
    }

    func testStandUp() {
        // The issues line keeps its trailing space for the person to type after.
        XCTAssertEqual(formatter.standUp(sampleLog()),
                       "한 일: app Release 0.9.1 · Color the low service (커밋 2)\n"
                       + "진행 중: api — 로그인 오류 고치기 (미커밋 2파일)\n"
                       + "이슈: ")
        XCTAssertEqual(formatter.standUp(DailyWorkLogBuilder().build(day: day, batch: WorkLogBatch())),
                       "한 일: —\n진행 중: —\n이슈: ")
    }

    func testMarkdown() {
        // app: 9:00 alone (5 min); 9:30, commits at 9:33 and 9:42 (17 min). api: 13:00–13:06 (11 min).
        XCTAssertEqual(formatter.markdown(sampleLog()), """
        ## 2026-10-17 (토) 작업 기록
        총 33분 · 프로젝트 2 · 커밋 2 · 파일 5

        ### app — 22분
        - 요청: 작업 기록 기획 문서 작성
        - 커밋: `a636106` Color the low service
        - 커밋: `ca0fcf1` Release 0.9.1
        - 파일 3개 변경 (커밋 2 · 미커밋 1)

        ### api — 11분
        - 요청: 로그인 오류 고치기
        - 파일 2개 변경 (커밋 0 · 미커밋 2)
        """)
    }

    func testDurationText() {
        XCTAssertEqual(WorkLogFormatter.duration(10), "1분 미만")
        XCTAssertEqual(WorkLogFormatter.duration(55 * 60), "55분")
        XCTAssertEqual(WorkLogFormatter.duration(120 * 60), "2시간")
        XCTAssertEqual(WorkLogFormatter.duration(115 * 60), "1시간 55분")
        XCTAssertEqual(WorkLogFormatter.duration(.nan), "1분 미만")
    }
}
