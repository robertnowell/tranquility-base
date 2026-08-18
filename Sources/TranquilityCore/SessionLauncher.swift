import AppKit
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
/// Lives in Core so `tbase new` and the app's menu item are the same code path,
/// and because the only capability it needs — Terminal automation via
/// AppleScript — is already Core's (`AppleScript.run`, the dispatcher's own
/// transport). The Automation permission the app holds covers this identically:
/// same target app, same entitlement.
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
    /// Blocks while watching for the prompt — ~4s in the common case (two
    /// settled polls), up to ~30s if the tab never looks started; call
    /// off-main.
    /// Returns the new tab's tty, so a caller can watch exactly this window.
    ///
    /// **Terminal is not activated** (ruled 18 Aug: "the terminal window does
    /// not need to be focused"). Starting an agent is a background act — the
    /// panel is the interface, and the whole point of the greeting is that you
    /// never have to look at the tab. Nothing here needs focus either: the
    /// trust prompt is answered with `do script ""` into the tab by id, not
    /// with keystrokes, so it works on a window you were never shown.
    ///
    /// `resume` still activates, and that ruling stands for its own reason —
    /// a revived session asks a question (summary or full context) that only
    /// you can answer, in its own window.
    @discardableResult
    public static func launch(
        directory: String = defaultDirectory,
        command: String = defaultCommand,
        acceptTrustPrompt: Bool = true
    ) -> Result<String, ScriptError> {
        // `quoted form of` is AppleScript's own shell-quoting — the directory
        // never touches the shell unescaped. The tab's tty comes back so the
        // follow-up can address exactly this window and no other.
        let script = """
            tell application "Terminal"
              set newTab to do script "cd " & quoted form of "\(directory)" & " && \(command)"
              return tty of newTab
            end tell
            """
        switch AppleScript.run(script: script) {
        case .success(let tty):
            let tty = tty.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.trace?("newSession: launched `\(command)` in \(directory) (tty \(tty))")
            // Callers that drive their own watcher pass false and run
            // `watchForTrustPrompt` CONCURRENTLY: this blocks for at least two
            // settled polls (~4s) and up to 30, and everything waiting behind
            // it — the registration the greeting card binds to, in particular —
            // was paying that latency for a prompt that usually never appears.
            if acceptTrustPrompt { watchForTrustPrompt(tty: tty) }
            return .success(tty)
        case .failure(let error):
            Self.trace?("newSession FAILED: \(error.message)")
            return .failure(error)
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
        acceptTrustPrompt: Bool = true
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
        // shell quoting rather than trusted, because "cannot" is a property of
        // today's Claude Code and not of this function.
        let script = """
            tell application "Terminal"
              activate
              set newTab to do script "cd " & quoted form of "\(directory)" \
                & " && \(command) \(AgentDefaults.resumeSuffix()) " & quoted form of "\(sessionId)"
              return tty of newTab
            end tell
            """
        switch AppleScript.run(script: script) {
        case .success(let tty):
            let tty = tty.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.trace?("revive: resumed \(sessionId.prefix(8)) in \(directory) "
                + "as `\(command)` (tty \(tty))")
            if acceptTrustPrompt { watchForTrustPrompt(tty: tty) }
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
    public static func watchForTrustPrompt(tty: String) {
        var settled = 0
        for _ in 0..<15 {
            usleep(2_000_000)
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
                """) else { continue }
            if text.contains("trust this folder") || text.contains("Do you trust") {
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
                Self.trace?("newSession: accepted the trust prompt in \(tty) — user-commanded launch")
                return
            }
            // Interactive without a trust prompt: nothing to accept. Kept
            // alongside the banner check, not instead of it — an old CLI on
            // this machine would still exit on its hint line.
            if text.contains("? for shortcuts") { return }
            if text.contains("Claude") { settled += 1 } else { settled = 0 }
            if settled >= 2 {
                Self.trace?("newSession: started with no trust prompt in \(tty); watcher done")
                return
            }
        }
        Self.trace?("newSession: no trust prompt seen in \(tty) within 30s; leaving it be")
    }
}
