import Foundation

/// The one function that starts the process of an agent that has none.
///
/// Ruled 14 Nov 2026 (`docs/rulings/ruling-one-start-function-and-no-open-agents-file.md`):
/// every door calls this, and nothing that starts a process is written
/// beside it. The doors are the revive tap, Go to Agent, a reply, the open
/// microphone, and `tbase revive`.
///
/// It exists because the reply's first version (`GoneStart`, 11 Nov)
/// repeated the tap's gates and missed one. `ResumeGuard.claim` reads only
/// `inFlight`; the tap's own reservation lives in `intents`. A tap followed
/// by a reply could both proceed, and the reply then showed a false
/// "Couldn't start" card. Two doors with two definitions of "gone" is how
/// one of them starts a second process.
///
/// **What every caller now gets, in this order.**
/// 1. The intent reservation. A second caller for the same id answers
///    `.joined` and starts nothing.
/// 2. A fresh discovery, and the row's own harness.
/// 3. Proof the process is gone. No proof answers `.running` or `.unknown`,
///    and neither starts anything. A failed probe is never an empty machine.
/// 4. The launch record (`verifiedCurrent`), for every caller. A process
///    this app launched does not carry its id in its command line, so the
///    process scan cannot see it in the window where the registry drops it.
/// 5. The harness's own way to start, chosen by what the harness can do
///    (`registersWithLiveness`), not by its name.
/// 6. One wait for the process to register, the same length for everybody.
///
/// The caller keeps only what is its own: the tap its announcements, the
/// reply its send.
public enum AgentStart {

    /// Which door asked. It rides the one result event, so a falling count
    /// of taps can be read against a rising count of replies.
    public enum Via: String, Sendable {
        case tap
        case goToAgent = "go_to_agent"
        case reply
        case microphone
        case cli
    }

    /// How a started process came to be running.
    public enum How: String, Sendable, Equatable {
        /// `SessionLauncher.resume` started it in a new pane.
        case resumed
        /// The harness's own attach (`attemptCodexResume`) took it.
        case attached
        /// It was running all along and this app had lost its address.
        case adopted
    }

    public enum Refusal: Sendable, Equatable {
        /// No transcript on disk for the id.
        case notOnDisk
        /// The directory it would land in is gone.
        case directoryGone
        /// It runs somewhere this app does not control, on the harness's own
        /// evidence (Codex's single-writer lock).
        case liveElsewhere
        /// The harness came up and exited without resuming. Its last screen,
        /// when one was captured, holds the reason.
        case exited(lastScreen: String?)
        /// The start itself failed. `worthRetrying` is the launcher's own.
        case failed(message: String, worthRetrying: Bool, harness: String)
    }

    public enum Outcome: Sendable, Equatable {
        /// It has a process already. Nothing was started.
        case running
        /// A process was started. `pid` is nil when it never registered
        /// inside the wait: it is up, in `pane`, and not answering.
        case started(how: How, pane: TmuxPaneAddress?, pid: Int?, cwd: String)
        /// Another caller in this app is starting it right now. Nothing was
        /// started here. That caller reports; this one may wait (`settle`).
        case joined
        /// The pane came up and stopped on a screen only a person answers.
        /// It is alive and it is not resumed. Never type into it.
        case waitingOnQuestion(says: String, screen: String, pane: TmuxPaneAddress)
        /// A process holds the id and the registry does not list it.
        case heldBy([ResumeGuard.Holder], cwd: String)
        /// No proof either way: a probe could not be read. Nothing started.
        case unknown(String)
        /// Proven gone, and it cannot be started.
        case refused(Refusal, cwd: String?)

        /// The outcome word the one result event carries.
        public var word: String {
            switch self {
            case .running: return "already_running"
            case .started(_, _, let pid, _): return pid == nil ? "started_unregistered" : "started"
            case .joined: return "joined"
            case .waitingOnQuestion: return "waiting_on_question"
            case .heldBy: return "held_by_unregistered_process"
            case .unknown: return "unknown"
            case .refused: return "refused"
            }
        }
    }

    /// How long any caller waits for a started process to register. One
    /// number: the tap used 8 s and the reply's first version used 30 s.
    /// Measured 12 Nov on Claude Code 2.1.322: the registry listed a new
    /// process within 0.38 s, in 4 of 4 tries, with a 10 MB transcript.
    public static let registrationWait: TimeInterval = 8

