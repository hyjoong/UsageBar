import Combine
import Foundation
import UsageBarCore
import WorkLogCore

/// Tabs of the work log window. The raw values are stored, so keep them stable.
enum WorkLogTab: String, CaseIterable, Identifiable {
    case today, week, receipts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: String(localized: "오늘")
        case .week: String(localized: "7일")
        case .receipts: String(localized: "영수증")
        }
    }
}

/// What the person chose in Settings → Work log. See docs/plans/0.10-work-log.md §8 and §15.
struct WorkLogSettings: Equatable, Sendable {
    /// Off until the person turns it on from the intro card or Settings (decision Q1).
    var isEnabled = false
    /// Off by default: reading project folders can make macOS ask for Desktop or Documents access (Q2).
    var includesGit = false
    /// When off, cards and copies show session titles only.
    var showsPrompts = true
    /// Project names left out of the log and its copies, compared case-insensitively.
    var excludedProjects: [String] = []
}

struct WorkLogRequest: Sendable {
    let now: Date
    let days: Int
    let settings: WorkLogSettings
}

struct WorkLogResult: Sendable {
    /// One log per day, newest first.
    var logs: [DailyWorkLog]
    var isPartial = false
    /// The index could not be saved; the next refresh reads the logs again.
    var savedIndex = true
}

/// Builds the daily journal from the local Claude Code and Codex logs (and, when allowed, git) for the
/// work log window. The heavy part runs off the main actor; only the finished logs come back.
@MainActor
final class WorkLogController: ObservableObject {
    typealias Loader = @Sendable (WorkLogRequest) async -> WorkLogResult

    /// Days the today tab can step back through. The index keeps one more, so a stretch that starts
    /// before the first shown midnight still has its beginning.
    static let days = 7
    static let refreshInterval: Duration = .seconds(600)
    /// A partial pass continues soon instead of waiting for the next interval.
    static let partialRetry: Duration = .seconds(3)
    /// After the index could not be saved, every pass starts from the beginning again; retrying every
    /// few seconds would reread hundreds of megabytes in a loop.
    static let unsavedRetry: Duration = .seconds(60)
    private var indexSaveFailed = false

    @Published private(set) var settings = WorkLogSettings()
    @Published var tab: WorkLogTab = .today {
        didSet { if !isDemo { defaults.set(tab.rawValue, forKey: Keys.tab) } }
    }
    /// Newest first.
    @Published private(set) var logs: [DailyWorkLog] = []
    /// Start of the day the today tab shows.
    @Published var selectedDay: Date
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var message: String?

    let isDemo: Bool
    private let defaults: UserDefaults
    private let loader: Loader
    private let clearIndex: @Sendable () async throws -> Void
    private var refreshTask: Task<WorkLogResult, Never>?
    private var generation = 0
    private let demoExcerpts: [String: String]

    private enum Keys {
        static let enabled = "workLogEnabled", git = "workLogIncludesGit", prompts = "workLogShowsPrompts"
        static let excluded = "workLogExcludedProjects", tab = "workLogTab"
    }

