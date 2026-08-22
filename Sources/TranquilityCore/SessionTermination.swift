import Foundation

/// Ending a session for good — the mechanism behind the grid's Terminate.
///
/// The old shape (13 Aug) sent one `SIGTERM` and logged that it had sent it.
/// That is a receipt for a signal, not for a death, and the difference is the
/// whole feature: "end session" has to mean the process is gone, or the row you
/// just right-clicked is lying to you.
///
/// Three things measured on this machine 15 Aug, which is why this file has the
/// shape it does:
///
/// 1. `SIGTERM` is enough in the ordinary case — a probe session died inside a
///    second. The ladder starts there and stays there almost always; `SIGKILL`
///    exists for the case measurement cannot rule out, not for the common one.
///    Starting at TERM is also what keeps the session RESUMABLE: it exits clean,
///    the transcript is already appended per message, and the row comes back as
///    REVIVE having lost at most the turn in flight.
///
/// 2. `claude` leads its own process group (pid == pgid) and its MCP servers are
///    children inside it. In a Terminal.app tab the shell sits in a DIFFERENT
///    group and is the tty's session leader, so signalling the GROUP takes the
///    agent and everything it spawned, structurally incapable of reaching the
///    shell — "end the session without closing the tab" was free there, not
///    delicate, and never addressed the tab at all. Every launch is a tmux
///    pane now (ruled 21 Aug), where the pane's shell execs `claude` as its
///    last command (`/bin/zsh -c "cd … && claude …"`): ending the agent's
///    group there ends the pane's own controlling process, closing the pane
///    and the tmux session with it — not delicate either (there is no stray
///    empty pane to leave behind, and the tmux SERVER, `exit-empty off`,
///    outlives it), just a different mechanism than the paragraph above
///    describes. Reasoned from the exec chain, not independently re-measured.
///
/// 3. The liveness cache is six seconds deep, so a pid handed to us can already
///    be dead — and on a busy machine, reused. Every rung therefore re-reads the
///    process's identity immediately before it signals, and refuses if the pid is
///    no longer a Claude session. Without that guard "reliably exit the process"
///    occasionally means reliably exiting somebody else's.
///
/// The signalling is injected (`ProcessControlling`) so the ladder's decisions —
/// including the two that are invisible in production, a pid reused mid-ladder
/// and a process that survives both rungs — are asserted by `swift test` against
/// a fake rather than by killing something and hoping.
///
/// Every path here blocks while polling. Call it off-main (rule 9).
public enum SessionTermination {

    /// Same shape as `SessionLauncher.trace` / `QueueStore.trace`: Core stays
    /// silent unless a host wires the log in.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// Which rung the process died on.
    public enum Rung: String, Sendable, Equatable {
        case term = "SIGTERM"
        case kill = "SIGKILL"
    }

    /// What we address. The group when Claude leads one, the bare process when
    /// it does not — never a guess in between.
    public enum Target: Equatable, Sendable {
        /// `kill(-pgid, …)`: the agent and the MCP servers it spawned.
        case group(pgid: Int)
        /// `kill(pid, …)`: Claude is not its group's leader, so a negative-pid
        /// signal could reach further than this gesture promises.
        case process(pid: Int)
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing there when we looked. Terminating an already-dead session is
        /// success, not failure — the user asked for it gone and it is gone.
        case alreadyGone
        case died(rung: Rung, afterMs: Int, target: Target)
        /// Survived both rungs. Should be unreachable; reported rather than
        /// swallowed, because a `SIGKILL` that does not land means the process
        /// is wedged in the kernel and the honest answer is "I could not".
        case survived
        /// The identity guard said no. The pid is not ours to signal.
        case refused(String)

        public var isGone: Bool {
            switch self {
            case .alreadyGone, .died: return true
            case .survived, .refused: return false
            }
        }
    }

    /// How long each rung is given. These numbers are a preference, not a
    /// measurement: TERM has always won inside a second here, so five seconds is
    /// "long enough that a busy machine is not mistaken for a wedged one", and
    /// two seconds after KILL is "long enough to notice the kernel did not".
    public struct Policy: Sendable, Equatable {
        public var termWindow: TimeInterval
        public var killWindow: TimeInterval
        public var poll: TimeInterval

        public init(termWindow: TimeInterval, killWindow: TimeInterval, poll: TimeInterval) {
            self.termWindow = termWindow
            self.killWindow = killWindow
            self.poll = poll
        }

