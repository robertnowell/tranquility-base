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
    /// A single held writer lock is an answer. No lock and several locks are
    /// both ambiguity, never an invitation to choose the newest one.
    static func threadId(lsofOutput: String, locks: URL) -> String? {
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
        return ids.count == 1 ? ids.first : nil
    }

    public static func activeThreadId(
        for record: SessionOwnershipRecord,
        locks: URL = CodexRollout.threadWriterLocksDirectory
    ) -> String? {
        guard record.harness == CodexAdapter().id,
              UUID(uuidString: record.sessionId) != nil,
              ProcessProbe.isAlive(record.pid)
        else { return nil }

        let recordedLock = locks.appendingPathComponent(record.sessionId.lowercased() + ".lock")
        if FileManager.default.fileExists(atPath: recordedLock.path) {
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
        return threadId(lsofOutput: output, locks: locks)
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
