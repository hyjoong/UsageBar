import Foundation
import UsageBarCore
import WorkLogCore

/// Read-only integration check. Never emits credentials, account identifiers, or subprocess transcripts.
@main
struct UsageBarDoctor {
    static func main() async {
        let requested = CommandLine.arguments.dropFirst().first
        if requested == "worklog" { workLog(); return }
        let providers: [any UsageProvider] = requested == "claude" ? [ClaudeProvider()]
            : requested == "codex" ? [CodexProvider()] : [ClaudeProvider(), CodexProvider()]
        for provider in providers {
            do {
                let snapshot = try await provider.fetch()
                let report: [String: Any] = [
                    "provider": provider.id.rawValue,
                    "status": "connected",
                    "windows": snapshot.windows.map { window -> [String: Any] in
                        var value: [String: Any] = ["name": window.label, "remainingPercent": window.remainingPercent]
                        if let date = window.resetsAt { value["reset"] = ISO8601DateFormatter().string(from: date) }
                        return value
                    },
                    "dailyRecordCount": snapshot.dailyUsage?.count ?? 0,
                    "resetCreditsAvailable": snapshot.resetCreditCount as Any? ?? NSNull(),
                    "accountSeparationAvailable": snapshot.accountKey != nil
                ]
                write(report)
            } catch {
                write(["provider": provider.id.rawValue, "status": "needs_attention",
                       "message": (error as? LocalizedError)?.errorDescription ?? "조회하지 못했어요."])
            }
        }
    }

    /// Today's work log from local session logs, as counts only: no prompt text, paths or project names.
    /// `--days N` indexes N days back, `--git` also reads commits (macOS may ask for folder access).
    /// Each source is indexed twice in memory: a first pass from scratch, then an incremental pass.
    private static func workLog() {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        let days = arguments.firstIndex(of: "--days").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 1
        let readGit = arguments.contains("--git")
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let since = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        let day = DateInterval(start: today, end: calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400))

        var index = LogIndex()
        for (source, roots) in [(WorkLogSource.claude, WorkLogRoots.claude), (.codex, WorkLogRoots.codex)] {
            let started = Date()
            let first = WorkLogIndexer.refresh(&index, source: source, roots: roots, since: since)
            let firstSeconds = Date().timeIntervalSince(started)
            let again = Date()
            let second = WorkLogIndexer.refresh(&index, source: source, roots: roots, since: since)
            let events = index.files.values.filter { $0.source == source }.flatMap(\.batch.events)
            var kinds: [String: Int] = [:]
            for event in events { kinds[kindName(event.kind), default: 0] += 1 }
            write(["source": source.rawValue, "days": days, "files": first.files,
                   "megabytes": Double(first.bytes / 10_000) / 100, "lines": first.lines, "partial": first.isPartial,
                   "events": kinds, "sessions": Set(events.map(\.sessionID)).count,
                   "firstPassSeconds": rounded(firstSeconds),
                   "incrementalSeconds": rounded(Date().timeIntervalSince(again)), "incrementalBytes": second.bytes])
        }

        var batch = index.batch
        batch.titles.merge(CodexSessionTitles.read()) { current, _ in current }
        let builder = DailyWorkLogBuilder(resolve: readGit ? WorkLogProject.repository : WorkLogProject.folder)
        var git: [String: ProjectGit] = [:]
        let started = Date()
        if readGit {
            let reader = ProcessGitRunner().map { GitHistoryReader(runner: $0) }
            git = DailyWorkLogBuilder.readGit(for: Array(builder.projects(in: batch).keys), day: day, reader: reader)
        }
        let log = builder.build(day: day, batch: batch, git: git)
        var states: [String: Int] = [:]
        for project in log.projects { states[project.git.state.rawValue, default: 0] += 1 }
        write(["source": "today", "projects": log.projects.count, "activeMinutes": Int((log.duration / 60).rounded()),
               "projectMinutesSum": Int((log.projects.reduce(0) { $0 + $1.duration } / 60).rounded()),
               "requests": log.projects.reduce(0) { $0 + $1.prompts.count },
               "readableRequests": log.projects.flatMap(\.prompts).compactMap { PromptExcerpt.read($0.location) }.count,
               "commits": log.commitCount, "changedFiles": log.changedFileCount,
               "pullRequests": log.projects.reduce(0) { $0 + $1.pullRequests.count },
               "gitStates": states, "buildSeconds": rounded(Date().timeIntervalSince(started)),
               "indexMegabytes": Double(((try? JSONEncoder().encode(index))?.count ?? 0) / 10_000) / 100])
    }

    private static func rounded(_ seconds: TimeInterval) -> Double { (seconds * 100).rounded() / 100 }

    private static func minutes(_ intervals: [WorkInterval]) -> Int {
        Int((WorkTimeCalculator.total(intervals) / 60).rounded())
    }

    private static func kindName(_ kind: WorkLogEventKind) -> String {
        switch kind {
        case .activity: return "activity"
        case .prompt: return "prompt"
        case .fileEdit: return "fileEdit"
        case .turn: return "turn"
        case .commit: return "commit"
        case .pullRequest: return "pullRequest"
        }
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let output = String(data: data, encoding: .utf8) else { return }
        print(output)
    }
}
