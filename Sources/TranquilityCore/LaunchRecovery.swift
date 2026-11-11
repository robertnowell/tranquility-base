import Foundation

/// A launch receipt is written before spawning. It is never automatically replayed.
public struct LaunchRecoveryRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var enforcesAccount: Bool?
    public var targetID: String
    public var directory: String
    public var createdAt: Date
    public var paneID: String?
    public var paneSession: String?
    public var sessionID: String?
    public var state: String
    public var instruction: String?
    public init(id: String, targetID: String, directory: String, enforcesAccount: Bool = true) {
        self.enforcesAccount = enforcesAccount
        self.id = id; self.targetID = targetID; self.directory = directory
        createdAt = Date(); state = "prepared"
    }
}

public final class LaunchRecoveryStore: @unchecked Sendable {
    public static let shared = LaunchRecoveryStore(fileURL: QueueStore.supportDirectory.appendingPathComponent("pending-launches.json"))
    private let lock = NSLock()
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func records() throws -> [LaunchRecoveryRecord] {
        lock.lock(); defer { lock.unlock() }; return try read()
    }
    private func read() throws -> [LaunchRecoveryRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([LaunchRecoveryRecord].self, from: Data(contentsOf: fileURL))
    }
    public func save(_ record: LaunchRecoveryRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let descriptor = try SavedAccountStore.acquireWriteLock(fileURL)
        defer { SavedAccountStore.releaseWriteLock(descriptor) }
        var records = try read(); records.removeAll { $0.id == record.id }; records.append(record)
        try SavedAccountStore.write(records, to: fileURL)
    }
    public func update(_ id: String, _ change: (inout LaunchRecoveryRecord) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let descriptor = try SavedAccountStore.acquireWriteLock(fileURL)
        defer { SavedAccountStore.releaseWriteLock(descriptor) }
        var records = try read()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index]); try SavedAccountStore.write(records, to: fileURL)
    }
    /// Exact launched pane + account. Same-directory sessions cannot steal a handoff.
    public static func matches(_ session: LiveSession, record: LaunchRecoveryRecord) -> Bool {
        guard session.cwd == record.directory,
              (record.enforcesAccount == false || session.accountTargetID == record.targetID),
              let pane = record.paneID, let name = record.paneSession,
              let tmux = session.registryTmux else { return false }
        return tmux.hasPrefix(name + ":") && tmux.hasSuffix("." + pane)
    }
}
