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
}

/// Human-readable labels shared by the panel, instrument, and windows.
enum UsageFormat {
    static func freshness(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "방금 확인" }
        if minutes < 60 { return "\(minutes)분 전 기록" }
        return "\(minutes / 60)시간 전 기록"
    }

    static func relativeDate(_ date: Date, now: Date, expiry: Bool) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return expiry ? "만료 시각 경과" : "리셋 시각 지남 · 확인 필요" }
        let minutes = max(1, seconds / 60)
        if minutes >= 1440 { return "\(minutes / 1440)일 \((minutes % 1440) / 60)시간 후" }
        if minutes >= 60 { return "\(minutes / 60)시간 \(minutes % 60)분 후" }
        return "\(minutes)분 후"
    }

    static func tokenLabel(_ number: Int64) -> String {
        if number >= 1_000_000 { return String(format: "%.1fM", Double(number) / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", Double(number) / 1_000) }
        return String(number)
    }

    static func durationLabel(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "시간 확인 불가" }
        let minutes = Int(min(max(0, interval / 60), Double(Int.max / 2)))
        if minutes == 0 { return "1분 미만" }
        if minutes < 60 { return "\(minutes)분" }
        return minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes / 60)시간 \(minutes % 60)분"
    }

    static func deltaLabel(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "비교 불가" }
        if value == 0 { return "변화 없음" }
        return "+\(value.formatted(.number.precision(.fractionLength(0...2))))%p"
    }

    /// "5시간 한도 +6%p · 주간 한도 +1%p" for the first `limit` rows of a receipt.
    static func receiptSummary(_ rows: [WorkQuotaDelta], limit: Int = .max) -> String {
        guard !rows.isEmpty else { return "한도 비교 없이 시간만 기록했어요" }
        return rows.prefix(limit).map { "\($0.label) \(deltaLabel($0.percentagePoints))" }.joined(separator: " · ")
    }

    static func creditStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "available": return "사용 가능"
        case "used", "consumed", "redeemed": return "사용 완료"
        case "expired": return "만료"
        default: return "상태 확인 필요"
        }
    }

    static let koreanDateTime = Date.FormatStyle.dateTime.locale(Locale(identifier: "ko_KR")).month().day().hour().minute()

    /// Clock time alone when the date is today; otherwise month, day, and time.
    static func resetClock(_ date: Date, now: Date) -> String {
        let locale = Locale(identifier: "ko_KR")
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.locale(locale).hour().minute())
        }
        return date.formatted(.dateTime.locale(locale).month().day().hour().minute())
    }
}

/// Opens the bundled Claude connection script in Terminal and reports a user-facing failure message.
enum ClaudeSetupLauncher {
    @MainActor static func open() -> String? {
        do {
            guard let script = Bundle.main.url(forResource: "setup-claude", withExtension: "command") else {
                return "build 폴더의 UsageBar.app에서 연결 설정을 열어 주세요."
            }
            let launcher = try ClaudeProvider.prepareConnectionScript(scriptURL: script)
            return NSWorkspace.shared.open(launcher) ? nil : "터미널을 열지 못했어요. 연결 설정 파일을 다시 열어 주세요."
        } catch { return error.localizedDescription }
    }
}
