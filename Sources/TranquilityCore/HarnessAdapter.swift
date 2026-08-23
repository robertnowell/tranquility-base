import Foundation

/// What a terminal AI harness is, as a set of facts rather than a name.
///
/// Milestone 2 of the arc: the coupling map the 19 Aug audit drew (Claude
/// Code's resume flag written twice, its trust needles watched by two
/// hand-copied loops, one for each transport) collapses into this. The
/// protocol is deliberately small and deliberately explicit about variance —
/// the multi-harness survey's one documented regret (Happy's
/// `respondToPermission`, one method silently meaning different things per
/// backend) is the shape every capability here is written to avoid: each
/// value is a fact about ONE harness, named for what it is, not inferred.
public protocol HarnessAdapter: Sendable {
    /// Stable, human-legible: "claude-code", "codex". Persisted nowhere yet;
    /// exists so a log line or a card can say which harness it means.
    var id: String { get }

    /// What `ps -o comm=` actually prints for a live process of this harness
    /// — deliberately NOT `id`: Claude Code's id is "claude-code" but its
    /// binary is `claude`, and conflating the two would silently break the
    /// pid-reuse guard in `SessionTermination` the day it looks up an
    /// adapter by id and expects the result to match a process listing.
    var processCommandFragment: String { get }

    /// The command a launcher runs, and how it appends a resume target.
    /// A FUNCTION, not a string suffix: Claude Code resumes with a flag
    /// (`--resume <id>`), Codex with a subcommand (`resume <id>`), and a
    /// suffix string cannot represent that difference — the exact shape the
    /// audit flagged when it found `resumeSuffix()` written once in
    /// `AgentDefaults` and the literal `["--resume", sessionId]` written
    /// again, independently, in `SessionDiscovery.reviveCommand`.
    func resumeArguments(sessionId: String) -> [String]

    /// The directory-trust prompt this harness's TUI shows on an unfamiliar
    /// cwd, if it has one — nil skips the watcher entirely rather than
    /// polling for needles that will never appear.
    var trustPrompt: TrustPromptSpec? { get }

    /// Facts about the TUI a launcher/transport needs and must never guess:
    /// does pasted text echo into a visible composer line, what glyph marks
    /// the composer's own line, does the harness queue typed input while
    /// mid-turn rather than reject it, does it register with a liveness
    /// probe TB can poll, does it have a hook system TB's intake can lean
    /// on. STILL NOT CONSUMED (M2 gate finding; M3 landed — dispatch-target
    /// resolution, not harness wiring — and did not touch this either):
    /// TmuxTransport's landing check still hardcodes its own "every target
    /// echoes" belief rather than reading `echoesPaste` per target, because
    /// `DispatchTarget` carries no adapter reference yet. A parity test
    /// (`HarnessAdapterTests.testClaudeCodeEchoesPasteMatchesWhatTmuxTransportAssumes`)
    /// pins the two together until the wiring itself lands. That now lands
    /// WITH CodexAdapter by design, not after it: a second adapter is what
    /// makes per-target harness selection a real question rather than a
    /// field with one possible answer — see `docs/architecture-program.md`'s
    /// CodexAdapter checklist item.
    var capabilities: HarnessCapabilities { get }
}

public struct HarnessCapabilities: Sendable {
    public var echoesPaste: Bool
    public var promptGlyph: String
    public var queuesInputMidTurn: Bool
    public var registersWithLiveness: Bool
    public var hasHooks: Bool
    /// Whether this harness tolerates a SECOND process resuming a
    /// conversation the first is still holding open. Named 21 Aug
    /// (2026-08-21-tb-dual-live-harness-parity, 2026-08-21-tb-codex-tmux-
    /// prior-art), measured live on both harnesses: Claude Code allows it
    /// (and arbitrates it with its own "Remote Control" feature) — true.
    /// Codex's app-server enforces a hard single-writer-per-thread lock; a
    /// second `resume` fails immediately and cleanly with JSON-RPC `-32600`
    /// ("already has an active writer"), and OpenAI was asked for a first-
    /// party way around it (`codex inject`, issue #11415) and closed it "not
    /// planned" — false. `Coordinator`'s adoption logic branches on this:
    /// true means launch a tmux twin and leave the original process alone;
    /// false means graceful end, then resume, with the user's approval.
    public var allowsConcurrentResume: Bool

