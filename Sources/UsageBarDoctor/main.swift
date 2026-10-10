import Foundation
import UsageBarCore

/// Read-only integration check. Never emits credentials, account identifiers, or subprocess transcripts.
@main
struct UsageBarDoctor {
    static func main() async {
        let requested = CommandLine.arguments.dropFirst().first
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

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let output = String(data: data, encoding: .utf8) else { return }
        print(output)
    }
}
