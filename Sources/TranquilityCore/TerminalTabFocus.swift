import Foundation

/// Bring a live session to the front — the addressing half of "go to
/// session".
///
/// Two shapes, tried in order, because the thing behind a tty stopped being
/// one thing on 21 Aug (`cc7bf4e`, "tmux is simply how a launch works now"):
///
/// 1. **tmux pane** (every session TB launches, unconditionally, since
///    `cc7bf4e`): `TmuxOwnership.pane(forTty:)` finds the live pane and this
///    opens a fresh Terminal window running `tmux attach`, per "The end
///    state" note in `docs/architecture-program.md` ("GO TO AGENT = attach").
///    A LIVE server cannot serve a stale pane the way Terminal.app served a
///    dead tab (the 19 Aug misfire this file's sibling type guards against),
///    which is what makes this branch safe to try first, always.
/// 2. **Terminal.app tab** (a hand-started session the user opened directly
///    in their own tab, never launched by TB at all — the adoption design's
///    "every session is adoptable, wherever it started") — the original
///    mechanism, unchanged, kept as the fallback for exactly that case.
///
/// Found live, 22 Aug, the hard way: branch 2 alone was ALL this type did
/// until today, and since branch 1's precondition (every launch is tmux) has
/// held for every session TB launches since 21 Aug, "Go to Agent" had been a
/// silent, universal no-op for a full day — reproduced on a session launched
/// seconds before the fix, not just an old one. `SessionLauncher.focus(pid:)`
/// was the other copy of branch 2 alone; deleted rather than fixed twice,
/// its one call site routed through here instead.
///
/// One osascript run per branch, two Apple events for the tab walk
/// regardless of how many tabs exist: a batched `tty of tabs of windows`
/// fetch answers for every tab at once, then a single select-and-raise lands
/// on the match. The shape it replaces — one `tty of t` Apple event per tab —
/// is the shape that froze the app (issue 14): 192 open tabs meant 192
/// round-trips, 3.5 s against an idle Terminal and unbounded against a busy
/// one, each event entitled to the two-minute default Apple-event timeout.
/// Measured 12 Aug: the batched fetch answers the same 192 tabs in ~120 ms.
///
/// The index math runs locally between the two events, so window/tab indices
/// are only trusted for the milliseconds between fetch and select — the same
/// script execution.
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

    /// The script is only ever built around a tty that looks like one.
    /// A tty is spliced into AppleScript source, so anything outside the
    /// character set of a device path is refused rather than quoted.
    static func script(focusing tty: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        guard tty.hasPrefix("/dev/"), tty.count <= 64,
              tty.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        // The inner `try` keeps one tab with an unreadable tty (a closing
        // window, a missing value) from failing the whole search — the old
        // per-tab walk had the same exposure on every event.
        return """
            tell application "Terminal"
              set ttyLists to tty of tabs of windows
              set wi to 0
              repeat with wl in ttyLists
                set wi to wi + 1
                set ti to 0
                repeat with tv in wl
                  set ti to ti + 1
                  try
                    if (tv as text) is "\(tty)" then
                      set w to window wi
                      set selected tab of w to tab ti of w
                      set index of w to 1
                      activate
                      return "ok"
                    end if
                  end try
                end repeat
              end repeat
              return "notfound"
            end tell
            """
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
        case .failure(let e): return .failed(e.message)
        }
    }

    /// Only a name shaped the way `launchTmux` actually makes one (`tb-`
    /// plus an 8-char hex session-id prefix) is ever attached to — the same
    /// posture `script(focusing:)` takes with a tty: refuse to script
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
    static func attachScript(
        binary: String, socket: String?, tmuxTmpDir: String, sessionName: String
    ) -> String? {
        guard !sessionName.isEmpty, sessionName.count <= 64,
              sessionName.unicodeScalars.allSatisfy({ sessionNameCharset.contains($0) })
        else { return nil }
        let command: String
        if let socket {
            command = """
                "env TMUX_TMPDIR=" & quoted form of "\(tmuxTmpDir)" \
                & " " & quoted form of "\(binary)" & " -L " & quoted form of "\(socket)" \
                & " attach -t " & quoted form of "\(sessionName)"
                """
        } else {
            command = """
                quoted form of "\(binary)" & " attach -t " & quoted form of "\(sessionName)"
                """
        }
        return """
            tell application "Terminal"
              activate
              do script \(command)
            end tell
            """
    }

    /// Never call from the main actor: the one Apple event still blocks for
    /// up to `timeout` when Terminal is busy, and a main-thread block past
    /// ~1 s trips the event-tap watchdog and silently kills the hotkeys.
    public static func focus(tty: String, timeout: TimeInterval = 5) async -> Outcome {
        if let pane = TmuxOwnership.pane(forTty: tty) {
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
            return outcome(of: await AppleScript.run(script: script, timeout: timeout),
                           timeout: timeout)
        }
        guard let script = script(focusing: tty) else {
            return .failed("refused to script an unexpected tty form: \(tty)")
        }
        return outcome(of: await AppleScript.run(script: script, timeout: timeout),
                       timeout: timeout)
    }
}