    public init(echoesPaste: Bool, promptGlyph: String, queuesInputMidTurn: Bool,
               registersWithLiveness: Bool, hasHooks: Bool, allowsConcurrentResume: Bool) {
        self.echoesPaste = echoesPaste
        self.promptGlyph = promptGlyph
        self.queuesInputMidTurn = queuesInputMidTurn
        self.registersWithLiveness = registersWithLiveness
        self.hasHooks = hasHooks
        self.allowsConcurrentResume = allowsConcurrentResume
    }
}

/// What a launcher's trust watcher looks for and how it answers.
///
/// One generic loop (`TrustPromptWatcher.watch`) reads this instead of two
/// hand-copied 40-line loops (one per transport) each carrying the same
/// needles by hand. Needles are matched by substring, not regex: both
/// existing watchers already worked this way and neither ever needed more.
public struct TrustPromptSpec: Sendable {
    /// Any one of these appearing means the prompt is up.
    public var promptNeedles: [String]
    /// Seeing this means the TUI started with NOTHING to accept — stop
    /// watching immediately (Claude Code's "? for shortcuts" hint line).
    public var startedWithNoPromptNeedle: String?
    /// Seeing this twice in a row (banner settled) with no prompt needle
    /// means the same thing, less specifically — the fallback sentinel.
    public var settledBannerNeedle: String
    /// Consecutive settled-banner sightings required before giving up on a
    /// prompt ever appearing.
    public var settledThreshold: Int
    /// Needles this loop must NEVER press through, checked before
    /// `promptNeedles`. Added for Codex's hooks-review dialog ("Hooks need
    /// review... Trust all and continue"): hook-trust is the user's own
    /// choice, never auto-accepted — the same bar the directory-trust prompt
    /// clears only because Robert's 05 Aug ruling gave TB standing consent
    /// for THAT one specific prompt. Seeing one of these stops the watcher
    /// exactly as "nothing appeared at all" does; no user-facing escalation
    /// is wired yet (open, see docs/architecture-program.md's CodexAdapter
    /// item) but the failure direction is safe either way — a prompt left
    /// sitting, never a consent TB had no authority to give.
    ///
    /// Honest about scope (gate finding, 21 Aug): the check itself is
    /// correct by construction — a screen matching both this and
    /// `promptNeedles` still never gets pressed, this list wins, always —
    /// but it is currently unreachable in the running app. No call site
    /// passes `CodexAdapter` to `SessionLauncher.watchForTrustPrompt` yet
    /// (both overloads default to `ClaudeCodeAdapter()`, whose own
    /// `neverAutoAcceptNeedles` is empty), so today this guarantee lives in
    /// the type, not in anything that runs. And even once wired: Codex
    /// loads hooks only AFTER directory trust is granted, so on a first-run
    /// untrusted launch the watcher presses the trust prompt and returns
    /// before a hooks-review dialog could ever render — the path where this
    /// actually fires is an already-trusted launch whose hooks changed
    /// since the last review, not the common first-run case.
    public var neverAutoAcceptNeedles: [String]

    public init(promptNeedles: [String], startedWithNoPromptNeedle: String?,
               settledBannerNeedle: String, settledThreshold: Int = 2,
               neverAutoAcceptNeedles: [String] = []) {
        self.promptNeedles = promptNeedles
        self.startedWithNoPromptNeedle = startedWithNoPromptNeedle
        self.settledBannerNeedle = settledBannerNeedle
        self.settledThreshold = settledThreshold
        // An empty string here would match every screen — `"".isEmpty ==
        // false` for `text.contains("")` — and permanently disable the
        // watcher on the very first poll. Can't happen from either adapter
        // today; making it impossible is cheaper than trusting that stays
        // true (gate finding, 21 Aug).
        self.neverAutoAcceptNeedles = neverAutoAcceptNeedles.filter { !$0.isEmpty }
    }
}

/// Claude Code, as a HarnessAdapter. The facts here are measurements, not
/// defaults: needles verified live 19 Aug against a real trust prompt
/// (`SessionLauncher.watchForTrustPrompt`), echo verified live 19 Aug on the
/// tmux composer, resume flag unchanged from `AgentDefaults.resumeSuffix()`.
public struct ClaudeCodeAdapter: HarnessAdapter {
    public let id = "claude-code"
    public let processCommandFragment = "claude"

    public init() {}

    public func resumeArguments(sessionId: String) -> [String] {
        ["--resume", sessionId]
    }