    /// Everything this reads from the machine, so a test decides.
    public struct Witness: Sendable {
        public var discover: @Sendable (_ sessionId: String) -> SessionDiscovery.Session?
        /// Does this harness list its live processes in a registry?
        public var registers: @Sendable (_ harness: String) -> Bool
        public var ownsLiveProcess: @Sendable (_ sessionId: String) -> Bool
        /// A harness process in this directory that no registry or launch
        /// record accounts for. Asked only for a start nobody tapped for.
        public var stranger: @Sendable (_ directory: String, _ harness: String) -> ResumeGuard.Holder?
        public var resume: @Sendable (_ sessionId: String, _ directory: String)
            -> Result<TmuxPaneAddress, ScriptError>
        public var attach: @Sendable (_ sessionId: String, _ directory: String)
            -> Result<SessionLauncher.CodexResumeOutcome, ScriptError>
        public var adopt: @Sendable (_ sessionId: String, _ directory: String) -> TmuxPaneAddress?
        /// Blocks up to `registrationWait` for the id to show a live pid.
        public var awaitPid: @Sendable (_ sessionId: String) -> Int?

        public init(
            discover: @escaping @Sendable (String) -> SessionDiscovery.Session?,
            registers: @escaping @Sendable (String) -> Bool = {
                KnownHarnesses.adapter(for: $0).capabilities.registersWithLiveness
            },
            ownsLiveProcess: @escaping @Sendable (String) -> Bool,
            stranger: @escaping @Sendable (String, String) -> ResumeGuard.Holder? = { _, _ in nil },
            resume: @escaping @Sendable (String, String) -> Result<TmuxPaneAddress, ScriptError>,
            attach: @escaping @Sendable (String, String)
                -> Result<SessionLauncher.CodexResumeOutcome, ScriptError>,
            adopt: @escaping @Sendable (String, String) -> TmuxPaneAddress? = { _, _ in nil },
            awaitPid: @escaping @Sendable (String) -> Int?
        ) {
            self.discover = discover
            self.registers = registers
            self.ownsLiveProcess = ownsLiveProcess
            self.stranger = stranger
            self.resume = resume
            self.attach = attach
            self.adopt = adopt
            self.awaitPid = awaitPid
        }

        /// The real machine. Blocks for as long as the launcher does (the
        /// trust-prompt watch, up to ~30 s) plus the wait; call off-main.
        public static let live = Witness(
            discover: { id in
                // Fresh first. The wider cached list second, for a Codex id
                // a zero-ttl pass did not carry (the tap's own fallback).
                SessionDiscovery.discover(ttl: 0).sessions.first { $0.sessionId == id }
                    ?? SessionDiscovery.discover().sessions.first { $0.sessionId == id }
            },
            ownsLiveProcess: { id in
                FileSessionOwnershipStore.shared.verifiedCurrent(sessionId: id) != nil
            },
            stranger: { directory, harness in
                UnregisteredProcess.inDirectory(directory, harness: harness)
            },
            resume: { id, directory in
                SessionLauncher.resume(sessionId: id, directory: directory,
                                       launch: HarnessLaunch.forExistingSession(id))
            },
            attach: { id, directory in
                SessionLauncher.attemptCodexResume(sessionId: id, directory: directory)
            },
            adopt: { id, directory in
                SessionLauncher.adoptRunningCodex(sessionId: id, cwd: directory)
            },
            awaitPid: { id in
                let deadline = Date().addingTimeInterval(AgentStart.registrationWait)
                repeat {
                    if let pid = ((ClaudeAgentsCLI().sessions() ?? [])
                        + FileSessionOwnershipStore.shared.liveNonRegistrySessions())
                        .first(where: { $0.sessionId == id })?.pid { return pid }
                    Thread.sleep(forTimeInterval: 0.4)
                } while Date() < deadline
                return nil
            })
    }

