import Foundation

/// Spawn a fresh Claude session in a new Terminal window.
///
/// The dispatch loop is reactive by construction — sessions announce, the user
/// answers. This is the proactive half (ruled 05 Aug): "sometimes I want to
/// kick off an investigation." v1 is deliberately choiceless: always `claude`,
/// always `--dangerously-skip-permissions`, always the home directory. The two
/// knobs worth a UI (directory, agent command) arrive with the grid's
/// new-session affordance; adding options before the habit exists is furniture.
///
/// Lives in Core so `vdctl new` and the app's menu item are the same code path,
/// and because the only capability it needs — Terminal automation via
/// AppleScript — is already Core's (`AppleScript.run`, the dispatcher's own
/// transport). The Automation permission the app holds covers this identically:
/// same target app, same entitlement.
public enum SessionLauncher {

    /// Same shape as Coordinator.trace / QueueStore.trace: Core stays silent
    /// unless a host wires the log in.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    public static let defaultDirectory = NSHomeDirectory()
    public static let defaultCommand = "claude --dangerously-skip-permissions"

    /// Opens a new Terminal window in `directory` running `command`, and — by
    /// explicit ruling — clicks through Claude's own directory-trust prompt if
    /// it appears.
    ///
    /// Robert, 05 Aug, verbatim intent: "I authorize you to click through and
    /// start this. I told you to start the session. Start the session." The
    /// consent happened at the button press; the prompt is asking permission
    /// for the thing the user just commanded. The scope is surgical and stays
    /// that way: ONLY the tab this call just created (addressed by its tty),
    /// ONLY the known trust prompt, ONLY within thirty seconds of launch. The
    /// dispatcher's rule — never type into unregistered sessions — is intact
    /// everywhere else; this tab is not "some session", it is our own launch.
    ///
    /// Blocks up to ~30s while watching for the prompt; call off-main.
    @discardableResult
    public static func launch(
        directory: String = defaultDirectory,
        command: String = defaultCommand,
        acceptTrustPrompt: Bool = true
    ) -> Result<Void, ScriptError> {
        // `quoted form of` is AppleScript's own shell-quoting — the directory
        // never touches the shell unescaped. The tab's tty comes back so the
        // follow-up can address exactly this window and no other.
        let script = """
            tell application "Terminal"
              activate
              set newTab to do script "cd " & quoted form of "\(directory)" & " && \(command)"
              return tty of newTab
            end tell
            """
        switch AppleScript.run(script: script) {
        case .success(let tty):
            let tty = tty.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.trace?("newSession: launched `\(command)` in \(directory) (tty \(tty))")
            if acceptTrustPrompt { acceptTrustPromptIfShown(tty: tty) }
            return .success(())
        case .failure(let error):
            Self.trace?("newSession FAILED: \(error.message)")
            return .failure(error)
        }
    }

    /// Watch the just-launched tab; if Claude's trust prompt renders, press
    /// Return once (the same bare-Return `do script "" in t` the dispatcher
    /// uses to submit). Stops watching the moment the session looks started.
    private static func acceptTrustPromptIfShown(tty: String) {
        for _ in 0..<15 {
            usleep(2_000_000)
            guard case .success(let text) = AppleScript.run(script: """
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if (tty of t) as text is "\(tty)" then return contents of t
                    end repeat
                  end repeat
                  return ""
                end tell
                """) else { continue }
            if text.contains("Do you trust") {
                _ = AppleScript.run(script: """
                    tell application "Terminal"
                      repeat with w in windows
                        repeat with t in tabs of w
                          if (tty of t) as text is "\(tty)" then
                            do script "" in t
                            return "ok"
                          end if
                        end repeat
                      end repeat
                      return "notfound"
                    end tell
                    """)
                Self.trace?("newSession: accepted the trust prompt in \(tty) — user-commanded launch")
                return
            }
            // The prompt line Claude shows once it is interactive: nothing to accept.
            if text.contains("? for shortcuts") { return }
        }
        Self.trace?("newSession: no trust prompt seen in \(tty) within 30s; leaving it be")
    }
}