        public static let `default` = Policy(termWindow: 5, killWindow: 2, poll: 0.25)
    }

    /// What a pid IS right now, read fresh. `nil` from `identity(of:)` means the
    /// pid does not exist.
    public struct Identity: Equatable, Sendable {
        public var command: String
        public var pgid: Int
        public var tty: String?

        public init(command: String, pgid: Int, tty: String?) {
            self.command = command
            self.pgid = pgid
            self.tty = tty
        }

        /// The guard, stated once. `ps -o comm=` gives the executable, so a
        /// resumed or renamed session still reads `claude`, while whatever
        /// inherited a recycled pid almost certainly does not.
        public var looksLikeClaude: Bool {
            command.lowercased().contains("claude")
        }
    }

    public protocol ProcessControlling: Sendable {
        func identity(of pid: Int) -> Identity?
        /// True when the signal was delivered.
        func send(_ signal: Int32, to target: Target) -> Bool
        func waitBriefly(_ seconds: TimeInterval)
        /// Monotonic-enough milliseconds, injected so tests do not sleep.
        func nowMs() -> Int
    }

    /// End the session running as `pid`.
    ///
    /// `expectedTty` is the tty the session was seen on, when the caller knows
    /// it. It is a second lock on the same door as the command check: a recycled
    /// pid that somehow IS another `claude` would still have to be on the same
    /// terminal to be signalled.
    public static func end(
        pid: Int,
        named name: String,
        expectedTty: String? = nil,
        control: some ProcessControlling = LiveProcessControl(),
        policy: Policy = .default
    ) -> Outcome {
        let label = "\(name) (pid \(pid))"

        guard let identity = control.identity(of: pid) else {
            trace?("terminate: \(label) was already gone")
            return .alreadyGone
        }
        if let refusal = refusal(for: identity, pid: pid, expectedTty: expectedTty) {
            trace?("terminate: REFUSED \(label) — \(refusal)")
            return .refused(refusal)
        }

        // The group when Claude leads it, which is the case measured on every
        // live session here; the bare pid otherwise.
        let target: Target = identity.pgid == pid
            ? .group(pgid: pid)
            : .process(pid: pid)
        if case .process = target {
            trace?("terminate: \(label) does not lead its group (pgid \(identity.pgid)) — "
                + "signalling the process alone, so nothing outside this session is touched")
        }

        let started = control.nowMs()

        for rung in [Rung.term, Rung.kill] {
            let window = rung == .term ? policy.termWindow : policy.killWindow

            // Re-read before EVERY signal, not just the first: the whole point of
            // the ladder is that time passes between rungs, and a pid can change
            // hands in that time.
            switch state(of: pid, expectedTty: expectedTty, control: control) {
            case .gone:
                // Before the first signal this means it exited on its own between
                // the guard above and here. Before the second it means SIGTERM
                // landed after its window closed — late, but it was TERM that did
                // it, and the receipt should not credit a SIGKILL we never sent.
                guard rung == .kill else {
                    trace?("terminate: \(label) exited on its own before we signalled")
                    return .alreadyGone
                }
                let ms = control.nowMs() - started
                trace?("terminate: \(label) gone after \(ms)ms — "
                    + "\(Rung.term.rawValue) won just after its window closed")
                return .died(rung: .term, afterMs: ms, target: target)
            case .refused(let why):
                trace?("terminate: stopped before \(rung.rawValue) on \(label) — \(why)")
                return .refused(why)
            case .alive:
                break
            }

            let signal: Int32 = rung == .term ? SIGTERM : SIGKILL
            guard control.send(signal, to: target) else {
                // Delivery failed with the process still there — no permission,
                // or it exited between the check and the call. One more look
                // decides which, rather than reporting a failure that was a race.
                if case .gone = state(of: pid, expectedTty: expectedTty, control: control) {
                    let ms = control.nowMs() - started
                    trace?("terminate: \(label) gone after \(ms)ms (exited as we signalled)")
                    return .died(rung: rung, afterMs: ms, target: target)
                }
                let why = "\(rung.rawValue) could not be delivered to \(describe(target))"
                trace?("terminate: \(why)")
                return .refused(why)
            }
            trace?("terminate: \(rung.rawValue) → \(describe(target)) for \(label)")

            if let ms = pollUntilGone(pid: pid, expectedTty: expectedTty,
                                      window: window, control: control,
                                      policy: policy, since: started) {
                trace?("terminate: \(label) died on \(rung.rawValue) after \(ms)ms"
                    + (rung == .term ? " — clean exit, resumable via revive" : ""))
                return .died(rung: rung, afterMs: ms, target: target)
            }

            if rung == .term {
                trace?("terminate: \(label) still alive \(Int(policy.termWindow))s after "
                    + "\(Rung.term.rawValue) — escalating")
            }
        }

        trace?("terminate: \(label) SURVIVED both rungs — wedged in the kernel, "
            + "nothing left to send")
        return .survived
    }

