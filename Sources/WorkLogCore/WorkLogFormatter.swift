import Foundation

/// Text the person copies out of the journal: a three-line stand-up note and a Markdown day log.
public struct WorkLogFormatter {
    public var calendar: Calendar
    public var locale: Locale
    /// How a request is shown. Defaults to reading it back from the session log.
    public var excerpt: (PromptLocation) -> String?
    /// Requests per project in the Markdown log.
    public var promptsPerProject = 3

    public init(calendar: Calendar = .current, locale: Locale = .current,
                excerpt: @escaping (PromptLocation) -> String? = PromptExcerpt.read) {
        self.calendar = calendar; self.locale = locale; self.excerpt = excerpt
    }

    // MARK: Stand-up

    /// "Done", "in progress" and an empty "issues" line for the person to fill in.
    public func standUp(_ log: DailyWorkLog) -> String {
        let done = log.projects.filter { !$0.commits.isEmpty }.prefix(3).map { project -> String in
            let subjects = project.commits.suffix(2).reversed().map(\.subject).joined(separator: " · ")
            return "\(project.name) \(subjects) " + String(localized: "(커밋 \(project.commits.count))")
        }
        let ongoing = log.projects.filter { $0.commits.isEmpty }.prefix(3).map { project -> String in
            var text = project.name
            if let summary = summary(project) { text += " — " + summary }
            if !project.git.uncommittedFiles.isEmpty {
                text += " " + String(localized: "(미커밋 \(project.git.uncommittedFiles.count)파일)")
            }
            return text
        }
        return [
            String(localized: "한 일: \(done.isEmpty ? "—" : done.joined(separator: ", "))"),
            String(localized: "진행 중: \(ongoing.isEmpty ? "—" : ongoing.joined(separator: ", "))"),
            String(localized: "이슈: "),
        ].joined(separator: "\n")
    }

    // MARK: Markdown

    public func markdown(_ log: DailyWorkLog) -> String {
        var lines = [String(localized: "## \(dayTitle(log.day.start)) 작업 기록"), headline(log)]
        if log.isPartial { lines.append(String(localized: "_세션 기록 일부만 집계했습니다._")) }
        for project in log.projects {
            lines.append("")
            lines.append("### \(project.name) — \(Self.duration(project.duration))")
            let requests = project.prompts.compactMap { excerpt($0.location) }.prefix(promptsPerProject)
            if requests.isEmpty {
                for title in project.sessions.compactMap(\.title).prefix(promptsPerProject) {
                    lines.append(String(localized: "- 세션: \(title)"))
                }
            } else {
                for request in requests { lines.append(String(localized: "- 요청: \(request)")) }
            }
            for commit in project.commits {
                lines.append(String(localized: "- 커밋: `\(commit.shortSHA)` \(commit.subject)"))
            }
            if let files = fileLine(project) { lines.append("- " + files) }
            for url in project.pullRequests { lines.append("- PR: \(url)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Pieces shared with the window

    /// "총 3시간 40분 · 프로젝트 3 · 커밋 5 · 파일 23"
    public func headline(_ log: DailyWorkLog) -> String {
        var parts = [String(localized: "총 \(Self.duration(log.duration))"),
                     String(localized: "프로젝트 \(log.projects.count)")]
        if log.commitCount > 0 { parts.append(String(localized: "커밋 \(log.commitCount)")) }
        if log.changedFileCount > 0 { parts.append(String(localized: "파일 \(log.changedFileCount)")) }
        return parts.joined(separator: " · ")
    }

    /// "파일 12개 변경 (커밋 9 · 미커밋 3)", or nil when nothing changed.
    public func fileLine(_ project: ProjectDay) -> String? {
        let count = project.changedFiles.count
        guard count > 0 else { return nil }
        let base = String(localized: "파일 \(count)개 변경")
        guard project.git.state == .ok else { return base }
        return base + " " + String(localized: "(커밋 \(project.committedFiles.count) · 미커밋 \(project.git.uncommittedFiles.count))")
    }

    /// "1시간 55분", "55분", "1분 미만"
    public static func duration(_ value: TimeInterval) -> String {
        let minutes = Int((max(0, value.isFinite ? value : 0) / 60).rounded())
        if minutes == 0 { return String(localized: "1분 미만") }
        if minutes < 60 { return String(localized: "\(minutes)분") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? String(localized: "\(hours)시간") : String(localized: "\(hours)시간 \(rest)분")
    }

    /// "2026-10-17 (금)"
    public func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "yyyy-MM-dd (E)"
        return formatter.string(from: date)
    }

    /// The first request, or the first session title when requests are hidden or unreadable.
    private func summary(_ project: ProjectDay) -> String? {
        project.prompts.lazy.compactMap { self.excerpt($0.location) }.first
            ?? project.sessions.lazy.compactMap(\.title).first
    }
}
