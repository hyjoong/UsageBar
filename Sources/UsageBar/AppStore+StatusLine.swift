import AppKit
import Foundation
import UsageBarCore

// MARK: Claude Code status line

extension AppStore {
    private var statusLineDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageBar", isDirectory: true)
    }
    private var statusLineFile: URL { statusLineDirectory.appendingPathComponent("statusline.txt") }
    var statusLineScript: URL { statusLineDirectory.appendingPathComponent("statusline.sh") }
    private var claudeSettingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    var statusLineCommand: String { ClaudeStatusLine.command(script: statusLineScript) }

    /// Recording state, each enabled service's leading limit, and the run-out time when one is near.
    func statusLineSegments() -> [ClaudeStatusLine.Segment] {
        var segments: [ClaudeStatusLine.Segment] = []
        if let active = workJournal.state.active {
            let elapsed = UsageFormat.compactDuration(clockNow.timeIntervalSince(active.startedAt))
            segments.append(.init(String(localized: "기록 중 \(elapsed)"), tone: .recording))
        } else if let last = Self.lastSessionSegment(receipts: workJournal.state.receipts, now: clockNow) {
            segments.append(last)
        }
        for provider in activeProviders {
            guard let window = primaryWindow(for: provider) else { continue }
            let current = freshness(for: provider) == .current
            let tone: ClaudeStatusLine.Segment.Tone = !current ? .dim : (window.remainingPercent <= 20 ? .warning : .normal)
            segments.append(.init("\(provider.title) \(Int(window.remainingPercent.rounded()))%", tone: tone))
            if let projection = projection(for: provider, window: window), case .runsOut(let at) = projection.outcome {
                segments.append(.init(String(localized: "\(UsageFormat.resetClock(at, now: clockNow)) 소진 예상"), tone: .warning))
            }
        }
        return segments
    }

    /// For 10 minutes after a session ends: "방금 작업 25분 · +3%p", so the result shows without opening the panel.
    static func lastSessionSegment(receipts: [WorkReceipt], now: Date,
                                   within: TimeInterval = 10 * 60) -> ClaudeStatusLine.Segment? {
        guard let last = receipts.max(by: { $0.endedAt < $1.endedAt }),
              (0...within).contains(now.timeIntervalSince(last.endedAt)) else { return nil }
        let duration = UsageFormat.compactDuration(last.duration)
        let result: String?
        if let row = last.rows.first {
            if let points = row.percentagePoints { result = UsageFormat.deltaLabel(points) }
            else if let estimate = row.estimatedPercentagePoints {
                result = "≈+\(estimate.formatted(.number.precision(.fractionLength(0...1))))%p"
            } else { result = nil }
        } else { result = nil }
        let output = last.activity.map(\.outputTokens).flatMap { $0 > 0 ? $0 : nil }
        let detail = result ?? output.map { String(localized: "출력 \(TokenFormat.compact($0))") }
        guard let detail else { return .init(String(localized: "방금 작업 \(duration)")) }
        return .init(String(localized: "방금 작업 \(duration) · \(detail)"))
    }

    func refreshStatusLineState() {
        guard !isDemo else { return }
        statusLineState = ClaudeStatusLine.state(settings: claudeSettingsFile)
    }

    func installStatusLine() {
        statusLineMessage = nil
        if isDemo { statusLineState = .installed; return }
        do {
            try ClaudeStatusLine.install(settings: claudeSettingsFile, script: statusLineScript, lineFile: statusLineFile)
            statusLineEnabled = true
            exportStatusLine()
        } catch ClaudeStatusLine.Failure.otherStatusLine {
            statusLineMessage = String(localized: "이미 다른 상태줄이 설정돼 있어서 바꾸지 않았어요.")
        } catch ClaudeStatusLine.Failure.invalidSettings {
            statusLineMessage = String(localized: "~/.claude/settings.json을 읽을 수 없어 바꾸지 않았어요. 파일 형식을 확인해 주세요.")
        } catch {
            statusLineMessage = String(localized: "상태줄을 설정하지 못했어요.")
        }
        refreshStatusLineState()
    }

    func removeStatusLine() {
        statusLineMessage = nil
        if isDemo { statusLineState = .notConfigured; return }
        do { try ClaudeStatusLine.uninstall(settings: claudeSettingsFile) }
        catch { statusLineMessage = String(localized: "상태줄 설정을 지우지 못했어요.") }
        statusLineEnabled = false
        try? FileManager.default.removeItem(at: statusLineFile)
        refreshStatusLineState()
    }

    /// For people who already have a status line script: keep the line file current and hand them the command.
    func copyStatusLineCommand() {
        statusLineMessage = nil
        if !isDemo {
            do {
                try FileManager.default.createDirectory(at: statusLineDirectory, withIntermediateDirectories: true)
                try ClaudeStatusLine.script(lineFile: statusLineFile).write(to: statusLineScript, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusLineScript.path)
            } catch {
                statusLineMessage = String(localized: "상태줄 스크립트를 만들지 못했어요.")
                return
            }
            statusLineEnabled = true
            exportStatusLine()
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statusLineCommand, forType: .string)
        statusLineMessage = String(localized: "명령을 복사했어요. 기존 상태줄 스크립트 끝에 붙여 넣으세요.")
    }

    /// Rewritten every minute so the script can tell a running UsageBar from a closed one by the file's age.
    func exportStatusLine() {
        guard statusLineEnabled, !isDemo, writesToDisk else { return }
        let line = ClaudeStatusLine.render(statusLineSegments())
        try? FileManager.default.createDirectory(at: statusLineDirectory, withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: statusLineFile, options: .atomic)
    }
}
