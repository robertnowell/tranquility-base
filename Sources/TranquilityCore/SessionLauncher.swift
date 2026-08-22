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
/// path. `resume` (reviving a dead session) still opens a Terminal.app window
/// and still needs the Automation permission and `AppleScript.run` — that is
/// the one remaining consumer of both, not `launch`.
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
        command: String = defaultCommand,
        acceptTrustPrompt: Bool = true,
        adapter: any HarnessAdapter = ClaudeCodeAdapter()
    ) -> Result<String, ScriptError> {
        // Ruled 21 Aug: no flags, no parallel launch paths. A launch is a
        // detached tmux session on the app's own server, full stop — the
        // opt-in this replaced (`tbase tmux on`, 19-21 Aug) is gone along
        // with the setting behind it, and `launchTerminal`, the Terminal.app
        // launch path it used to choose between, is deleted outright rather
        // than left as an unreachable second path. `resume` (below) still
        // opens a Terminal.app window for a REVIVED session — a separate,
        // not-yet-decided piece of this same cleanup; see its doc comment.
        launchTmux(directory: directory, command: command,
                  acceptTrustPrompt: acceptTrustPrompt, adapter: adapter)
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
    /// inheritance.
    @discardableResult
    static func launchTmux(
        directory: String,
        command: String,
        acceptTrustPrompt: Bool,
        adapter: any HarnessAdapter = ClaudeCodeAdapter()
    ) -> Result<String, ScriptError> {
        // The launch command re-quotes the directory through printf %q-style
        // single-quote wrapping; the directory came from settings validation
        // (must exist) but is still never trusted as shell syntax.
        let quotedDir = Self.shellQuoted(directory)
        let name = "tb-" + String(UUID().uuidString.prefix(8)).lowercased()
        let path = ([
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]).joined(separator: ":")

        switch Tmux.run([
            "new-session", "-d", "-s", name, "-x", "220", "-y", "50",
            "-c", directory,
            "-e", "PATH=\(path)",
            "-e", "LANG=en_US.UTF-8",
            "/bin/zsh", "-c", "cd \(quotedDir) && \(command)",
        ], socket: Tmux.socketName, timeout: 10) {
        case .failure(let error):
            Self.trace?("newSession(tmux) FAILED: \(error.message)")
            return .failure(error)
        case .success:
            break
        }
        // Server posture, set AFTER new-session because a server only exists
        // once it hosts something — `set -s` against no server fails silently
        // and the default (exit-empty on) then takes the whole server down
        // with its last session, which is exactly what happened on the first
        // live termination test. Idempotent, so every launch re-asserts it.
        Tmux.run(["set", "-s", "exit-empty", "off"], socket: Tmux.socketName)
        Tmux.run(["set", "-t", name, "window-size", "manual"], socket: Tmux.socketName)
        Tmux.run(["set", "-t", name, "mouse", "on"], socket: Tmux.socketName)

        guard case .success(let tty) = Tmux.run(
            ["display-message", "-p", "-t", name, "#{pane_tty}"],
            socket: Tmux.socketName, timeout: 3)
        else {
            return .failure(ScriptError(message: "tmux session \(name) came up without a pane tty"))
        }
        Self.trace?("newSession: launched `\(command)` in \(directory) "
            + "(tmux \(name), tty \(tty))")
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
    static func resumeTmux(
        sessionId: String,
        directory: String,
        command: String = defaultCommand,
        acceptTrustPrompt: Bool = true,
        adapter: any HarnessAdapter = ClaudeCodeAdapter()
    ) -> Result<String, ScriptError> {
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
        return launchTmux(directory: directory, command: fullCommand,
                          acceptTrustPrompt: acceptTrustPrompt, adapter: adapter)
    }

    /// Single-quote wrapping, the shell's own escape for "trust nothing
    /// inside this": embedded single quotes close the quote, insert an
    /// escaped literal one, and reopen it. The one implementation —
    /// `launchTmux`'s directory quoting used to be a second, identical copy
    /// of this exact expression; collapsed here rather than reintroduced
    /// for `resumeTmux`'s arguments. Not `private`: pinned directly by a
    /// test, the way a security-relevant string transform earns.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        settleMaxPolls: Int = 20
    ) -> Result<CodexResumeOutcome, ScriptError> {
        switch resumeTmux(sessionId: sessionId, directory: directory, command: "codex",
                          acceptTrustPrompt: false, adapter: adapter) {
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
    /// This function used to say the opposite — "no trust prompt: the directory
    /// was trusted when the session first ran there, and this is the same
    /// directory by construction" — which was reasoned rather than measured,
    /// and wrong. Run against a real six-day-old session on 12 Aug: Claude Code
    /// asks the workspace-trust question on a RESUME too, and the window then
    /// sat on it doing nothing. Clicking REVIVE opened a terminal that needed
    /// you to go and find it, which is precisely the hunt this whole feature
    /// exists to end.
    ///
    /// The consent argument is `launch`'s, unchanged: the prompt is asking
    /// permission for the thing the user just pressed a button to do, in a
    /// directory their own session already ran in.
    ///
    /// What it does NOT answer is the question that comes next. A resume of a
    /// long session offers "resume from summary" or "resume full session as-is"
    /// and says the full one "will consume a substantial portion of your usage
    /// limits". That is a spend, and a preference — it stays with the user, and
    /// it is why Terminal is brought to the front rather than left behind.
    /// `watchForTrustPrompt` returns the moment it presses once, so it
    /// cannot walk into it.
    ///
    /// Blocks up to ~30s while watching; call off-main.
    @discardableResult
    public static func resume(
        sessionId: String,
        directory: String,
        command: String = AgentDefaults.load(),
        acceptTrustPrompt: Bool = true,
        adapter: any HarnessAdapter = ClaudeCodeAdapter()
    ) -> Result<Void, ScriptError> {
        // The SAME command a new session gets, plus the conversation to open.
        // Ruled 12 Aug: "any new or revived session gets launched under the
        // same parameters." One setting, appended to, rather than two strings
        // that have to be kept in agreement.
        //
        // Terminal is activated on purpose, and the ruling that keeps it is
        // about what resume actually does: Claude Code asks whether to resume
        // from the full context or from a summary, so a revived session is
        // waiting on you the moment it opens. A row that lit itself while a
        // question sat unanswered in a window you were never shown would be
        // the lamp lying.
        //
        // The id comes from a transcript FILENAME, so it cannot contain a
        // quote or a space — but it is still passed through AppleScript's own
        // `quoted form of` at script-run time, same as the directory, rather
        // than trusted: "cannot" is a property of today's harness, not of
        // this function.
        //
        // An adapter returning [] here is a programmer error, not a shape to
        // render around: a joined-empty segment leaves the script's trailing
        // `&` with nothing after it, which osacompile confirms is a syntax
        // error — AppleScript.run would then fail with a compile error that
        // points nowhere near the real cause (M2 gate finding). Every
        // resumable harness resumes SOME conversation by SOME argument;
        // failing loudly here, before the AppleScript ever runs, is more
        // honest than emitting a script that cannot compile.
        let resumeArgs = adapter.resumeArguments(sessionId: sessionId)
        guard !resumeArgs.isEmpty else {
            Self.trace?("revive: \(adapter.id) adapter returned no resume arguments "
                + "for \(sessionId.prefix(8)) — refusing rather than emitting broken AppleScript")
            return .failure(ScriptError(message: "\(adapter.id) adapter: empty resume arguments"))
        }
        let resumeSegment = resumeArgs
            .map { "quoted form of \"\($0)\"" }
            .joined(separator: " & \" \" & ")
        let script = """
            tell application "Terminal"
              activate
              set newTab to do script "cd " & quoted form of "\(directory)" \
                & " && \(command) " & \(resumeSegment)
              return tty of newTab
            end tell
            """
        switch AppleScript.run(script: script) {
        case .success(let tty):
            let tty = tty.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.trace?("revive: resumed \(sessionId.prefix(8)) in \(directory) "
                + "as `\(command)` (tty \(tty))")
            if acceptTrustPrompt { watchForTrustPrompt(tty: tty, adapter: adapter) }
            return .success(())
        case .failure(let error):
            Self.trace?("revive FAILED for \(sessionId.prefix(8)): \(error.message)")
            return .failure(error)
        }
    }

    /// Bring a LIVE session's terminal tab to the front.
    ///
    /// The other half of the list's one click: a session that is still running
    /// does not need reviving, it needs finding — which is the whole complaint
    /// the list exists to answer ("I don't know which terminal tab it's in").
    /// Same AppleScript the card's GO TO AGENT has always used; this one is
    /// reached from a session id rather than from the card's current target.
    @discardableResult
    public static func focus(pid: Int) -> Result<Bool, ScriptError> {
        guard let tty = ProcessProbe.tty(of: pid) else {
            Self.trace?("goTo: no tty for pid \(pid)")
            return .success(false)
        }
        // Order matters, and it is the whole fix (ruled 18 Aug: "it brought all
        // the terminal windows to the top"). Selecting the tab and promoting
        // its window to index 1 FIRST makes the agent's window Terminal's own
        // frontmost; activating afterwards through `NSRunningApplication`
        // brings that window forward and leaves the rest where they were.
        // AppleScript's `activate` cannot do this — it is an app-level
        // activation that raises every window the app owns, which is how one
        // click on GO TO AGENT buried the screen under nine other terminals.
        let script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if (tty of t) as text is "\(tty)" then
                    set selected tab of w to t
                    set index of w to 1
                    return "ok"
                  end if
                end repeat
              end repeat
              return "notfound"
            end tell
            """
        switch AppleScript.run(script: script) {
        case .success(let out) where out.contains("notfound"):
            Self.trace?("goTo: tab not found for \(tty)")
            return .success(false)
        case .success:
            // Without `.activateAllWindows`, which is the option that would
            // reproduce exactly what we just stopped doing.
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.Terminal")
                .first?.activate()
            Self.trace?("goTo: focused \(tty)")
            return .success(true)
        case .failure(let error):
            Self.trace?("goTo FAILED: \(error.message)")
            return .failure(error)
        }
    }

    /// Watch the just-launched tab; if Claude's trust prompt renders, press
    /// Return once and STOP. The single press and immediate return are
    /// load-bearing (ruled 12 Aug, PR #34): on a resume, the screen after
    /// trust offers "resume from summary / full", and the full option is a
    /// usage-limit spend that stays with the user. Answering once and leaving
    /// is what keeps this watcher safe on both the launch and revive paths.
    ///
    /// Measured on a real revive (12 Aug, session bd28a0a1, 753k tokens, so
    /// the stakes were live, not hypothetical):
    /// - Registration and the first transcript append happen BEFORE the
    ///   resume-choice prompt is answered, so a revived session reads LIVE in
    ///   `claude agents --json` while it is actually blocked on that
    ///   question. The trust prompt is the opposite: nothing registers until
    ///   it is answered. Liveness is not evidence the tab needs no attention.
    /// - A second Return on the resume prompt would pick "summary
    ///   (recommended)", the cheap option — wrong owner, not catastrophe.
    ///   The early return below is what keeps that press from happening.
    ///
    /// Twice-rotted and re-verified against a live v2.1.229 tab on 12 Aug
    /// (scripts/canary.sh caught both; it replays this exact contract at
    /// every deploy):
    ///
    /// 1. WORDING. "Do you trust" was the pre-2.1 prompt; v2.1.x renders
    ///    "Quick safety check: … ❯ 1. Yes, I trust this folder". Matched on
    ///    "trust this folder", with the old needle kept for older CLIs. The
    ///    started-sentinel was `? for shortcuts` (also gone); it is now the
    ///    banner word "Claude" — capital C, so the lowercase `claude` in the
    ///    echoed launch command cannot satisfy it. Two consecutive sightings,
    ///    because a single read can catch the tab mid-boot. (The v2.1.229
    ///    trust screen itself contains "Claude", which is why the trust check
    ///    runs FIRST in every poll — reorder these and the watcher will call
    ///    an unanswered trust prompt "started".)
    ///
    /// 2. ADDRESSING. `contents of t` where t is a repeat variable is
    ///    AppleScript's DEREFERENCE operator, not Terminal's `contents`
    ///    property: it returns the tab object, which stringifies as
    ///    "tab 1 of window id N", so every needle missed against nine words
    ///    of specifier text. Only a directly typed specifier
    ///    (`contents of tab i of window id wid`) reads the screen. The same
    ///    trap applies to `do script "" in t`, so both scripts address
    ///    directly.
    public static func watchForTrustPrompt(tty: String, adapter: any HarnessAdapter = ClaudeCodeAdapter()) {
        // A tmux-owned tty is watched through capture-pane: the same needles,
        // none of the AppleScript dereference pathology this doc block
        // describes (that trap rotted twice and earned its own canary; it
        // simply does not exist in tmux's read path).
        if let pane = TmuxOwnership.pane(forTty: tty) {
            watchForTrustPrompt(pane: pane, adapter: adapter)
            return
        }
        guard let spec = adapter.trustPrompt else { return }
        TrustPromptWatcher.watch(
            spec: spec,
            read: {
                guard case .success(let text) = AppleScript.run(script: """
                    tell application "Terminal"
                      repeat with w in windows
                        set wid to id of w
                        set n to count of tabs of w
                        repeat with i from 1 to n
                          if (tty of tab i of window id wid) as text is "\(tty)" then
                            return contents of tab i of window id wid
                          end if
                        end repeat
                      end repeat
                      return ""
                    end tell
                    """) else { return nil }
                return text
            },
            press: {
                _ = AppleScript.run(script: """
                    tell application "Terminal"
                      repeat with w in windows
                        set wid to id of w
                        set n to count of tabs of w
                        repeat with i from 1 to n
                          if (tty of tab i of window id wid) as text is "\(tty)" then
                            do script "" in tab i of window id wid
                            return "ok"
                          end if
                        end repeat
                      end repeat
                      return "notfound"
                    end tell
                    """)
            },
            trace: Self.trace, label: tty)
    }

    /// The tmux twin, identical contract, capture-pane instead of
    /// AppleScript. Verified live 19 Aug: the v2.1 "trust this folder"
    /// screen read cleanly through capture-pane and a single send-keys
    /// Enter accepted it, with registration correctly absent until it did.
    static func watchForTrustPrompt(pane: TmuxPaneAddress, adapter: any HarnessAdapter = ClaudeCodeAdapter()) {
        guard let spec = adapter.trustPrompt else { return }
        TrustPromptWatcher.watch(
            spec: spec,
            read: {
                guard case .success(let text) = Tmux.run(
                    ["capture-pane", "-p", "-t", pane.paneId],
                    socket: pane.socketName, timeout: 3) else { return nil }
                return text
            },
            press: {
                Tmux.run(["send-keys", "-t", pane.paneId, "Enter"], socket: pane.socketName)
            },
            trace: Self.trace, label: pane.sessionName)
    }
}
