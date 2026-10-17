import Foundation

public enum LogIndexStoreError: Error, Equatable, Sendable {
    case unsafePath, tooLarge
}

/// Keeps the work log index in `~/Library/Application Support/<app>/worklog-index/index.json`, readable by
/// this user only. The index holds cursors, parser state, event times, edited file paths and session titles.
/// Prompt text is never in it, only where each prompt sits in its log.
///
/// An index that cannot be read (damaged, from another version, too large) is treated as empty: it is only
/// a cache of the logs and is rebuilt on the next refresh.
public actor LogIndexStore {
    public static let maxBytes = 20_000_000
    private let fileURL: URL

    public init(directory: URL? = nil, appFolder: String = "UsageBar") {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appFolder, isDirectory: true)
        fileURL = base.appendingPathComponent("worklog-index", isDirectory: true).appendingPathComponent("index.json")
    }

    public func load() -> LogIndex {
        guard (try? guardPath()) != nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= Self.maxBytes,
              let data = try? Data(contentsOf: fileURL),
              let index = try? JSONDecoder().decode(LogIndex.self, from: data),
              index.version == LogIndex.currentVersion else { return LogIndex() }
        return index
    }

    public func save(_ index: LogIndex) throws {
        let data = try JSONEncoder().encode(index)
        guard data.count <= Self.maxBytes else { throw LogIndexStoreError.tooLarge }
        let folder = fileURL.deletingLastPathComponent()
        try guardPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try guardPath()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try data.write(to: fileURL, options: .atomic)
        try guardPath()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Removes the index, for example when the person turns the work log off.
    public func clear() throws {
        try guardPath()
        let folder = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func guardPath() throws {
        // Same rule as the work journal: no symbolic link anywhere on the path.
        var candidate = fileURL
        while candidate.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw LogIndexStoreError.unsafePath
            }
            candidate.deleteLastPathComponent()
        }
    }
}
