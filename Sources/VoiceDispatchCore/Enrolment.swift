import Foundation

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
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    public func isEnrolled(sessionId: String, cwd: String?) -> Bool {
        let file = load()
        if file.allowAll { return true }
        if file.sessionIds.contains(sessionId) { return true }
        if let cwd { return file.cwdPrefixes.contains { !$0.isEmpty && cwd.hasPrefix($0) } }
        return false
    }

    public func enrol(sessionId: String) throws {
        var file = load()
        if !file.sessionIds.contains(sessionId) { file.sessionIds.append(sessionId) }
        try save(file)
    }

    public func enrol(cwdPrefix: String) throws {
        var file = load()
        if !file.cwdPrefixes.contains(cwdPrefix) { file.cwdPrefixes.append(cwdPrefix) }
        try save(file)
    }

    public func revoke(sessionId: String) throws {
        var file = load()
        file.sessionIds.removeAll { $0 == sessionId }
        try save(file)
    }

    public func summary() -> (sessions: [String], prefixes: [String], allowAll: Bool) {
        let f = load()
        return (f.sessionIds, f.cwdPrefixes, f.allowAll)
    }
}