    /// `usesIndex: false` keeps tests away from the home folder: nothing is read and nothing is stored.
    init(demo: Bool = false, defaults: UserDefaults, usesIndex: Bool = true,
         loader: Loader? = nil, clearIndex: (@Sendable () async throws -> Void)? = nil) {
        isDemo = demo
        self.defaults = defaults
        selectedDay = Calendar.current.startOfDay(for: Date())
        let store = LogIndexStore()
        if let loader {
            self.loader = loader
        } else if usesIndex && !demo {
            self.loader = { request in await Task.detached(priority: .utility) { await Self.load(request, store: store) }.value }
        } else {
            self.loader = { _ in WorkLogResult(logs: []) }
        }
        if let clearIndex {
            self.clearIndex = clearIndex
        } else if usesIndex && !demo {
            self.clearIndex = { try await store.clear() }
        } else {
            self.clearIndex = {}
        }
        if demo {
            let demo = Self.demoLogs(now: Date())
            logs = demo.logs
            demoExcerpts = demo.excerpts
            settings = WorkLogSettings(isEnabled: true, includesGit: true)
            #if DEBUG
            if CommandLine.arguments.contains("--ui-worklog-intro") { settings.isEnabled = false; logs = [] }
            if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-worklog-tab=") })?.split(separator: "=").last,
               let saved = WorkLogTab(rawValue: String(raw)) { tab = saved }
            #endif
        } else {
            demoExcerpts = [:]
            settings.isEnabled = defaults.bool(forKey: Keys.enabled)
            settings.includesGit = defaults.bool(forKey: Keys.git)
            if defaults.object(forKey: Keys.prompts) != nil { settings.showsPrompts = defaults.bool(forKey: Keys.prompts) }
            settings.excludedProjects = defaults.stringArray(forKey: Keys.excluded) ?? []
            tab = WorkLogTab(rawValue: defaults.string(forKey: Keys.tab) ?? "") ?? .today
        }
    }

    // MARK: Settings

    func setEnabled(_ enabled: Bool) async {
        guard enabled != settings.isEnabled else { return }
        settings.isEnabled = enabled
        if !isDemo { defaults.set(enabled, forKey: Keys.enabled) }
        if enabled {
            await refresh()
        } else {
            // Let a pass in flight finish first, or it would write the index back after it was removed.
            generation += 1
            await waitForRefreshes()
            logs = []
            lastRefreshed = nil
            do { try await clearIndex(); message = nil } catch {
                message = String(localized: "작업 일지 캐시를 지우지 못했어요. 다시 꺼 보세요.")
            }
        }
    }

    /// Call only after the person saw the folder access notice (`WorkLogGitNotice`).
    func setIncludesGit(_ value: Bool) async {
        guard value != settings.includesGit else { return }
        settings.includesGit = value
        if !isDemo { defaults.set(value, forKey: Keys.git) }
        await refreshIfEnabled()
    }

    func setShowsPrompts(_ value: Bool) {
        settings.showsPrompts = value
        if !isDemo { defaults.set(value, forKey: Keys.prompts) }
    }

    func setExcludedProjects(_ names: [String]) async {
        var seen = Set<String>()
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard cleaned != settings.excludedProjects else { return }
        settings.excludedProjects = cleaned
        if !isDemo { defaults.set(cleaned, forKey: Keys.excluded) }
        if isDemo {
            let excluded = Set(cleaned.map { $0.lowercased() })
            logs = Self.demoLogs(now: Date(), excluding: excluded).logs
        }
        await refreshIfEnabled()
    }

