import Foundation

/// Starting the process of an agent that has none, because a reply is on its
/// way to it.
///
/// Ruled 11 Nov 2026: "if I go to interact with them and it's not alive, then
/// it revives it, and then sends the message. The user shouldn't have to care
/// about that." Measured before building: 83 revives requested by hand in 36
/// days, every one of them a step the person took only so that the next thing
/// they did would work, and a reply to an agent with no process was refused
/// with "can't take this yet".
///
/// **This is the tap, called by the reply.** The gates are the revive door's
/// own, in the same order (`AppDelegate.revive`): a fresh discovery, the
/// row's own harness, `reviveCommand`, then `SessionLauncher.resume` with its
/// `ResumeGuard` claim. Nothing here is a second opinion about what "gone"
/// means; two definitions of gone is how one of them starts a second process.
///
/// **It answers three ways, and only one of them starts anything.**
/// `notGone` is every case where this function has no proof: the session is
/// live, the witness did not answer, the harness is not one this step covers,
/// or a process already holds the id. Dispatch then does exactly what it did
/// before this existed. A failed probe must never read as an empty machine
/// here: `agents.sessions() ?? []` in dispatch cannot tell the two apart, and
/// discovery can (`liveness == .unknown`).
public enum GoneStart {
    public enum Outcome: Sendable, Equatable {
        /// A process was started for the id, in this pane. `nil` when this
        /// app was already starting one (the tap got there first) and the
        /// pane is that caller's to report. The caller waits for the process
        /// to register either way.
        case started(TmuxPaneAddress?)
        /// No proof the process is gone. The caller goes on as before.
        case notGone(String)
        /// Proven gone, and it cannot be started. The words are kept; the
        /// reason is the sentence the card shows.
        case refused(String)
    }

    /// Everything this reads from the machine, so a test decides.
    public struct Witness: Sendable {
        public var discover: @Sendable (_ sessionId: String) -> SessionDiscovery.Session?
        public var ownsLiveProcess: @Sendable (_ sessionId: String) -> Bool
        public var resume: @Sendable (_ sessionId: String, _ directory: String)
            -> Result<TmuxPaneAddress, ScriptError>

        public init(
            discover: @escaping @Sendable (String) -> SessionDiscovery.Session?,
            ownsLiveProcess: @escaping @Sendable (String) -> Bool,
            resume: @escaping @Sendable (String, String) -> Result<TmuxPaneAddress, ScriptError>
        ) {
            self.discover = discover
            self.ownsLiveProcess = ownsLiveProcess
            self.resume = resume
        }

        /// The real machine. Blocks for as long as `SessionLauncher.resume`
        /// does (the trust-prompt watch, up to ~30 s); call off-main.
        public static let live = Witness(
            discover: { id in
                SessionDiscovery.discover(ttl: 0).sessions.first { $0.sessionId == id }
            },
            ownsLiveProcess: { id in
                FileSessionOwnershipStore.shared.verifiedCurrent(sessionId: id) != nil
            },
            resume: { id, directory in
                SessionLauncher.resume(sessionId: id, directory: directory,
                                       launch: HarnessLaunch.forExistingSession(id))
            })
    }

    /// Claude Code only. A Codex id answers `notGone`: its resume has a
    /// different proof of readiness (`attemptCodexResume`'s `.attached`) and
    /// two hazards this path does not guard yet, so it keeps the tap.
    public static func claude(sessionId: String, witness: Witness = .live) -> Outcome {
        guard let found = witness.discover(sessionId) else {
            return .notGone("no transcript on disk for it")
        }
        guard found.harness == ClaudeCodeAdapter().id else {
            return .notGone("not a Claude Code session")
        }
        switch found.liveness {
        case .live: return .notGone("its process is running")
        case .unknown: return .notGone("the registry could not be read")
        case .gone: break
        }
        // A process this app launched and can still see is not gone, whatever
        // the registry said this second. A new agent can register and briefly
        // drop out before it has taken any input (measured 19 Aug); the
        // launch record is the witness for that window.
        guard !witness.ownsLiveProcess(sessionId) else {
            return .notGone("a process this app launched still holds it")
        }
        guard let command = found.reviveCommand else {
            return .refused("its directory is gone")
        }
        switch witness.resume(sessionId, command.cwd) {
        case .success(let pane):
            return .started(pane)
        case .failure(let error):
            // The tap is already bringing it back. One resume, two waiters.
            if error.duplicateResume { return .started(nil) }
            // A process holds the id and the registry does not list it: it is
            // standing on a dialog. That is the old refusal's own case.
            if !error.alreadyRunning.isEmpty {
                return .notGone("a process already holds it")
            }
            return .refused(error.message)
        }
    }
}
