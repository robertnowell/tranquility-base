import Foundation

/// Which pid (and, for a tmux-hosted session, which pane) TB currently holds
/// for a session it launched or resumed — the fact Claude Code's own
/// `agents --json` gives for free and no other harness does.
///
/// General on purpose, not `CodexOwnership`: harness-specific facts already
/// live behind `HarnessAdapter` (resumeArguments, trustPrompt, capabilities);
/// which pid answers to a session id is exactly that kind of fact, just one
/// this repo never needed to persist before, because Claude Code's own CLI
/// already answers it and Codex's does not. The next harness this app adds
/// gets ownership tracking for free from this type rather than a bespoke
/// bolt-on, and Claude Code writes into the SAME store as Codex rather than
/// living outside it — one mechanism, not "the thing Codex alone needs."
public struct SessionOwnershipRecord: Codable, Sendable, Equatable {
    public var sessionId: String
    /// `HarnessAdapter.id` ("claude-code", "codex", …).
    public var harness: String
    public var pid: Int
    /// Present for a tmux-hosted session (every launch, since 21 Aug); nil
    /// for the Terminal.app path `resume()` still uses for Claude Code.
    public var paneId: String?
    public var socketName: String?
    public var sessionName: String?
    public var paneTty: String?
    /// The launch directory — carried so `EnrolmentRegistry`'s cwd-prefix
    /// rail works for a session found through this store the same way it
    /// already does for one found through `agents --json`, not just the
    /// narrower exact-sessionId form.
    public var cwd: String?
    public var attachedAt: Date

    public init(sessionId: String, harness: String, pid: Int,
               paneId: String? = nil, socketName: String? = nil,
               sessionName: String? = nil, paneTty: String? = nil,
               cwd: String? = nil, attachedAt: Date = Date()) {
        self.sessionId = sessionId
        self.harness = harness
        self.pid = pid
        self.paneId = paneId
        self.socketName = socketName
        self.sessionName = sessionName
        self.paneTty = paneTty
        self.cwd = cwd
        self.attachedAt = attachedAt
    }

    /// Reconstructs the pane address this record was captured with, when it
    /// carried one — a tmux-hosted record only.
    public var pane: TmuxPaneAddress? {
        guard let paneId, let paneTty else { return nil }
        return TmuxPaneAddress(socketName: socketName, paneId: paneId,
                               sessionName: sessionName ?? sessionId, paneTty: paneTty)
    }
}

/// Where session-ownership records live. A protocol, not a concrete file
/// path baked into every call site — matches how this repo already treats
/// `ClaudeAgentsReading`/`DispatchTransport`: today's implementation is a
/// local file (this machine, this process's disk), but nothing above this
/// layer should need to know that. A future hosted deployment (a shared
/// backend instead of one machine's disk) is a second conformance, not a
/// rewrite of every caller.
public protocol SessionOwnershipStore: Sendable {
    func record(_ r: SessionOwnershipRecord)
    func current(sessionId: String) -> SessionOwnershipRecord?
    func remove(sessionId: String)
    func all() -> [SessionOwnershipRecord]
}

extension SessionOwnershipStore {
    /// The record for a session, ONLY if its pid is still actually alive —
    /// never hand back a stale pid without checking, the same "never trust a
    /// stale live-lookup" discipline `TmuxOwnership` already lives by. Does
    /// not remove a stale record on its own: it is simply ignored at the
    /// point of use, self-healing the next time that session is attached
    /// again — the same "no active cleanup needed for correctness" call this
    /// arc already made for stale Codex discovery rows
    /// (`SessionDiscovery.discoverCodex`).
    public func verifiedCurrent(sessionId: String) -> SessionOwnershipRecord? {
        guard let r = current(sessionId: sessionId), ProcessProbe.isAlive(r.pid) else { return nil }
        return r
    }