    /// "a, b" ↔ ["a", "b"] for the settings field.
    static func parseProjectList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { String($0) }
    }

    // MARK: Refresh

    /// Refreshes now and then every `refreshInterval` until the caller's task is cancelled (the window closed).
    func runWhileVisible() async {
        while !Task.isCancelled {
            guard settings.isEnabled else { return }
            await refresh()
            let partial = logs.first?.isPartial ?? false
            try? await Task.sleep(for: indexSaveFailed ? Self.unsavedRetry : partial ? Self.partialRetry : Self.refreshInterval)
        }
    }

    func refreshIfEnabled() async {
        if settings.isEnabled { await refresh() }
    }

    func refresh() async {
        guard settings.isEnabled, !isDemo else { return }
        await waitForRefreshes()
        // Turned off while waiting: starting a pass now would write the index back after it was cleared.
        guard settings.isEnabled else { return }
        generation += 1
        let token = generation
        let request = WorkLogRequest(now: Date(), days: Self.days, settings: settings)
        isRefreshing = true
        let task = Task { await loader(request) }
        refreshTask = task
        let result = await task.value
        if refreshTask == task { refreshTask = nil }
        isRefreshing = refreshTask != nil
        guard token == generation, settings.isEnabled else { return }
        // Someone looking at the newest day keeps looking at it after midnight, instead of at yesterday.
        let followsNewest = logs.isEmpty || selectedDay == logs.first?.day.start
        logs = result.logs
        if followsNewest, let newest = logs.first { selectedDay = newest.day.start }
        lastRefreshed = request.now
        indexSaveFailed = !result.savedIndex
        message = result.savedIndex ? nil : String(localized: "작업 일지 캐시를 저장하지 못했어요. 다음 갱신 때 다시 읽어요.")
        clampSelection()
    }

    /// Waits until no pass is running, including one another waiter started in the meantime.
    private func waitForRefreshes() async {
        while let running = refreshTask {
            _ = await running.value
            // The pass's owner may not have resumed yet to clear it; clearing here ends the loop.
            if refreshTask == running { refreshTask = nil }
        }
    }

    // MARK: Days

    var selectedLog: DailyWorkLog? { logs.first { $0.day.start == selectedDay } }
    var canGoBack: Bool { logs.contains { $0.day.start < selectedDay } }
    var canGoForward: Bool { logs.contains { $0.day.start > selectedDay } }

    func step(_ direction: Int) {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: direction, to: selectedDay),
              logs.contains(where: { $0.day.start == next }) else { return }
        selectedDay = next
    }

    func show(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        tab = .today
    }

    private func clampSelection() {
        if selectedLog == nil, let newest = logs.first { selectedDay = newest.day.start }
    }

    // MARK: Requests and copies

    /// Reads a request back from its session log. Nil when requests are hidden or the log is gone.
    func excerptReader() -> @Sendable (PromptLocation) -> String? {
        guard settings.showsPrompts else { return { _ in nil } }
        if isDemo {
            let table = demoExcerpts
            return { table[$0.path] }
        }
        return { PromptExcerpt.read($0) }
    }

    /// The requests to draw for a card, read off the main actor.
    func excerpts(_ locations: [PromptLocation]) async -> [String] {
        let read = excerptReader()
        return await Task.detached(priority: .userInitiated) { locations.compactMap(read) }.value
    }

    func formatter() -> WorkLogFormatter { WorkLogFormatter(excerpt: excerptReader()) }

    /// Every non-empty day of the week as Markdown, oldest first.
    func weekMarkdown() -> String {
        let formatter = formatter()
        return logs.reversed().filter { !$0.isEmpty }.map(formatter.markdown).joined(separator: "\n\n")
    }

    /// Receipts recorded while the project was being worked on.
    static func receipts(_ receipts: [WorkReceipt], overlapping project: ProjectDay) -> [WorkReceipt] {
        receipts.filter { receipt in
            project.intervals.contains { $0.start < receipt.endedAt && receipt.startedAt < $0.end }
        }.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: Pipeline

    /// Index → refresh both CLIs for the last `days + 1` days → titles → git → one log per day.
    nonisolated static func load(_ request: WorkLogRequest, store: LogIndexStore,
                                 claudeRoots: [URL] = WorkLogRoots.claude, codexRoots: [URL] = WorkLogRoots.codex,
                                 codexTitles: URL = WorkLogRoots.codexSessionIndex,
                                 gitRunner: (any GitRunning)? = ProcessGitRunner()) async -> WorkLogResult {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: request.now)
        guard let since = calendar.date(byAdding: .day, value: -request.days, to: today) else { return WorkLogResult(logs: []) }
        var index = await store.load()
        let loaded = index
        var partial = false
        // About four seconds of reading per source on a recent Mac; cursors carry the rest to the next pass.
        let budget: UInt64 = 400_000_000
        for (source, roots) in [(WorkLogSource.claude, claudeRoots), (.codex, codexRoots)] {
            partial = WorkLogIndexer.refresh(&index, source: source, roots: roots, since: since, maxBytes: budget).isPartial || partial
        }
        // Most passes read nothing new; skip rewriting the index then.
        var saved = true
        if index != loaded { saved = (try? await store.save(index)) != nil }
        var batch = index.batch
        batch.titles.merge(CodexSessionTitles.read(codexTitles)) { _, named in named }

        let settings = request.settings
        let builder = DailyWorkLogBuilder(excludedNames: Set(settings.excludedProjects),
                                          resolve: settings.includesGit ? WorkLogProject.repository : WorkLogProject.folder)
        let days: [DateInterval] = (0..<request.days).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        var git: [String: ProjectGit] = [:]
        if settings.includesGit, let first = days.last, let last = days.first {
            // One read for the whole week; each day keeps its own commits. Uncommitted files describe now.
            let reader = gitRunner.map { GitHistoryReader(runner: $0) }
            git = DailyWorkLogBuilder.readGit(for: Array(builder.projects(in: batch).keys),
                                              day: DateInterval(start: first.start, end: last.end), reader: reader)
        }
        let logs = days.enumerated().map { offset, day in
            let dayGit = offset == 0 ? git : git.mapValues { ProjectGit(state: $0.state, commits: $0.commits) }
            return builder.build(day: day, batch: batch, git: dayGit, isPartial: partial)
        }
        return WorkLogResult(logs: logs, isPartial: partial, savedIndex: saved)
    }

    // MARK: Demo

    /// A fictional week built through the real builder, so screenshots exercise the same code as real logs.
    static func demoLogs(now: Date, excluding excluded: Set<String> = []) -> (logs: [DailyWorkLog], excerpts: [String: String]) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var events: [WorkLogEvent] = []
        var excerpts: [String: String] = [:]
        var titles: [String: String] = [:]
        var commits: [String: [GitCommit]] = [:]
        var promptNumber = 0
        let folders = ["habit-tracker": "/Users/demo/Projects/habit-tracker",
                       "api-gateway": "/Users/demo/Projects/api-gateway",
                       "blog": "/Users/demo/Projects/blog"]

        func session(_ project: String, _ source: WorkLogSource, id: String, start: Date, minutes: [Double],
                     prompts: [(Double, String)] = [], files: [String] = [], title: String? = nil) {
            let cwd = folders[project]!
            for minute in minutes {
                events.append(WorkLogEvent(time: start.addingTimeInterval(minute * 60), source: source, sessionID: id,
                                           cwd: cwd, kind: .activity))
            }
            for (minute, text) in prompts {
                promptNumber += 1
                let path = "demo-prompt-\(promptNumber)"
                excerpts[path] = text
                events.append(WorkLogEvent(time: start.addingTimeInterval(minute * 60), source: source, sessionID: id, cwd: cwd,
                                           kind: .prompt(PromptLocation(path: path, offset: 0, length: 1, characterCount: 40))))
            }
            for (number, file) in files.enumerated() {
                events.append(WorkLogEvent(time: start.addingTimeInterval(Double(number + 1) * 60), source: source, sessionID: id,
                                           cwd: cwd, kind: .fileEdit(path: cwd + "/" + file)))
            }
            if let title { titles[id] = title }
        }
        func commit(_ project: String, _ sha: String, at time: Date, _ subject: String, _ files: [String]) {
            commits[folders[project]!, default: []].append(GitCommit(sha: sha, time: time, subject: subject, files: files))
        }

        // Today: the main project overlaps the demo receipt (the last 47 minutes).
        let main = now.addingTimeInterval(-95 * 60)
        session("habit-tracker", .claude, id: "demo-claude-1", start: main,
                minutes: Array(stride(from: 0.0, through: 92, by: 4)),
                prompts: [(0, String(localized: "주간 통계 화면에 연속 기록 일수를 추가해 줘")),
                          (40, String(localized: "알림 권한을 거부했을 때 설정으로 안내하는 문구를 넣어 줘")),
                          (70, String(localized: "통계 계산 테스트를 경계값 위주로 보강해 줘"))],
                files: ["Sources/Stats/StreakView.swift", "Sources/Stats/StreakCalculator.swift",
                        "Sources/Settings/NotificationNotice.swift", "Tests/StreakCalculatorTests.swift"],
                title: String(localized: "연속 기록 통계"))
        session("habit-tracker", .codex, id: "demo-codex-1", start: main.addingTimeInterval(30 * 60),
                minutes: Array(stride(from: 0.0, through: 24, by: 6)),
                prompts: [(0, String(localized: "위젯 타임라인이 자정에 갱신되는지 확인해 줘"))],
                files: ["Widget/TimelineProvider.swift"])
        commit("habit-tracker", "4be1c0a9d2", at: main.addingTimeInterval(38 * 60), "Show the current streak on the weekly stats",
               ["Sources/Stats/StreakView.swift", "Sources/Stats/StreakCalculator.swift"])
        commit("habit-tracker", "9f03d7e1aa", at: main.addingTimeInterval(88 * 60), "Cover streak edges in tests",
               ["Tests/StreakCalculatorTests.swift"])
        let morning = now.addingTimeInterval(-5 * 3_600)
        session("api-gateway", .codex, id: "demo-codex-2", start: morning, minutes: Array(stride(from: 0.0, through: 50, by: 5)),
                prompts: [(0, String(localized: "결제 웹훅이 실패하면 지수 백오프로 다시 시도하게 해 줘"))],
                files: ["internal/webhook/retry.go", "internal/webhook/retry_test.go", "docs/webhooks.md"],
                title: String(localized: "웹훅 재시도"))
        commit("api-gateway", "c71d2b4e08", at: morning.addingTimeInterval(48 * 60), "Retry failed payment webhooks with backoff",
               ["internal/webhook/retry.go", "internal/webhook/retry_test.go"])
        session("blog", .claude, id: "demo-claude-3", start: now.addingTimeInterval(-3 * 3_600), minutes: [0, 6, 12],
                prompts: [(0, String(localized: "지난 글 목록에 읽는 시간 표시를 넣어 줘"))],
                files: ["src/components/PostList.astro"])

        // Earlier days, lighter.
        for (offset, project, minutes, sha, subject) in [(1, "habit-tracker", 130.0, "1a2b3c4d5e", "Add weekly stats screen"),
                                                         (1, "api-gateway", 45.0, "2b3c4d5e6f", "Log webhook delivery ids"),
                                                         (2, "api-gateway", 70.0, "3c4d5e6f70", "Split rate limiter config"),
                                                         (4, "habit-tracker", 95.0, "4d5e6f7081", "Remember the last selected habit"),
                                                         (5, "blog", 30.0, "5e6f708192", "Draft release notes post")] {
            let start = calendar.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(10 * 3_600 + Double(offset) * 1_800)
            session(project, offset.isMultiple(of: 2) ? .codex : .claude, id: "demo-\(offset)-\(project)", start: start,
                    minutes: Array(stride(from: 0.0, through: minutes, by: 5)),
                    prompts: [(0, String(localized: "지난 작업에서 이어서 진행해 줘"))])
            commit(project, sha, at: start.addingTimeInterval(minutes * 60),
                   subject, ["README.md"])
        }

        let batch = WorkLogBatch(events: events.sorted { $0.time < $1.time }, titles: titles)
        let git = commits.mapValues { ProjectGit(state: .ok, commits: $0) }
        let builder = DailyWorkLogBuilder(excludedNames: excluded)
        var withChanges = git
        withChanges[folders["habit-tracker"]!]?.uncommittedFiles = ["Sources/Settings/NotificationNotice.swift", "Widget/TimelineProvider.swift"]
        let logs: [DailyWorkLog] = (0..<days).map { offset in
            let start = calendar.date(byAdding: .day, value: -offset, to: today)!
            let day = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
            return builder.build(day: day, batch: batch, git: offset == 0 ? withChanges : git)
        }
        return (logs, excerpts)
    }
}
