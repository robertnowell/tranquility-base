import Foundation

/// Refuses to start a SECOND process resuming a session that already has one.
///
/// Ruled 27 Aug, on measured state loss. A Claude Code transcript is a
/// singly-linked chain: every record carries the uuid of its parent, and
/// `--resume` rebuilds the conversation by walking that chain back from one
/// leaf. Two processes resuming the same id both load the chain as it stood
/// at THEIR launch, and both append from the parent they each remember. The
/// file is fine — every byte is still there — but it is now a tree, and the
/// next resume follows one branch and cannot see the other. Nothing is
/// deleted; work simply stops being reachable.
///
/// This is not theoretical and was not rare. On this machine that morning
/// three processes were resuming one session id and four more pairs existed
/// besides; across 64 transcripts, 8,443 records sat on branches no resume
/// would ever walk again — 3,982 of them in a single session, 60% of its
/// history. The trigger was ordinary: GO TO AGENT pressed twice, and a
/// revive that fired twice in one second.
///
/// Why a process scan and not the registry. `claude agents --json` is what
/// `OwnershipTransfer` already consults, and it is exactly what missed these:
/// two of the seven duplicate processes were on no tmux server and in no
/// registry, invisible to both the app's ownership table and the CLI's own
/// list, while very much alive and very much writing to the transcript. A
/// registry is a claim about what this app started; the process table is the
/// fact of what is running. Only the fact can answer "would a second writer
/// exist after this call".
///
/// Matching the SESSION ID as a needle rather than a binary name, the same
/// reasoning `ProcessProbe.pid(onTty:containing:)` states: the id appears in
/// any resume argv, for either harness (`claude --resume <id>`,
/// `codex resume <id>`), and a binary-name match would have to know every
/// spelling in advance.
public enum ResumeGuard {

    /// A live process already holding this session id.
    public struct Holder: Sendable, Equatable {
        public let pid: Int
        /// The argv as `ps` reported it, kept so a refusal can SHOW the
        /// reader what it found rather than asserting a conflict they have
        /// no way to check.
        public let command: String

        public init(pid: Int, command: String) {
            self.pid = pid
            self.command = command
        }
    }

    public enum Verdict: Error, Sendable, Equatable {
        /// No other process holds this id. Resuming creates the only writer.
        case clear
        /// At least one live process is already resuming this id. Resuming
        /// again forks the transcript.
        case alreadyResuming([Holder])

        public var holders: [Holder] {
            if case .alreadyResuming(let h) = self { return h }
            return []
        }
    }

    // MARK: - The in-flight claim

    /// A session id can only be claimed by one resume at a time, process-wide.
    ///
    /// The `ps` scan alone cannot close this. The two duplicate revives that
    /// exposed the bug were 18082 and 18103 — launched ONE SECOND apart. A
    /// scan takes ~120ms, but a tmux pane needs longer than a second to get
    /// as far as an exec'd harness, so the second call scans a table that
    /// does not show the first call's process yet, reads clear, and spawns.
    /// Two writers, both of which passed the guard honestly.
    ///
    /// So the check and the decision to spawn happen together, under one
    /// lock, and the claim is held for the whole of `resumeTmux` — which
    /// blocks while it watches for the trust prompt, long past the point
    /// where the new process is visible to anyone else's scan. The lock
    /// covers only the claim bookkeeping; the slow work happens outside it.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var inFlight: Set<String> = []

    /// Held for the duration of a resume, released when it ends.
    public final class Claim {
        let sessionId: String
        private var released = false
        init(sessionId: String) { self.sessionId = sessionId }

        public func release() {
            ResumeGuard.lock.lock()
            defer { ResumeGuard.lock.unlock() }
            guard !released else { return }
            released = true
            ResumeGuard.inFlight.remove(sessionId)
        }

        deinit { release() }
    }

    /// The atomic front door: scan and claim as one indivisible act.
    ///
    /// Returns the claim on success, or the reason a second writer would
    /// exist. Callers must hold the returned claim until the spawned process
    /// is observable — `resumeTmux` does this with a `defer`.
    public static func claim(sessionId: String, exempt: Set<Int> = []) -> Result<Claim, Verdict> {
        guard !sessionId.isEmpty else { return .success(Claim(sessionId: sessionId)) }
        lock.lock()
        if inFlight.contains(sessionId) {
            lock.unlock()
            SessionLauncher.trace?("resume guard: \(sessionId.prefix(8)) is already being "
                + "resumed by a call still in flight — refusing the second")
            return .failure(.alreadyResuming([]))
        }
        // Claimed BEFORE the scan is released, so no second caller can slip
        // between the scan and the insert.
        inFlight.insert(sessionId)
        lock.unlock()

        let verdict = check(sessionId: sessionId, exempt: exempt)
        if case .alreadyResuming = verdict {
            lock.lock()
            inFlight.remove(sessionId)
            lock.unlock()
            return .failure(verdict)
        }
        return .success(Claim(sessionId: sessionId))
    }

