import Foundation

/// Who was live last tick and is not now: the agents that left on their own.
///
/// Parallel to `LampWatch`, and deliberately as small: a pure diff over the
/// set of live agents. `LampWatch` turns a disappearance into an
/// `agent_lamp_changed to="gone"` for the record. `ExitWatch` turns the same
/// disappearance into the fact the app then acts on (read the dead pane, say
/// what killed it, reap it), but only for agents that vanished spontaneously.
///
/// It carries no tmux and files no report. It is fed the live set and hands
/// back the ids that left, with the last-known tmux session name so the caller
/// can find the corpse. Whether a corpse still EXISTS is the caller's test and
/// the whole safety story: a session ended on purpose disarms `remain-on-exit`
/// and self-closes, so it leaves no corpse and never reaches a report. See
/// `SessionLauncher.postMortem` / `disarmRemainOnExit`.
///
/// Seeded like `LampWatch`: the first `observe` only records the baseline and
/// returns nothing, so the app starting up (or this watch being constructed)
/// mid-life does not report every already-running agent as freshly dead.
public struct ExitWatch: Sendable {

    /// One agent that was present last call and is absent now.
    public struct Vanished: Sendable, Equatable {
        public let id: String
        public let harness: String
        /// The tmux session that ran it, if one was ever resolved while it was
        /// alive. `nil` means there is nowhere to look for a corpse, so the
        /// caller has nothing to read and nothing to reap.
        public let sessionName: String?
        public let secondsAlive: Int
    }

    private struct Seen {
        var harness: String
        var sessionName: String?
        var since: Date
    }

    private var seen: [String: Seen] = [:]
    private var seeded = false

    public init() {}

    /// Feed every currently-live agent. Returns the ones present last call and
    /// absent now. `sessionName` may be `nil` on any given call (the caller
    /// resolves it lazily), so the earliest non-nil name seen for an id is
    /// carried forward, and `since` is kept from the first sighting so
    /// `secondsAlive` is the process's life, not the time in its last state.
    public mutating func observe(
        _ live: [(id: String, harness: String, sessionName: String?)],
        now: Date = Date()
    ) -> [Vanished] {
        var current: [String: Seen] = [:]
        current.reserveCapacity(live.count)
        for a in live {
            if let prior = seen[a.id] {
                current[a.id] = Seen(harness: a.harness,
                                     sessionName: a.sessionName ?? prior.sessionName,
                                     since: prior.since)
            } else {
                current[a.id] = Seen(harness: a.harness, sessionName: a.sessionName, since: now)
            }
        }
        // `seen` is still last call's map here. Reassign only on the way out,
        // after the diff below has read it.
        defer { seen = current; seeded = true }
        guard seeded else { return [] }
        var out: [Vanished] = []
        for (id, prior) in seen where current[id] == nil {
            out.append(Vanished(id: id, harness: prior.harness,
                                sessionName: prior.sessionName,
                                secondsAlive: max(0, Int(now.timeIntervalSince(prior.since)))))
        }
        return out
    }
}
