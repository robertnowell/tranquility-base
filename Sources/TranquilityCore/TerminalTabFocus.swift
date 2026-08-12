import Foundation

/// Focus the Terminal tab attached to a tty — the addressing half of
/// "go to session".
///
/// One osascript run, two Apple events, regardless of how many tabs exist:
/// a batched `tty of tabs of windows` fetch answers for every tab at once,
/// then a single select-and-raise lands on the match. The shape it replaces —
/// one `tty of t` Apple event per tab — is the shape that froze the app
/// (issue 14): 192 open tabs meant 192 round-trips, 3.5 s against an idle
/// Terminal and unbounded against a busy one, each event entitled to the
/// two-minute default Apple-event timeout. Measured 12 Aug: the batched fetch
/// answers the same 192 tabs in ~120 ms.
///
/// The index math runs locally between the two events, so window/tab indices
/// are only trusted for the milliseconds between fetch and select — the same
/// script execution.
public enum TerminalTabFocus {
    public enum Outcome: Equatable, Sendable {
        /// The tab is selected, its window raised, Terminal activated.
        case focused
        /// Every tab answered; none carries this tty.
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

    /// Never call from the main actor: the one Apple event still blocks for
    /// up to `timeout` when Terminal is busy, and a main-thread block past
    /// ~1 s trips the event-tap watchdog and silently kills the hotkeys.
    public static func focus(tty: String, timeout: TimeInterval = 5) async -> Outcome {
        guard let script = script(focusing: tty) else {
            return .failed("refused to script an unexpected tty form: \(tty)")
        }
        return outcome(of: await AppleScript.run(script: script, timeout: timeout),
                       timeout: timeout)
    }
}
