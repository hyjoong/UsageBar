import Foundation
import XCTest
@testable import UsageBarCore

final class ClaudeLoginTests: XCTestCase {
    func testSignInURLAcceptsOnlyAnthropicHostsOverHTTPS() {
        XCTAssertEqual(ClaudeLogin.signInURL(in: "If the browser didn't open, visit: https://claude.com/oauth/authorize?x=1\n")?.host,
                       "claude.com")
        XCTAssertEqual(ClaudeLogin.signInURL(in: "visit (https://console.anthropic.com/login)")?.host, "console.anthropic.com")
        XCTAssertNil(ClaudeLogin.signInURL(in: "visit http://claude.com/oauth"))
        XCTAssertNil(ClaudeLogin.signInURL(in: "visit https://claude.com.example.net/oauth"))
        XCTAssertNil(ClaudeLogin.signInURL(in: "visit https://evilclaude.com/oauth"))
    }

    func testManualCommandQuotesTheResolvedExecutable() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let bin = base.appendingPathComponent("it's bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("claude")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        XCTAssertEqual(ClaudeLogin.manualCommand(executablePath: executable.path, environment: [:]),
                       "'" + executable.resolvingSymlinksInPath().path.replacingOccurrences(of: "'", with: "'\\''") + "' auth login")
        XCTAssertEqual(ClaudeLogin.manualCommand(executablePath: base.appendingPathComponent("missing").path, environment: [:]),
                       "claude auth login")
    }

    func testSuccessfulLoginReportsTheSignInAddressAndRunsWithoutSessionTokens() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("claude")
        try writeExecutable("""
        #!/bin/sh
        [ "$1 $2 $3" = 'auth login --claudeai' ] || exit 21
        [ "${CLAUDE_CODE_OAUTH_TOKEN+x}" = '' ] || exit 22
        [ "${CLAUDECODE+x}" = '' ] || exit 23
        printf 'Opening browser to sign in…\\nIf the browser did not open, visit: https://claude.com/oauth/authorize?code=fixture\\n'
        sleep 0.3
        exit 0
        """, to: executable)
        let reported = expectation(description: "sign-in address")
        let login = ClaudeLogin()
        let outcome = login.runProcess(executable: executable.path, directory: base,
                                       environment: ["PATH": "/usr/bin:/bin", "DISABLE_AUTOUPDATER": "1"], timeout: 10) { url in
            XCTAssertEqual(url.absoluteString, "https://claude.com/oauth/authorize?code=fixture")
            reported.fulfill()
        }
        XCTAssertEqual(outcome, .succeeded)
        wait(for: [reported], timeout: 2)
    }

    func testFailedOrAbandonedLoginIsNotSuccess() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let failing = base.appendingPathComponent("failing")
        try writeExecutable("#!/bin/sh\necho 'login failed'\nexit 1\n", to: failing)
        guard case .failed = ClaudeLogin().runProcess(executable: failing.path, directory: base, environment: [:],
                                                      timeout: 10, onSignInURL: { _ in }) else {
            return XCTFail("a non-zero exit must not count as signed in")
        }
        let waiting = base.appendingPathComponent("waiting")
        try writeExecutable("#!/bin/sh\nexec sleep 30\n", to: waiting)
        let started = Date()
        guard case .failed = ClaudeLogin().runProcess(executable: waiting.path, directory: base, environment: [:],
                                                      timeout: 0.5, onSignInURL: { _ in }) else {
            return XCTFail("a login that never finishes must time out")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancelStopsAWaitingLogin() async throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let waiting = base.appendingPathComponent("waiting")
        try writeExecutable("#!/bin/sh\nexec sleep 30\n", to: waiting)
        let login = ClaudeLogin()
        let task = Task.detached {
            login.runProcess(executable: waiting.path, directory: base, environment: [:], timeout: 30, onSignInURL: { _ in })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        login.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }

    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeLoginTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
