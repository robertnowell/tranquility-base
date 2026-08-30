import Foundation

/// Grant Codex's hook trust, once, because the user asked for it.
///
/// Codex will not run a hooks file it has not had reviewed, and it declines in
/// silence: no hook, no warning, no log line (measured 28 Aug against
/// codex-cli 0.150.1). The grant is a menu in its TUI and there is no other
/// route. Checked the same day: no CLI flag persists it
/// (`--dangerously-bypass-hook-trust` is per-invocation by design), and the
/// `trusted_hash` it writes is an internal canonicalisation this repo could
/// not reproduce, so writing the record ourselves is out. Codex's app-server
/// does expose `SetHookTrusted`, but this app has ruled the app-server out
/// twice on dual-path grounds and a one-off grant is not the place to reopen
/// that.
///
/// So: drive the menu. THE DISTINCTION THAT MAKES THIS ALLOWED is that the
/// user pressed a button asking for it. `CodexAdapter.neverAutoAcceptNeedles`
/// keeps the LAUNCH watcher's hands off this same screen, and that rule stands
/// exactly as written: a launcher that silently presses a security prompt is
/// the thing nobody wants. A launcher pressing it during a launch and a person
/// clicking "approve" in a setup screen are different acts, and only the
/// second one has consent attached. This type exists so the code can tell them
/// apart instead of one rule having to mean both.
public enum CodexHookApproval {

    public enum Outcome: Sendable, Equatable {
        /// Nothing to do; the record was already there.
        case alreadyGranted
        /// The menu was answered and the record appeared.
        case granted
        /// Codex never showed the review menu. Usually means the hooks are
        /// already trusted from another route, but the record still says no,
        /// so it is reported rather than assumed away.
        case promptNeverAppeared
        /// Answered, and the record never appeared. Deliberately distinct from
        /// the case above: one is "we were not asked", the other is "we
        /// answered and it did not take".
        case notRecorded
        case failed(String)
    }

    /// The row that grants it, by its own words rather than its position.
    ///
    /// Measured on codex-cli 0.150.1 the menu reads:
    ///
    ///     1. Review hooks
    ///     2. Trust all and continue
    ///     3. Continue without trusting (hooks won't run)
    ///
    /// Hardcoding "2" would work today and would silently start choosing
    /// "Review hooks" the day a row is inserted above it, which is the worst
    /// available failure: a menu answered with the wrong choice, by us, about
    /// security. So the digit is read off the line that says what we mean.
    /// nil when no such row is on screen, and the caller then presses nothing.
    public static func trustAllOption(onScreen text: String) -> String? {
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains("trust all") else { continue }
            // The leading digit of "› 2. Trust all and continue".
            guard let digit = line.first(where: { $0.isNumber }) else { continue }
            return String(digit)
        }
        return nil
    }

    /// True once the screen is showing the review menu.
    public static func isReviewPrompt(_ text: String) -> Bool {
        text.contains("Hooks need review")
    }

    /// Everything injected, so the whole decision is testable without a real
    /// Codex, a real pane, or a real config file. The app supplies tmux for
    /// `read`/`press` and `HookManifest.approval` for `granted`.
    ///
    /// `granted` is checked FIRST and LAST. First because the cheapest correct
    /// answer is "you already have it"; last because the menu closing is not
    /// evidence the record was written, and this returns what the config says
    /// rather than what the keystroke implied.
    public static func grant(
        read: () -> String?,
        press: (String) -> Void,
        granted: () -> Bool,
        wait: (TimeInterval) -> Void,
        pollInterval: TimeInterval = 1.0,
        maxPolls: Int = 25
    ) -> Outcome {
        if granted() { return .alreadyGranted }

        var answered = false
        for _ in 0..<maxPolls {
            guard let screen = read() else { wait(pollInterval); continue }
            if !answered, isReviewPrompt(screen) {
                guard let option = trustAllOption(onScreen: screen) else {
                    return .failed("the review menu had no \"trust all\" row")
                }
                press(option)
                press("\r")
                answered = true
            }
            if granted() { return .granted }
            wait(pollInterval)
        }
        if granted() { return .granted }
        return answered ? .notRecorded : .promptNeverAppeared
    }
}

// MARK: - Driving a real Codex

extension CodexHookApproval {

    /// The flag that SUPPRESSES the review menu, and therefore must not be on
    /// the command this drives.
    ///
    /// It is on the configured launch command by design (that is what makes
    /// TB-launched sessions work before the grant exists), and leaving it there
    /// here would open a Codex that never asks, which this code would then
    /// correctly report as `promptNeverAppeared` forever. Subtle enough to be
    /// worth naming rather than commenting.
    static let suppressingFlag = "--dangerously-bypass-hook-trust"

    public static func commandThatWillAsk(_ configured: String) -> String {
        configured.split(separator: " ")
            .filter { $0 != suppressingFlag }
            .joined(separator: " ")
    }

    /// Open a throwaway Codex session, answer its review menu, verify the
    /// record, and close it again.
    ///
    /// The session is its own tmux session with a distinctive name, killed in
    /// every exit path, so it can never be mistaken for an agent: it does not
    /// go in the ownership store, it is never dispatched to, and a grid that
    /// saw it would be showing a row for a thing that exists for nine seconds.
    public static func grantByDrivingCodex(
        harness: HookManifest.Harness,
        command: String,
        directory: String,
        socket: String = "tb",
        trace: (@Sendable (String) -> Void)? = nil
    ) -> Outcome {
        guard HookManifest.approval(for: harness) != .granted else {
            return .alreadyGranted
        }
        let name = "tb-approve-hooks-\(UUID().uuidString.prefix(8))"
        let asking = commandThatWillAsk(command)
        trace?("approve: opening \(name) with `\(asking)`")

        if case .failure(let error) = Tmux.run(
            ["new-session", "-d", "-s", name, "-x", "200", "-y", "50",
             "-c", directory, asking], socket: socket) {
            return .failed("could not open a tmux session: \(error.message)")
        }
        defer {
            _ = Tmux.run(["kill-session", "-t", name], socket: socket)
            trace?("approve: closed \(name)")
        }

        let outcome = grant(
            read: { try? Tmux.run(["capture-pane", "-p", "-t", name],
                                   socket: socket).get() },
            press: { key in
                if key == "\r" {
                    _ = Tmux.run(["send-keys", "-t", name, "Enter"], socket: socket)
                } else {
                    _ = Tmux.run(["send-keys", "-t", name, "-l", key], socket: socket)
                }
            },
            granted: { HookManifest.approval(for: harness) == .granted },
            wait: { Thread.sleep(forTimeInterval: $0) })
        trace?("approve: \(harness.id) -> \(outcome)")
        return outcome
    }
}
