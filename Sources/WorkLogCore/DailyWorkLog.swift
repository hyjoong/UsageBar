import Foundation

/// What a working directory belongs to in the journal.
public struct WorkLogProject: Hashable, Sendable {
    /// Stable key: the shared git directory for a repository, otherwise the directory itself.
    public let id: String
    public let name: String
    /// Folder that edited file paths are shown relative to (the worktree or directory the session used).
    public let root: String
    public let repository: GitRepository?

    public init(id: String, name: String, root: String, repository: GitRepository?) {
        self.id = id; self.name = name; self.root = root; self.repository = repository
    }

    /// ID prefix of a Codex worktree read without git; the builder joins it to the same-named folder.
    static let codexWorktreePrefix = "codex-worktree:"

    /// A project per folder, from the path alone: nothing on disk is read, so no folder access is asked.
    /// Agent worktrees are recognized by their layout:
    /// `<repo>/.claude/worktrees/<name>` belongs to `<repo>`; `~/.codex/worktrees/<id>/<repo name>` cannot
    /// be traced to its repository without reading git, so it carries the repository's folder name and the
    /// builder joins it to a project of that name.
    public static func folder(_ cwd: String) -> WorkLogProject {
        func name(_ path: String) -> String {
            let last = URL(fileURLWithPath: path).lastPathComponent
            return last.isEmpty ? path : String(last.prefix(80))
        }
        if let marker = cwd.range(of: "/.claude/worktrees/") {
            let repo = String(cwd[..<marker.lowerBound])
            if let worktree = cwd[marker.upperBound...].split(separator: "/").first, !repo.isEmpty {
                return WorkLogProject(id: repo, name: name(repo), root: repo + "/.claude/worktrees/" + worktree, repository: nil)
            }
        }
        if let marker = cwd.range(of: "/.codex/worktrees/") {
            let parts = cwd[marker.upperBound...].split(separator: "/")
            if parts.count >= 2 {
                let root = String(cwd[..<marker.upperBound]) + parts[0] + "/" + parts[1]
                return WorkLogProject(id: codexWorktreePrefix + parts[1].lowercased(), name: String(parts[1].prefix(80)),
                                      root: root, repository: nil)
            }
        }
        return WorkLogProject(id: cwd, name: name(cwd), root: cwd, repository: nil)
    }

    /// A project per repository, so worktrees and subfolders join their repository. Falls back to the folder.
    public static func repository(_ cwd: String) -> WorkLogProject {
        guard let repository = RepositoryLocator.repository(for: cwd) else { return folder(cwd) }
        return WorkLogProject(id: repository.commonDirectory, name: repository.name, root: repository.root,
                              repository: repository)
    }
}

/// Whether a project's commits could be read.
public enum GitReadState: String, Codable, Sendable {
    /// Reading git is turned off, or the folder is not a repository.
    case off
    case ok
    /// No usable git binary on this Mac.
    case unavailable
    /// git ran but failed (permission, timeout, damaged repository).
    case failed
}

/// A repository's commits and uncommitted changes for one day.
public struct ProjectGit: Equatable, Sendable {
    public var state: GitReadState
    public var commits: [GitCommit]
    public var uncommittedFiles: [String]
    public init(state: GitReadState, commits: [GitCommit] = [], uncommittedFiles: [String] = []) {
        self.state = state; self.commits = commits; self.uncommittedFiles = uncommittedFiles
    }
}

public struct WorkLogSession: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: WorkLogSource
    public let title: String?
    public let start: Date
    public let end: Date
    public let promptCount: Int
}

public struct ProjectPrompt: Equatable, Sendable {
    public let time: Date
    public let sessionID: String
    public let location: PromptLocation
}

public struct ProjectDay: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let duration: TimeInterval
    public let intervals: [WorkInterval]
    public let sources: [WorkLogSource]
    public let sessions: [WorkLogSession]
    /// The main requests, oldest first, at most `DailyWorkLogBuilder.maxPrompts`.
    public let prompts: [ProjectPrompt]
    public let git: ProjectGit
    /// Files the agents changed, relative to the project folder.
    public let editedFiles: [String]
    public let pullRequests: [String]

    public var commits: [GitCommit] { git.commits }
    public var committedFiles: Set<String> { Set(git.commits.flatMap(\.files)) }
    /// Every file touched today: edited by an agent, committed, or still uncommitted.
    public var changedFiles: Set<String> { Set(editedFiles).union(committedFiles).union(git.uncommittedFiles) }
}

