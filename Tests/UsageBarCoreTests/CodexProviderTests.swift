import Darwin
import Foundation
import XCTest
@testable import UsageBarCore

final class CodexProviderTests: XCTestCase {
    private let account: [String: Any] = ["account": ["type": "chatgpt", "planType": "pro"]]

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testMultipleScopesKeepZeroAndUseActualWindowDuration() throws {
        let limits = try json(#"""
        {
          "accountId":"synthetic-account-id",
          "rateLimits":{"primary":{"usedPercent":99},"planType":"plus"},
          "rateLimitsByLimitId":{
            "codex":{"limitName":"Codex","primary":{"usedPercent":0,"windowDurationMins":90,"resetsAt":1791500000},"secondary":null},
            "fast":{"limitName":"Fast","primary":{"usedPercent":25,"windowDurationMins":30},"secondary":{"usedPercent":50,"windowDurationMins":10080}}
          }
        }
        """#)
        let result = try CodexSnapshotParser.snapshot(account: account, limits: limits, usage: nil)
        XCTAssertEqual(result.windows.map(\.id), ["codex.primary", "fast.primary", "fast.secondary"])
        XCTAssertEqual(result.windows.map(\.label), ["Codex · 1시간 30분 한도", "Fast · 30분 한도", "Fast · 주간 한도"])
        XCTAssertEqual(result.windows[0].usedPercent, 0)
        XCTAssertEqual(result.windows[0].remainingPercent, 100)
        XCTAssertEqual(result.windows[0].resetsAt?.timeIntervalSince1970, 1_791_500_000)
        XCTAssertEqual(result.plan, "plus")
        XCTAssertEqual(result.accountKey?.count, 64)
        XCTAssertNotEqual(result.accountKey, "synthetic-account-id")
    }

    func testNullMissingAndInvalidWindowsNeverBecomeZero() throws {
        let limits = try json(#"""
        {"rateLimits":{},"rateLimitsByLimitId":{
          "one":{"primary":null,"secondary":{"windowDurationMins":300}},
          "two":{"primary":{"usedPercent":false},"secondary":{"usedPercent":-1}},
          "three":{"primary":{"usedPercent":0,"windowDurationMins":null,"resetsAt":null}}
        }}
        """#)
        let result = try CodexSnapshotParser.snapshot(account: account, limits: limits, usage: nil)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.id, "three.primary")
        XCTAssertNil(result.windows.first?.durationMinutes)
        XCTAssertNil(result.windows.first?.resetsAt)
        XCTAssertNil(result.resetCreditCount)
        XCTAssertNil(result.resetCredits)
        XCTAssertNil(result.dailyUsage)
    }

    func testResetDetailsNullEmptyAndCappedCountsRemainDistinct() throws {
        let countOnly = try CodexSnapshotParser.snapshot(account: account,
            limits: json(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":3,"credits":null}}"#), usage: nil)
        XCTAssertEqual(countOnly.resetCreditCount, 3)
        XCTAssertNil(countOnly.resetCredits)

        let empty = try CodexSnapshotParser.snapshot(account: account,
            limits: json(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#), usage: nil)
        XCTAssertEqual(empty.resetCreditCount, 0)
        XCTAssertEqual(empty.resetCredits, [])

        let capped = try CodexSnapshotParser.snapshot(account: account, limits: json(#"""
        {"rateLimits":{},"rateLimitResetCredits":{"availableCount":3,"credits":[
          {"id":"one","status":"available","title":null,"expiresAt":null},
          {"id":"two","status":"available","expiresAt":1791500000},
          {"id":"invalid","status":"available","expiresAt":-1}
        ]}}
        """#), usage: nil)
        XCTAssertEqual(capped.resetCreditCount, 3)
        XCTAssertEqual(capped.resetCredits?.count, 2)
        XCTAssertNil(capped.resetCredits?.first?.expiresAt)
        XCTAssertEqual(capped.resetCredits?.last?.expiresAt?.timeIntervalSince1970, 1_791_500_000)
    }

    func testDailyBucketsValidateDatesAndTokensWithoutInventingMissingDays() throws {
        let result = try CodexSnapshotParser.snapshot(account: account, limits: ["rateLimits": [:]], usage: json(#"""
        {"dailyUsageBuckets":[
          {"startDate":"2026-10-09","tokens":10},
          {"startDate":"2026-10-09","tokens":20},
          {"startDate":"2026-10-10","tokens":0},
          {"startDate":"2026-10-11","tokens":-1},
          {"startDate":"2026-10-12","tokens":false},
          {"startDate":"2026-10-13","tokens":1.5},
          {"startDate":"2026-02-30","tokens":5},
          {"startDate":"nonsense","tokens":100}
        ]}
        """#))
        XCTAssertEqual(result.dailyUsage, [DailyUsage(day: "2026-10-09", tokens: 20), DailyUsage(day: "2026-10-10", tokens: 0)])
    }

    func testLegacyLimitsAndUnavailableActivityAreSupported() throws {
        let result = try CodexSnapshotParser.snapshot(account: account,
            limits: json(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300}},"rateLimitsByLimitId":null}"#),
            usage: ["dailyUsageBuckets": NSNull()])
        XCTAssertEqual(result.windows.first?.label, "5시간 한도")
        XCTAssertNil(result.dailyUsage)
        XCTAssertNil(result.accountKey)
    }

    func testAPIKeyAndSignedOutAccountProduceActionableErrors() {
        XCTAssertThrowsError(try CodexSnapshotParser.accountPlan(["account": ["type": "apiKey"]])) { error in
            guard case ProviderError.unsupported = error else { return XCTFail("Expected unsupported account") }
        }
        XCTAssertThrowsError(try CodexSnapshotParser.accountPlan(["account": NSNull()])) { error in
            guard case ProviderError.authenticationRequired = error else { return XCTFail("Expected sign-in state") }
        }
    }

    func testPrivateProcessHandshakeKeepsQuotasWhenActivityMethodIsUnsupported() async throws {
        let fixture = try executable(#"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'codex-cli 0.160.1\n'; exit 0; fi
        IFS= read -r request
        case "$request" in *'"method":"initialize"'*) ;; *) exit 11 ;; esac
        printf '{"id":1,"result":{"userAgent":"fixture"}}\n'
        IFS= read -r notification
        case "$notification" in *'"method":"initialized"'*) ;; *) exit 12 ;; esac
        IFS= read -r request
        case "$request" in *'"method":"account/read"'*) ;; *) exit 13 ;; esac
        printf '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}\n'
        IFS= read -r request
        case "$request" in *'"method":"account/rateLimits/read"'*) ;; *) exit 14 ;; esac
        printf '{"method":"account/rateLimits/updated","params":{"rateLimits":{"planType":null}}}\n'
        printf '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300}}}}\n'
        IFS= read -r request
        case "$request" in *'"method":"account/usage/read"'*) ;; *) exit 15 ;; esac
        printf '{"id":4,"error":{"code":-32601,"message":"unsupported fixture method"}}\n'
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let result = try await CodexProvider(executablePath: fixture.path).fetch()
        XCTAssertEqual(result.windows.first?.usedPercent, 0)
        XCTAssertEqual(result.plan, "plus")
        XCTAssertNil(result.dailyUsage)
    }

    func testTimeoutReapsOwnedProcess() throws {
        let fixture = try executable("#!/bin/sh\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let pidFile = fixture.deletingLastPathComponent().appendingPathComponent("child.pid")
        try Data("#!/bin/sh\nprintf '%s' \"$$\" > '\(pidFile.path)'\nexec /bin/sleep 30\n".utf8).write(to: fixture)
        let child = try CodexRPC(executable: fixture, arguments: [], cancellation: CodexCancellation(),
                                 deadline: ProcessInfo.processInfo.systemUptime + 1)
        let started = Date()
        XCTAssertThrowsError(try child.initialize()) { error in
            guard case CodexTransportError.timeout = error else { return XCTFail("Expected timeout") }
        }
        child.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCancellationBeforeLaunchDoesNotStartCLI() async {
        let provider = CodexProvider(executablePath: "/does/not/exist")
        let task = Task { try await provider.fetch() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation before discovery") }
    }

    private func executable(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-codex-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("codex")
        try Data(source.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
