import Foundation

/// Bring a live session to the front — the addressing half of "go to
/// session".
///
/// An agent's terminal is a tmux pane, and a pane is reached by attaching to
/// its tmux session. So there is one mechanism and one question: is there
/// already a window attached to it that we opened, or does one need opening?
///
///   1. **A window we opened.** `TerminalWindows` holds Terminal's own window
///      id, recorded at the moment we opened it. Raising by id is exact.
///   2. **Otherwise, a fresh one.** `tmux attach -d` detaches whatever client
///      was there — so the previous window closes itself rather than being
///      left as a second view onto the same pane — and the new window's id is
///      recorded on the way past.
///
/// **There is no tty matching here any more, and there must never be again.**
/// Terminal reports the tty of a tab whose shell has exited, and macOS
/// recycles tty device numbers, so a tty names several tabs at once and only
/// one of them is alive. Measured 13 Sep 2026: 61 Terminal windows on one
/// machine, `/dev/ttys045` claimed by five of them, four dead. The old
/// `tty of tabs of windows` walk returned the first match — a dead canary
/// window, left behind by `scripts/canary.sh` — and reported `.focused`,
/// twelve presses in a row, while the agent sat in window 61. Filtering that
/// list by liveness was considered and rejected: it stacks a second scraped
/// fact on the first and the two have to agree, which is the shape of the bug
/// rather than a fix for it. We open the window, so we know its id; nothing
/// needs to be inferred.
///
/// One osascript run per focus, one Apple event, no tab walk at any size. The
/// walk it replaces is what froze the app at 192 open tabs (issue 14).
public enum TerminalTabFocus {
    public enum Outcome: Equatable, Sendable {
        /// The tab is selected, its window raised, Terminal activated — or,
        /// for a tmux pane, a fresh window is now attached to it.
        case focused
        /// Every tab answered; none carries this tty. Never returned for the
        /// tmux branch — a live server attach either succeeds or fails, it
        /// does not report "gone" the way a stale tab search can.
        case tabGone
        /// Terminal did not answer inside the deadline. The tab may well
        /// still exist — the honest message is "busy", not "gone".
        case timedOut(seconds: Int)
        case failed(String)
    }

    /// Pure mapping from the script result, separated so it is testable
    /// without Terminal.
    static func outcome(
        of result: Result<String, ScriptError>, timeout: TimeInterval
    ) -> Outcome {
        switch result {
        case .success(let out) where out.contains("notfound"): return .tabGone
        case .success: return .focused
        case .failure(let e) where e.timedOut: return .timedOut(seconds: Int(timeout))
        case .failure(let e): return .failed(Self.plainWords(for: e.message))
        }
    }

    /// AppleScript's own error text, translated into the one thing the reader
    /// can act on.
    ///
    /// `-1743` is macOS refusing to let this app send Apple events to
    /// Terminal — the Automation permission. It is a SETTING, not a fault:
    /// nothing is broken, nothing was lost, and there is exactly one action
    /// that fixes it. Surfacing the raw string instead ("41:537: execution
    /// error: Not authorized to send Apple events to Terminal. (-1743)")
    /// tells a person their app is broken in a language written for whoever
    /// wrote the app.
    ///
    /// Reported 26 Aug, and it is the reason GO TO AGENT stopped working at
    /// all: the permission was revoked deliberately while testing the
    /// first-run experience and never granted back. macOS does not re-prompt
    /// once denied, so nothing would ever have asked again.
    static func plainWords(for message: String) -> String {
        guard message.contains("-1743") || message.contains("Not authorized to send Apple events")
        else { return message }
        return "Tranquility Base isn't allowed to control Terminal, so it can't open the "
            + "agent's window. Grant it under Privacy & Security → Automation, then try again."
    }

