import Foundation

/// A git repository a session worked in. Worktrees of one repository share `commonDirectory`, so work in
/// an agent's worktree is reported under the repository it belongs to.
public struct GitRepository: Codable, Hashable, Sendable {
    /// Top of the working tree the session was in (a worktree's own folder for a linked worktree).
    public let root: String
    /// The repository's shared git directory, the same for every worktree.
    public let commonDirectory: String
    /// The main working tree's folder name.
    public let name: String

    public init(root: String, commonDirectory: String, name: String) {
        self.root = root; self.commonDirectory = commonDirectory; self.name = name
    }
}

/// Finds the repository of a working directory by looking for `.git` in it and its parents. Reads only
/// small git metadata files and starts no process.
///
/// On macOS, looking inside Desktop or Documents can make the system ask the person for folder access,
/// so callers do this only when git reading is turned on.
public enum RepositoryLocator {
    public static func repository(for cwd: String, fileManager: FileManager = .default,
                                  home: String? = nil) -> GitRepository? {
        // Paths are normalized by hand: Foundation's standardizing turns /private/tmp into /tmp.
        var folder = URL(fileURLWithPath: normalize(cwd), isDirectory: true)
        let start = folder.path
        let home = normalize(home ?? fileManager.homeDirectoryForCurrentUser.path)
        while folder.path != "/" {
            // A dotfiles repository in the home folder is not the project of everything below it.
            // It counts only when the session ran in the home folder itself.
            if folder.path == home && folder.path != start { break }
            let marker = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return GitRepository(root: folder.path, commonDirectory: marker.path, name: folder.lastPathComponent)
                }
                return linkedWorktree(root: folder, marker: marker)
            }
            if folder.path == home { break }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    /// A `.git` file says `gitdir: <path>`; that directory's `commondir` points at the shared git directory.
    private static func linkedWorktree(root: URL, marker: URL) -> GitRepository? {
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let gitDirectory = URL(fileURLWithPath: resolve(target, from: root.path))
        var common = gitDirectory
        if let pointer = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
            let value = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { common = URL(fileURLWithPath: resolve(value, from: gitDirectory.path)) }
        }
        let name = common.lastPathComponent == ".git" ? common.deletingLastPathComponent().lastPathComponent
            : common.deletingPathExtension().lastPathComponent
        return GitRepository(root: root.path, commonDirectory: common.path, name: name.isEmpty ? root.lastPathComponent : name)
    }
}

extension RepositoryLocator {
    /// `path` made absolute against `base` when relative, then normalized.
    static func resolve(_ path: String, from base: String) -> String {
        normalize(path.hasPrefix("/") ? path : base + "/" + path)
    }

    /// Removes `.`, `..` and repeated slashes without consulting the file system.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// One commit as the work log shows it.
public struct GitCommit: Codable, Hashable, Sendable {
    public let sha: String
    public let time: Date
    public let subject: String
    /// Paths relative to the repository root.
    public let files: [String]
    public init(sha: String, time: Date, subject: String, files: [String]) {
        self.sha = sha; self.time = time; self.subject = subject; self.files = files
    }
    public var shortSHA: String { String(sha.prefix(7)) }
}

public enum GitRunError: Error, Equatable, Sendable {
    case unavailable, failed(Int32), timedOut, outputTooLarge
}

/// Runs a read-only git command. A protocol so tests can stand in for the real binary.
public protocol GitRunning: Sendable {
    func run(_ arguments: [String], in directory: String) throws -> String
}

/// The git binary on this Mac, run with a minimal environment: no inherited PATH, no prompts, no
/// optional locks, so reading never changes a repository or waits on the person.
public struct ProcessGitRunner: GitRunning {
    public let executable: String
    public var timeout: TimeInterval = 3
    /// A week of `git log --name-only` in a large monorepo easily passes 1 MB; past this the whole
    /// repository shows as failed, so the cap only guards against runaway output.
    public var maxOutput = 8_000_000