    public var trustPrompt: TrustPromptSpec? {
        TrustPromptSpec(
            promptNeedles: ["trust this folder", "Do you trust"],
            startedWithNoPromptNeedle: "? for shortcuts",
            settledBannerNeedle: "Claude",
            // The resume-depth prompt ("Resuming the full session will
            // consume a substantial portion of your usage limits") — a real
            // usage-cost decision that stays with the human, same bar as
            // Codex's hooks-review dialog below. Found live, 23 Aug: a
            // revive that landed here showed a green "✓ RESUMED" chip with
            // nothing on screen to say a decision was still pending, and the
            // session sat there until someone happened to go looking.
            // Ruled (Robert, 23 Aug, verbatim): "if there's a question and
            // the user has to answer then not showing the window is
            // broken." `TrustPromptWatcher`'s `onNeedsHuman` now opens the
            // pane automatically whenever any needle in this list is hit —
            // this one included.
            neverAutoAcceptNeedles: ["Resuming the full session will consume"])
    }

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(echoesPaste: true, promptGlyph: "❯",
                            queuesInputMidTurn: true, registersWithLiveness: true,
                            hasHooks: true, allowsConcurrentResume: true)
    }
}

/// Codex, as a HarnessAdapter. Measured live 21 Aug against codex-cli 0.149.0
/// in a real tmux pane (the same live-verify battery this file's gate
/// requires — see the audit-gate commit for the process): directory-trust
/// needle and glyph confirmed against a live prompt and composer, echo and
/// mid-turn queueing confirmed by actually sending two messages back to
/// back (a plain Enter mid-turn queued the second one and it was answered
/// as its own turn — the same mechanism TB's transport already uses, not a
/// new one it needs), hooks confirmed by two real SessionStart firings.
/// `allowsConcurrentResume` is 19-20 Aug + repeated this session, not new
/// today: a second `resume` on a thread still held open fails with -32600.
///
/// NOT reconfirmed today, honestly: `neverAutoAcceptNeedles`'s exact text is
/// the 19-20 Aug C0 finding, carried forward — this scratch directory had no
/// project-level hook config to trigger it again live. `startedWithNoPrompt`
/// has no Codex equivalent found — see the needle-choice note below, which
/// the gate corrected: the first version of this comment claimed "? for
/// shortcuts" appears WHILE the trust prompt is up (measured with a
/// scrollback-inclusive `capture-pane -S`), which is not what
/// `SessionLauncher` reads. A second live pass (gate, 21 Aug, plain
/// `capture-pane -p`, matching the real read path exactly) found the
/// opposite problem: on an UNTRUSTED dir, the trust-prompt screen shows
/// ONLY the prompt block — no hint line, no banner, both pushed into
/// scrollback a plain capture cannot see. `nil` for `startedWithNoPrompt`
/// is still the right call (costs latency, never a wrong press), but the
/// settled-banner fallback below had to change with it — see its own note.
public struct CodexAdapter: HarnessAdapter {
    public let id = "codex"
    public let processCommandFragment = "codex"

    public init() {}

    public func resumeArguments(sessionId: String) -> [String] {
        ["resume", sessionId]
    }

    public var trustPrompt: TrustPromptSpec? {
        TrustPromptSpec(
            promptNeedles: ["Do you trust the contents of this directory?"],
            startedWithNoPromptNeedle: nil,
            // NOT "OpenAI Codex" (the header box) — the first version of
            // this needle, wrong: the gate's live re-verification (plain
            // `capture-pane -p`, 21 Aug) found the header scrolls into
            // scrollback within ~1s of any real output, invisible to the
            // exact read `SessionLauncher` does. A watcher relying on it
            // would burn its full ~30s timeout on every ordinary, no-
            // trust-prompt Codex launch. "Ask Codex to do anything" is the
            // composer's own idle placeholder — sits at the bottom of the
            // pane, not scrollable history, confirmed 10/10 across repeated
            // polls of a resumed (already-trusted) session.
            settledBannerNeedle: "Ask Codex to do anything",
            neverAutoAcceptNeedles: ["Hooks need review"])
    }

