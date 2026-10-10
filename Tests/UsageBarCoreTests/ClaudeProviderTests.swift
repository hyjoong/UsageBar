import XCTest
@testable import UsageBarCore

final class ClaudeProviderTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-10T08:00:00Z")!
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    func testSubscriptionWindowsPreserveZeroAndOptionalModels() throws {
        let result = try windows("""
        /usage
        Current session
        ▏ 0% used
        Resets 10pm (Asia/Seoul)

        Current week (all models)
        █████ 72% used
        Resets Oct 13 at 10pm (Asia/Seoul)

        Current week (Sonnet only)
        ██ 21.5% used
        Resets Tue 10pm (Asia/Seoul)
        Extra usage
        35% used
        """)
        XCTAssertEqual(result.map(\.id), ["session", "weekly", "weekly-sonnet-only"])
        XCTAssertEqual(result.map(\.usedPercent), [0, 72, 21.5])
        XCTAssertEqual(result.map(\.durationMinutes), [300, 10080, 10080])
        XCTAssertEqual(result[0].remainingPercent, 100)
        XCTAssertEqual(result[0].resetsAt, date("2026-10-10T13:00:00Z"))
        XCTAssertEqual(result[1].resetsAt, date("2026-10-13T13:00:00Z"))
    }

    func testRemainingPercentIsNotTreatedAsUsedPercent() throws {
        for wording in ["left", "remaining", "available"] {
            let result = try windows("Current session\n80% \(wording)")
            XCTAssertEqual(result[0].usedPercent, 20)
        }
        XCTAssertEqual(try windows("Current session\n100% left")[0].usedPercent, 0)
    }

    func testMissingOrInvalidPercentDoesNotBecomeZero() {
        for text in ["Current session\nResets 10pm", "Current session\n0%", "Current session\n-1% used",
                     "Current session\n101% used", "Current session\n+4% used", "Current session\nNaN% used"] {
            assertPending(text)
        }
    }

    func testLoadingOverlayDoesNotReturnAnOldQuota() {
        assertPending("Current session\n63% used\nLoading usage data…")
        assertPending("Current session\n63% used\nLoading...")
        assertPending("Fetching usage…")
    }

    func testWeeklyOnlyIsValidAndNoSessionIsInvented() throws {
        let result = try windows("Current week (all models)\n0% used")
        XCTAssertEqual(result.map(\.id), ["weekly"])
    }

    func testInsightsAndExtraUsageAreNotSubscriptionWindows() throws {
        let result = try windows("""
        Current session
        42% used
        What's contributing to your limits usage?
        Current week (all models)
        90% used
        """)
        XCTAssertEqual(result.count, 1)
        assertPending("Extra usage\n15% used\nSpent this month: $20")
    }

    func testLastCompleteHeadingWins() throws {
        let result = try windows("Current session\n12% used\nCurrent session\n13% used")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].usedPercent, 13)
    }

    func testUnknownResetIsNilButShortResetDescriptionIsRetained() throws {
        let result = try windows("Current session\n4% used\nResets tomorrow afternoon")
        XCTAssertNil(result[0].resetsAt)
        XCTAssertEqual(result[0].resetDescription, "Resets tomorrow afternoon")
        let privateText = try windows("Current session\n4% used\nResets email@example.com")
        XCTAssertNil(privateText[0].resetDescription)
    }

    func testTrustAndLoginErrorsExposeOnlyStaticMessages() {
        let fixtures = ["Do you trust the files in this folder?", "Select a text style", "Please run /login",
                        "Invalid OAuth token", "Keychain permission denied", "Failed to load usage data"]
        for text in fixtures {
            guard case .failure(let error) = ClaudeUsageParser.inspect(text + "\nprivate@example.com secret-value", now: now, timeZone: seoul) else {
                XCTFail("Expected actionable error for \(text)"); continue
            }
            XCTAssertFalse(error.localizedDescription.contains("private@example.com"))
            XCTAssertFalse(error.localizedDescription.contains("secret-value"))
        }
    }

    func testStartupPromptsHaveDistinctActionableCategories() {
        let fixtures: [(String, ClaudeStartupPrompt)] = [
            ("Do you trust the files in this folder?", .folderTrust),
            ("Quick safety check: Is this a project you created or one you trust?", .folderTrust),
            ("Choose the text style that looks best with your terminal", .terminalStyle),
            ("Select a theme", .terminalStyle),
            ("Do you accept the updated terms?", .termsAcceptance)
        ]
        for (text, category) in fixtures {
            XCTAssertEqual(ClaudeStartupPrompt.detect(in: text), category)
            guard case .failure(.setupRequired(let message)) = ClaudeUsageParser.inspect(text) else {
                XCTFail("Expected categorized setup state"); continue
            }
            XCTAssertEqual(message, category.message)
        }
        XCTAssertNil(ClaudeStartupPrompt.detect(in: "Welcome to Claude Code"))
        XCTAssertNil(ClaudeStartupPrompt.detect(in: "Terms of Service · Privacy Policy"))
        XCTAssertNotEqual(ClaudeStartupPrompt.folderTrust.message, ClaudeStartupPrompt.terminalStyle.message)
        XCTAssertNotEqual(ClaudeStartupPrompt.terminalStyle.message, ClaudeStartupPrompt.termsAcceptance.message)
    }

    func testRateLimitIsDistinctFromAuthenticationFailure() {
        guard case .failure(.rateLimited(let retry)) = ClaudeUsageParser.inspect("HTTP 429: Too many requests") else {
            return XCTFail("Expected rate limit")
        }
        XCTAssertEqual(retry, 300)
    }

    func testRelativeAndISOResetDates() {
        XCTAssertEqual(reset("Resets in 2h 30m"), now.addingTimeInterval(9000))
        XCTAssertEqual(reset("Resets in 1 hour, 15 minutes"), now.addingTimeInterval(4500))
        XCTAssertEqual(reset("Resets in 0m"), now)
        XCTAssertEqual(reset("Resets 2026-10-10T10:30:00.000Z"), date("2026-10-10T10:30:00Z"))
        XCTAssertNil(reset("Resets in 2h probably"))
        XCTAssertNil(reset("Resets in 6h"))
    }

    func testResetTimeZonesAndYearBoundary() {
        XCTAssertEqual(reset("Resets 9pm (Asia/Seoul)"), date("2026-10-10T12:00:00Z"))
        XCTAssertEqual(reset("Resets 1pm (UTC)"), date("2026-10-10T13:00:00Z"))
        XCTAssertNil(reset("Resets 9pm (Not/AZone)"))
        let newYear = ClaudeResetDate.parse("Resets Jan 1 at 2am (UTC)", now: date("2026-12-31T22:00:00Z"), timeZone: seoul, windowMinutes: 10080)
        XCTAssertEqual(newYear, date("2027-01-01T02:00:00Z"))
    }

    func testMalformedResetDatesAreNeverGuessed() {
        for value in ["Resets 25:00", "Resets 13pm", "Resets 10:90pm", "Resets Octopus 10 at 10pm",
                      "Resets Oct 32 at 10pm", "Resets Feb 30 at 10pm", "Resets 2020-01-01T00:00:00Z", "Resets soon"] {
            XCTAssertNil(reset(value), value)
        }
    }

    func testScreenReplayKeepsOnlyTheLatestFrame() throws {
        let text = "Current session\r\n98% used\r\nResets 8pm\u{1B}[2J\u{1B}[HLoading usage…\u{1B}[2J\u{1B}[HCurrent session\r\n0% used\r\nResets 10pm"
        let screen = ClaudeTerminalScreen.render(text)
        XCTAssertFalse(screen.contains("98%"))
        XCTAssertFalse(screen.contains("Loading"))
        XCTAssertEqual(try windows(screen)[0].usedPercent, 0)
    }

    func testANSIColorsCursorRewriteAndOSCDoNotLeakIntoValues() throws {
        let text = "\u{1B}]0;private@example.com\u{07}\u{1B}[32mCurrent session\u{1B}[0m\r\n89% used\r\u{1B}[2K\u{1B}[33m7% used\u{1B}[0m"
        let screen = ClaudeTerminalScreen.render(text)
        XCTAssertFalse(screen.contains("private@example.com"))
        XCTAssertFalse(screen.contains("89%"))
        XCTAssertEqual(try windows(screen)[0].usedPercent, 7)
    }

    func testCursorUpAndEraseUpdateExistingRows() throws {
        let text = "Current session\r\n82% used\r\nResets 9pm\u{1B}[1A\r\u{1B}[2K3% used"
        XCTAssertEqual(try windows(ClaudeTerminalScreen.render(text))[0].usedPercent, 3)
    }

    func testExecutableResolutionNeverUsesRelativePATHEntries() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        XCTAssertEqual(ClaudeProvider.resolveExecutable(preferred: nil, environment: ["PATH": directory.path], home: directory, knownPaths: []), executable.resolvingSymlinksInPath().path)
        XCTAssertNil(ClaudeProvider.resolveExecutable(preferred: directory.appendingPathComponent("absent").path, environment: ["PATH": directory.path], home: directory))
    }

    func testKnownExecutablePrecedesPATHAndResolvesSymlink() throws {
        let base = try fixtureDirectory(root: connectionFixtureRoot)
        defer { try? FileManager.default.removeItem(at: base) }
        let preferred = base.appendingPathComponent("known ' CLI")
        let fallback = base.appendingPathComponent("claude")
        let link = base.appendingPathComponent("known-link")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: preferred)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: fallback)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: preferred)
        XCTAssertEqual(ClaudeProvider.resolveExecutable(preferred: nil, environment: ["PATH": base.path],
            home: base, knownPaths: [link.path]), preferred.path)
        XCTAssertNil(ClaudeProvider.resolveExecutable(preferred: base.path, environment: [:], knownPaths: []))
        XCTAssertNil(ClaudeProvider.resolveExecutable(preferred: "relative/claude", environment: [:], knownPaths: []))
        XCTAssertNil(ClaudeProvider.resolveExecutable(preferred: nil, environment: ["PATH": ".:relative:"],
            home: base, knownPaths: []))
    }

    func testConnectionLauncherQuotesPathsAndExecutesOnlyFixtureCLI() throws {
        let base = try fixtureDirectory(root: connectionFixtureRoot)
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("CLI ' $(touch INJECTED)")
        try writeExecutable("""
        #!/bin/sh
        [ "$1" = "--safe-mode" ] || exit 31
        [ "${CLAUDE_CODE_OAUTH_TOKEN+x}" = "" ] || exit 32
        for arg do last="$arg"; done
        [ "$last" = "/usage" ] || exit 33
        printf 'fixture-selected'
        """, to: executable)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/setup-claude.command")
        let script = base.appendingPathComponent("setup ' quoted.command")
        try FileManager.default.copyItem(at: source, to: script)
        let directory = base.appendingPathComponent("Library/Application Support/UsageBar/ClaudeConnection")
        let launcher = try ClaudeProvider.prepareConnectionScript(scriptURL: script, directory: directory,
            environment: [:], home: base, knownPaths: [executable.path])
        let attributes = try FileManager.default.attributesOfItem(atPath: launcher.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [launcher.path]
        process.environment = ["HOME": base.path, "PATH": "/usr/bin:/bin", "CLAUDE_CODE_OAUTH_TOKEN": "fixture-only"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("fixture-selected"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("INJECTED").path))
        XCTAssertFalse(try String(contentsOf: launcher).contains("fixture-only"))
    }

    func testConnectionLauncherRejectsExistingSymlink() throws {
        let base = try fixtureDirectory(root: connectionFixtureRoot)
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("cli")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        let directory = try ClaudeProvider.prepareConnectionDirectory(at: base.appendingPathComponent("connection"))
        let launcher = directory.appendingPathComponent("ConnectClaude.command")
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: executable)
        XCTAssertThrowsError(try ClaudeProvider.prepareConnectionScript(scriptURL: executable, directory: directory,
            environment: [:], home: base, knownPaths: [executable.path]))
        XCTAssertEqual(try String(contentsOf: executable), "#!/bin/sh\nexit 0\n")
    }

    func testConnectionLauncherMissingCLIGivesInstallationGuidance() throws {
        let base = try fixtureDirectory(root: connectionFixtureRoot)
        defer { try? FileManager.default.removeItem(at: base) }
        let script = base.appendingPathComponent("setup.command")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: script)
        XCTAssertThrowsError(try ClaudeProvider.prepareConnectionScript(scriptURL: script,
            directory: base.appendingPathComponent("connection"), environment: [:], home: base, knownPaths: [])) { error in
            guard case ProviderError.setupRequired(let message) = error else {
                return XCTFail("Expected installation guidance")
            }
            XCTAssertEqual(message, "Claude Code가 필요해요. 설치 후 터미널에서 로그인해 주세요.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("connection").path))
    }

    func testConnectionDirectoryCreationIsPrivateAndRepeatable() throws {
        let base = try fixtureDirectory(root: connectionFixtureRoot)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("Application Support/UsageBar/ClaudeConnection", isDirectory: true)
        XCTAssertEqual(try ClaudeProvider.prepareConnectionDirectory(at: directory).path, directory.path)
        XCTAssertEqual(try ClaudeProvider.prepareConnectionDirectory(at: directory).path, directory.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testConnectionDirectoryRejectsSymbolicLinks() throws {
        let base = try fixtureDirectory(root: connectionFixtureRoot)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ClaudeProvider.prepareConnectionDirectory(at: link))
        XCTAssertThrowsError(try ClaudeProvider.prepareConnectionDirectory(at: link.appendingPathComponent("ClaudeConnection", isDirectory: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("ClaudeConnection").path))
    }

    func testAuthMetadataHashesIdentityAndNeverReturnsEmail() throws {
        let first = try XCTUnwrap(ClaudeAuthMetadata.parse(Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"first@example.com","orgId":"org-1","subscriptionType":"max"}"#.utf8)))
        let second = try XCTUnwrap(ClaudeAuthMetadata.parse(Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"second@example.com","orgId":"org-1","subscriptionType":"max"}"#.utf8)))
        XCTAssertEqual(first.accountKey?.count, 64)
        XCTAssertNotEqual(first.accountKey, second.accountKey)
        XCTAssertFalse(first.accountKey?.contains("example") ?? true)
        XCTAssertEqual(first.plan, "Max")
        XCTAssertNil(ClaudeAuthMetadata.parse(Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8)))
        XCTAssertNil(ClaudeAuthMetadata.parse(Data(#"{"loggedIn":true,"authMethod":"api_key","email":"first@example.com"}"#.utf8)))
        XCTAssertNil(ClaudeAuthMetadata.parse(Data("not JSON".utf8)))
    }

    func testOfficialAuthStatusReadsOnlyMetadata() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        try writeExecutable("""
        #!/bin/sh
        [ "$1" = "auth" ] && [ "$2" = "status" ] && [ "$3" = "--json" ] || exit 12
        printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","email":"fixture@example.com","subscriptionType":"pro"}'
        """, to: executable)
        let result = try ClaudePTYCapture().authMetadata(executable: executable.path, directory: directory, environment: [:])
        XCTAssertEqual(result?.plan, "Pro")
        XCTAssertEqual(result?.accountKey?.count, 64)
    }

    func testPTYCapturesOnlyBuiltInUsageWithSafeArguments() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        try writeExecutable("""
        #!/bin/sh
        [ "$1" = "--safe-mode" ] || exit 11
        [ "$2" = "--ax-screen-reader" ] || exit 12
        [ "$3" = "--tools" ] && [ "$4" = "" ] || exit 13
        for arg do last="$arg"; done
        [ "$last" = "/usage" ] || exit 14
        printf 'Current session\n0%% used\nResets in 2h\nCurrent week (all models)\n51%% used\n'
        """, to: executable)
        let result = try ClaudePTYCapture().run(executable: executable.path, directory: directory, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(result.map(\.usedPercent), [0, 51])
    }

    func testPTYStopsAtTrustPromptWithoutResponding() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        try writeExecutable("#!/bin/sh\nprintf 'Do you trust the files in this folder?\\n'\nwhile IFS= read -r line; do :; done\n", to: executable)
        XCTAssertThrowsError(try ClaudePTYCapture().run(executable: executable.path, directory: directory, environment: [:], timeout: 1)) { error in
            guard case ProviderError.setupRequired = error else { return XCTFail("Expected trust setup state") }
        }
    }

    func testPTYTimeoutAndCancellationAreBounded() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        try writeExecutable("#!/bin/sh\nwhile IFS= read -r line; do :; done\n", to: executable)
        let started = Date()
        XCTAssertThrowsError(try ClaudePTYCapture().run(executable: executable.path, directory: directory, environment: [:], timeout: 0.15))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let capture = ClaudePTYCapture()
        let task = Task.detached { try capture.run(executable: executable.path, directory: directory, environment: [:]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        capture.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    private func windows(_ text: String) throws -> [UsageWindow] {
        guard case .usage(let result) = ClaudeUsageParser.inspect(text, now: now, timeZone: seoul) else {
            throw NSError(domain: "ClaudeFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture did not contain a completed quota"])
        }
        return result
    }

    private func assertPending(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .pending = ClaudeUsageParser.inspect(text, now: now, timeZone: seoul) else {
            return XCTFail("Expected pending data", file: file, line: line)
        }
    }

    private func reset(_ value: String) -> Date? {
        ClaudeResetDate.parse(value, now: now, timeZone: seoul, windowMinutes: 300)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    // macOS canonicalizes existing /private/tmp and /private/var URLs back to
    // their symlink aliases. Use this real workspace for no-symlink fixtures.
    private var connectionFixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build", isDirectory: true)
    }

    private func fixtureDirectory(root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appendingPathComponent("UsageBar-ClaudeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
