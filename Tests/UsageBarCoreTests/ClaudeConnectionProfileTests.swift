import Foundation
import XCTest
@testable import UsageBarCore

final class ClaudeConnectionProfileTests: XCTestCase {
    func testTerminalProfileUsesDirectCleanShellAndPrivateFiles() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("fixture-cli")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        let directory = base.appendingPathComponent("Application Support/UsageBar/ClaudeConnection")
        let secret = "fixture-credential-that-must-not-be-serialized"
        let profile = try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: setupScript, directory: directory,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": secret, "CLAUDECODE": "fixture-nested-session"],
            home: base, systemPaths: [executable.path])

        XCTAssertEqual(profile, directory.appendingPathComponent("ConnectClaude.terminal"))
        let settings = try profileSettings(profile)
        XCTAssertEqual(settings["type"] as? String, "Window Settings")
        XCTAssertEqual((settings["ProfileCurrentVersion"] as? NSNumber)?.doubleValue, 2.07)
        XCTAssertEqual(settings["name"] as? String, "UsageBar Claude Connection")
        XCTAssertEqual(settings["RunCommandAsShell"] as? Bool, false)
        let command = try XCTUnwrap(settings["CommandString"] as? String)
        let launcher = directory.appendingPathComponent("ConnectClaude.command")
        XCTAssertEqual(command, shellCommand(["/bin/zsh", "-f", launcher.path]))
        let helper = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertTrue(helper.contains(shellCommand(["/bin/zsh", "-f", setupScript.path,
                                                    "--claude-executable", executable.path])))
        XCTAssertFalse(helper.contains(secret))
        XCTAssertFalse(helper.contains("fixture-nested-session"))
        let serializedProfile = try String(contentsOf: profile, encoding: .utf8)
        XCTAssertFalse(serializedProfile.contains(secret))
        XCTAssertFalse(serializedProfile.contains("fixture-nested-session"))
        XCTAssertEqual(try permissions(profile), 0o600)
        XCTAssertEqual(try permissions(launcher), 0o700)
        XCTAssertEqual(try permissions(directory), 0o700)
    }

    func testProfileCommandBypassesStartupFilesAndQuotesEveryPathWhileRetainingSafetyOptions() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home ' $(touch INJECTED_HOME)")
        let zshConfiguration = base.appendingPathComponent("zsh configuration")
        for directory in [home, zshConfiguration] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for filename in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                try "print -u2 'UNEXPECTED_STARTUP_FILE'; exit 91\n"
                    .write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            }
        }
        let executable = base.appendingPathComponent("CLI ' $(touch INJECTED_CLI)")
        try writeExecutable("""
        #!/bin/sh
        [ "$#" -eq 9 ] || exit 31
        [ "$1" = '--safe-mode' ] || exit 32
        [ "$2" = '--ax-screen-reader' ] || exit 33
        [ "$3" = '--tools' ] && [ "$4" = '' ] || exit 34
        [ "$5" = '--strict-mcp-config' ] || exit 35
        [ "$6" = '--no-chrome' ] || exit 36
        [ "$7" = '--settings' ] || exit 37
        [ "$8" = '{"disableAllHooks":true,"remoteControlAtStartup":false}' ] || exit 38
        [ "$9" = '/usage' ] || exit 39
        [ "${CLAUDE_CODE_OAUTH_TOKEN+x}" = '' ] || exit 40
        [ "${CLAUDECODE+x}" = '' ] || exit 41
        [ "$DISABLE_AUTOUPDATER" = '1' ] || exit 42
        [ "$PWD" = "$HOME/Library/Application Support/UsageBar/ClaudeConnection" ] || exit 43
        printf 'fixture-cli-selected\n'
        """, to: executable)
        let source = base.appendingPathComponent("setup ' $(touch INJECTED_SOURCE).command")
        try FileManager.default.copyItem(at: setupScript, to: source)
        let directory = base.appendingPathComponent("profile ' $(touch INJECTED_PROFILE)")
        let profile = try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: source, directory: directory, environment: [:], home: home,
            systemPaths: [executable.path])
        let command = try XCTUnwrap(profileSettings(profile)["CommandString"] as? String)

        // Parse Terminal's command without invoking a login/interactive shell first.
        // Both the helper and the bundle setup script must also retain zsh -f.
        let result = try runCommand(command, at: base, environment: [
            "HOME": home.path, "ZDOTDIR": zshConfiguration.path, "PATH": "/usr/bin:/bin",
            "CLAUDE_CODE_OAUTH_TOKEN": "fixture-only-token", "CLAUDECODE": "fixture-only-session"
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("fixture-cli-selected"))
        XCTAssertFalse(result.output.contains("UNEXPECTED_STARTUP_FILE"))
        let createdPaths = try FileManager.default.subpathsOfDirectory(atPath: base.path)
        for marker in ["INJECTED_HOME", "INJECTED_CLI", "INJECTED_SOURCE", "INJECTED_PROFILE"] {
            XCTAssertFalse(createdPaths.contains { URL(fileURLWithPath: $0).lastPathComponent == marker }, marker)
        }
    }

    func testReplacingExistingProfileRestoresPrivatePermissions() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("fixture-cli")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        let directory = base.appendingPathComponent("connection")
        let profile = try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: setupScript, directory: directory, environment: [:], home: base,
            systemPaths: [executable.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profile.path)

        let next = try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: setupScript, directory: directory, environment: [:], home: base,
            systemPaths: [executable.path])
        XCTAssertEqual(next, profile)
        XCTAssertEqual(try permissions(next), 0o600)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try profileSettings(next)["RunCommandAsShell"] as? Bool, false)
    }

    func testHelperRetainsAppRuntimeSearchPathWhenTerminalHasOnlySystemPaths() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtimeDirectory = base.appendingPathComponent("runtime ' tools")
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: false)
        try writeExecutable("#!/bin/sh\nprintf 'fixture-runtime-from-app-path\\n'\n",
                            to: runtimeDirectory.appendingPathComponent("usagebar-fixture-node"))
        let executable = base.appendingPathComponent("fixture-cli")
        try writeExecutable("#!/usr/bin/env usagebar-fixture-node\n", to: executable)
        try "print -u2 'UNEXPECTED_STARTUP_FILE'; exit 91\n"
            .write(to: base.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let profile = try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: setupScript, directory: base.appendingPathComponent("connection"),
            environment: ["PATH": runtimeDirectory.path], home: base, systemPaths: [executable.path])
        let command = try XCTUnwrap(profileSettings(profile)["CommandString"] as? String)

        let result = try runCommand(command, at: base, environment: [
            "HOME": base.path, "ZDOTDIR": base.path, "PATH": "/usr/bin:/bin"
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("fixture-runtime-from-app-path"))
        XCTAssertFalse(result.output.contains("UNEXPECTED_STARTUP_FILE"))
    }

    func testHelperFindsNPMPrefixRuntimeWithoutAppOrTerminalSearchPath() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let prefix = base.appendingPathComponent("fixture node installation")
        let runtimeDirectory = prefix.appendingPathComponent("bin")
        let executable = prefix.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code/cli.js")
        for directory in [runtimeDirectory, executable.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeExecutable("#!/bin/sh\nprintf 'fixture-runtime-from-npm-prefix\\n'\n",
                            to: runtimeDirectory.appendingPathComponent("usagebar-fixture-node"))
        try writeExecutable("#!/usr/bin/env usagebar-fixture-node\n", to: executable)
        try "print -u2 'UNEXPECTED_STARTUP_FILE'; exit 91\n"
            .write(to: base.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let profile = try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: setupScript, directory: base.appendingPathComponent("connection"),
            environment: [:], home: base, systemPaths: [executable.path])
        let command = try XCTUnwrap(profileSettings(profile)["CommandString"] as? String)

        let result = try runCommand(command, at: base, environment: [
            "HOME": base.path, "ZDOTDIR": base.path, "PATH": "/usr/bin:/bin"
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("fixture-runtime-from-npm-prefix"))
        XCTAssertFalse(result.output.contains("UNEXPECTED_STARTUP_FILE"))
    }

    func testProfileRejectsExistingSymlinkWithoutOverwritingTarget() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("fixture-cli")
        let content = "#!/bin/sh\nexit 0\n"
        try writeExecutable(content, to: executable)
        let directory = try ClaudeProvider.prepareConnectionDirectory(at: base.appendingPathComponent("connection"))
        let profile = directory.appendingPathComponent("ConnectClaude.terminal")
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: executable)

        XCTAssertThrowsError(try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: setupScript, directory: directory, environment: [:], home: base,
            systemPaths: [executable.path]))
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), content)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: profile.path), executable.path)
    }

    func testProfileRejectsNonregularDestinationWithoutRemovingContents() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("fixture-cli")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        let directory = try ClaudeProvider.prepareConnectionDirectory(at: base.appendingPathComponent("connection"))
        let profile = directory.appendingPathComponent("ConnectClaude.terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        let existingFile = profile.appendingPathComponent("preserve.txt")
        try "preserve this fixture".write(to: existingFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: setupScript, directory: directory, environment: [:], home: base,
            systemPaths: [executable.path]))
        XCTAssertEqual(try String(contentsOf: existingFile, encoding: .utf8), "preserve this fixture")
    }

    func testProfileRejectsSymlinkedConnectionDirectory() throws {
        let base = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("fixture-cli")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let directory = base.appendingPathComponent("linked-connection")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)

        XCTAssertThrowsError(try ClaudeProvider.prepareConnectionTerminalProfile(
            scriptURL: setupScript, directory: directory, environment: [:], home: base,
            systemPaths: [executable.path]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    private var setupScript: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/setup-claude.command")
            .resolvingSymlinksInPath()
    }

    private func fixtureDirectory() throws -> URL {
        // Foundation canonicalizes existing /private/tmp URLs back to the /tmp
        // symlink. Match the provider's existing no-symlink fixtures in .build.
        let root = setupScript.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build", isDirectory: true)
        let directory = root.appendingPathComponent("UsageBar-ConnectionProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutable(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func profileSettings(_ url: URL) throws -> [String: Any] {
        let propertyList = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        return try XCTUnwrap(propertyList as? [String: Any])
    }

    private func permissions(_ url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    private func shellCommand(_ arguments: [String]) -> String {
        arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    private func runCommand(_ command: String, at directory: URL,
                            environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
