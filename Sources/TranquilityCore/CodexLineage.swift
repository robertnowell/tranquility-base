import Foundation

/// A Codex fork is the same conversation under a new id.
///
/// Editing an earlier prompt in the Codex TUI opens a new thread and writes
/// `forked_from_id` on it. What it does NOT do is copy the conversation:
/// measured on the fork of 13 Sep, the child rollout opens at ordinal 6537
/// with the edited prompt and holds 258 lines, while the 6,537 records before
/// it stay in the parent's file for ever. Codex itself replays the parent on
/// resume — the TUI shows an unbroken conversation — so the split is
/// invisible until something reads history BY ID, which is what every hub,
/// grid row and turn list in this app does.
///
/// So a fork must join its parent the way a Claude Code continuation already
/// does (`SessionLineage`), or the conversation's history begins at the
/// prompt that was edited. Ruled 13 Sep: two hubs for one conversation is
/// tolerable; a hub that has lost the days before the edit is not.
///
/// The link is on the CHILD, which makes the map cheaper to build than Claude
/// Code's: no tail read, no guessing which file continues which. It is also
/// the same field a sub-agent carries, so `thread_source` does the excluding
/// — a sub-agent is a different conversation that happens to have a parent,
/// and folding eleven of them into one hub would bury the thing they were
/// spawned to help with.
public enum CodexLineage {

    /// One rollout's `(id, forked_from_id)`, or nil when it is not a fork of
    /// a conversation. Pure over a meta so the rule is testable without files.
    static func link(_ meta: CodexRollout.SessionMeta?) -> (child: String, parent: String)? {
        guard let meta, !meta.isSubagent,
              let parent = meta.forkedFromId, !parent.isEmpty,
              parent.caseInsensitiveCompare(meta.sessionId) != .orderedSame
        else { return nil }
        return (meta.sessionId, parent)
    }

    /// Every fork link on disk, in `SessionLineage.Map`'s own shape
    /// (continuation → what it continues), ready to merge with it.
    ///
    /// Memoized per file, not per scan. A rollout's first line is written
    /// once and never changes, so a file read once is never read again; only
    /// rollouts that appeared since the last scan cost anything. Without
    /// that, this is 296 head reads on this machine every time the cache
    /// expires, on a question whose answer cannot change.
    public static func scan(sessions: URL = CodexRollout.sessionsDirectory)
        -> SessionLineage.Map {
        guard let walker = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [:] }
        var map: SessionLineage.Map = [:]
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let link = memo.link(for: url) else { continue }
            map[link.child] = link.parent
        }
        return map
    }

    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        /// Absent = never read. Present-and-nil = read, and not a fork.
        private var known: [String: (child: String, parent: String)?] = [:]

        func link(for url: URL) -> (child: String, parent: String)? {
            lock.lock()
            if let cached = known[url.path] { lock.unlock(); return cached }
            lock.unlock()
            let found = CodexLineage.link(CodexRollout.meta(rollout: url))
            lock.lock(); known[url.path] = found; lock.unlock()
            return found
        }
    }
    private static let memo = Memo()
}