public struct DailyWorkLog: Equatable, Sendable {
    public let day: DateInterval
    public let projects: [ProjectDay]
    /// Union of every project's work, so parallel sessions count once. Can be less than the sum of projects.
    public let duration: TimeInterval
    /// Some logs were not read completely yet.
    public let isPartial: Bool

    public var commitCount: Int { projects.reduce(0) { $0 + $1.commits.count } }
    public var changedFileCount: Int { projects.reduce(0) { $0 + $1.changedFiles.count } }
    public var isEmpty: Bool { projects.isEmpty }
}

/// Builds one day's journal from indexed events and, optionally, git history. Rule based, no AI:
/// see docs/plans/0.10-work-log.md §6 (time) and §10 (which requests to show).
public struct DailyWorkLogBuilder {
    public static let maxPrompts = 10
    /// Prompts shorter than this ("ok", "계속", "ㅇㅇ") are replies, not requests.
    public static let minPromptCharacters = 12

    public var rules: WorkTimeRules
    /// Project names left out of the journal and its copies (case-insensitive).
    public var excludedNames: Set<String>
    public var resolve: (String) -> WorkLogProject
    /// Folders that hold the CLIs' own files rather than a project.
    public var toolFolders: [String]

    public static var defaultToolFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.claude", home + "/.codex"]
    }

    public init(rules: WorkTimeRules = .standard, excludedNames: Set<String> = [],
                toolFolders: [String] = DailyWorkLogBuilder.defaultToolFolders,
                resolve: @escaping (String) -> WorkLogProject = WorkLogProject.folder) {
        self.rules = rules
        self.toolFolders = toolFolders
        self.excludedNames = Set(excludedNames.map { $0.lowercased() })
        var cache: [String: WorkLogProject] = [:]
        self.resolve = { cwd in
            if let known = cache[cwd] { return known }
            let project = resolve(cwd)
            cache[cwd] = project
            return project
        }
    }

    /// Every event of `batch` grouped by project, excluded projects left out. Callers read git for these
    /// projects before `build`, so a project with only commits on a given day still appears.
    ///
    /// A session's directory is first brought back to where the session works: Claude Code's `cwd` follows
    /// `cd`, so a subfolder joins the session's top folder, and a visit to the CLIs' own folders
    /// (`toolFolders`, such as reading `~/.claude`) counts toward the session's main folder.
    public func projects(in batch: WorkLogBatch) -> [WorkLogProject: [WorkLogEvent]] {
        let directories = sessionDirectories(batch.events)
        var grouped: [WorkLogProject: [WorkLogEvent]] = [:]
        for event in batch.events {
            guard let cwd = directories[event.sessionID]?[event.cwd ?? ""] ?? directories[event.sessionID]?[""] else { continue }
            let project = resolve(cwd)
            guard !excludedNames.contains(project.name.lowercased()) else { continue }
            // Carry the normalized directory, so later steps see where the work counts, not where `cd` led.
            grouped[project, default: []].append(WorkLogEvent(time: event.time, source: event.source, sessionID: event.sessionID,
                                                              cwd: cwd, isSubagent: event.isSubagent, kind: event.kind))
        }
        return grouped
    }

    /// For each session, every directory it reported mapped to the directory its work is counted under.
    /// The key "" is the session's main directory, used for events that carry none.
    private func sessionDirectories(_ events: [WorkLogEvent]) -> [String: [String: String]] {
        var seen: [String: [String]] = [:]
        for event in events {
            guard let cwd = event.cwd else { continue }
            if !(seen[event.sessionID]?.contains(cwd) ?? false) { seen[event.sessionID, default: []].append(cwd) }
        }
        var result: [String: [String: String]] = [:]
        for (session, cwds) in seen {
            let work = cwds.filter { !isToolFolder($0) }
            var map: [String: String] = [:]
            for cwd in work {
                // The shortest of the session's own directories that contains this one.
                map[cwd] = work.filter { Self.contains($0, cwd) }.min { $0.count < $1.count } ?? cwd
            }
            let main = work.first.map { map[$0] ?? $0 }
            for cwd in cwds where isToolFolder(cwd) { map[cwd] = main ?? cwd }
            map[""] = main ?? cwds.first
            result[session] = map
        }
        return result
    }

    private func isToolFolder(_ path: String) -> Bool {
        !path.contains("/worktrees/") && toolFolders.contains { Self.contains($0, path) }
    }

    /// `parent` is `child` or one of its ancestors.
    static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    public func build(day: DateInterval, batch: WorkLogBatch, git: [String: ProjectGit] = [:],
                      isPartial: Bool = false) -> DailyWorkLog {
        var days: [ProjectDay] = []
        var merged: [String: (WorkLogProject, [WorkLogEvent])] = [:]
        // Only events near the day matter for its time; the gap on each side lets a stretch that crosses
        // midnight keep its shape before it is clipped.
        let window = DateInterval(start: day.start.addingTimeInterval(-rules.gap), end: day.end.addingTimeInterval(rules.gap))
        let grouped = projects(in: batch)
        // A Codex worktree found without git joins the folder project of the same name, if there is one.
        var byName: [String: WorkLogProject] = [:]
        for project in grouped.keys.sorted(by: { $0.id < $1.id })
        where !project.id.hasPrefix(WorkLogProject.codexWorktreePrefix) {
            byName[project.name.lowercased()] = byName[project.name.lowercased()] ?? project
        }
        for (project, events) in grouped {
            var owner = project
            if project.id.hasPrefix(WorkLogProject.codexWorktreePrefix), let named = byName[project.name.lowercased()] {
                owner = named
            }
            merged[owner.id, default: (owner, [])].1 += events.filter { Self.touches($0, window) }
        }
        for (id, value) in merged {
            if let built = projectDay(value.0, events: value.1, titles: batch.titles, day: day,
                                      git: git[id] ?? ProjectGit(state: .off)) { days.append(built) }
        }
        days.sort { lhs, rhs in
            if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
            if lhs.commits.count != rhs.commits.count { return lhs.commits.count > rhs.commits.count }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let total = WorkTimeCalculator.total(days.flatMap(\.intervals))
        return DailyWorkLog(day: day, projects: days, duration: total, isPartial: isPartial)
    }

    /// An event belongs near a range by its time, or, for a Codex turn, by any overlap of the turn.
    /// A turn that starts before midnight and ends after it still counts on the later day.
    static func touches(_ event: WorkLogEvent, _ range: DateInterval) -> Bool {
        if range.contains(event.time) { return true }
        if case .turn(let end) = event.kind { return event.time < range.end && end > range.start }
        return false
    }

    private func projectDay(_ project: WorkLogProject, events: [WorkLogEvent], titles: [String: String],
                            day: DateInterval, git: ProjectGit) -> ProjectDay? {
        let commits = git.commits.filter { day.contains($0.time) && $0.time < day.end }
        let commitMoments = commits.map { WorkLogEvent(time: $0.time, source: .git, sessionID: "git", cwd: nil, kind: .activity) }
        let intervals = WorkTimeCalculator.clip(WorkTimeCalculator.intervals(for: events + commitMoments, rules: rules), to: day)
        let today = events.filter { Self.touches($0, day) && $0.time < day.end }
        guard !today.isEmpty || !commits.isEmpty else { return nil }

        // Sessions
        var bySession: [String: [WorkLogEvent]] = [:]
        for event in today { bySession[event.sessionID, default: []].append(event) }
        let sessions = bySession.map { id, events -> WorkLogSession in
            let sorted = events.sorted { $0.time < $1.time }
            let prompts = sorted.filter { if case .prompt = $0.kind { return true } else { return false } }.count
            // Titles are written by the CLI from what the person typed, so they get the prompts' masking.
            return WorkLogSession(id: id, source: sorted[0].source, title: titles[id].map(PromptExcerpt.redact), start: sorted[0].time,
                                  end: sorted[sorted.count - 1].time, promptCount: prompts)
        }.sorted { $0.start < $1.start }

        // Requests: each session's first, the first after a pause, and the last before each commit.
        var chosen: [ProjectPrompt] = []
        var candidates: [ProjectPrompt] = []
        for (id, events) in bySession {
            var previous: Date?
            var first = true
            for event in events.sorted(by: { $0.time < $1.time }) {
                defer { previous = event.time }
                guard case .prompt(let location) = event.kind, !event.isSubagent,
                      location.characterCount >= Self.minPromptCharacters else { continue }
                let prompt = ProjectPrompt(time: event.time, sessionID: id, location: location)
                candidates.append(prompt)
                if first || previous.map({ event.time.timeIntervalSince($0) >= rules.gap }) ?? true { chosen.append(prompt) }
                first = false
            }
        }
        for commit in commits {
            if let last = candidates.filter({ $0.time <= commit.time }).max(by: { $0.time < $1.time }) { chosen.append(last) }
        }
        var seenPrompts = Set<PromptLocation>()
        let prompts = chosen.sorted { $0.time < $1.time }.filter { seenPrompts.insert($0.location).inserted }
            .prefix(Self.maxPrompts)

        // Files and pull requests
        var edited: [String] = []
        var seenFiles = Set<String>()
        var pullRequests: [String] = []
        for event in today.sorted(by: { $0.time < $1.time }) {
            switch event.kind {
            case .fileEdit(let path):
                // The session's own folder (a worktree's, when it worked in one), then the project's.
                let relative = event.cwd.flatMap { Self.relative(path, to: resolve($0).root) } ?? Self.relative(path, to: project.root)
                if let relative, seenFiles.insert(relative).inserted { edited.append(relative) }
            case .pullRequest(let raw):
                let url = PromptExcerpt.redact(raw)
                if !pullRequests.contains(url) { pullRequests.append(url) }
            default:
                break
            }
        }

        let sources = Set(today.map(\.source)).filter { $0 != .git }
        return ProjectDay(id: project.id, name: project.name, duration: WorkTimeCalculator.total(intervals),
                          intervals: intervals, sources: WorkLogSource.allCases.filter(sources.contains),
                          sessions: sessions, prompts: Array(prompts),
                          git: ProjectGit(state: git.state, commits: commits.sorted { $0.time < $1.time }.map {
                              GitCommit(sha: $0.sha, time: $0.time, subject: PromptExcerpt.redact($0.subject), files: $0.files)
                          },
                                          uncommittedFiles: git.uncommittedFiles),
                          editedFiles: edited, pullRequests: pullRequests)
    }

    /// `path` relative to `root`, or nil when it lies outside it.
    static func relative(_ path: String, to root: String) -> String? {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return nil }
        let rest = String(path.dropFirst(base.count))
        return rest.isEmpty ? nil : rest
    }

    /// Reads the day's commits for every repository among `projects`. Each repository is read once,
    /// with its configured author when `onlyMine` is set.
    public static func readGit(for projects: [WorkLogProject], day: DateInterval, reader: GitHistoryReader?,
                               onlyMine: Bool = true) -> [String: ProjectGit] {
        var result: [String: ProjectGit] = [:]
        for project in projects where result[project.id] == nil {
            guard let repository = project.repository else { continue }
            guard let reader else { result[project.id] = ProjectGit(state: .unavailable); continue }
            do {
                let author = onlyMine ? reader.authorEmail(repository) : nil
                let commits = try reader.commits(repository, in: day, author: author)
                let uncommitted = (try? reader.uncommittedFiles(repository)) ?? []
                result[project.id] = ProjectGit(state: .ok, commits: commits, uncommittedFiles: uncommitted)
            } catch GitRunError.unavailable {
                result[project.id] = ProjectGit(state: .unavailable)
            } catch {
                result[project.id] = ProjectGit(state: .failed)
            }
        }
        return result
    }
}