    /// Ask the process table directly.
    ///
    /// `exempt` is for the one caller that legitimately expects to find a
    /// corpse: `OwnershipTransfer` ENDS the hand-started process and then
    /// resumes it, and `ps` can still list a pid for a moment after
    /// `SessionTermination.end` has confirmed it gone. Without the exemption
    /// the transfer would refuse to restart the very session it just closed
    /// — the 24 Aug failure shape, reintroduced by its own fix.
    public static func check(sessionId: String, exempt: Set<Int> = []) -> Verdict {
        // A short id is not a needle, it is a wildcard. Real session ids are
        // uuids; anything shorter cannot be matched against a command line
        // without hitting unrelated processes by coincidence (a test using
        // "x" as an id matched most of the process table). Below the
        // threshold there is nothing meaningful to check.
        guard sessionId.count >= 8 else { return .clear }
        guard case .success(let raw) = Subprocess.run(
            "/bin/ps", ["-axo", "pid=,command="], timeout: 5)
        else {
            // A scan that could not run is not evidence of absence. Reporting
            // `.clear` here would turn every `ps` hiccup into a licence to
            // double-spawn, which is the exact outcome this exists to stop —
            // so an unreadable process table reads as "cannot rule it out".
            SessionLauncher.trace?("resume guard: could not read the process table for "
                + "\(sessionId.prefix(8)) — treating as contended rather than clear")
            return .alreadyResuming([])
        }
        return classify(psOutput: raw, sessionId: sessionId,
                        exempt: exempt.union([Int(ProcessInfo.processInfo.processIdentifier)]))
    }

    /// Pure half, testable against captured `ps` text with no live process
    /// table — the same read-it/decide-it split `ProcessProbe.matchPid` and
    /// `TmuxOwnership.match` already keep.
    static func classify(psOutput: String, sessionId: String, exempt: Set<Int>) -> Verdict {
        guard sessionId.count >= 8 else { return .clear }
        var holders: [Holder] = []
        for line in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[trimmed.startIndex..<spaceIdx])
            else { continue }
            let command = String(trimmed[trimmed.index(after: spaceIdx)...])
            guard command.contains(sessionId), !exempt.contains(pid) else { continue }
            guard !isTmuxServer(command) else { continue }
            guard runsAHarness(command) else { continue }
            holders.append(Holder(pid: pid, command: command))
        }
        return holders.isEmpty ? .clear : .alreadyResuming(holders)
    }

    /// The tmux SERVER keeps the argv of the `new-session` that started it,
    /// forever — including the `--resume <id>` it was asked to run. Left
    /// unfiltered, the first resume of a session would poison every later
    /// one: the server outlives the pane, so the guard would find "a process
    /// holding this id" for the rest of the app's life and no session could
    /// ever be revived again. Measured on this machine: pid 3636, alive since
    /// 09:53, still advertising a `--resume` for a pane that had long exited.
    ///
    /// Matched on the executable's basename, not a substring of the whole
    /// line — `/opt/homebrew/bin/tmux` and a bare `tmux` are both the server,
    /// while a harness resuming inside a pane whose CWD merely contains the
    /// word is not.
    static func isTmuxServer(_ command: String) -> Bool {
        guard let first = command.split(separator: " ", maxSplits: 1,
                                        omittingEmptySubsequences: true).first
        else { return false }
        return (first as NSString).lastPathComponent == "tmux"
    }

    /// Does this process actually RUN a harness, or does it merely mention
    /// the id?
    ///
    /// Mentioning is common and completely innocent: `grep <id> *.jsonl`, a
    /// `cat` of the transcript, an editor with the file open, or — the case
    /// that caught this before it shipped — a wrapper shell whose argv
    /// carries a heredoc containing the id. Every one of those would have
    /// been counted as a live writer by a bare substring match, and the
    /// consequence is not cosmetic: the guard would refuse to revive a
    /// session for as long as that unrelated process lived, which is the
    /// same "GO TO AGENT does nothing" failure it exists to prevent, merely
    /// arrived at from the other side.
    ///
    /// A TOKEN whose basename is the harness's own command, not a substring
    /// of the line. The distinction is load-bearing: the false positive that
    /// exposed this contained the text "claude" four times — in
    /// `/Users/robertnowell/.claude/shell-snapshots/...` — while running no
    /// harness at all. Its basename was `snapshot-zsh-….sh`, so basename
    /// matching rejects it and a `contains("claude")` would not.
    ///
    /// The fragments come from the adapters (`processCommandFragment`, which
    /// `ProcessProbe` already leans on) rather than a list spelled here, so
    /// a harness added later is covered by adding it in one place.
    static func runsAHarness(_ command: String) -> Bool {
        let fragments = KnownHarnesses.all.map(\.processCommandFragment)
        for token in command.split(separator: " ", omittingEmptySubsequences: true) {
            // Strip the shell quoting a launch line carries ('--resume').
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let base = (bare as NSString).lastPathComponent
            if fragments.contains(base) { return true }
        }
        return false
    }

    /// What the refusal says out loud. One sentence of consequence, then the
    /// pids, because "already running" without an address is a dead end for
    /// anyone trying to get to their session.
    ///
    /// No em dash: this string reaches a card, and `Drills.copyDrill` sweeps
    /// rendered labels for exactly that character (ruled 18 Aug). The dash
    /// still earns its keep in the trace line one frame up, which is a log.
    public static func refusal(sessionId: String, holders: [Holder]) -> String {
        let where_ = holders.isEmpty
            ? "the process table could not be read, so a second writer cannot be ruled out"
            : "already running as " + holders.map { "pid \($0.pid)" }.joined(separator: ", ")
        return "\(sessionId.prefix(8)) is \(where_). Resuming it again would fork its "
            + "transcript and strand one branch, so nothing was started."
    }
}