    /// Make sure the agent has a process.
    ///
    /// - `unasked`: true when no person tapped for this start (a reply, the
    ///   microphone). Such a start also refuses to begin beside a harness
    ///   process in the same directory that nothing accounts for. A person's
    ///   tap is not held to that, because the person can see the terminal.
    /// - `willStart`: called once, just before the launch, and only when a
    ///   launch will happen. The tap announces here; the reply plays a sound.
    public static func ensureRunning(
        sessionId: String,
        unasked: Bool,
        witness: Witness = .live,
        willStart: @Sendable () -> Void = {}
    ) -> Outcome {
        guard ResumeGuard.beginIntent(sessionId) else { return .joined }
        defer { ResumeGuard.endIntent(sessionId) }

        guard let found = witness.discover(sessionId) else {
            return .refused(.notOnDisk, cwd: nil)
        }
        let registers = witness.registers(found.harness)
        if registers {
            switch found.liveness {
            case .live: return .running
            case .unknown: return .unknown("the registry could not be read")
            case .gone: break
            }
        }
        // A process this app launched and can still see is not gone,
        // whatever the registry said this second. For a harness with no
        // registry this record is the only word on liveness there is.
        guard !witness.ownsLiveProcess(sessionId) else { return .running }

        guard found.revivable, let cwd = SessionDiscovery.landingDirectory(for: found.cwd) else {
            return .refused(.directoryGone, cwd: found.cwd)
        }
        if unasked, let stranger = witness.stranger(cwd, found.harness) {
            return .heldBy([stranger], cwd: cwd)
        }

        willStart()
        return registers
            ? resume(sessionId, in: cwd, harness: found.harness, witness: witness)
            : attach(sessionId, in: cwd, harness: found.harness, witness: witness)
    }

    private static func resume(_ sessionId: String, in cwd: String, harness: String,
                               witness: Witness) -> Outcome {
        switch witness.resume(sessionId, cwd) {
        case .success(let pane):
            return .started(how: .resumed, pane: pane, pid: witness.awaitPid(sessionId), cwd: cwd)
        case .failure(let error):
            // Another call in this app holds the claim. One start, two waiters.
            if error.duplicateResume { return .joined }
            if !error.alreadyRunning.isEmpty { return .heldBy(error.alreadyRunning, cwd: cwd) }
            // The process table could not be read. That is no proof of
            // anything, and it must never reach a person as a refusal.
            if error.scanUnreadable { return .unknown("the process table could not be read") }
            return .refused(.failed(message: error.message, worthRetrying: error.worthRetrying,
                                    harness: harness), cwd: cwd)
        }
    }

    private static func attach(_ sessionId: String, in cwd: String, harness: String,
                               witness: Witness) -> Outcome {
        let outcome = witness.attach(sessionId, cwd)
        if case .success(.attached) = outcome {
            return .started(how: .attached, pane: nil, pid: witness.awaitPid(sessionId), cwd: cwd)
        }
        // A pane on a question is not a session to adopt (11 Sep: adopted as
        // RESUMED, the next dictation chose "Update now").
        if case .success(.stoppedOnPrompt(let says, let screen, let pane)) = outcome {
            return .waitingOnQuestion(says: says, screen: screen, pane: pane)
        }
        // Every remaining answer may mean "already running". Find it first.
        if let pane = witness.adopt(sessionId, cwd) {
            return .started(how: .adopted, pane: pane, pid: witness.awaitPid(sessionId), cwd: cwd)
        }
        switch outcome {
        case .success(.alreadyLive):
            return .refused(.liveElsewhere, cwd: cwd)
        case .success(.exitedWithoutResuming(let lastScreen)):
            return .refused(.exited(lastScreen: lastScreen), cwd: cwd)
        case .failure(let error):
            if error.scanUnreadable { return .unknown("the process table could not be read") }
            return .refused(.failed(message: error.message, worthRetrying: error.worthRetrying,
                                    harness: harness), cwd: cwd)
        case .success(.attached), .success(.stoppedOnPrompt):
            return .unknown("the attach answered twice")   // unreachable: both returned above
        }
    }

