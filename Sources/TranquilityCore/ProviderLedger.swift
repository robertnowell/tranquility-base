import Foundation

/// Which protocol providers this app has ever started an agent on, on disk.
///
/// **A relaunch has to know which binaries are worth spawning.** A registered
/// `ACPProvider` runs no process until something is started on it, which is
/// what makes listing every installed agent at launch free. But the sessions
/// it started live in the agent's own store, not in this app, and the only
/// way to ask for them back is to spawn the agent and call `session/list`.
/// Spawning every installed vendor at every launch just to ask would undo the
/// free listing; spawning none means a started agent is gone at the next
/// relaunch, which this app relaunches on every merge.
///
/// So: one mark per provider, set the first time an agent is started on it,
/// read by `ACPProvider.mine()` when the poller seeds. Marked means spawn and
/// list; unmarked means there was never anything to find. The same rule local
/// sessions have had since 11 Aug: they do not stop existing once their
/// process ends, and adoption at launch is how they come back.
///
/// A file rather than `UserDefaults` so a test can point it at a temporary
/// directory and the class of failure recorded three times on 14 Sep (a
/// default that reads the developer's disk) cannot recur here.
public struct ProviderLedger: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// The app's own, beside the spool.
    public static var standard: ProviderLedger {
        ProviderLedger(url: QueueStore.supportDirectory.appendingPathComponent("agents-used.json"))
    }

    /// Record that an agent was started on `provider`, with when.
    public func mark(_ provider: String, at date: Date = Date()) {
        var file = read()
        file.used[provider] = ISO8601DateFormatter().string(from: date)
        write(file)
    }

    /// Whether an agent has ever been started on `provider` from this Mac.
    public func used(_ provider: String) -> Bool {
        read().used[provider] != nil
    }

    /// The user ended this agent (the provider's own id). It is not adopted
    /// again at the next launch: the vendor still lists it, and a row that
    /// came back after End Agent would be the row refusing to end.
    public func forget(_ raw: String, provider: String) {
        var file = read()
        var ended = Set(file.ended[provider] ?? [])
        ended.insert(raw)
        file.ended[provider] = ended.sorted()
        write(file)
    }

    public func forgotten(_ raw: String, provider: String) -> Bool {
        read().ended[provider]?.contains(raw) == true
    }

    private struct File { var used: [String: String] = [:]; var ended: [String: [String]] = [:] }

    private func read() -> File {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return File() }
        // The first shape was a flat provider → date map (15 Sep, morning).
        if let flat = object as? [String: String] { return File(used: flat) }
        return File(used: object["used"] as? [String: String] ?? [:],
                    ended: object["ended"] as? [String: [String]] ?? [:])
    }

    private func write(_ file: File) {
        let object: [String: Any] = ["used": file.used, "ended": file.ended]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