    /// Only a name shaped the way `launchTmux` actually makes one (`tb-`
    /// plus an 8-char hex session-id prefix) is ever attached to — the same
    /// posture the tty filter used to take: refuse to script
    /// anything outside the character set of the thing being addressed,
    /// rather than trust a live server's own output.
    static let sessionNameCharset = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// Every dynamic piece goes through AppleScript's own `quoted form of`
    /// rather than manual Swift-side shell escaping — the same pattern
    /// `SessionLauncher.resume()`'s `cd … && …` build already uses. `binary`
    /// and `tmuxTmpDir` are internal facts (a resolved executable path, this
    /// app's own support directory), never attacker input; `sessionName` is
    /// the one value that comes from outside this process (a live tmux
    /// server's own listing), which is why it alone is character-filtered
    /// before any script is built.
    /// Resized before attaching, always — a human window, never left at
    /// whatever size the pane was created with. Launch panes are sized wide
    /// (220×50) for TB's own capture-pane reading, which is uncomfortable to
    /// read as a terminal window and — found live, 23 Aug — can hide the
    /// exact content a human was just sent here to read below the fold. That
    /// alone would just be an annoyance; what makes it a real bug is mouse
    /// mode (on for every TB-launched pane): scrolling to see the hidden
    /// content drops the pane into tmux's copy-mode, silently, and 1/2/Enter
    /// then navigate the frozen scrollback instead of reaching the live
    /// process — a real resume-depth prompt that looked completely
    /// unresponsive because of it. `window-size manual` means the pane never
    /// resizes on its own; this is the same `resize-window` any tmux tool
    /// that creates panes headlessly and expects a human to attach later
    /// already has to call — not new machinery, just calling it.
    static let humanAttachColumns = 120
    static let humanAttachRows = 40

    static func attachScript(
        binary: String, socket: String?, tmuxTmpDir: String, sessionName: String
    ) -> String? {
        guard !sessionName.isEmpty, sessionName.count <= 64,
              sessionName.unicodeScalars.allSatisfy({ sessionNameCharset.contains($0) })
        else { return nil }
        // Built once, reused for both tmux invocations below — same pattern
        // `SessionLauncher.resume()`'s own
        // `cd … && …` build already use: every dynamic piece goes through
        // AppleScript's `quoted form of`, never manual Swift-side escaping.
        func tmuxCommand(_ args: String) -> String {
            if let socket {
                return """
                    "env TMUX_TMPDIR=" & quoted form of "\(tmuxTmpDir)" \
                    & " " & quoted form of "\(binary)" & " -L " & quoted form of "\(socket)" \
                    & " \(args) -t " & quoted form of "\(sessionName)"
                    """
            }
            return """
                quoted form of "\(binary)" & " \(args) -t " & quoted form of "\(sessionName)"
                """
        }
        let resize = tmuxCommand("resize-window -x \(humanAttachColumns) -y \(humanAttachRows)")
        // `attach -d` rather than a bare attach, and this is the whole of the
        // "two windows onto the same pane" fix (found live 23 Aug, previously
        // handled by searching Terminal for the existing client's tty and
        // raising that instead). tmux already has the verb: -d detaches every
        // other client as this one attaches, so the old window's `tmux attach`
        // exits and the window goes with it. One flag, tmux's own semantics,
        // and no tty is consulted to get there.
        let attach = tmuxCommand("attach -d")
        // The window id comes back with the "ok", because we OPENED this
        // window and that is the only moment its identity is knowable without
        // guessing. `do script` with no `in` clause makes a new window and
        // leaves it frontmost, so `window 1` is it. Wrapped in a try: an id we
        // fail to read costs a future reopen, never this attach.
        return """
            tell application "Terminal"
              activate
              do script \(resize) & " && " & \(attach)
              set wid to ""
              try
                set wid to (id of window 1) as text
              end try
              return "ok|" & wid
            end tell
            """
    }

    /// Raise a window we opened earlier, by Terminal's own id.
    ///
    /// No tty, no tab walk, no search. Either the id still names a window or
    /// it does not, and "notfound" is a fact rather than a near-miss — which
    /// is exactly what the tty match could never say, because a recycled tty
    /// on a dead tab looks identical to the live one.
    static func raiseScript(windowId: Int) -> String {
        """
        tell application "Terminal"
          if (exists window id \(windowId)) then
            set index of window id \(windowId) to 1
            activate
            return "ok"
          end if
          return "notfound"
        end tell
        """
    }