    /// Codex's own single-writer-lock refusal — measured live, 22 Aug,
    /// against real codex-cli 0.149.0: resuming a session a second process
    /// already holds does NOT exit immediately (an earlier, app-server-level
    /// JSON-RPC measurement said "exits immediately, status 1" — that
    /// described a different code path than the CLI's own TUI takes). The
    /// TUI instead shows the error INSIDE its normal interface and stays
    /// open for several seconds: "Error: Failed to resume session from
    /// .../rollout-....jsonl: thread/resume failed during TUI bootstrap:
    /// thread/resume failed: thread <id> already has an active writer
    /// (code -32600)". This substring is the stable part — legible on its
    /// own in a trace line, unlike the bare code — and is what
    /// `SessionLauncher.attemptCodexResume` polls for to tell "the session
    /// is live elsewhere" apart from an ordinary successful resume.
    public static let resumeConflictNeedle = "already has an active writer"

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(echoesPaste: true, promptGlyph: "›",
                            queuesInputMidTurn: true, registersWithLiveness: false,
                            hasHooks: true, allowsConcurrentResume: false)
    }
}

/// The one trust-prompt loop, parameterized by how to read a screen and how
/// to press Return — the two primitives that used to be the entire
/// difference between the AppleScript watcher and the tmux watcher. Both now
/// call this with their own `read`/`press`, and a `TrustPromptSpec` supplies
/// every needle. `nil` spec (a harness with no trust prompt) never calls in.
public enum TrustPromptWatcher {
    /// `pollInterval` is injectable (M2 gate finding): a test proving control
    /// flow ("accept on the needle", "stand down on the sentinel") does not
    /// need to pay the real 2s-per-poll wall-clock cost this loop uses live —
    /// three such tests once cost ~10s of `swift test` for zero additional
    /// evidence.
    public static func watch(
        spec: TrustPromptSpec,
        read: () -> String?,
        press: () -> Void,
        trace: (@Sendable (String) -> Void)? = nil,
        label: String = "",
        pollInterval: TimeInterval = 2.0,
        maxPolls: Int = 15,
        // Fired exactly once, exactly when a `neverAutoAcceptNeedles` needle
        // is hit — a screen this loop will never press through because the
        // choice on it is a real cost the human bears (a resume-depth
        // token spend, a hooks-review grant), never TB's to make silently.
        // "Never press it" and "never let anyone SEE it" are different
        // promises; this loop only ever kept the first one, which is
        // exactly the gap ruled a real bug 23 Aug (see ClaudeCodeAdapter's
        // own comment on this needle) — default no-op so every caller that
        // predates this stays byte-for-byte unchanged.
        onNeedsHuman: () -> Void = {}
    ) {
        var settled = 0
        for _ in 0..<maxPolls {
            usleep(UInt32(pollInterval * 1_000_000))
            guard let text = read() else { continue }
            if spec.neverAutoAcceptNeedles.contains(where: { text.contains($0) }) {
                trace?("newSession: \(label) needs a human choice, never auto-accepted; leaving it be")
                onNeedsHuman()
                return
            }
            if spec.promptNeedles.contains(where: { text.contains($0) }) {
                press()
                trace?("newSession: accepted the trust prompt in \(label) — user-commanded launch")
                // A second, DIFFERENT dialog (Claude Code's resume-depth
                // prompt) can render a beat after this one is answered, not
                // simultaneously with it — found live, 23 Aug: this loop
                // used to return the instant it pressed, so a
                // never-auto-accept needle that only appears AFTER the
                // trust prompt was never seen at all, and `onNeedsHuman`
                // never fired for the exact case it exists for. A few more
                // looks, never another press (only a needle match does
                // anything from here on) — bounded, so the ordinary case
                // (nothing follows) pays a few seconds, not fifteen polls.
                for _ in 0..<3 {
                    usleep(UInt32(pollInterval * 1_000_000))
                    guard let followUp = read() else { continue }
                    if spec.neverAutoAcceptNeedles.contains(where: { followUp.contains($0) }) {
                        trace?("newSession: \(label) needs a human choice after the trust "
                            + "prompt; leaving it be")
                        onNeedsHuman()
                        return
                    }
                }
                return
            }
            if let noPrompt = spec.startedWithNoPromptNeedle, text.contains(noPrompt) {
                return
            }
            if text.contains(spec.settledBannerNeedle) { settled += 1 } else { settled = 0 }
            if settled >= spec.settledThreshold {
                trace?("newSession: started with no trust prompt in \(label); watcher done")
                return
            }
        }
        let waited = Int(pollInterval * Double(maxPolls))
        trace?("newSession: no trust prompt seen in \(label) within \(waited)s; leaving it be")
    }
}