    /// Every session from a harness with no registry of its own — Codex
    /// today, whatever harness comes next tomorrow — in `agents.sessions()`'s
    /// own shape, so a caller built around Claude Code's registry can just
    /// add these in rather than rewrite itself around a second source.
    ///
    /// The one seam: found live, 26 Aug, that the same "ask `agents` and
    /// nothing else" assumption was independently written at roughly thirty
    /// call sites across this app — three of them on the single fresh-
    /// launch-then-reply path, each silently treating a demonstrably live
    /// Codex session as gone. `Coordinator.waiting()` and `dispatch()` were
    /// hand-fixed first, in the order the bug was found in; this is the
    /// same fix, factored out once, for the rest.
    ///
    /// Excludes Claude Code deliberately, even though this store can hold
    /// Claude Code records too (a revive writes one) — `agents.sessions()`
    /// is already authoritative for that harness, and a Claude Code row
    /// from BOTH sources would double the same session in a `+`-combined
    /// list.
    /// `status` and `name` are INJECTED rather than looked up here, because
    /// both answers live somewhere this type cannot reach and neither is worth
    /// a second source of truth.
    ///
    /// Status was hard-coded `"idle"` from the day this was written, which was
    /// honest while Codex told us nothing: `GridAssembler` reads
    /// `live.status == "busy"` for its blue lamp, so a Codex session that was
    /// visibly working sat grey next to a Claude one that did not (Robert,
    /// 30 Aug, with a screenshot of a pane reading "Working (24s)"). The
    /// answer now exists and costs nothing: the hooks installed on 29 Aug put
    /// a UserPromptSubmit and a Stop in the event store for every Codex turn,
    /// so the latest of the two IS the busy signal, and the grid already loads
    /// it for other reasons.
    ///
    /// Name is the same shape of problem. `discoverCodex` learned to read
    /// Codex's own thread name, but that is the DISK band; a live session
    /// never reaches it, so the rows he was looking at fell back to their
    /// directory and both said "Projects".
    public func liveNonRegistrySessions(
        status: (String) -> String? = { _ in nil },
        name: (String) -> String? = { _ in nil }
    ) -> [LiveSession] {
        all().filter { $0.harness != ClaudeCodeAdapter().id && ProcessProbe.isAlive($0.pid) }
            .map { LiveSession(pid: $0.pid, sessionId: $0.sessionId, cwd: $0.cwd,
                               status: status($0.sessionId) ?? "idle",
                               name: name($0.sessionId), waitingFor: nil) }
    }
}

/// Default, local implementation — one JSON file, same shape
/// `AgentDefaults` already uses: the support directory, tolerate a missing
/// or corrupt file rather than crash (a fresh/empty store, not a launch
/// failure). Shared, for free, by the GUI app and every `tbase` invocation,
/// since both read and write the same path.
public final class FileSessionOwnershipStore: SessionOwnershipStore, @unchecked Sendable {
    public static let shared = FileSessionOwnershipStore()

    public var fileURL: URL
    /// Only protects concurrent access WITHIN one process — a GUI-app write
    /// racing a `tbase` CLI write (a different process) is not locked
    /// against here. Accepted rather than solved: the write is "record ONE
    /// session," never a merge of unrelated data, so the realistic race is
    /// two DIFFERENT sessions attaching in the same instant, and the loser
    /// self-heals on its own next attach. `.atomic` below is what actually
    /// matters cross-process — no writer can ever observe a torn file.
    private let lock = NSLock()

    public init(fileURL: URL = QueueStore.supportDirectory
        .appendingPathComponent("session-ownership.json")) {
        self.fileURL = fileURL
    }

    private func load() -> [String: SessionOwnershipRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                [String: SessionOwnershipRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ records: [String: SessionOwnershipRecord]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        // Atomic, unlike AgentDefaults' own write: this is a many-record
        // store rewritten on every attach, not one setting, so a torn write
        // would lose every session's ownership rather than one field.
        try? data.write(to: fileURL, options: .atomic)
    }

    public func record(_ r: SessionOwnershipRecord) {
        lock.lock(); defer { lock.unlock() }
        var records = load()
        records[r.sessionId] = r
        save(records)
    }

    public func current(sessionId: String) -> SessionOwnershipRecord? {
        lock.lock(); defer { lock.unlock() }
        return load()[sessionId]
    }

    public func remove(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        var records = load()
        records.removeValue(forKey: sessionId)
        save(records)
    }

    public func all() -> [SessionOwnershipRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(load().values)
    }
}
