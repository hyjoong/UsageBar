import XCTest
@testable import WorkLogCore

final class GitRepositoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("worklog-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLocatorFindsRepositoryFromSubfolderAndJoinsWorktrees() throws {
        let repo = directory.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/Deep"), withIntermediateDirectories: true)
        let worktree = directory.appendingPathComponent("worktrees/wt")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: repo.appendingPathComponent(".git/worktrees/wt/commondir"), atomically: true, encoding: .utf8)

        let main = RepositoryLocator.repository(for: repo.appendingPathComponent("Sources/Deep").path)
        XCTAssertEqual(main, GitRepository(root: repo.path, commonDirectory: repo.path + "/.git", name: "app"))
        let linked = RepositoryLocator.repository(for: worktree.appendingPathComponent("lib").path)
        XCTAssertEqual(linked, GitRepository(root: worktree.path, commonDirectory: repo.path + "/.git", name: "app"))
        XCTAssertNil(RepositoryLocator.repository(for: directory.appendingPathComponent("nothing/here").path))

        let project = WorkLogProject.repository(worktree.path)
        XCTAssertEqual(project.id, repo.path + "/.git")
        XCTAssertEqual(project.root, worktree.path)
    }

    func testParseLogSkipsDuplicatesAndBrokenRecords() {
        let output = "\u{1e}aaaaaaa1\u{1f}2026-10-17T10:00:00+09:00\u{1f}Fix: a | b\nSources/A.swift\nREADME.md\n"
            + "\u{1e}aaaaaaa1\u{1f}2026-10-17T10:00:00+09:00\u{1f}Fix: a | b\n"
            + "\u{1e}bad\u{1f}not a date\u{1f}x\n"
            + "\u{1e}bbbbbbb2\u{1f}2026-10-17T11:00:00+09:00\u{1f}Empty commit\n"
        let commits = GitHistoryReader.parseLog(output)
        XCTAssertEqual(commits.map(\.sha), ["aaaaaaa1", "bbbbbbb2"])
        XCTAssertEqual(commits[0].files, ["Sources/A.swift", "README.md"])
        XCTAssertEqual(commits[0].time, LogParsing.date("2026-10-17T01:00:00Z"))
        XCTAssertEqual(commits[1].files, [])
    }

    private struct FakeRunner: GitRunning {
        let error: GitRunError?
        func run(_ arguments: [String], in directory: String) throws -> String {
            if let error { throw error }
            return ""
        }
    }

    func testReadGitReportsState() {
        let repo = GitRepository(root: "/r", commonDirectory: "/r/.git", name: "r")
        let project = WorkLogProject(id: "/r/.git", name: "r", root: "/r", repository: repo)
        let folder = WorkLogProject.folder("/plain")
        let day = DateInterval(start: LogParsing.date("2026-10-17T00:00:00Z")!, duration: 86_400)
        XCTAssertEqual(DailyWorkLogBuilder.readGit(for: [project, folder], day: day, reader: nil)["/r/.git"]?.state, .unavailable)
        XCTAssertNil(DailyWorkLogBuilder.readGit(for: [folder], day: day, reader: nil)["/plain"])
        let failing = GitHistoryReader(runner: FakeRunner(error: .timedOut))
        XCTAssertEqual(DailyWorkLogBuilder.readGit(for: [project], day: day, reader: failing)["/r/.git"]?.state, .failed)
        let missing = GitHistoryReader(runner: FakeRunner(error: .unavailable))
        XCTAssertEqual(DailyWorkLogBuilder.readGit(for: [project], day: day, reader: missing)["/r/.git"]?.state, .unavailable)
    }

    // MARK: Real git

    private func git(_ arguments: [String], in folder: URL, date: String? = nil, author: String = "me@example.com") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessGitRunner()!.executable)
        process.arguments = ["-C", folder.path] + arguments
        var environment = ["HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Me",
                           "GIT_COMMITTER_NAME": "Me", "GIT_AUTHOR_EMAIL": author, "GIT_COMMITTER_EMAIL": author]
        if let date { environment["GIT_AUTHOR_DATE"] = date; environment["GIT_COMMITTER_DATE"] = date }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    func testReadsDayCommitsByAuthorAndUncommittedFiles() throws {
        guard let runner = ProcessGitRunner() else { throw XCTSkip("git is not installed") }
        let repo = directory.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        try git(["config", "user.email", "me@example.com"], in: repo)
        func commit(_ file: String, _ message: String, _ date: String, author: String = "me@example.com") throws {
            try message.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try git(["add", file], in: repo)
            try git(["commit", "-q", "-m", message], in: repo, date: date, author: author)
        }
        try commit("a.txt", "Yesterday", "2026-10-16T23:30:00Z")
        try commit("b.txt", "Morning work", "2026-10-17T09:00:00Z")
        try commit("c.txt", "Someone else", "2026-10-17T10:00:00Z", author: "other@example.com")
        try "changed".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let repository = try XCTUnwrap(RepositoryLocator.repository(for: repo.path))
        let reader = GitHistoryReader(runner: runner)
        let day = DateInterval(start: LogParsing.date("2026-10-17T00:00:00Z")!, duration: 86_400)
        XCTAssertEqual(reader.authorEmail(repository), "me@example.com")
        let mine = try reader.commits(repository, in: day, author: "me@example.com")
        XCTAssertEqual(mine.map(\.subject), ["Morning work"])
        XCTAssertEqual(mine.first?.files, ["b.txt"])
        XCTAssertEqual(try reader.commits(repository, in: day, author: nil).count, 2)
        XCTAssertEqual(try reader.uncommittedFiles(repository), ["a.txt"])
    }
}
