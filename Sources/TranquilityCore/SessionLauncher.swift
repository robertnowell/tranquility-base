import AppKit
import Foundation

/// Spawn a fresh Claude session in a detached tmux pane (ruled 21 Aug — see
/// `launch()` below; `launchTerminal`, the Terminal.app path this replaced,
/// is deleted, not kept as a second one).
///
/// The dispatch loop is reactive by construction — sessions announce, the user
/// answers. This is the proactive half (ruled 05 Aug): "sometimes I want to
/// kick off an investigation." v1 is deliberately choiceless: always `claude`,
/// always `--dangerously-skip-permissions`, always the home directory. The two
/// knobs worth a UI (directory, agent command) arrive with the grid's
/// new-session affordance; adding options before the habit exists is furniture.
///
/// Lives in Core so `tbase new` and the app's menu item are the same code
/// path. `resume` (reviving a dead session) is routed through `resumeTmux`
/// (22 Aug) — see its own doc comment for why the Terminal.app/Automation
/// path it used until then is gone, not merely bypassed.
/// A harness and the command that starts it, resolved together.
///
/// These were two independently-defaulted parameters — `command:` defaulting
/// to the app-wide DEFAULT LAUNCHER setting, `adapter:` hardcoded to
/// `ClaudeCodeAdapter()` — on `launchTmux`, `resumeTmux`, `resume` and
/// `manualRevival`. Any caller that passed neither got the default harness's
/// BINARY with Claude Code's FLAGS, and the two only agreed while the default
/// launcher happened to be Claude Code.
///
/// It stopped agreeing the day the setting was changed to Codex. GO TO AGENT
/// ended a live Claude Code session and tried to resume it as
/// `codex --dangerously-bypass-approvals-and-sandbox --resume <id>` — Codex's
/// binary, Claude Code's flag spelling, rejected outright — so the pane died
/// in a second, and the rescue command copied to the clipboard was the same
/// impossible string. One session ended, nothing restarted, and the offered
/// remedy could not run.
///
/// Fixing the two call sites would have left the footgun loaded for the next
/// one; there were seven more signatures carrying the same pair. So the pair
/// is gone: one harness id in, both values out, and disagreement is no longer
/// something a caller can express.
public struct HarnessLaunch: Sendable {
    public let adapter: any HarnessAdapter
    public let command: String

    /// Both halves from one id — the only way to build one, unless a caller
    /// genuinely needs a command the settings do not hold (see below).
    public init(harness: String) {
        self.adapter = KnownHarnesses.adapter(for: harness)
        self.command = AgentDefaults.load(for: harness)
    }

    /// An explicit pair, for the one caller that runs a bare binary rather
    /// than the configured launch command (`attemptCodexResume`, which needs
    /// `codex` without the settings' flags). Still built from an adapter, so
    /// the flags and the binary still come from the same harness.
    public init(adapter: any HarnessAdapter, command: String) {
        self.adapter = adapter
        self.command = command
    }

    /// The Settings default, for a NEW agent, which by definition has no
    /// session of its own to take a harness from.
    public static var settingsDefault: HarnessLaunch {
        HarnessLaunch(harness: AgentDefaults.defaultHarness)
    }

    /// The harness an EXISTING session belongs to, from disk.
    ///
    /// Codex records every session as a rollout file named after its id, so
    /// the presence of one is positive evidence and its absence is positive
    /// evidence the other way — the same disk fact `revive` already leans on
    /// when `SessionDiscovery` comes up empty. Deliberately not the Settings
    /// default: what a NEW agent would be has nothing to do with what THIS
    /// session is, and confusing the two is what ended a live session.
    public static func forExistingSession(_ sessionId: String) -> HarnessLaunch {
        let isCodex = CodexRollout.rolloutPath(forSessionId: sessionId) != nil
        return HarnessLaunch(harness: isCodex ? CodexAdapter().id : ClaudeCodeAdapter().id)
    }
}

public enum SessionLauncher {

    /// Same shape as Coordinator.trace / QueueStore.trace: Core stays silent
    /// unless a host wires the log in.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// Where a NEW agent starts. A setting since 15 Aug — see AgentDefaults.
    public static var defaultDirectory: String { AgentDefaults.directory() }
    /// The configured launch command, one setting for every path that starts an
    /// agent — see `AgentCommand`. Was a constant until 12 Aug, when revival
    /// became a second launch path and the two disagreed about permissions.
    public static var defaultCommand: String { AgentDefaults.load() }

    /// Opens a detached tmux pane in `directory` running `command`, and — by
    /// explicit ruling — clicks through Claude's own directory-trust prompt if
    /// it appears.
    ///
    /// Robert, 05 Aug, verbatim intent: "I authorize you to click through and
    /// start this. I told you to start the session. Start the session." The
    /// consent happened at the button press; the prompt is asking permission
    /// for the thing the user just commanded. The scope is surgical and stays
    /// that way: ONLY the pane this call just created (addressed by its tty),
    /// ONLY the known trust prompt, ONLY within thirty seconds of launch. The
    /// dispatcher's rule — never type into unregistered sessions — is intact
    /// everywhere else; this pane is not "some session", it is our own launch.
    ///
    /// Blocks while watching for the prompt — ~4s in the common case (two
    /// settled polls), up to ~30s if the session never looks started; call
    /// off-main.
    /// Returns the new pane's tty, so a caller can watch exactly this session.
    ///
    /// Nothing is activated or brought forward — the pane exists on the app's
    /// own tmux server with no window anywhere until someone asks for one
    /// (`tmux attach`). Starting an agent is a background act; the panel is
    /// the interface, and the whole point of the greeting is that you never
    /// have to look at the pane. `resume`, below, is the opposite by design:
    /// a revived session asks a question (summary or full context) that only
    /// you can answer, so it activates a Terminal window for that one turn.
    ///
    /// History, kept because it explains a shape still visible in the tmux
    /// path (one pane per agent, never a shared window someone else's reply
    /// could land in): before 21 Aug this opened a Terminal.app WINDOW, ruled
    /// 18 Aug because Terminal.app cannot script a new TAB (`do script …
    /// in window 1` types into that window's SELECTED tab, not a fresh one)
    /// and the only mechanism that works, ⌘T via System Events, needs
    /// Terminal frontmost — "that's brittle and is gonna break," scoped,
    /// costed, and refused. tmux has no such constraint (`new-session` always
    /// creates fresh), which is part of why the launch path moved there.
    @discardableResult
    public static func launch(
        directory: String = defaultDirectory,
        launch: HarnessLaunch = .settingsDefault,
        acceptTrustPrompt: Bool = true
    ) -> Result<String, ScriptError> {
        // Ruled 21 Aug: no flags, no parallel launch paths. A launch is a
        // detached tmux session on the app's own server, full stop — the
        // opt-in this replaced (`tbase tmux on`, 19-21 Aug) is gone along
        // with the setting behind it, and `launchTerminal`, the Terminal.app
        // launch path it used to choose between, is deleted outright rather
        // than left as an unreachable second path. `resume` (below) still
        // opens a Terminal.app window for a REVIVED session — a separate,
        // not-yet-decided piece of this same cleanup; see its doc comment.
        launchTmux(directory: directory, launch: launch,
                   acceptTrustPrompt: acceptTrustPrompt)
    }

