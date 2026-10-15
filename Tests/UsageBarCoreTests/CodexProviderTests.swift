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

    func testDiscoverySkipsCLIWhoseNodeRuntimeIsMissingFromGUIPath() throws {
        let broken = try executable("#!/bin/sh\nexec /usr/bin/env PATH=/usr/bin:/bin:/usr/sbin:/sbin node --version\n")
        let working = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        defer {
            try? FileManager.default.removeItem(at: broken.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: working.deletingLastPathComponent())
        }
        let selected = try CodexProvider.resolveExecutable(path: nil, candidates: [broken.path, working.path],
            cancellation: CodexCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 5)
        XCTAssertEqual(selected, working.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testDiscoveryProbesRepeatedSymlinkTargetsOnlyOnce() throws {
        let broken = try executable("#!/bin/sh\nexit 127\n")
        let directory = broken.deletingLastPathComponent()
        let attempts = directory.appendingPathComponent("attempts")
        try "#!/bin/sh\nprintf 'probe\\n' >> '\(attempts.path)'\nexit 127\n".write(to: broken, atomically: false, encoding: .utf8)
        let alias = directory.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: broken)
        let working = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: working.deletingLastPathComponent())
        }
        let selected = try CodexProvider.resolveExecutable(path: nil, candidates: [broken.path, alias.path, broken.path, working.path],
            cancellation: CodexCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 5)
        XCTAssertEqual(selected, working.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: attempts), "probe\n")
    }

    func testDiscoveryPrefersNewestRunnableCLIOverEarlierOutdatedOne() throws {
        let outdated = try executable("#!/bin/sh\nprintf 'codex-cli 0.46.0\\n'\n")
        let current = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        let sameAsCurrent = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        defer {
            for url in [outdated, current, sameAsCurrent] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        let selected = try CodexProvider.resolveExecutable(path: nil, candidates: [outdated.path, current.path, sameAsCurrent.path],
            cancellation: CodexCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 15)
        XCTAssertEqual(selected, current.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(CodexProvider.versionKey("0.47.0-alpha.2"), [0, 47, 0])
        XCTAssertTrue(CodexProvider.versionKey("0.46.0").lexicographicallyPrecedes(CodexProvider.versionKey("0.160.1")))
    }

    func testExplicitExecutableFailureDoesNotSelectAnAutomaticFallback() throws {
        let broken = try executable("#!/bin/sh\nexit 127\n")
        let working = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        defer {
            try? FileManager.default.removeItem(at: broken.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: working.deletingLastPathComponent())
        }
        XCTAssertThrowsError(try CodexProvider.resolveExecutable(path: broken.path, candidates: [working.path],
            cancellation: CodexCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 5)) { error in
            guard case ProviderError.setupRequired(let message) = error else { return XCTFail("Expected explicit path guidance") }
            XCTAssertEqual(message, "Codex CLI 버전을 확인하지 못했어요. 실행 파일 경로와 설치 상태를 확인해 주세요.")
        }
    }

    func testDiscoverySkipsMalformedVersionsAndReportsWhenNoneAreRunnable() throws {
        let invalid = try executable("#!/bin/sh\nprintf 'other-tool 1.0.0\\n'\n")
        let working = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        defer {
            try? FileManager.default.removeItem(at: invalid.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: working.deletingLastPathComponent())
        }
        let selected = try CodexProvider.resolveExecutable(path: nil, candidates: [invalid.path, working.path],
            cancellation: CodexCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 5)
        XCTAssertEqual(selected, working.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertThrowsError(try CodexProvider.resolveExecutable(path: nil, candidates: [invalid.path],
            cancellation: CodexCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 5)) { error in
            guard case ProviderError.setupRequired = error else { return XCTFail("Expected invalid-version guidance") }
        }
        XCTAssertThrowsError(try CodexProvider.resolveExecutable(path: nil, candidates: [],
            cancellation: CodexCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 5)) { error in
            guard case ProviderError.setupRequired(let message) = error else { return XCTFail("Expected missing executable guidance") }
            XCTAssertEqual(message, "Codex CLI를 찾지 못했어요. Codex를 설치하거나 실행 파일 경로를 지정해 주세요.")
        }
    }

    func testTimedOutVersionProbeIsReapedBeforeWorkingFallback() throws {
        let stalled = try executable("#!/bin/sh\nexec /bin/sleep 30\n")
        let directory = stalled.deletingLastPathComponent()
        let pidFile = directory.appendingPathComponent("probe.pid")
        try "#!/bin/sh\nprintf '%s' \"$$\" > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: stalled, atomically: false, encoding: .utf8)
        let working = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: working.deletingLastPathComponent())
        }
        let started = ProcessInfo.processInfo.systemUptime
        let selected = try CodexProvider.resolveExecutable(path: nil, candidates: [stalled.path, working.path],
            cancellation: CodexCancellation(), deadline: started + 5)
        XCTAssertEqual(selected, working.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 4.5)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testDiscoveryCancellationAndExpiredDeadlineDoNotLaunchCandidates() throws {
        let working = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        defer { try? FileManager.default.removeItem(at: working.deletingLastPathComponent()) }
        let marker = working.deletingLastPathComponent().appendingPathComponent("launched")
        try "#!/bin/sh\nprintf 'launched' > '\(marker.path)'\nprintf 'codex-cli 0.160.1\\n'\n".write(to: working, atomically: false, encoding: .utf8)
        let cancellation = CodexCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try CodexProvider.resolveExecutable(path: nil, candidates: [working.path],
            cancellation: cancellation, deadline: ProcessInfo.processInfo.systemUptime + 5)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try CodexProvider.resolveExecutable(path: nil, candidates: [working.path],
            cancellation: CodexCancellation(), deadline: ProcessInfo.processInfo.systemUptime - 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDiscoverySharesDeadlineAcrossStalledCandidates() throws {
        let first = try executable("#!/bin/sh\nexec /bin/sleep 30\n")
        let second = try executable("#!/bin/sh\nexec /bin/sleep 30\n")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CodexProvider.resolveExecutable(path: nil, candidates: [first.path, second.path],
            cancellation: CodexCancellation(), deadline: started + 0.15))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

    func testCancellationDuringVersionProbeStopsDiscoveryAndReapsChild() throws {
        let stalled = try executable("#!/bin/sh\nexec /bin/sleep 30\n")
        let directory = stalled.deletingLastPathComponent()
        let pidFile = directory.appendingPathComponent("probe.pid")
        try "#!/bin/sh\nprintf '%s' \"$$\" > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: stalled, atomically: false, encoding: .utf8)
        let working = try executable("#!/bin/sh\nprintf 'codex-cli 0.160.1\\n'\n")
        let fallbackMarker = working.deletingLastPathComponent().appendingPathComponent("launched")
        try "#!/bin/sh\nprintf 'launched' > '\(fallbackMarker.path)'\nprintf 'codex-cli 0.160.1\\n'\n".write(to: working, atomically: false, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: working.deletingLastPathComponent())
        }
        let cancellation = CodexCancellation()
        DispatchQueue.global().async {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !FileManager.default.fileExists(atPath: pidFile.path), ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            cancellation.cancel()
        }
        XCTAssertThrowsError(try CodexProvider.resolveExecutable(path: nil, candidates: [stalled.path, working.path],
            cancellation: cancellation, deadline: ProcessInfo.processInfo.systemUptime + 5)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackMarker.path))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
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
