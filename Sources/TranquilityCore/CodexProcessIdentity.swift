import Foundation

/// Which Codex thread one already-running process owns *now*.
///
/// A Codex TUI may replace its thread without replacing its process: editing
/// an earlier prompt forks the conversation, drops the parent's writer lock,
/// and acquires the child's lock in the same pid. `SessionOwnershipRecord`
/// captures the id at launch, so this probe is the narrow bridge between the
/// stable attachment (pid / pane / tty) and Codex's movable thread identity.
///
/// The normal path performs no subprocess work. As long as the lock named by
/// the ownership record still exists, the record is current. Only proven
/// drift asks `lsof` which lock that exact pid holds in Codex's lock directory.
public enum CodexProcessIdentity {
    /// Every thread-writer lock this lsof output says the process holds.
    /// Filenames only: a UUID directly inside `locks`, never `.coordination.
    /// lock` and never a nested path.
    static func heldThreadIds(lsofOutput: String, locks: URL) -> Set<String> {
        let root = locks.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var ids = Set<String>()

        for line in lsofOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "n" else { continue }
            let path = String(line.dropFirst())
            guard path.hasPrefix(prefix), path.hasSuffix(".lock") else { continue }
            let name = String(path.dropFirst(prefix.count).dropLast(5))
            guard !name.contains("/"), UUID(uuidString: name) != nil else { continue }
            ids.insert(name.lowercased())
        }
        return ids
    }

    /// Which of the held locks is the CONVERSATION, given the id we recorded
    /// when the pane was attached.
    ///
    /// "Exactly one held lock is the answer, anything else is ambiguity" was
    /// this function until 13 Sep, and it was right about a process that has
    /// only ever run one thread. Measured against the pane that reported this
    /// bug (pid 91395, two days old): SEVEN locks, and a sub-agent's lock is
    /// never released — three of them had been held since 11 Sep. So on any
    /// pane that has ever spawned a sub-agent, "count == 1" is false for the
    /// rest of the process's life, this returned nil, and the fork of 13 Sep
    /// was never followed. The grid kept the dead parent and the live
    /// conversation had no row at all.
    ///
    /// Two facts on disk settle it, and neither is a heuristic:
    ///
    ///  - a sub-agent SAYS SO (`thread_source: "subagent"`), and a sub-agent
    ///    is never the pane's conversation. Only a positive claim excludes:
    ///    a candidate with no readable rollout yet — a thread newer than its
    ///    first flush — stays in.
    ///  - a fork SAYS WHAT IT FORKED FROM (`forked_from_id`), so the child of
    ///    the recorded id is identifiable rather than merely newest.
    ///
    /// Ambiguity still answers nil: two candidate conversations in one pid
    /// is not a thing to guess at.
    static func activeThreadId(
        amongHeld held: Set<String>, recordedId: String?,
        meta: (String) -> CodexRollout.SessionMeta?
    ) -> String? {
        if let recordedId, held.contains(recordedId.lowercased()) {
            return recordedId
        }
        let conversations = held.filter { meta($0)?.isSubagent != true }
        if conversations.count == 1 { return conversations.first }
        guard conversations.count > 1, let recordedId else { return nil }
        let descendants = conversations.filter {
            descends($0, from: recordedId, meta: meta)
        }
        return descendants.count == 1 ? descendants.first : nil
    }

    /// Does `id` continue `ancestor`, following `forked_from_id` back? An edit
    /// two prompts ago makes a chain, not a single link, so this walks —
    /// bounded, because a cycle the harness should never write must not spin.
    static func descends(_ id: String, from ancestor: String,
                         meta: (String) -> CodexRollout.SessionMeta?,
                         limit: Int = 16) -> Bool {
        var here = id
        var seen: Set<String> = [id.lowercased()]
        for _ in 0..<limit {
            guard let parent = meta(here)?.forkedFromId else { return false }
            if parent.caseInsensitiveCompare(ancestor) == .orderedSame { return true }
            guard seen.insert(parent.lowercased()).inserted else { return false }
            here = parent
        }
        return false
    }

    /// The lsof half, kept as its own seam so the parsing is testable without
    /// a Codex install.
    static func threadId(lsofOutput: String, locks: URL, recordedId: String? = nil,
                         meta: (String) -> CodexRollout.SessionMeta? = { _ in nil })
        -> String? {
        activeThreadId(amongHeld: heldThreadIds(lsofOutput: lsofOutput, locks: locks),
                       recordedId: recordedId, meta: meta)
    }

    /// A thread that FORKED from the recorded one holds a lock of its own.
    ///
    /// The fast path believes the recorded id because its lock file is still
    /// there, and a file is not a holder: nothing here has asked whether this
    /// pid is the process behind it. On the pane that found the fork bug
    /// Codex had dropped the parent's lock, which is what made that trade
    /// sound — but "Codex always drops it" is an observation of one release,
    /// not a guarantee, and if it ever stops being true the fast path
    /// silently serves a dead id again.
    ///
    /// This is the cheap half of the proof. `lsof` can say which lock a pid
    /// holds and costs a subprocess; a directory listing plus the memoized
    /// fork map can say that the conversation has a child holding a lock,
    /// which is evidence enough to stop trusting the file and go ask
    /// properly. It answers false for the overwhelmingly common case (no
    /// fork), so the normal path still performs no subprocess work.
    static func conversationMovedOn(from recordedId: String, locks: URL,
                                    lineage: SessionLineage.Map) -> Bool {
        guard !lineage.isEmpty else { return false }
        return CodexRollout.liveThreadIds(locks: locks).contains { id in
            id.caseInsensitiveCompare(recordedId) != .orderedSame
                && SessionLineage.origin(of: id, in: lineage)
                    .caseInsensitiveCompare(recordedId) == .orderedSame
        }
    }

    /// The entry point every caller uses, with the signature it has always
    /// had.
    ///
    /// Kept as its own function rather than folded into the one below with a
    /// defaulted argument, because a defaulted argument RENAMES the symbol:
    /// cross-module optimisation emits this default into its callers, so the
    /// app target linked against `(for:locks:sessions:)` and an incremental
    /// build that did not recompile it failed with an undefined symbol at
    /// the very last step. `swift test` never saw it — only the app bundle
    /// links. One overload costs nothing and cannot do that to anybody.
    public static func activeThreadId(
        for record: SessionOwnershipRecord,
        locks: URL = CodexRollout.threadWriterLocksDirectory,
        sessions: URL = CodexRollout.sessionsDirectory
    ) -> String? {
        activeThreadId(for: record, locks: locks, sessions: sessions,
                       lineage: { CodexLineage.scan() })
    }

    static func activeThreadId(
        for record: SessionOwnershipRecord,
        locks: URL,
        sessions: URL,
        lineage: () -> SessionLineage.Map
    ) -> String? {
        guard record.harness == CodexAdapter().id,
              UUID(uuidString: record.sessionId) != nil,
              ProcessProbe.isAlive(record.pid)
        else { return nil }

        let recordedLock = locks.appendingPathComponent(record.sessionId.lowercased() + ".lock")
        if FileManager.default.fileExists(atPath: recordedLock.path),
           !conversationMovedOn(from: record.sessionId, locks: locks, lineage: lineage()) {
            return record.sessionId
        }

        // A reused pid must not inherit an old ownership record. Every TB-
        // hosted Codex record carries the pane tty, and a mismatch is enough
        // to refuse before inspecting any files owned by the new process.
        guard let expectedTty = record.paneTty,
              let actualTty = ProcessProbe.tty(of: record.pid),
              normalizedTty(expectedTty) == normalizedTty(actualTty)
        else { return nil }

        guard case .success(let output) = Subprocess.run(
            "/usr/sbin/lsof",
            // Do not use lsof's `+d` selector here. On macOS it can print the
            // matching descriptor and still exits 1, which a bounded process
            // runner must treat as failure. Reading this one pid succeeds;
            // `threadId` performs the exact-directory filter itself.
            lsofArguments(pid: record.pid),
            timeout: 2)
        else { return nil }
        // Memoized: every `meta` read walks the rollout archive to find the
        // file for an id, and the resolution below asks about the same ids
        // more than once. Only drift ever gets here, so the cache is one
        // probe's worth and dies with it.
        var seen: [String: CodexRollout.SessionMeta?] = [:]
        let meta = { (id: String) -> CodexRollout.SessionMeta? in
            if let cached = seen[id] { return cached }
            let found = CodexRollout.meta(sessionId: id, sessions: sessions)
            seen[id] = found
            return found
        }
        return threadId(lsofOutput: output, locks: locks,
                        recordedId: record.sessionId, meta: meta)
    }

    static func normalizedTty(_ value: String) -> String {
        value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
    }

    /// Kept separate because `+d <directory>` looks like the smaller query
    /// but can exit 1 on supported macOS versions even after printing a match.
    static func lsofArguments(pid: Int) -> [String] {
        ["-p", "\(pid)", "-Fn"]
    }
}