    /// The tmux launch path: a detached session on the app's own server, no
    /// window anywhere until someone asks for one (`tmux attach`). Validated
    /// live before it was written: registration as kind interactive, trust
    /// prompt answered through capture-pane, 100/100 exact-once deliveries
    /// (2026-08-19-tb-tmux-transport-validation and -delivery-protocol-proof).
    ///
    /// The command runs with an explicitly constructed environment — a
    /// GUI-launched app's env is minimal, tmux panes start login shells whose
    /// /etc/zprofile reorders PATH, and a reused server propagates almost
    /// nothing (the trap claude-squad hit as issue #278). Nothing here trusts
    /// inheritance. PATH is sourced from the adapter's own
    /// `pathCandidates` (23 Aug) — not a single generic list hand-copied
    /// here regardless of which harness is being launched, since different
    /// harnesses' install methods put a binary in different places.
    @discardableResult
    static func launchTmux(
        directory: String,
        launch: HarnessLaunch,
        acceptTrustPrompt: Bool
    ) -> Result<String, ScriptError> {
        let command = launch.command
        let adapter = launch.adapter
        let name = "tb-" + String(UUID().uuidString.prefix(8)).lowercased()
        let path = adapter.pathCandidates.joined(separator: ":")

        // `-P -F` prints the new pane's tty as part of THIS command's own
        // output, atomically with creation — not a separate query run
        // afterward. That second query used to be a `display-message` call
        // here, and it raced: measured live, 23 Aug, on a real machine
        // straight out of a reboot, the FIRST pane this socket directory
        // ever hosted answered `new-session` successfully and then
        // `display-message`, run immediately after, came back an empty
        // string (success, not a subprocess failure) for the exact same
        // pane. `-P -F` has nothing to race against — tmux cannot report a
        // pane's tty in the same breath that creates it without the tty
        // already existing — so this removes the failure mode at its root
        // instead of retrying around it.
        let tty: String
        switch Tmux.run([
            "new-session", "-d", "-s", name, "-x", "220", "-y", "50",
            "-c", directory, "-P", "-F", "#{pane_tty}",
            "-e", "PATH=\(path)",
            "-e", "LANG=en_US.UTF-8",
            // PATH is exported INSIDE the command, not only through `-e`.
            // Measured 24 Aug against tmux 3.7b, after four launches in six
            // minutes died within a second of being reported successful: a
            // pane inherits the tmux CLIENT's environment, and `-e` sets only
            // the SESSION environment, which the pane never reads. The
            // session env showed the right PATH the whole time; the pane saw
            // `/usr/bin:/bin:/usr/sbin:/sbin`, the app's own, and `claude` is
            // not on it. Every pane exited 127, `command not found: claude`.
            //
            // The app's PATH is exactly the variable here, which is why this
            // failure is invisible in development: launched by relaunch.sh
            // from a shell, the app inherits a developer's PATH and the pane
            // works by accident. Launched by Finder or launchd — a GUI app's
            // normal life — it inherits the four-entry system PATH and every
            // launch dies. The same build did both, seventeen minutes apart.
            //
            // `-e` stays: it is the correct record of the session's intended
            // environment and `tbase` reads it. It is simply not the thing
            // the pane obeys, so it cannot be the only place the fact lives.
            "/bin/zsh", "-c", Self.paneCommand(path: path, directory: directory, command: command),
        ], socket: Tmux.socketName, timeout: 10) {
        case .failure(let error):
            Self.trace?("newSession(tmux) FAILED: \(error.message)")
            return .failure(error)
        case .success(let printed):
            let trimmed = printed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Never measured, but the same guard the retry-based fix
                // had: a session with no addressable tty is worse than none
                // at all (TmuxOwnership.pane(forTty:) can never find it
                // again either), so it gets torn down rather than orphaned.
                Tmux.run(["kill-session", "-t", name], socket: Tmux.socketName)
                return .failure(ScriptError(
                    message: "tmux session \(name) reported no pane tty — killed it"))
            }
            tty = trimmed
        }
        // Server posture, set AFTER new-session because a server only exists
        // once it hosts something — `set -s` against no server fails silently
        // and the default (exit-empty on) then takes the whole server down
        // with its last session, which is exactly what happened on the first
        // live termination test. Idempotent, so every launch re-asserts it.
        Tmux.run(["set", "-s", "exit-empty", "off"], socket: Tmux.socketName)
        Tmux.run(["set", "-t", name, "window-size", "manual"], socket: Tmux.socketName)
        Tmux.run(["set", "-t", name, "mouse", "on"], socket: Tmux.socketName)

        Self.trace?("newSession: launched `\(command)` in \(directory) "
            + "(tmux \(name), tty \(tty))")

        // A launch is not a launch until the pane is still there. Ruled 24
        // Aug: the panel spoke "RESUMED" over four corpses in six minutes,
        // because `new-session` printing a tty was the whole success test
        // and a pane that exits 127 prints one on its way out. The app
        // already knew — `pane(forTty:)` came back empty a second later and
        // the miss was logged as a note about the trust watcher having
        // nothing to watch. That query is promoted here from a watcher
        // precondition to the launch's success condition, which is what it
        // always was.
        //
        // `remain-on-exit` is armed for the length of this check so a
        // failure leaves its own reason behind rather than vanishing — the
        // 24 Aug diagnosis needed the dead pane's exit status and its one
        // line of stderr, and neither exists without this. Disarmed on the
        // success path so live panes never linger as corpses.
        Tmux.run(["set", "-t", name, "remain-on-exit", "on"], socket: Tmux.socketName)
        if let failure = Self.survivalFailure(session: name, tty: tty) {
            Tmux.run(["kill-session", "-t", name], socket: Tmux.socketName)
            Self.trace?("newSession: \(name) died on launch — \(failure.reason)")
            return .failure(ScriptError(message: failure.reason,
                                        worthRetrying: failure.worthRetrying))
        }
        Tmux.run(["set", "-t", name, "remain-on-exit", "off"], socket: Tmux.socketName)

