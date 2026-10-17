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
    private static func workLog() {
        let today = Calendar.current.startOfDay(for: Date())
        let day = DateInterval(start: today, duration: 86_400)
        var all: [WorkLogEvent] = []
        for (source, roots) in [(WorkLogSource.claude, WorkLogRoots.claude), (.codex, WorkLogRoots.codex)] {
            let started = Date()
            let (batch, stats) = WorkLogScanner.scan(source: source, roots: roots, since: today)
            all += batch.events
            var kinds: [String: Int] = [:]
            for event in batch.events { kinds[kindName(event.kind), default: 0] += 1 }
            write(["source": source.rawValue, "files": stats.files, "megabytes": Double(stats.bytes / 10_000) / 100,
                   "lines": stats.lines, "partial": stats.isPartial, "events": kinds,
                   "sessions": Set(batch.events.map(\.sessionID)).count,
                   "folders": Set(batch.events.compactMap(\.cwd)).count,
                   "activeMinutes": minutes(WorkTimeCalculator.clip(WorkTimeCalculator.intervals(for: batch.events), to: day)),
                   "elapsedSeconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
        }
        // Per folder, then the union, so parallel sessions are counted once.
        let perFolder = Dictionary(grouping: all) { $0.cwd ?? "" }.values.flatMap { WorkTimeCalculator.intervals(for: $0) }
        write(["source": "total", "activeMinutes": minutes(WorkTimeCalculator.clip(perFolder, to: day))])
    }

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