    // MARK: - The guard

    private enum State {
        case gone
        case alive
        case refused(String)
    }

    /// Gone, still ours, or no longer ours. The third case is pid reuse: the
    /// process we meant to kill has died and something else answers to its
    /// number, which reads as "alive" to `kill(pid, 0)` and must not.
    private static func state(
        of pid: Int, expectedTty: String?, control: some ProcessControlling
    ) -> State {
        guard let identity = control.identity(of: pid) else { return .gone }
        guard identity.looksLikeClaude else {
            // Our process died; the pid was recycled. That IS the death we asked
            // for, and signalling further would hit a stranger.
            return .gone
        }
        if let expected = expectedTty, let actual = identity.tty, actual != expected {
            return .refused("pid \(pid) is a Claude session on \(actual), "
                + "not the one on \(expected) — refusing to signal")
        }
        return .alive
    }

    private static func refusal(
        for identity: Identity, pid: Int, expectedTty: String?
    ) -> String? {
        guard identity.looksLikeClaude else {
            return "pid \(pid) is `\(identity.command)`, not a Claude session"
        }
        if let expected = expectedTty, let actual = identity.tty, actual != expected {
            return "pid \(pid) is on \(actual), not the \(expected) this row was seen on"
        }
        return nil
    }

    /// Milliseconds since `since` when it dies inside the window; nil when it
    /// outlives it.
    private static func pollUntilGone(
        pid: Int, expectedTty: String?, window: TimeInterval,
        control: some ProcessControlling, policy: Policy, since: Int
    ) -> Int? {
        var waited: TimeInterval = 0
        while waited < window {
            control.waitBriefly(policy.poll)
            waited += policy.poll
            if case .gone = state(of: pid, expectedTty: expectedTty, control: control) {
                return control.nowMs() - since
            }
        }
        return nil
    }

    public static func describe(_ target: Target) -> String {
        switch target {
        case .group(let pgid): return "process group \(pgid)"
        case .process(let pid): return "pid \(pid)"
        }
    }
}

/// The real thing: `ps` for identity, `kill` for the signal.
public struct LiveProcessControl: SessionTermination.ProcessControlling {
    public init() {}

    /// One `ps` call for all three fields. The command comes LAST in the format
    /// string on purpose — it is the only field that can contain a space, so
    /// everything after the second column is the command and nothing has to be
    /// guessed about where it ends.
    ///
    /// Routed through `Subprocess.run` (codebase audit, 21 Aug): this is
    /// re-read before EVERY rung of the kill ladder as the pid-reuse guard,
    /// so a wedged `ps` used to block the terminating thread indefinitely —
    /// the exact unbounded-spawn shape `Subprocess` exists to close, on the
    /// one path where a hang means END SESSION never ends.
    public func identity(of pid: Int) -> SessionTermination.Identity? {
        guard case .success(let raw) = Subprocess.run(
            "/bin/ps", ["-o", "pgid=,tty=,comm=", "-p", "\(pid)"], timeout: 3)
        else { return nil }
        return Self.parse(psLine: raw)
    }

    /// Split out so the parsing is testable without a process to look at.
    static func parse(psLine raw: String) -> SessionTermination.Identity? {
        let fields = raw.split(separator: " ", maxSplits: 2,
                              omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 3, let pgid = Int(fields[0]) else { return nil }
        let tty = fields[1]
        let command = (fields[2].trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        guard !command.isEmpty else { return nil }
        return SessionTermination.Identity(
            command: command,
            pgid: pgid,
            tty: tty == "??" || tty.isEmpty
                ? nil
                : (tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"))
    }

    public func send(_ signal: Int32, to target: SessionTermination.Target) -> Bool {
        switch target {
        case .group(let pgid): return kill(pid_t(-pgid), signal) == 0
        case .process(let pid): return kill(pid_t(pid), signal) == 0
        }
    }

    public func waitBriefly(_ seconds: TimeInterval) {
        usleep(useconds_t(max(0, seconds) * 1_000_000))
    }

    public func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
