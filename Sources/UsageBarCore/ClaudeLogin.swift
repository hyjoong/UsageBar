import Foundation

/// Runs the installed CLI's own `claude auth login`. The CLI opens the browser and waits for its
/// local callback, so signing in again needs no Terminal window and no shell startup files.
/// UsageBar never reads the login itself: it waits for the process to exit, then checks usage again.
public final class ClaudeLogin: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(String)
        case cancelled
    }

    public static let timeout: TimeInterval = 10 * 60
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false

    public init() {}

    /// Waits for the browser sign-in. `onSignInURL` receives the address the CLI prints for when
    /// the browser did not open, only if it points at Anthropic's own sign-in hosts.
    public func run(executablePath: String? = nil, timeout: TimeInterval = ClaudeLogin.timeout,
                    onSignInURL: @escaping @Sendable (URL) -> Void = { _ in }) async -> Outcome {
        var environment = ProcessInfo.processInfo.environment
        guard let executable = ClaudeProvider.resolveExecutable(preferred: executablePath, environment: environment) else {
            return .failed(String(localized: "Claude Code가 필요해요. 설치 후 터미널에서 로그인해 주세요."))
        }
        // Same isolation as the usage probe: the CLI's own stored login, no inherited session token.
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        environment.removeValue(forKey: "CLAUDECODE")
        environment["DISABLE_AUTOUPDATER"] = "1"
        let directory: URL
        do { directory = try ClaudeProvider.prepareConnectionDirectory() }
        catch { return .failed((error as? LocalizedError)?.errorDescription ?? String(localized: "Claude 로그인을 시작하지 못했어요.")) }
        let processEnvironment = environment
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                self.runProcess(executable: executable, directory: directory, environment: processEnvironment,
                                timeout: timeout, onSignInURL: onSignInURL)
            }.value
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        lock.lock(); cancelled = true; let process = child; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func runProcess(executable: String, directory: URL, environment: [String: String], timeout: TimeInterval,
                    onSignInURL: @escaping @Sendable (URL) -> Void) -> Outcome {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "login", "--claudeai"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let reader = output.fileHandleForReading
        let buffer = OutputBuffer()
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let url = buffer.append(data) else { return }
            onSignInURL(url)
        }
        defer { reader.readabilityHandler = nil; try? reader.close() }
        lock.lock()
        if cancelled { lock.unlock(); return .cancelled }
        do { try process.run() } catch {
            lock.unlock()
            return .failed(String(localized: "Claude Code를 실행할 수 없어요. 설치 경로를 확인해 주세요."))
        }
        child = process
        lock.unlock()
        try? output.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            lock.lock(); child = nil; let wasCancelled = cancelled; lock.unlock()
            return wasCancelled ? .cancelled : .failed(String(localized: "로그인을 기다리다 시간이 지났어요. 다시 시도해 주세요."))
        }
        lock.lock(); child = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { return .cancelled }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .failed(String(localized: "로그인이 끝나지 않았어요. 다시 시도하거나 명령어를 복사해 터미널에서 로그인해 주세요."))
        }
        return .succeeded
    }

    /// The first https address on an Anthropic sign-in host. Anything else the CLI prints is ignored.
    static func signInURL(in text: String) -> URL? {
        let hosts = ["claude.com", "claude.ai", "anthropic.com"]
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[],"))
            guard candidate.hasPrefix("https://"), let url = URL(string: candidate), url.scheme == "https",
                  let host = url.host?.lowercased(),
                  hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
            return url
        }
        return nil
    }

    /// The command a person can paste into any terminal when the in-app login cannot run.
    public static func manualCommand(executablePath: String? = nil,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let executable = ClaudeProvider.resolveExecutable(preferred: executablePath, environment: environment)
        guard let executable else { return "claude auth login" }
        return "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' auth login"
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var reported = false

        /// Returns the sign-in address once, the first time it appears.
        func append(_ data: Data) -> URL? {
            lock.lock(); defer { lock.unlock() }
            guard !reported, text.utf8.count < 64 * 1024 else { return nil }
            text += String(decoding: data, as: UTF8.self)
            // Only finished lines: an address cut between two reads must not be reported half-written.
            guard let end = text.lastIndex(where: \.isNewline),
                  let url = ClaudeLogin.signInURL(in: String(text[..<end])) else { return nil }
            reported = true
            return url
        }
    }
}