        if acceptTrustPrompt { watchForTrustPrompt(tty: tty, adapter: adapter) }
        return .success(tty)
    }

    /// Resume any adaptable session in a fresh detached tmux pane — the one
    /// mechanism both harness-specific adoption strategies need underneath,
    /// whatever their policy differences: Claude Code's dual-live twin
    /// (spawn a TB-owned pane alongside a foreground process the user never
    /// asked TB to touch, original left running — 2026-08-21-tb-dual-live-
    /// harness-parity) and Codex's graceful-end-then-resume (spawn only
    /// AFTER the original process has exited, since Codex's app-server
    /// refuses a second writer with -32600). The policy — whether anything
    /// gets asked to end first, whose approval that needs — belongs to the
    /// caller, same division `resume` already draws for Terminal.app: this
    /// function is the mechanism, not the policy.
    ///
    /// Shares `launchTmux`'s server posture and trust-watching rather than
    /// re-deriving them; the only difference is the argv — `command` PLUS
    /// the adapter's own resume arguments, built through `resumeArguments`
    /// like `resume` and `SessionDiscovery.reviveCommand` already are, never
    /// a hand-built suffix (the exact duplication M2 collapsed — a second
    /// copy here would reopen it for the tmux leg specifically).
    ///
    /// An adapter returning `[]` is a programmer error, not a shape to
    /// render around, same reasoning `resume` uses: refuses loudly before
    /// any tmux call, rather than spawning a pane running a command with
    /// nothing to resume.
    @discardableResult
    public static func resumeTmux(
        sessionId: String,
        directory: String,
        launch: HarnessLaunch,
        acceptTrustPrompt: Bool = true
    ) -> Result<String, ScriptError> {
        let adapter = launch.adapter
        let command = launch.command
        let resumeArgs = adapter.resumeArguments(sessionId: sessionId)
        guard !resumeArgs.isEmpty else {
            Self.trace?("resumeTmux: \(adapter.id) adapter returned no resume arguments "
                + "for \(sessionId.prefix(8)) — refusing rather than spawning a pane with "
                + "nothing to resume")
            return .failure(ScriptError(message: "\(adapter.id) adapter: empty resume arguments"))
        }
        // Quoted individually, same discipline as `directory` a few lines
        // into `launchTmux`: a resume argument reaches here from data (a
        // session id read out of a filename, or — for Codex — out of a
        // rollout's own JSON, which is not guaranteed shell-safe just
        // because it looks like a uuid), not from a constant, and it lands
        // in the same raw `/bin/zsh -c "..."` string `directory` does.
        let quotedArgs = resumeArgs.map(Self.shellQuoted)
        let fullCommand = ([command] + quotedArgs).joined(separator: " ")
        return launchTmux(directory: directory,
                          launch: HarnessLaunch(adapter: adapter, command: fullCommand),
                          acceptTrustPrompt: acceptTrustPrompt)
    }

    /// Single-quote wrapping, the shell's own escape for "trust nothing
    /// inside this": embedded single quotes close the quote, insert an
    /// escaped literal one, and reopen it. The one implementation —
    /// `launchTmux`'s directory quoting used to be a second, identical copy
    /// of this exact expression; collapsed here rather than reintroduced
    /// for `resumeTmux`'s arguments. Not `private`: pinned directly by a
    /// test, the way a security-relevant string transform earns.
    /// The line a human can paste into their own terminal to bring this
    /// session back, when the app's own launcher cannot.
    ///
    /// The point is that it does NOT go through anything this app owns. It
    /// runs in the user's shell, with the user's PATH and the user's
    /// environment — which is exactly the axis the 24 Aug failure lived on,
    /// where every in-app launch died and this line would have worked all
    /// morning. Deliberately without the pane's PATH export: a human's shell
    /// already has one, and a command you are asked to trust should be short
    /// enough to read.
    public static func manualRevival(
        sessionId: String,
        directory: String,
        launch: HarnessLaunch
    ) -> String {
        let adapter = launch.adapter
        let command = launch.command
        // Quote only what needs it. A human has to read this line and decide
        // whether to trust it before pasting it, and a line where every token
        // wears quotes — `codex 'resume' 'abc'` — reads like something is
        // being hidden. An argument made only of characters a shell treats as
        // ordinary is already literal, so quoting adds nothing but noise;
        // anything else keeps its quotes, which is where they matter.
        let plain = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@%+=-")
        let args = adapter.resumeArguments(sessionId: sessionId).map { arg in
            !arg.isEmpty && arg.unicodeScalars.allSatisfy(plain.contains) ? arg : shellQuoted(arg)
        }
        return (["cd \(shellQuoted(directory)) &&", command] + args).joined(separator: " ")
    }

    /// What the pane's shell is actually asked to run. Pulled out of the argv
    /// so a test can pin it: the PATH export is the whole 24 Aug fix, and the
    /// argv it lives in cannot be asserted against without a tmux server.
    static func paneCommand(path: String, directory: String, command: String) -> String {
        "export PATH=\(shellQuoted(path)); cd \(shellQuoted(directory)) && "
            + "\(nativeArchPrefix)\(command)"
    }

    /// `arch -arm64 `, or nothing.
    ///
    /// Measured 25 Aug, from inside a pane TB had launched: `arch` answered
    /// `i386` and `uname -m` answered `x86_64` on an Apple Silicon Mac. The
    /// pane was running under Rosetta, and so was the agent in it, and so was
    /// everything that agent then built. `preflight.sh` inside such a pane
    /// fails on the XCTest bundle with "incompatible architecture (have
    /// 'arm64', need 'x86_64')" — a failure it already has a named check for,
    /// which means this has bitten before and was read as a local mystery.
    ///
    /// The cause is inherited, not chosen: this machine's Homebrew lives in
    /// /usr/local and is the INTEL one (`brew config` reports macOS
    /// `26.5.1-x86_64`, `Rosetta 2: true`, and an 18-core "westmere" — that
    /// is Rosetta describing an M-series chip). `tmux` came from there, the
    /// tmux SERVER is therefore x86_64, and every pane it forks inherits the
    /// translation. Nothing in TB ever asked for Intel: `Tmux.locateBinary`
    /// prefers /opt/homebrew/bin/tmux, the Apple Silicon path, and only falls
    /// back to /usr/local because on this machine the first does not exist.
    ///
    /// So the correction belongs at the point where TB starts the AGENT,
    /// which is the process whose architecture actually matters and the one
    /// thing here TB owns. `arch -arm64` re-execs it natively no matter what
    /// the server is, and on an already-native pane it is a pass-through.
    /// Verified live before it was written: the composed command runs
    /// `claude --version` natively out of a translated shell, and a nested
    /// shell under it reports `arm64`.
    ///
    /// Compile-time, on the app's own architecture, because that is the one
    /// question with a certain answer here — an app built for arm64 is
    /// running on a Mac that has it. A missing `/usr/bin/arch` would be a
    /// broken macOS install, but it costs one stat to not bet on that, and a
    /// wrong bet here is a pane that cannot start at all.
    static var nativeArchPrefix: String {
        #if arch(arm64)
        FileManager.default.isExecutableFile(atPath: "/usr/bin/arch") ? "arch -arm64 " : ""
        #else
        ""
        #endif
    }

    /// Why the pane this launch just made is not running, or nil when it is.
    ///
    /// Two questions, because a pane can fail in two shapes and they read
    /// differently to whoever gets the message: a pane that is GONE never
    /// reached the inventory (the session collapsed with it), and a pane that
    /// is DEAD is still addressable and can say what killed it. The second is
    /// the one that carried `command not found: claude`, and it only exists
    /// because `remain-on-exit` is armed around this check.
    ///
    /// Polls rather than asking once: the failing case measured at under a
    /// second, but a healthy claude takes a beat to draw, and a check that
    /// raced would turn a working launch into a reported failure — strictly
    /// worse than the bug it replaces. Three looks over ~600ms, and a pane
    /// still present at the end is a launch. Blocks; `launchTmux` already
    /// documents itself as an off-main call.
    static func survivalFailure(session name: String, tty: String)
        -> (reason: String, worthRetrying: Bool)? {
        var lastSeen: (dead: Bool, status: String)?
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            guard case .success(let out) = Tmux.run(
                ["list-panes", "-t", name, "-F", "#{pane_dead}\t#{pane_dead_status}"],
                socket: Tmux.socketName, timeout: 3),
                let line = out.split(separator: "\n").first
            else { lastSeen = nil; continue }
            let parts = line.split(separator: "\t", maxSplits: 1,
                                   omittingEmptySubsequences: false).map(String.init)
            lastSeen = (dead: parts.first == "1", status: parts.count > 1 ? parts[1] : "")
            if lastSeen?.dead == false { return nil }
            break
        }
        guard let seen = lastSeen else {
            // tmux never delivered a pane we could address. Nothing was
            // observed to refuse anything, so a second attempt is a fair ask.
            return ("tmux session \(name) (tty \(tty)) was gone within a second of launching — "
                + "its pane never reached the server's inventory", true)
        }
        let reason = Self.lastLine(ofPane: name)
        let status = seen.status.isEmpty ? "unknown" : seen.status
        // The command ran and exited on its own terms. Same command, same
        // environment, same status — retrying is a loop, not a repair.
        return ("the launched command exited immediately (status \(status))"
            + (reason.isEmpty ? "" : ": \(reason)"), false)
    }

    /// The last thing a dead pane printed — the whole point of arming
    /// `remain-on-exit`. Empty when there is nothing to read, which is a
    /// worse message but never a wrong one.
    private static func lastLine(ofPane name: String) -> String {
        guard case .success(let out) = Tmux.run(
            ["capture-pane", "-p", "-J", "-S", "-", "-t", name],
            socket: Tmux.socketName, timeout: 3)
        else { return "" }
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty && !$0.hasPrefix("Pane is dead") }) ?? ""
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Ends a hand-started (non-tmux) process and resumes it fresh under
    /// tmux — ONE mechanism, shared by every interaction that used to leave
    /// a hand-started session dual-live: `Coordinator.dispatch`'s own
    /// `resumeTwin` (typing into it) and, as of 23 Aug, GO TO AGENT
    /// (bringing it forward). Ruled 23 Aug, blunt and explicit: no parallel
    /// human+tmux session, ever — every interaction with a hand-started
    /// session transfers it, unconditionally, not just the first dispatch.
    ///
    /// `directory` is resolved from the live session's own `cwd` when the
    /// caller does not already have it in hand (`Coordinator.dispatch`
    /// does, from its own `live` lookup; GO TO AGENT does not, and asking
    /// it to re-derive one would duplicate the exact lookup this function
    /// already has to make to find the pid to end).
    public enum OwnershipTransfer {

        /// What a transfer actually did — and specifically whether it ENDED
        /// the hand-started process before whatever went wrong.
        ///
        /// Ruled 24 Aug, on a transfer that killed a live session and then
        /// told its owner "Nothing was closed." Every failure used to return
        /// nil, so the one message written for the case where nothing had
        /// happened yet was also the message for the case where the process
        /// was already dead. That is not a wording problem: the sentence sent
        /// the reader to look for a session in a terminal that no longer had
        /// one, and it is the difference between "try again" and "your work
        /// is in the transcript, revive it".
        public enum Outcome: Sendable {
            /// Under tmux, addressable, with a fresh pid.
            case moved(pane: TmuxPaneAddress, pid: Int)
            /// Nothing was signalled and nothing was ended. The session is
            /// wherever it was, still running.
            case refused(String)
            /// The hand-started process was ended cleanly and the resumed
            /// pane did not come up. The conversation is intact on disk and
            /// revivable; the process is not coming back on its own.
            case endedButNotRestarted(String, worthRetrying: Bool, manualRevival: String)

            public var moved: (pane: TmuxPaneAddress, pid: Int)? {
                if case .moved(let pane, let pid) = self { return (pane, pid) }
                return nil
            }
        }

        /// The transfer, with its outcome stated rather than collapsed to nil.
        /// `launch` is REQUIRED, and has no default on purpose. A transfer
        /// ends a live session before it resumes it, so getting the harness
        /// wrong here does not fail harmlessly — it kills an agent and cannot
        /// bring it back. A caller must say which harness it is acting on;
        /// there is no sensible guess, and the guess this used to make (the
        /// Settings default) is what ended a Claude Code session and tried to
        /// resume it with Codex on 26 Aug.
        public static func attempt(
            sessionId: String,
            launch: HarnessLaunch,
            directory: String? = nil,
            agents: any ClaudeAgentsReading = ClaudeAgentsCLI()
        ) -> Outcome {
            let live = (agents.sessions() ?? []).first(where: { $0.sessionId == sessionId })
            guard let resolvedDirectory = directory ?? live?.cwd else {
                let why = "no directory to resume into — neither the caller nor a live lookup "
                    + "supplied one"
                SessionLauncher.trace?("transfer: \(sessionId.prefix(8)) \(why)")
                return .refused(why)
            }
            // Positive evidence of death before resuming, per `resume`'s own
            // requirement — a session already gone (no `live`) needs no
            // ending, it is simply the first-ever resume for this id.
            var ended = false
            if let live {
                let outcome = SessionTermination.end(
                    pid: live.pid, named: sessionId, expectedTty: ProcessProbe.tty(of: live.pid))
                guard outcome.isGone else {
                    let why = "refused to end its hand-started process (\(outcome))"
                    SessionLauncher.trace?("transfer: \(sessionId.prefix(8)) \(why) — "
                        + "not resuming under tmux")
                    return .refused(why)
                }
                ended = true
            }
            // Past this line the old process is gone, so every remaining
            // failure is `endedButNotRestarted` — the caller must not be
            // told nothing happened.
            func failed(_ why: String, worthRetrying: Bool = true) -> Outcome {
                SessionLauncher.trace?("transfer: \(sessionId.prefix(8)) \(why)")
                guard ended else { return .refused(why) }
                // The process is gone and this app could not bring it back, so
                // the only recovery worth offering is the one that does not run
                // through this app at all.
                return .endedButNotRestarted(
                    why, worthRetrying: worthRetrying,
                    manualRevival: SessionLauncher.manualRevival(
                        sessionId: sessionId, directory: resolvedDirectory, launch: launch))
            }
            let resumed = resumeTmux(sessionId: sessionId, directory: resolvedDirectory,
                                     launch: launch)
            guard case .success(let tty) = resumed else {
                guard case .failure(let error) = resumed else {
                    return failed("could not start a tmux pane to resume into")
                }
                return failed("could not start a tmux pane to resume into — \(error.message)",
                              worthRetrying: error.worthRetrying)
            }
            guard let pane = TmuxOwnership.pane(forTty: tty)
            else { return failed("the resumed pane (\(tty)) is not on any live tmux server") }
            guard let pid = (agents.sessions() ?? []).first(where: { $0.sessionId == sessionId })?.pid
            else { return failed("resumed under tmux but hasn't reappeared in agents --json yet") }
            return .moved(pane: pane, pid: pid)
        }

        /// The optional-shaped answer, for the two callers that route the
        /// same way whatever went wrong (`Coordinator.dispatch`'s resumeTwin
        /// and `tbase dispatch`, which both fall through to their own
        /// no-pane refusal).
        public static func toTmux(
            sessionId: String,
            launch: HarnessLaunch,
            directory: String? = nil,
            agents: any ClaudeAgentsReading = ClaudeAgentsCLI()
        ) -> (pane: TmuxPaneAddress, pid: Int)? {
            attempt(sessionId: sessionId, launch: launch,
                    directory: directory, agents: agents).moved
        }
    }

    /// What actually happened when TB tried to bring a Codex session under
    /// its control via `attemptCodexResume`. `resumeTmux` alone only
    /// confirms a PANE came up — not whether the resume itself succeeded,
    /// since a losing `codex resume <id>` does not exit immediately
    /// (`CodexAdapter.resumeConflictNeedle`'s doc comment has the measured
    /// detail); "the pane exists" is not evidence of anything here.
    public enum CodexResumeOutcome: Sendable, Equatable {
        /// The resume succeeded; TB now owns this session's pid, on the
        /// same footing as any session it launched itself.
        case attached(tty: String)
        /// Codex's own single-writer lock refused a second writer. The
        /// session is live somewhere TB does not control — resolved design
        /// (2026-08-22-tb-codex-hand-started-adoption): TB signals nothing
        /// to it, the caller asks the human to end it in their own
        /// terminal, then retries.
        case alreadyLive
    }

    /// Pure half of `attemptCodexResume`'s poll loop, testable against
    /// captured screens without a live tmux pane — the same split
    /// `TmuxTransport.classifyPromptLine` already keeps between reading a
    /// screen and deciding what it means.
    enum CodexResumePoll: Equatable {
        case alreadyLive
        case attached
        case inconclusive
    }

    static func classifyCodexResumeScreen(_ text: String, settledNeedle: String?) -> CodexResumePoll {
        if text.contains(CodexAdapter.resumeConflictNeedle) { return .alreadyLive }
        if let settledNeedle, text.contains(settledNeedle) { return .attached }
        return .inconclusive
    }

    /// Attempts to bring a Codex session under TB's control, and reads
    /// Codex's OWN answer rather than trusting the spawn alone — the
    /// resolved design in full: no pid is ever guessed at, TB simply tries
    /// the resume and reports whichever of the two real outcomes actually
    /// happens.
    ///
    /// Two real bugs, both caught only by running this against a genuinely
    /// live conflicting session (22 Aug), not by reasoning about the
    /// measured error text alone:
    ///
    /// 1. `command` must be passed explicitly as `"codex"`. `resumeTmux`'s
    ///    own default is `defaultCommand` (`AgentDefaults.load()`), a
    ///    Claude-Code-specific, user-configurable setting — leaving it off
    ///    launches `claude resume <id>`, not `codex resume <id>`. The first
    ///    run of this function hit Claude Code's own directory-trust prompt
    ///    instead of Codex's resume-conflict screen, because that is
    ///    genuinely what it ran.
    ///
    /// 2. A losing `codex resume <id>` does NOT keep its error visible for
    ///    several seconds. Timed precisely (0.25s samples): the process,
    ///    and with it the only window in its tmux session, is gone within
    ///    under a second — confirmed twice. An earlier pass through this
    ///    same investigation concluded the opposite ("stays open for
    ///    several seconds") from a manual capture that turned out to have
    ///    its own trailing `sleep` propping the pane open after codex had
    ///    already exited — an artifact of the measuring harness, not real
    ///    Codex behavior, and wrong to have generalized from. Polling
    ///    screen text on a ~1s interval, as the first version of this
    ///    function did, reliably missed the whole window: it would not
    ///    even take its first sample until after the pane was already gone.
    ///    The reliable signal is therefore PANE SURVIVAL through a short
    ///    grace window, checked tightly (`deathCheckInterval`/
    ///    `deathCheckCount`, ~3s by default) — not matched screen text,
    ///    which is kept only as a defense-in-depth bonus in phase two below
    ///    for whatever fraction of cases it happens to still be visible in.
    ///
    /// `resumeTmux` is called with `acceptTrustPrompt: false`: its usual
    /// path (`watchForTrustPrompt`) has no needle for a resume-conflict
    /// screen and would burn its own ~30s budget waiting for something
    /// that, per the above, is gone in under a second — consuming the one
    /// window this function needs before its own polling even starts. This
    /// function's phase two covers trust needles itself instead.
    ///
    /// Neither phase reaching a conclusive answer within its budget is
    /// reported as a failure, never silently read as success — the same
    /// "typing fails CLOSED" doctrine `DispatchTransport` already applies
    /// to injecting into a session TB cannot verify.
    ///
    /// Blocks up to `(deathCheckInterval * deathCheckCount) +
    /// (settlePollInterval * settleMaxPolls)` seconds (~23s by default);
    /// call off-main, same contract `resume` already carries.
    @discardableResult
    public static func attemptCodexResume(
        sessionId: String,
        directory: String,
        adapter: CodexAdapter = CodexAdapter(),
        deathCheckInterval: TimeInterval = 0.25,
        deathCheckCount: Int = 12,
        settlePollInterval: TimeInterval = 1.0,
        settleMaxPolls: Int = 20,
        ownership: any SessionOwnershipStore = FileSessionOwnershipStore.shared
    ) -> Result<CodexResumeOutcome, ScriptError> {
        switch resumeTmux(sessionId: sessionId, directory: directory,
                          launch: HarnessLaunch(adapter: adapter, command: "codex"),
                          acceptTrustPrompt: false) {
        case .failure(let error):
            return .failure(error)
        case .success(let tty):
            guard let pane = TmuxOwnership.pane(forTty: tty) else {
                // Already gone before we even looked — the fastest possible
                // shape of the same signal phase one polls for below.
                Self.trace?("attemptCodexResume: \(sessionId.prefix(8)) had no pane immediately "
                    + "after spawn — already live elsewhere")
                return .success(.alreadyLive)
            }

            // Phase one: does the pane survive the grace window at all?
            for _ in 0..<deathCheckCount {
                usleep(UInt32(deathCheckInterval * 1_000_000))
                if case .failure = Tmux.run(["has-session", "-t", pane.sessionName],
                                            socket: pane.socketName, timeout: 2) {
                    Self.trace?("attemptCodexResume: \(sessionId.prefix(8)) exited within "
                        + "\(deathCheckInterval * Double(deathCheckCount))s — already live elsewhere")
                    return .success(.alreadyLive)
                }
            }

            // Phase two: survived the grace window — wait for it to
            // actually settle (or handle a trust prompt on the way).
            let spec = adapter.trustPrompt
            for _ in 0..<settleMaxPolls {
                usleep(UInt32(settlePollInterval * 1_000_000))
                guard case .success(let text) = Tmux.run(
                    ["capture-pane", "-p", "-t", pane.paneId], socket: pane.socketName, timeout: 3)
                else {
                    // Exited late, past the fast-death window checked
                    // above — still the same verdict: an ordinary
                    // interactive resume does not otherwise exit on its own.
                    Self.trace?("attemptCodexResume: \(sessionId.prefix(8)) exited during "
                        + "settle-wait — already live elsewhere")
                    return .success(.alreadyLive)
                }
                if let spec, spec.neverAutoAcceptNeedles.contains(where: { text.contains($0) }) {
                    Self.trace?("attemptCodexResume: \(sessionId.prefix(8)) needs a human "
                        + "choice (hook review or similar); standing down")
                    return .failure(ScriptError(
                        message: "attemptCodexResume: \(sessionId.prefix(8)) needs a human choice"))
                }
                switch Self.classifyCodexResumeScreen(text, settledNeedle: spec?.settledBannerNeedle) {
                case .alreadyLive:
                    Self.trace?("attemptCodexResume: \(sessionId.prefix(8)) already live elsewhere "
                        + "(conflict text matched)")
                    return .success(.alreadyLive)
                case .attached:
                    // The real agent pid, not tmux's own `#{pane_pid}` —
                    // see `ProcessProbe.pid(onTty:containing:)`'s doc
                    // comment for why the two can differ and why a needle
                    // match, not a prefix match, is what finds it correctly.
                    // A miss (nil) records nothing, on purpose: a record
                    // whose pid this function does not actually trust is
                    // exactly what `verifiedCurrent` exists to refuse later
                    // anyway, so there is no point writing one now.
                    if let pid = ProcessProbe.pid(onTty: tty, containing: sessionId) {
                        ownership.record(SessionOwnershipRecord(
                            sessionId: sessionId, harness: adapter.id, pid: pid,
                            paneId: pane.paneId, socketName: pane.socketName,
                            sessionName: pane.sessionName, paneTty: pane.paneTty,
                            cwd: directory))
                    } else {
                        Self.trace?("attemptCodexResume: \(sessionId.prefix(8)) attached but "
                            + "its real pid could not be found on \(tty) — pane recorded, "
                            + "pid-based liveness checks on this record will fail closed")
                    }
                    Self.trace?("attemptCodexResume: \(sessionId.prefix(8)) attached")
                    return .success(.attached(tty: tty))
                case .inconclusive:
                    if let spec, spec.promptNeedles.contains(where: { text.contains($0) }) {
                        Tmux.run(["send-keys", "-t", pane.paneId, "Enter"], socket: pane.socketName)
                        Self.trace?("attemptCodexResume: \(sessionId.prefix(8)) accepted the "
                            + "trust prompt on resume")
                    }
                    continue
                }
            }
            let waited = Int(settlePollInterval * Double(settleMaxPolls))
            return .failure(ScriptError(message: "attemptCodexResume: \(sessionId.prefix(8)) "
                + "survived the death check but never settled within \(waited)s"))
        }
    }

    /// Bring a session that has exited back, in its own directory.
    ///
    /// Ruled 11 Aug: an agent does not stop existing when its process ends, and
    /// its history should be reachable rather than merely readable. `--resume`
    /// is the whole mechanism — Claude Code keeps the conversation under the
    /// same id and appends to the same transcript, verified across 30 days of
    /// this machine's archive (no two transcripts share a message uuid), so the
    /// row that comes back is the row that left rather than a copy of it.
    ///
    /// The caller must have positive evidence the session is GONE. Resuming one
    /// that is still running leaves the original process alive and adds a
    /// second live entry under the same id, which crashed the app twice (06 Aug
    /// 14:35, 07 Aug 17:39, the second eighteen seconds after a resume). The
    /// guard lives at the call site because that is where liveness is known;
    /// this function is the mechanism, not the policy.
    ///
    /// Accepts the directory-trust prompt, exactly as `launch` does.
    ///
    /// Routed through `resumeTmux` (22 Aug), not the AppleScript/Terminal.app
    /// path this used until today. That path existed for one real reason,
    /// stated once and worth keeping: a resume of a long session offers
    /// "resume from summary" or "resume full session as-is," the full option
    /// "will consume a substantial portion of your usage limits," and a
    /// revived session sitting on that question with no visible window would
    /// be a lamp lying about being ready. Two things closed that gap without
    /// needing a visible window at all: `WaitingAt.resumePrompt` (ruled 19
    /// Aug) already surfaces this exact dialog in the grid's own lamp state,
    /// read from `claude agents --json` — which reports it identically
    /// whether the process sits in Terminal.app or a tmux pane — so the
    /// human is never left staring at a false-green row. And `TerminalTabFocus`
    /// (fixed 22 Aug, same day) is now a working "go look at it" door for a
    /// tmux pane specifically, where none existed before. Terminal.app's
    /// `activate` was this function's only way to guarantee visibility before
    /// today; it no longer is the only way, so it is no longer the right way.
    ///
    /// Blocks up to ~30s while watching; call off-main.
    @discardableResult
    public static func resume(
        sessionId: String,
        directory: String,
        launch: HarnessLaunch,
        acceptTrustPrompt: Bool = true
    ) -> Result<String, ScriptError> {
        // The tty travels back out, where it used to be dropped here.
        //
        // A caller that cannot name the pane cannot ask it anything, and the
        // revive path's "launched but never registered" branch spent its whole
        // life logging an absence for exactly that reason — the address of the
        // thing that could have explained it was discarded one frame up. Same
        // shape `launchTmux` and `resumeTmux` already return.
        switch resumeTmux(sessionId: sessionId, directory: directory, launch: launch,
                          acceptTrustPrompt: acceptTrustPrompt) {
        case .success(let tty):
            return .success(tty)
        case .failure(let error):
            Self.trace?("revive FAILED for \(sessionId.prefix(8)): \(error.message)")
            return .failure(error)
        }
    }

    /// What a pane is actually showing, asked directly, for the moment a
    /// launch did not land the way it was supposed to.
    ///
    /// "A process is alive on the tty" is not the same fact as "the agent
    /// started", and conflating them is what shipped on 26 Aug: a Codex pane
    /// frozen on an update prompt has a perfectly healthy `codex` process in
    /// it, so the liveness probe said yes and the panel announced a launch
    /// over a menu. The harness's own banner is the narrower, truer question,
    /// and the adapter has always known how to ask it.
    public enum PaneState: Sendable, Equatable {
        /// The harness's banner is up: this TUI started, and whatever it is
        /// waiting for, it is waiting the way it is supposed to.
        case started
        /// Something else is on screen — an update prompt, an auth screen, a
        /// picker nobody has named yet. Carries the text, because the whole
        /// lesson of 27 Aug is that this is the part worth keeping.
        case stopped(screen: String)
        /// No resolvable pane, or nothing readable in it.
        case unknown
    }

    public static func paneState(tty: String, adapter: any HarnessAdapter) -> PaneState {
        guard let spec = adapter.trustPrompt,
              let pane = TmuxOwnership.pane(forTty: tty),
              case .success(let text) = Tmux.run(
                ["capture-pane", "-p", "-t", pane.paneId],
                socket: pane.socketName, timeout: 3)
        else { return .unknown }
        return classifyPaneScreen(text, spec: spec)
    }

    /// Pure half of `paneState`, the same read-it/decide-it split
    /// `classifyCodexResumeScreen` and `TmuxTransport.classifyPromptLine`
    /// already keep — so the decision is testable against captured screens
    /// (including the real Codex update prompt) with no live pane.
    static func classifyPaneScreen(_ text: String, spec: TrustPromptSpec) -> PaneState {
        if text.contains(spec.settledBannerNeedle) { return .started }
        if let noPrompt = spec.startedWithNoPromptNeedle, text.contains(noPrompt) { return .started }
        return .stopped(screen: TrustPromptWatcher.meaningfulTail(text))
    }

    /// Put a real window on a pane — the same door `onNeedsHuman` opens, and
    /// the same one Go to Agent uses, lifted out of the trust watcher's
    /// closure so a caller that is not a watcher can open it too.
    ///
    /// A launch is detached because a launch that is WORKING needs no window
    /// ("starting an agent is a background act", `launch`'s own comment). The
    /// instant it stops needing that description, the reason evaporates:
    /// detached while it is progressing, attached the moment it is not.
    @discardableResult
    public static func showPane(tty: String, why: String) -> Bool {
        guard let pane = TmuxOwnership.pane(forTty: tty),
              let binary = Tmux.resolveBinary(),
              let script = TerminalTabFocus.attachScript(
                binary: binary, socket: pane.socketName,
                tmuxTmpDir: Tmux.socketDirectory.path, sessionName: pane.sessionName)
        else {
            Self.trace?("showPane: \(tty) — \(why), but no window could be opened for it")
            return false
        }
        if case .failure(let error) = AppleScript.run(script: script) {
            Self.trace?("showPane: \(tty) — \(why), but opening a window failed: \(error.message)")
            return false
        }
        Self.trace?("showPane: opened a window on \(tty) — \(why)")
        return true
    }


    /// Resolves `tty` to its tmux pane and watches that — a thin
    /// convenience for the two callers (`launchTmux`, and the app's own
    /// post-launch greeting task) that have a tty in hand from a launch
    /// they just made, not a second implementation. Before the
    /// single-transport cut (23 Aug) this fell back to an AppleScript
    /// watcher over a Terminal.app tab when the tty wasn't tmux-owned; that
    /// branch is deleted, not merely dead-code-flagged, because it no
    /// longer CAN be reached — `launchTmux` is the only launch path left,
    /// and every tty it produces is tmux-owned by construction. See
    /// `watchForTrustPrompt(pane:)` for the one remaining watch loop.
    public static func watchForTrustPrompt(
        tty: String, adapter: any HarnessAdapter = ClaudeCodeAdapter(),
        onNeedsHuman: (@Sendable (String) -> Void)? = nil
    ) {
        guard let pane = TmuxOwnership.pane(forTty: tty) else {
            Self.trace?("newSession: \(tty) has no resolvable tmux pane — trust watcher has "
                + "nothing to watch")
            return
        }
        watchForTrustPrompt(pane: pane, adapter: adapter, onNeedsHuman: onNeedsHuman)
    }

    /// Watch a just-launched pane; if the harness's trust prompt renders,
    /// press Return once and STOP. The single press and immediate return
    /// are load-bearing (ruled 12 Aug, PR #34, against the AppleScript
    /// predecessor this collapsed from — 23 Aug): on a resume, the screen
    /// after trust offers "resume from summary / full", and the full
    /// option is a usage-limit spend that stays with the user. Answering
    /// once and leaving is what keeps this watcher safe on both the launch
    /// and revive paths.
    ///
    /// Measured on a real revive (12 Aug, session bd28a0a1, 753k tokens, so
    /// the stakes were live, not hypothetical):
    /// - Registration and the first transcript append happen BEFORE the
    ///   resume-choice prompt is answered, so a revived session reads LIVE in
    ///   `claude agents --json` while it is actually blocked on that
    ///   question. The trust prompt is the opposite: nothing registers until
    ///   it is answered. Liveness is not evidence the pane needs no attention.
    /// - A second Return on the resume prompt would pick "summary
    ///   (recommended)", the cheap option — wrong owner, not catastrophe.
    ///   The early return in `TrustPromptWatcher.watch` is what keeps that
    ///   press from happening.
    ///
    /// The needle wording itself has rotted before and will again: "Do you
    /// trust" was the pre-2.1 Claude Code prompt; v2.1.x renders "Quick
    /// safety check: … ❯ 1. Yes, I trust this folder" — matched on "trust
    /// this folder", with the old needle kept for older CLIs. The
    /// started-sentinel was `? for shortcuts` (also gone); it is now the
    /// banner word "Claude" — capital C, so the lowercase `claude` in the
    /// echoed launch command cannot satisfy it. Two consecutive sightings,
    /// because a single read can catch the pane mid-boot.
    ///
    /// Verified live 19 Aug against a real tmux pane: the v2.1 "trust this
    /// folder" screen read cleanly through capture-pane and a single
    /// send-keys Enter accepted it, with registration correctly absent
    /// until it did. Before 23 Aug this loop had a second implementation
    /// (`watchForTrustPrompt(tty:)`'s own AppleScript read/press over a
    /// Terminal.app tab, one hand-copied 40-line pair for the transport
    /// that no longer exists) — deleted, not merely superseded, once the
    /// tty-based overload above stopped being reachable through anything
    /// but this one.
    /// `onNeedsHuman` is the panel's half of the same event, added 27 Aug.
    /// Opening the window is necessary and was never sufficient: a launch you
    /// walked away from puts a window somewhere behind whatever you are
    /// actually looking at, and the panel — the one surface this app promises
    /// you can watch instead of a terminal — went on showing a spinner. The
    /// window is the place to ANSWER; the card is the place to find out there
    /// is something to answer. Optional, so `tbase` and the tests keep the
    /// window-only behaviour they had.
    static func watchForTrustPrompt(
        pane: TmuxPaneAddress, adapter: any HarnessAdapter = ClaudeCodeAdapter(),
        onNeedsHuman: (@Sendable (String) -> Void)? = nil
    ) {
        guard let spec = adapter.trustPrompt else { return }
        TrustPromptWatcher.watch(
            spec: spec,
            read: {
                guard case .success(let text) = Tmux.run(
                    ["capture-pane", "-p", "-t", pane.paneId],
                    socket: pane.socketName, timeout: 3) else { return nil }
                return text
            },
            press: { steps in
                // Walk the selection onto the accepting row before confirming.
                // One send-keys per press rather than one call with N keys:
                // tmux delivers them as a burst either way, but a TUI that
                // drops a repeat under load loses one row of travel here and
                // the whole keystroke sequence there.
                for _ in 0..<abs(steps) {
                    Tmux.run(["send-keys", "-t", pane.paneId, steps > 0 ? "Down" : "Up"],
                             socket: pane.socketName)
                }
                Tmux.run(["send-keys", "-t", pane.paneId, "Enter"], socket: pane.socketName)
            },
            trace: Self.trace, label: pane.sessionName,
            onNeedsHuman: { question in
                // The panel first, the window second — on purpose. Opening a
                // window is an AppleScript round trip that can take a second
                // and can fail outright (Automation permission, no Terminal);
                // saying WHAT the pane is asking costs nothing and must not
                // queue behind it, least of all on the path where the window
                // never opens.
                onNeedsHuman?(question)
                // The same door Go to Agent uses, called automatically
                // rather than waiting for a click: a screen that genuinely
                // needs the human's own decision is not "resumed" until
                // they can see it (ruled 23 Aug — see the needle's own
                // comment on `ClaudeCodeAdapter.trustPrompt`).
                guard let binary = Tmux.resolveBinary(),
                      let script = TerminalTabFocus.attachScript(
                        binary: binary, socket: pane.socketName,
                        tmuxTmpDir: Tmux.socketDirectory.path, sessionName: pane.sessionName)
                else {
                    Self.trace?("newSession: \(pane.sessionName) needed a human but could not "
                        + "open a window for it")
                    return
                }
                if case .failure(let error) = AppleScript.run(script: script) {
                    Self.trace?("newSession: \(pane.sessionName) needed a human — opening a "
                        + "window failed: \(error.message)")
                }
            })
    }
}
