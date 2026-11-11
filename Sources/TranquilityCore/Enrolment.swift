import Foundation
import Darwin

/// The safety rail.
///
/// Dispatch refuses to inject into any session that has not been explicitly
/// enrolled. Real work sessions are opt-in, so a bug in the loop cannot type into
/// something that matters — the worst case is that nothing happens.
public struct EnrolmentRegistry: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? QueueStore.supportDirectory.appendingPathComponent("enrolled.json")
    }

    private struct File: Codable {
        var sessionIds: [String] = []
        var cwdPrefixes: [String] = []
        /// Off by default. Turning this on defeats the point of the rail; it exists
        /// so a deliberate "enrol everything" is a visible, recorded choice.
        var allowAll: Bool = false
    }

    private func load() -> File {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return File() }
        return file
    }

    private func save(_ file: File) throws {
        try? PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
        PrivateStorage.protect(url)
    }

    /// Serialize the whole read/modify/write across app and CLI processes.
    /// Atomic rename alone protects readers, but loses a concurrent enrollment.
    private func mutate(_ change: (inout File) -> Void) throws {
        try PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        let fd = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        let deadline = Date().addingTimeInterval(2)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard Date() < deadline else { throw POSIXError(.EBUSY) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer { flock(fd, LOCK_UN) }
        var file = File()
        if FileManager.default.fileExists(atPath: url.path) {
            // Preserve corrupt evidence instead of replacing it with an empty allowlist.
            file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        }
        change(&file)
        try save(file)
    }

    public func isEnrolled(sessionId: String, cwd: String?) -> Bool {
        let file = load()
        if file.allowAll { return true }
        if file.sessionIds.contains(sessionId) { return true }
        if let cwd { return file.cwdPrefixes.contains { !$0.isEmpty && cwd.hasPrefix($0) } }
        return false
    }

    public func enrol(sessionId: String) throws {
        try mutate { if !$0.sessionIds.contains(sessionId) { $0.sessionIds.append(sessionId) } }
    }

    public func enrol(cwdPrefix: String) throws {
        try mutate { if !$0.cwdPrefixes.contains(cwdPrefix) { $0.cwdPrefixes.append(cwdPrefix) } }
    }

    public func revoke(sessionId: String) throws {
        try mutate { $0.sessionIds.removeAll { $0 == sessionId } }
    }

    public func summary() -> (sessions: [String], prefixes: [String], allowAll: Bool) {
        let f = load()
        return (f.sessionIds, f.cwdPrefixes, f.allowAll)
    }
}