    /// Nil when no usable git exists. `/usr/bin/git` is only a shim that offers to install the Command
    /// Line Tools when they are missing, so it is used only when a developer directory is installed.
    public init?(fileManager: FileManager = .default) {
        let developer = ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
            .contains { fileManager.isExecutableFile(atPath: $0) } || Self.selectedDeveloperDirectoryHasGit(fileManager)
        let candidates = (developer ? ["/usr/bin/git"] : []) + ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        guard let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else { return nil }
        executable = found
    }

    public init(executable: String) { self.executable = executable }

    private static func selectedDeveloperDirectoryHasGit(_ fileManager: FileManager) -> Bool {
        // `xcode-select -s` stores its choice as this link; reading it does not start the shim.
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") else { return false }
        return fileManager.isExecutableFile(atPath: target + "/usr/bin/git")
    }

    public func run(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", directory, "-c", "core.fsmonitor=false", "-c", "core.quotepath=false"] + arguments
        var environment = ["LANG": "C", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
                           "GIT_PAGER": "cat", "PAGER": "cat"]
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let collected = OutputBox()
        let reader = DispatchGroup()
        reader.enter()
        let limit = maxOutput
        DispatchQueue.global(qos: .utility).async {
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if !collected.append(chunk, limit: limit) { process.terminate() }
            }
            reader.leave()
        }
        do { try process.run() } catch {
            try? output.fileHandleForWriting.close()   // lets the reader see end of file and finish
            throw GitRunError.unavailable
        }
        if reader.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = reader.wait(timeout: .now() + 1)
            throw GitRunError.timedOut
        }
        process.waitUntilExit()
        if collected.overflowed { throw GitRunError.outputTooLarge }
        guard process.terminationStatus == 0 else { throw GitRunError.failed(process.terminationStatus) }
        return String(decoding: collected.data, as: UTF8.self)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var data = Data()
        private(set) var overflowed = false
        func append(_ chunk: Data, limit: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard data.count + chunk.count <= limit else { overflowed = true; return false }
            data.append(chunk)
            return true
        }
    }
}

/// Reads a day's commits and the current uncommitted changes of a repository.
public struct GitHistoryReader: Sendable {
    public let runner: any GitRunning
    public init(runner: any GitRunning) { self.runner = runner }

    /// The repository's configured author email, or nil when none is set.
    public func authorEmail(_ repository: GitRepository) -> String? {
        guard let value = try? runner.run(["config", "user.email"], in: repository.root) else { return nil }
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }

    /// Commits authored inside `range` on any branch, newest first. With `author`, only that author's.
    public func commits(_ repository: GitRepository, in range: DateInterval, author: String?) throws -> [GitCommit] {
        let format = ISO8601DateFormatter()
        var arguments = ["log", "--all", "--no-merges", "--no-color", "--no-ext-diff",
                         "--since=\(format.string(from: range.start.addingTimeInterval(-86_400)))",
                         "--until=\(format.string(from: range.end.addingTimeInterval(86_400)))",
                         "--date=iso-strict", "--pretty=format:%x1e%H%x1f%aI%x1f%s", "--name-only"]
        if let author { arguments.append("--author=\(author)") }
        let output = try runner.run(arguments, in: repository.root)
        // `--since` filters on commit date; author date decides the day, so the window above is wider.
        return Self.parseLog(output).filter { range.contains($0.time) && $0.time < range.end }
    }

    /// Paths with uncommitted changes, relative to the repository root.
    public func uncommittedFiles(_ repository: GitRepository) throws -> [String] {
        let output = try runner.run(["status", "--porcelain=v1", "--no-renames"], in: repository.root)
        return output.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            return String(line.dropFirst(3))
        }
    }

    static func parseLog(_ output: String) -> [GitCommit] {
        var seen = Set<String>()
        return output.split(separator: "\u{1e}").compactMap { record -> GitCommit? in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { return nil }
            let fields = header.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let time = LogParsing.date(String(fields[1])) else { return nil }
            let sha = String(fields[0])
            guard sha.count >= 7, seen.insert(sha).inserted else { return nil }
            return GitCommit(sha: sha, time: time, subject: String(fields[2].prefix(200)),
                             files: lines.dropFirst().map(String.init).filter { !$0.isEmpty })
        }
    }
}
