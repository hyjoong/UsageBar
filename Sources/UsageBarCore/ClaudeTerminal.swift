import Foundation
import Darwin

/// A small bounded VT screen, rather than a regex that merges successive TUI frames.
/// It is deliberately local: captured output never leaves this process.
struct ClaudeTerminalScreen {
    let columns: Int
    let rows: Int
    private var cells: [[Unicode.Scalar]]
    private var row = 0
    private var column = 0
    private var saved = (row: 0, column: 0)

    init(columns: Int = 160, rows: Int = 200) {
        self.columns = columns; self.rows = rows
        cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    static func render(_ text: String) -> String {
        var screen = ClaudeTerminalScreen()
        screen.feed(text)
        return screen.text
    }

    var text: String {
        cells.map { String(String.UnicodeScalarView($0)).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func feed(_ text: String) {
        let input = Array(text.unicodeScalars)
        var index = 0
        while index < input.count {
            let scalar = input[index]
            index += 1
            if scalar.value == 27 {
                guard index < input.count else { break }
                let next = input[index]; index += 1
                if next == "[" {
                    let start = index
                    while index < input.count, !(0x40...0x7E).contains(input[index].value) { index += 1 }
                    guard index < input.count else { break }
                    let parameters = String(String.UnicodeScalarView(input[start..<index]))
                    csi(input[index], parameters: parameters)
                    index += 1
                } else if next == "]" || next == "P" || next == "_" {
                    while index < input.count {
                        if input[index].value == 7 { index += 1; break }
                        if input[index].value == 27, index + 1 < input.count, input[index + 1] == "\\" {
                            index += 2; break
                        }
                        index += 1
                    }
                } else if next == "7" { saved = (row, column) }
                else if next == "8" { row = saved.row; column = saved.column }
                else if next == "D" { newline() }
                else if next == "E" { column = 0; newline() }
                else if next == "M" { row = max(0, row - 1) }
                else if next == "c" { eraseAll(); row = 0; column = 0 }
                else if next == "(" || next == ")" { index = min(input.count, index + 1) }
                continue
            }
            switch scalar.value {
            case 13: column = 0
            case 10: column = 0; newline()
            case 8: column = max(0, column - 1)
            case 9: column = min(columns - 1, ((column / 8) + 1) * 8)
            case 0...31, 127: break
            default:
                if column >= columns { column = 0; newline() }
                cells[row][column] = scalar
                column += 1
                // Wide glyphs only affect placement; usage headings and values are ASCII.
                if Self.isWide(scalar), column < columns { cells[row][column] = " "; column += 1 }
            }
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7AF).contains(value) || (0xF900...0xFAFF).contains(value)
            || (0xFF01...0xFF60).contains(value) || (0x1F300...0x1FAFF).contains(value)
    }

    private mutating func newline() {
        row += 1
        if row >= rows {
            cells.removeFirst(); cells.append(Array(repeating: " ", count: columns)); row = rows - 1
        }
    }

    private mutating func eraseAll() { cells = Array(repeating: Array(repeating: " ", count: columns), count: rows) }

    private mutating func csi(_ final: Unicode.Scalar, parameters: String) {
        // Private mode switches (cursor visibility, alternate screen) contain no text.
        if parameters.hasPrefix("?") { return }
        let numbers = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = numbers.first ?? 0
        let amount = max(1, min(1000, first))
        switch final {
        case "H", "f":
            row = min(rows - 1, max(0, (numbers.first ?? 1) - 1))
            column = min(columns - 1, max(0, (numbers.dropFirst().first ?? 1) - 1))
        case "A": row = max(0, row - amount)
        case "B", "e": row = min(rows - 1, row + amount)
        case "C", "a": column = min(columns - 1, column + amount)
        case "D": column = max(0, column - amount)
        case "E": row = min(rows - 1, row + amount); column = 0
        case "F": row = max(0, row - amount); column = 0
        case "G", "`": column = min(columns - 1, max(0, first - 1))
        case "d": row = min(rows - 1, max(0, first - 1))
        case "s": saved = (row, column)
        case "u": row = saved.row; column = saved.column
        case "J":
            if first == 2 || first == 3 { eraseAll() }
            else if first == 1 {
                for r in 0..<row { cells[r] = Array(repeating: " ", count: columns) }
                for c in 0...min(column, columns - 1) { cells[row][c] = " " }
            } else {
                if column < columns { for c in column..<columns { cells[row][c] = " " } }
                if row + 1 < rows { for r in (row + 1)..<rows { cells[r] = Array(repeating: " ", count: columns) } }
            }
        case "K":
            let lower = first == 0 ? min(column, columns) : 0
            let upper = first == 1 ? min(column + 1, columns) : columns
            if lower < upper { for c in lower..<upper { cells[row][c] = " " } }
        case "X":
            if column < columns { for c in column..<min(columns, column + amount) { cells[row][c] = " " } }
        case "P":
            let start = min(column, columns - 1), count = min(amount, columns - min(column, columns - 1))
            cells[row].removeSubrange(start..<(start + count)); cells[row] += Array(repeating: " ", count: count)
        case "@":
            let start = min(column, columns - 1)
            cells[row].insert(contentsOf: Array(repeating: " ", count: min(amount, columns)), at: start)
            cells[row] = Array(cells[row].prefix(columns))
        case "L":
            for _ in 0..<min(amount, rows - row) { cells.insert(Array(repeating: " ", count: columns), at: row); cells.removeLast() }
        case "M":
            for _ in 0..<min(amount, rows - row) { cells.remove(at: row); cells.append(Array(repeating: " ", count: columns)) }
        case "S":
            for _ in 0..<min(amount, rows) { cells.removeFirst(); cells.append(Array(repeating: " ", count: columns)) }
        case "T":
            for _ in 0..<min(amount, rows) { cells.removeLast(); cells.insert(Array(repeating: " ", count: columns), at: 0) }
        default: break
        }
    }
}

/// Cancellation only signals the process created by this capture. No shell or credentials are read.
final class ClaudePTYCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var child: Process?

    func cancel() {
        lock.lock(); cancelled = true; let process = child; lock.unlock()
        if let process, process.isRunning { kill(process.processIdentifier, SIGTERM) }
    }

    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    /// The official read-only auth command exposes account metadata, never a token.
    /// Unsupported versions or unavailable metadata leave the account unknown.
    func authMetadata(executable: String, directory: URL, environment: [String: String]) throws -> ClaudeAuthMetadata? {
        try checkCancellation()
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status", "--json"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        do { try process.run() } catch { return nil }
        try? output.fileHandleForWriting.close()
        lock.lock(); child = process; lock.unlock()
        defer { stopOwnedProcess(process) }
        let deadline = Date().addingTimeInterval(3)
        var data = Data()
        while Date() < deadline {
            try checkCancellation()
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= 64 * 1024 else { return nil }
                data.append(contentsOf: buffer.prefix(count))
            } else if !process.isRunning {
                return process.terminationStatus == 0 ? ClaudeAuthMetadata.parse(data) : nil
            }
            usleep(20_000)
        }
        return nil
    }

    private func stopOwnedProcess(_ process: Process) {
        if process.isRunning {
            kill(process.processIdentifier, SIGTERM)
            let deadline = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        lock.lock(); child = nil; lock.unlock()
    }

    func run(executable: String, directory: URL, environment: [String: String], timeout: TimeInterval = 25) throws -> [UsageWindow] {
        try checkCancellation()
        var primary: Int32 = -1, secondary: Int32 = -1
        var size = winsize(ws_row: 200, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else {
            throw ProviderError.unavailable(String(localized: "Claude 사용량을 읽을 터미널을 열지 못했어요."))
        }
        defer { if primary >= 0 { close(primary) }; if secondary >= 0 { close(secondary) } }
        _ = fcntl(primary, F_SETFL, O_NONBLOCK)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--safe-mode", "--ax-screen-reader", "--tools", "", "--strict-mcp-config", "--no-chrome",
                             "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#, "/usage"]
        process.currentDirectoryURL = directory
        process.environment = environment
        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        do { try process.run() }
        catch { throw ProviderError.setupRequired(String(localized: "Claude Code를 실행할 수 없어요. 설치 경로를 확인해 주세요.")) }
        close(secondary); secondary = -1
        lock.lock(); child = process; lock.unlock()
        defer { stopOwnedProcess(process) }
        var output = Data()
        let deadline = Date().addingTimeInterval(min(25, max(0.1, timeout)))
        var firstValidAt: Date?
        var lastChangedAt = Date()
        var windows: [UsageWindow] = []
        var queryTail = Data()
        while Date() < deadline {
            try checkCancellation()
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(primary, &bytes, bytes.count)
            if count > 0 {
                let data = Data(bytes.prefix(count))
                guard output.count + data.count <= 512 * 1024 else {
                    throw ProviderError.unavailable(String(localized: "Claude 응답이 예상보다 커서 조회를 중단했어요."))
                }
                output.append(data); lastChangedAt = Date()
                queryTail.append(data)
                if queryTail.range(of: Data([27, 91, 54, 110])) != nil {
                    let response: [UInt8] = [27, 91, 49, 59, 49, 82]
                    _ = response.withUnsafeBytes { write(primary, $0.baseAddress!, $0.count) }
                }
                queryTail = Data(queryTail.suffix(3))
                let text = ClaudeTerminalScreen.render(String(decoding: output, as: UTF8.self))
                switch ClaudeUsageParser.inspect(text) {
                case .pending: windows = []; firstValidAt = nil
                case .failure(let error): throw error
                case .usage(let parsed):
                    windows = parsed
                    if firstValidAt == nil { firstValidAt = Date() }
                }
            } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EIO, errno != EINTR {
                throw ProviderError.unavailable(String(localized: "Claude 사용량 응답을 읽지 못했어요."))
            }
            if !windows.isEmpty, let firstValidAt,
               Date().timeIntervalSince(firstValidAt) >= 1.5,
               Date().timeIntervalSince(lastChangedAt) >= 0.25 { return windows }
            if !process.isRunning, count <= 0 {
                if !windows.isEmpty { return windows }
                throw ProviderError.unavailable(String(localized: "Claude가 사용량을 보내기 전에 종료됐어요. 터미널에서 /usage를 확인해 주세요."))
            }
            usleep(60_000)
        }
        try checkCancellation()
        throw ProviderError.unavailable(String(localized: "Claude 사용량 조회가 지연되고 있어요. 터미널에서 /usage를 확인한 뒤 다시 시도해 주세요."))
    }
}
