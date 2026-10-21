import AppKit
import Foundation
import SwiftUI
import UsageBarCore

extension ProviderID {
    var tint: Color { UsageTheme.accent }
    var symbol: String { self == .claude ? "asterisk.circle.fill" : "terminal.fill" }
    var statusURL: URL { URL(string: self == .claude ? "https://status.claude.com" : "https://status.openai.com")! }
    var dashboardURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
    var installURL: URL {
        URL(string: self == .claude ? "https://code.claude.com/docs/en/quickstart" : "https://github.com/openai/codex")!
    }
}

/// Human-readable labels shared by the panel, instrument, and windows.
enum UsageFormat {
    static func freshness(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return String(localized: "방금 확인") }
        if minutes < 60 { return String(localized: "\(minutes)분 전 기록") }
        return String(localized: "\(minutes / 60)시간 전 기록")
    }

    static func relativeDate(_ date: Date, now: Date, expiry: Bool) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return expiry ? String(localized: "만료 시각 경과") : String(localized: "리셋 시각 지남 · 확인 필요") }
        let minutes = max(1, seconds / 60)
        if minutes >= 1440 { return String(localized: "\(minutes / 1440)일 \((minutes % 1440) / 60)시간 후") }
        if minutes >= 60 { return String(localized: "\(minutes / 60)시간 \(minutes % 60)분 후") }
        return String(localized: "\(minutes)분 후")
    }

    static func tokenLabel(_ number: Int64) -> String { TokenFormat.compact(number) }

    /// "claude-fable-5-1 · 호출 42 · 출력 48K · 입력 1.2M" with an optional "+1" for further models.
    static func activityLine(_ model: ModelActivity, extraModels: Int) -> String {
        var line = String(localized: "\(model.model) · 호출 \(model.calls) · 출력 \(TokenFormat.compact(model.outputTokens)) · 입력 \(TokenFormat.compact(model.inputTokens))")
        if extraModels > 0 { line += " +\(extraModels)" }
        return line
    }

    /// Short enough for the menu bar and the Claude Code status line: minutes under an hour, whole hours after.
    static func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return minutes < 60 ? String(localized: "\(minutes)분") : String(localized: "\(minutes / 60)시간")
    }

    static func durationLabel(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return String(localized: "시간 확인 불가") }
        let minutes = Int(min(max(0, interval / 60), Double(Int.max / 2)))
        if minutes == 0 { return String(localized: "1분 미만") }
        if minutes < 60 { return String(localized: "\(minutes)분") }
        return minutes % 60 == 0 ? String(localized: "\(minutes / 60)시간") : String(localized: "\(minutes / 60)시간 \(minutes % 60)분")
    }

    static func deltaLabel(_ value: Double?) -> String {
        guard let value, value.isFinite else { return String(localized: "비교 불가") }
        if value == 0 { return String(localized: "변화 없음") }
        return "+\(value.formatted(.number.precision(.fractionLength(0...2))))%p"
    }

    /// "5시간 한도 +6%p · 주간 한도 +1%p" for the first `limit` rows of a receipt.
    static func receiptSummary(_ rows: [WorkQuotaDelta], limit: Int = .max) -> String {
        guard !rows.isEmpty else { return String(localized: "한도 비교 없이 시간만 기록했어요") }
        return rows.prefix(limit).map { row in
            if row.percentagePoints == nil, let estimate = row.estimatedPercentagePoints {
                return "\(row.label) ≈+\(estimate.formatted(.number.precision(.fractionLength(0...1))))%p"
            }
            return "\(row.label) \(deltaLabel(row.percentagePoints))"
        }.joined(separator: " · ")
    }

    static func creditStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "available": return String(localized: "사용 가능")
        case "used", "consumed", "redeemed": return String(localized: "사용 완료")
        case "expired": return String(localized: "만료")
        default: return String(localized: "상태 확인 필요")
        }
    }

    static let resetDateTime = Date.FormatStyle.dateTime.month().day().hour().minute()

    /// Clock time alone when the date is today; otherwise month, day, and time.
    static func resetClock(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(resetDateTime)
    }
}

/// Opens the bundled Claude connection script in Terminal and reports a user-facing failure message.
enum ClaudeSetupLauncher {
    /// Opens setup and, once Terminal is up, rechecks Claude until it connects. Returns a failure message.
    @MainActor static func open(watching store: AppStore) async -> String? {
        let message = await open()
        if message == nil { store.watchClaudeConnection() }
        return message
    }

    @MainActor static func open() async -> String? {
        do {
            guard let script = Bundle.main.url(forResource: "setup-claude", withExtension: "command") else {
                return String(localized: "build 폴더의 UsageBar.app에서 연결 설정을 열어 주세요.")
            }
            let launcher = try ClaudeProvider.prepareConnectionTerminalProfile(scriptURL: script)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                return String(localized: "터미널을 열지 못했어요. 연결 설정 파일을 다시 열어 주세요.")
            }
            do {
                _ = try await NSWorkspace.shared.open([launcher], withApplicationAt: terminal,
                                                      configuration: NSWorkspace.OpenConfiguration())
                return nil
            } catch {
                return String(localized: "터미널을 열지 못했어요. 연결 설정 파일을 다시 열어 주세요.")
            }
        } catch { return error.localizedDescription }
    }
}