    /// The window id an attach reported, or nil when it did not say.
    static func windowId(fromAttach result: String) -> Int? {
        guard let bar = result.firstIndex(of: "|") else { return nil }
        return Int(result[result.index(after: bar)...]
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Open a fresh window on this pane and remember which one it is.
    ///
    /// The single place an attach happens, so the launcher's two callers (a
    /// pane that needs a human, `showPane`) record their window the same way
    /// GO TO AGENT does and the next focus can raise it instead of opening a
    /// second one.
    @discardableResult
    public static func attachFresh(pane: TmuxPaneAddress,
                                   timeout: TimeInterval = 5) async -> Outcome {
        guard let binary = Tmux.resolveBinary() else {
            return .failed("tmux binary not found")
        }
        guard let script = attachScript(
            binary: binary, socket: pane.socketName,
            tmuxTmpDir: Tmux.socketDirectory.path, sessionName: pane.sessionName)
        else {
            return .failed("refused to script an unexpected tmux session name: "
                + "\(pane.sessionName)")
        }
        let result = await AppleScript.run(script: script, timeout: timeout)
        if case .success(let out) = result, let id = windowId(fromAttach: out) {
            TerminalWindows.remember(sessionName: pane.sessionName, windowId: id)
        }
        return outcome(of: result, timeout: timeout)
    }

    /// The same attach, run synchronously, for callers already off the main
    /// actor and not in an async context — the launcher's trust-prompt watcher
    /// and `showPane`. Both used to build the script themselves and drop the
    /// window id on the floor, so the window they opened was unknown to the
    /// next GO TO AGENT and got detached and reopened for no reason.
    @discardableResult
    public static func attachFreshSync(pane: TmuxPaneAddress) -> Outcome {
        guard let binary = Tmux.resolveBinary() else {
            return .failed("tmux binary not found")
        }
        guard let script = attachScript(
            binary: binary, socket: pane.socketName,
            tmuxTmpDir: Tmux.socketDirectory.path, sessionName: pane.sessionName)
        else {
            return .failed("refused to script an unexpected tmux session name: "
                + "\(pane.sessionName)")
        }
        let result = AppleScript.run(script: script)
        if case .success(let out) = result, let id = windowId(fromAttach: out) {
            TerminalWindows.remember(sessionName: pane.sessionName, windowId: id)
        }
        return outcome(of: result, timeout: 5)
    }

    /// Never call from the main actor: the one Apple event still blocks for
    /// up to `timeout` when Terminal is busy, and a main-thread block past
    /// ~1 s trips the event-tap watchdog and silently kills the hotkeys.
    ///
    /// Two steps, and neither of them looks at a tty:
    ///
    ///   1. **Raise the window we opened.** If this session has been focused
    ///      before in this run of the app, `TerminalWindows` has Terminal's
    ///      own window id for it. Raising by id cannot land on a corpse.
    ///   2. **Otherwise open a fresh one.** `attach -d` detaches whatever
    ///      client was there, so the old window closes itself, and the new
    ///      window's id is recorded on the way past.
    ///
    /// What is gone is the tab walk that matched on tty. It could not work:
    /// Terminal reports the stale tty of tabs whose shell has exited and macOS
    /// recycles the numbers, so `/dev/ttys045` named five windows at once on
    /// the machine this was found on, and the search returned the first — a
    /// dead canary window — while reporting success. `tty` survives in the
    /// signature only as the caller's way of naming a pane it already holds;
    /// nothing matches on it any more.
    public static func focus(tty: String, sessionId: String? = nil,
                             timeout: TimeInterval = 5) async -> Outcome {
        // Ask the session's own registry entry for its pane before inferring
        // one from a tty. A tty is two stale hops away from the truth (`ps`
        // for the pid, the server's inventory for the pane) and Claude Code
        // writes the pane down itself — see `TmuxOwnership.pane(forSessionId:pid:)`.
        let resolved = sessionId.flatMap { TmuxOwnership.pane(forSessionId: $0, pid: nil) }
        guard let pane = resolved ?? TmuxOwnership.pane(forTty: tty) else {
            // No live tmux server owns this. There is no identity to address
            // and nothing to attach to, and the tty search that used to stand
            // in here answered with whichever dead tab sorted first. Callers
            // reach this only for a session that was never moved under tmux;
            // `AppDelegate.goToSession` transfers one before it ever calls in.
            return .failed("no tmux pane owns \(tty), so there is no window to open")
        }
        if let known = TerminalWindows.windowId(for: pane.sessionName) {
            let raised = outcome(
                of: await AppleScript.run(script: raiseScript(windowId: known),
                                          timeout: timeout),
                timeout: timeout)
            // `.tabGone` here means the window was closed by hand since we
            // opened it. Forget it and open a fresh one, which is the same
            // answer as never having known it. Any other outcome — raised, or
            // a real Automation failure — is this call's answer.
            if raised != .tabGone { return raised }
            TerminalWindows.forget(sessionName: pane.sessionName)
        }
        return await attachFresh(pane: pane, timeout: timeout)
    }
}