    /// Wait for another caller's start of this id to finish. Returns false
    /// when it is still in flight at the deadline.
    public static func settle(_ sessionId: String, within seconds: TimeInterval = 45) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while ResumeGuard.isInFlight(sessionId) {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    // MARK: - What a reply needs from the answer

    /// The reply's three questions: go on and wait for it, go on as before,
    /// or stop and keep the words.
    public enum ForReply: Sendable, Equatable {
        /// A start was made. `registered` is the answer of the one wait
        /// (`registrationWait`): the reply never waits for it a second time.
        case started(TmuxPaneAddress?, registered: Bool)
        /// No proof the process is gone. Dispatch goes on as it did before.
        case notGone(String)
        /// It cannot be started. The words are kept; the sentence is the card's.
        case refused(String)
    }

    /// For a caller that will wait: when another door was already starting
    /// the id, wait for that start to finish and look once more.
    public static func ensureRunningJoining(
        sessionId: String, unasked: Bool, witness: Witness = .live,
        willStart: @Sendable () -> Void = {}
    ) -> Outcome {
        let first = ensureRunning(sessionId: sessionId, unasked: unasked,
                                  witness: witness, willStart: willStart)
        guard first == .joined, settle(sessionId) else { return first }
        return ensureRunning(sessionId: sessionId, unasked: unasked,
                             witness: witness, willStart: willStart)
    }
}

extension AgentStart.Outcome {
    public var forReply: AgentStart.ForReply {
        switch self {
        case .running: return .notGone("its process is running")
        case .started(_, let pane, let pid, _): return .started(pane, registered: pid != nil)
        // Another door still held the id after `settle`. Nothing proves a
        // process is up, so the reply keeps its words and says so.
        case .joined: return .started(nil, registered: false)
        case .waitingOnQuestion(let says, _, _):
            return .refused("it is waiting on a question in its terminal. \(says)")
        case .heldBy: return .notGone("a process already holds it")
        case .unknown(let why): return .notGone(why)
        case .refused(let refusal, _):
            switch refusal {
            case .notOnDisk: return .notGone("no transcript on disk for it")
            case .directoryGone: return .refused("its directory is gone")
            case .liveElsewhere: return .notGone("it is running somewhere this app does not control")
            case .exited(let lastScreen):
                return .refused(lastScreen.map { SessionLauncher.pointOfFailure(in: $0) }
                                ?? "it exited without resuming")
            case .failed(let message, _, _): return .refused(message)
            }
        }
    }
}

/// A harness process in an agent's directory that nothing accounts for.
///
/// Measured 12 Nov 2026 on Claude Code 2.1.322: an agent started by hand
/// (`claude`, `claude -c`) never has its session id in its command line, so
/// `ResumeGuard`'s scan cannot see it. The registry listed it within 0.38 s.
/// A process standing on a dialog before it registers could not be
/// reproduced, so that window is not measured. This is the guard for it.
public enum UnregisteredProcess {
    public static func inDirectory(_ directory: String, harness: String) -> ResumeGuard.Holder? {
        guard case .success(let ps) = Subprocess.run(
            "/bin/ps", ["-axo", "pid=,command="], timeout: 5) else { return nil }
        let accounted = Set((ClaudeAgentsCLI().sessions() ?? []).map(\.pid)
            + FileSessionOwnershipStore.shared.liveNonRegistrySessions().map(\.pid))
        let candidates = harnessProcesses(psOutput: ps, harness: harness)
            .filter { !accounted.contains($0.pid) }
        guard !candidates.isEmpty,
              case .success(let lsof) = Subprocess.run(
                "/usr/sbin/lsof",
                ["-a", "-d", "cwd", "-Fpn", "-p", candidates.map { String($0.pid) }.joined(separator: ",")],
                timeout: 5)
        else { return nil }
        let here = Set(pids(lsofOutput: lsof, in: directory))
        return candidates.first { here.contains($0.pid) }
    }

    /// Pure half: the processes whose first token is the harness's own
    /// command. A process that only mentions the name is not one.
    static func harnessProcesses(psOutput: String, harness: String) -> [ResumeGuard.Holder] {
        let fragment = KnownHarnesses.adapter(for: harness).processCommandFragment
        let own = Int(ProcessInfo.processInfo.processIdentifier)
        return psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[..<space]), pid != own else { return nil }
            let command = String(trimmed[trimmed.index(after: space)...])
            guard let first = command.split(separator: " ").first,
                  (String(first) as NSString).lastPathComponent == fragment else { return nil }
            return ResumeGuard.Holder(pid: pid, command: command)
        }
    }

    /// Pure half: `lsof -Fpn` prints `p<pid>` then `n<path>` for each process.
    static func pids(lsofOutput: String, in directory: String) -> [Int] {
        let want = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        var current: Int?
        var found: [Int] = []
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = current,
                    URL(fileURLWithPath: String(line.dropFirst())).resolvingSymlinksInPath().path == want {
                found.append(pid)
            }
        }
        return found
    }
}
