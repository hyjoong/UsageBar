import Darwin
import Foundation

/// Only this flag crosses the dispatch worker boundary. Process and pipe state stay on one worker.
final class CodexCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

enum CodexTransportError: Error {
    case timeout, closed, invalidResponse, outputLimit, rpc(Int)
}

/// Private JSONL connection, created for one fetch. Never attaches to an existing Codex process.
/// Polling happens on a utility dispatch worker, not the main thread or a Swift actor executor.
final class CodexRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let cancellation: CodexCancellation
    private let deadline: TimeInterval
    private var buffer = Data()
    private var outputBytes = 0
    private var errorBytes = 0
    private var outputClosed = false
    private var errorClosed = false
    private var launched = false
    private var closed = false
    private var nextID = 1
    private let maxOutput = 2 * 1_024 * 1_024
    private let maxLine = 512 * 1_024
    private let maxErrors = 256 * 1_024

    init(executable: URL, arguments: [String], cancellation: CodexCancellation, deadline: TimeInterval) throws {
        self.cancellation = cancellation
        self.deadline = deadline
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A utility should not depend on, or expose, a user's current project directory.
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        do {
            try cancellation.check()
            try configureNonblocking(output.fileHandleForReading.fileDescriptor)
            try configureNonblocking(errors.fileHandleForReading.fileDescriptor)
            try configureNonblocking(input.fileHandleForWriting.fileDescriptor)
            // A child can exit between poll and write; suppress SIGPIPE for this pipe only.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw CodexTransportError.closed
            }
            try process.run()
            launched = true
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    static func version(executable: URL, cancellation: CodexCancellation, deadline: TimeInterval) throws -> String {
        let child = try CodexRPC(executable: executable, arguments: ["--version"], cancellation: cancellation, deadline: deadline)
        defer { child.close() }
        while let line = try child.readLine(until: deadline) {
            guard let text = String(data: line, encoding: .utf8),
                  text.range(of: #"^codex-cli [0-9]+\.[0-9]+\.[0-9]+[^\r\n]*$"#, options: .regularExpression) != nil else { continue }
            return String(text.dropFirst("codex-cli ".count))
        }
        throw CodexTransportError.invalidResponse
    }

    func initialize() throws {
        _ = try request("initialize", params: ["clientInfo": ["name": "usagebar", "title": "UsageBar", "version": "0.1.0"]], timeout: 5)
        try writeObject(["method": "initialized"], until: deadline)
    }

    func request(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = 6) throws -> [String: Any] {
        // Do not extend this allowlist with turn, thread, command, login, or reset-consume methods.
        guard ["initialize", "account/read", "account/rateLimits/read", "account/usage/read"].contains(method) else {
            throw CodexTransportError.invalidResponse
        }
        let requestDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + timeout)
        let requestID = nextID
        nextID += 1
        var message: [String: Any] = ["id": requestID, "method": method]
        if let params { message["params"] = params }
        try writeObject(message, until: requestDeadline)
        while let line = try readLine(until: requestDeadline) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexTransportError.invalidResponse
            }
            // Ignore notifications; they can be sparse and must not replace our complete snapshot.
            guard let responseID = object["id"] as? Int, responseID == requestID else { continue }
            if let error = object["error"] as? [String: Any] {
                // Never include server error messages or data in logs/UI; these can contain account details.
                throw CodexTransportError.rpc(error["code"] as? Int ?? 0)
            }
            guard let result = object["result"] as? [String: Any] else { throw CodexTransportError.invalidResponse }
            return result
        }
        throw CodexTransportError.closed
    }

    func close() {
        guard !closed else { return }
        closed = true
        for handle in [input.fileHandleForWriting, input.fileHandleForReading,
                       output.fileHandleForReading, output.fileHandleForWriting,
                       errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
        guard launched else { return }
        if process.isRunning {
            process.terminate()
            let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < graceDeadline { usleep(10_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        // Reap our child, including after timeout/cancellation; never leave an orphan app-server.
        process.waitUntilExit()
    }

    private func configureNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { throw CodexTransportError.closed }
    }

    private func check(_ until: TimeInterval) throws {
        try cancellation.check()
        if ProcessInfo.processInfo.systemUptime >= min(deadline, until) { throw CodexTransportError.timeout }
    }

    private func writeObject(_ object: [String: Any], until: TimeInterval) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)
        data.append(0x0a)
        var offset = 0
        let fd = input.fileHandleForWriting.fileDescriptor
        while offset < data.count {
            try check(until)
            let count = data.withUnsafeBytes { bytes in Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count > 0 { offset += count; continue }
            if count == -1 && errno == EINTR { continue }
            guard count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) else { throw CodexTransportError.closed }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&descriptor, 1, 50)
        }
    }

    private func readLine(until: TimeInterval) throws -> Data? {
        while true {
            try check(until)
            if let newline = buffer.firstIndex(of: 0x0a) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= maxLine else { throw CodexTransportError.outputLimit }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }
            guard buffer.count <= maxLine else { throw CodexTransportError.outputLimit }
            if outputClosed {
                guard !buffer.isEmpty else { return nil }
                let last = buffer
                buffer = Data()
                return last
            }
            var descriptors = [
                pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorClosed ? -1 : errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            ]
            let result = poll(&descriptors, nfds_t(descriptors.count), 50)
            if result < 0 && errno != EINTR { throw CodexTransportError.closed }
            if descriptors[0].revents != 0 { try drain(descriptors[0].fd, isError: false) }
            if descriptors[1].revents != 0 { try drain(descriptors[1].fd, isError: true) }
        }
    }

    private func drain(_ fd: Int32, isError: Bool) throws {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        // One bounded read per poll keeps cancellation and deadlines responsive under output floods.
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 {
            if isError {
                errorBytes += count
                guard errorBytes <= maxErrors else { throw CodexTransportError.outputLimit }
            } else {
                outputBytes += count
                guard outputBytes <= maxOutput else { throw CodexTransportError.outputLimit }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        } else if count == 0 {
            if isError { errorClosed = true } else { outputClosed = true }
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            throw CodexTransportError.closed
        }
    }
}
