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

    /// Directories to search for this harness's own binary, in priority
    /// order, joined into the `PATH` a launched tmux pane's shell sees.
    /// Harness-specific because install methods differ (npm/bun/homebrew
    /// for Claude Code, cargo among them for Codex, which ships from a
    /// Rust workspace) — a launcher that hand-copies one generic list, as
    /// `launchTmux` did before this, silently stops finding a harness
    /// installed somewhere that list didn't anticipate. `~` is expanded by
    /// the adapter itself (each conformance already knows its own home
    /// directory calls); a launcher never guesses at that expansion.
    var pathCandidates: [String] { get }

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
    /// field with one possible answer — see `docs/log/architecture-program.md`'s
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
    /// The chip a TUI draws INSTEAD of pasted text once the paste crosses
    /// its own inline-render limit — the prefix, since the chip carries a
    /// counter or a size that changes every time. `echoesPaste: true` is
    /// only half true without this, and the half it omits is the half that
    /// broke: measured live 23 Aug, both harnesses stop echoing large
    /// pastes. Claude Code v2.1.241 renders 800 characters literally and
    /// collapses 810 to `[Pasted text #N]`; codex-cli renders 1,000 and
    /// collapses 1,024 to `[Pasted Content NNNN chars]`. A landing check
    /// looking for the literal payload therefore CANNOT pass on a dictated
    /// utterance longer than a paragraph — the transport pasted, never saw
    /// its own text, never pressed Return, and left the words sitting in
    /// the box (found live 23 Aug, twice in one afternoon). nil means "this
    /// harness renders every paste literally", which is an assertion about
    /// a measurement, not a default to fall back on.
    public var pasteChipPrefix: String?

    public init(echoesPaste: Bool, promptGlyph: String, queuesInputMidTurn: Bool,
               registersWithLiveness: Bool, hasHooks: Bool, allowsConcurrentResume: Bool,
               pasteChipPrefix: String? = nil) {
        self.echoesPaste = echoesPaste
        self.promptGlyph = promptGlyph
        self.queuesInputMidTurn = queuesInputMidTurn
        self.registersWithLiveness = registersWithLiveness
        self.hasHooks = hasHooks
        self.allowsConcurrentResume = allowsConcurrentResume
        self.pasteChipPrefix = pasteChipPrefix
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
    /// is wired yet (open, see docs/log/architecture-program.md's CodexAdapter
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

    /// The menu row that GRANTS trust, and the glyph marking whichever row is
    /// currently selected.
    ///
    /// Empty needles mean "the accepting row is the selected one" — press
    /// Return where it stands, which is what this watcher did unconditionally
    /// until 27 Aug, and is still right for a harness whose prompt defaults to
    /// yes (Codex).
    ///
    /// It is NOT right for Claude Code, and the cost of assuming it was is the
    /// whole reason this field exists. Measured live, 27 Aug, in a pane TB had
    /// just launched:
    ///
    ///     ❯ No, exit
    ///       Yes, I trust this folder
    ///     Enter to confirm · Esc to cancel
    ///
    /// The cursor starts on **No, exit**. The v2.1 screen this watcher was
    /// written against put the accepting option first and numbered it
    /// ("❯ 1. Yes, I trust this folder"), so a bare Return accepted; the
    /// current screen drops the numbering and leads with the refusal, so the
    /// exact same keystroke DECLINES and Claude Code exits 1. The launch then
    /// dies in the most confusing way available: `new-session` printed a tty,
    /// the pane survived its one-second survival check, the watcher logged
    /// "accepted the trust prompt", and thirty seconds later nothing had
    /// registered and the panel said "Couldn't confirm the new agent started."
    /// Three launches in a row, 22:57 and 23:27, and the pane was already gone
    /// by the time anyone could attach to it and look.
    ///
    /// So the row is found by name and navigated to, rather than assumed to be
    /// under the cursor. Position is the thing that rotted; the words on the
    /// two rows are what actually distinguish them.
    public var acceptOptionNeedles: [String]
    /// The glyph tmux shows against the selected row. Substring-matched like
    /// every other needle here.
    public var selectionGlyph: String

    /// How many consecutive IDENTICAL, unrecognized screens mean the pane has
    /// STOPPED on something rather than still booting.
    ///
    /// The needle lists above enumerate; this counts. Enumeration is what
    /// failed on 27 Aug: codex-cli 0.150.0 shipped an "Update available!"
    /// menu that runs BEFORE the TUI boots, no needle knew it, and so every
    /// Codex launch on the machine sat on a menu nobody could see while the
    /// panel waited thirty seconds for a registration that could never come.
    /// Twenty-one panes deep before a human noticed, because the one thing
    /// that would have resolved it — the pane itself — was the one thing a
    /// deliberately detached launch never shows you.
    ///
    /// A needle for that screen would have fixed that screen. The next
    /// prompt (an auth expiry, a model picker, a migration notice) would
    /// have failed exactly the same way, silently, and the fix would again
    /// be a string added after the fact. So the rule underneath the needles
    /// is a shape, not a word: **a pane that has stopped changing and is not
    /// showing its composer is waiting on a human.** Whatever the question
    /// is, that is the one fact the panel needs, and it is true of every
    /// question a harness has not been born with yet.
    ///
    /// Three, not two: the settled-banner threshold is two, and a stuck
    /// screen must never be able to beat a settling one to the verdict. At
    /// the live 2s poll that is a call at ~8s, comfortably inside the 30s
    /// registration wait it exists to pre-empt.
    public var stuckThreshold: Int

    public init(promptNeedles: [String], startedWithNoPromptNeedle: String?,
               settledBannerNeedle: String, settledThreshold: Int = 2,
               neverAutoAcceptNeedles: [String] = [], stuckThreshold: Int = 3,
               acceptOptionNeedles: [String] = [],
               selectionGlyph: String = "❯") {
        self.promptNeedles = promptNeedles
        self.startedWithNoPromptNeedle = startedWithNoPromptNeedle
        self.settledBannerNeedle = settledBannerNeedle
        self.settledThreshold = settledThreshold
        self.acceptOptionNeedles = acceptOptionNeedles.filter { !$0.isEmpty }
        self.selectionGlyph = selectionGlyph
        self.stuckThreshold = stuckThreshold
        // An empty string here would match every screen — `"".isEmpty ==
        // false` for `text.contains("")` — and permanently disable the
        // watcher on the very first poll. Can't happen from either adapter
        // today; making it impossible is cheaper than trusting that stays
        // true (gate finding, 21 Aug).
        self.neverAutoAcceptNeedles = neverAutoAcceptNeedles.filter { !$0.isEmpty }
    }

    /// How far the selection must move for Return to accept: positive means
    /// that many `Down` presses, negative that many `Up`, zero means press
    /// where it stands.
    ///
    /// `nil` means the screen could not be read as a menu — the accepting row
    /// or the cursor is missing — and is deliberately NOT the same answer as
    /// zero. Pressing blind is what shipped the bug this replaces, so an
    /// unreadable menu is escalated to the human instead of guessed at; a
    /// prompt left sitting with a window open on it is recoverable, a silently
    /// declined launch is not.
    ///
    /// Rows are one line each on both harnesses' prompts, so line distance IS
    /// selection distance. A prompt that ever wraps an option across two lines
    /// would need this to count rows rather than lines — it would misnavigate
    /// rather than fail loudly, which is the one weakness worth naming here.
    public func stepsToAccept(on screen: String) -> Int? {
        guard !acceptOptionNeedles.isEmpty else { return 0 }
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let accept = lines.firstIndex(where: { line in
            acceptOptionNeedles.contains(where: { line.contains($0) })
        }) else { return nil }
        guard let cursor = lines.firstIndex(where: { $0.contains(selectionGlyph) })
        else { return nil }
        return accept - cursor
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
            neverAutoAcceptNeedles: ["Resuming the full session will consume"],
            // Both wordings, for the same reason `promptNeedles` carries
            // both: the numbered v2.1 row ("1. Yes, I trust this folder")
            // and the current unnumbered one are the same substring from
            // "Yes" onward, so one needle covers each. See
            // `acceptOptionNeedles` for what pressing Return without this
            // cost on 27 Aug.
            acceptOptionNeedles: ["Yes, I trust this folder"])
    }

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(echoesPaste: true, promptGlyph: "❯",
                            queuesInputMidTurn: true, registersWithLiveness: true,
                            hasHooks: true, allowsConcurrentResume: true,
                            pasteChipPrefix: "[Pasted text #")
    }

    /// Same install locations `ClaudeAgentsCLI.resolveBinary()` already
    /// searches for the `claude` binary itself, minus the filename — the
    /// two lists describe the same fact (where this harness's install
    /// methods put a binary) for two different consumers (finding the
    /// binary to run `claude agents --json` vs. building a launched pane's
    /// `PATH`), so they stay in sync by staying the same list, not by
    /// coincidence.
    public var pathCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin", "\(home)/.claude/local",
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "/usr/bin", "/bin",
        ]
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
                            hasHooks: true, allowsConcurrentResume: false,
                            pasteChipPrefix: "[Pasted Content ")
    }

    /// This machine's own `codex` resolves through `~/.local/bin` same as
    /// `claude` (confirmed live, 23 Aug: a symlink into
    /// `~/.codex/packages/standalone/current/bin/codex`), so the common
    /// locations are shared with `ClaudeCodeAdapter`. `~/.cargo/bin` is
    /// listed too, ahead of the generic homebrew/usr paths: codex-rs is a
    /// Rust workspace, and a machine that built or installed it via cargo
    /// rather than the npm/standalone distribution would put it there —
    /// unverified on THIS machine (nothing installed that way here to
    /// check against), included because the failure mode of guessing wrong
    /// is silent (a launch that can't find `codex` at all), not because it
    /// was measured.
    public var pathCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin", "\(home)/.cargo/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "/usr/bin", "/bin",
        ]
    }
}

/// Every harness this app currently knows how to launch, and how to look one
/// up by `id` — the one place that question gets answered, so a settings
/// picker and a launch call site resolve "which adapter does this id mean"
/// the same way instead of each keeping their own list.
public enum KnownHarnesses {
    public static let all: [any HarnessAdapter] = [ClaudeCodeAdapter(), CodexAdapter()]

    /// Unrecognized ids (a harness this build predates) resolve to Claude
    /// Code rather than trap — the same fail-safe direction
    /// `AgentDefaults.fallback(for:)` already takes.
    public static func adapter(for id: String) -> any HarnessAdapter {
        all.first(where: { $0.id == id }) ?? ClaudeCodeAdapter()
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
        // Moves the selection `steps` rows (negative is up) and confirms.
        // Took no argument until 27 Aug, when "confirm whatever is selected"
        // turned out to mean "exit" on Claude Code's current trust screen —
        // see `TrustPromptSpec.acceptOptionNeedles`.
        press: (_ steps: Int) -> Void,
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
        //
        // It carries the question as of 27 Aug, because "someone should look
        // at this pane" and "Codex is asking whether to update" are different
        // amounts of help, and the second one costs a `first(where:)` over a
        // screen this loop has already read. A caller that only wants to open
        // a window ignores it.
        onNeedsHuman: (String) -> Void = { _ in }
    ) {
        var settled = 0
        // The screen this loop last looked at, kept for two things it could
        // not do without it. The give-up exit can SAY what it saw: every
        // version before 27 Aug read the pane fifteen times, matched each read
        // against a fixed list of needles, threw the text away on every miss,
        // and then logged the absence. And the loop can tell a pane that is
        // STILL BOOTING from one that has STOPPED, which is the only evidence
        // available about a screen no needle knows — see `stuckThreshold`.
        var lastScreen: String?
        var unchanged = 0
        for _ in 0..<maxPolls {
            usleep(UInt32(pollInterval * 1_000_000))
            guard let text = read() else { continue }
            // Counted BEFORE the needles, so the count is about the pane
            // rather than about which branch happened to look at it.
            if text == lastScreen { unchanged += 1 } else { unchanged = 1 }
            lastScreen = text
            if spec.neverAutoAcceptNeedles.contains(where: { text.contains($0) }) {
                trace?("newSession: \(label) needs a human choice, never auto-accepted; leaving it be")
                onNeedsHuman(Self.questionOnScreen(text) ?? "It is asking you something.")
                return
            }
            if spec.promptNeedles.contains(where: { text.contains($0) }) {
                // Where the accepting row is RELATIVE TO THE CURSOR, read off
                // the same capture that matched the needle — not a second read
                // that could catch the menu mid-repaint with the selection
                // somewhere else.
                guard let steps = spec.stepsToAccept(on: text) else {
                    trace?("newSession: \(label) is on a trust prompt whose accepting option "
                        + "this build cannot find — refusing to press blind; opening a window")
                    // The screen itself, same as every other needs-a-human
                    // exit: the one thing that resolves an unrecognised menu
                    // is seeing it, and this branch exists precisely because
                    // nothing here knows what the options say.
                    onNeedsHuman(Self.questionOnScreen(text)
                        ?? "It is asking whether you trust this folder.")
                    return
                }
                press(steps)
                trace?("newSession: accepted the trust prompt in \(label) "
                    + "(\(steps) row\(abs(steps) == 1 ? "" : "s") to the accepting option) "
                    + "— user-commanded launch")
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
                        onNeedsHuman(Self.questionOnScreen(followUp) ?? "It is asking you something.")
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
            // Nothing above recognized this screen. Recognition is not the
            // only evidence available: a TUI that is booting REDRAWS, and one
            // that has stopped on a question does not. So compare the screen
            // to the last one instead of to a needle — see
            // `TrustPromptSpec.stuckThreshold` for the 27 Aug launch that
            // this is the whole answer to.
            if unchanged >= spec.stuckThreshold, let question = Self.questionOnScreen(text) {
                trace?("newSession: \(label) has stopped on a screen this launcher does not "
                    + "know and cannot answer: \(question)")
                onNeedsHuman(question)
                return
            }
        }
        // Giving up is a THIRD kind of needs-a-human, and until 27 Aug it was
        // the only one with no promise attached to it at all.
        //
        // The 23 Aug ruling separated two promises — "never press it" and
        // "never let anyone SEE it" — and wired `onNeedsHuman` to the first
        // list of needles that needed both. This exit is the case the ruling
        // did not reach: a screen we do not RECOGNISE. It got neither promise,
        // because a needle list can only speak about prompts somebody already
        // knew to name.
        //
        // Measured, 27 Aug: Codex 0.149.0 began greeting every fresh pane with
        // "✨ Update available! 0.149.0 -> 0.150.0 … Press enter to continue"
        // and stopped there. This loop read that screen fifteen times over
        // thirty seconds, matched it against every needle, missed on all of
        // them, discarded it, and logged "no trust prompt seen". Twenty-one of
        // twenty-two Codex panes on the machine were sitting on it. Nothing in
        // the app had ever said the words "Update available" — not because the
        // app could not see them, but because it only ever wrote down what it
        // was LOOKING for.
        //
        // So: a watcher that gives up logs what it was looking AT. A timeout
        // line naming only its expectation is unfalsifiable — identical
        // whether the pane was blank, crashed, or showing the answer.
        let waited = Int(pollInterval * Double(maxPolls))
        let screen = lastScreen.map { Self.meaningfulTail($0) } ?? "(nothing readable)"
        trace?("newSession: \(label) never looked started within \(waited)s. Its screen says: "
            + screen)
        // And it opens a window, because a pane stopped on something we cannot
        // name is exactly the pane a human should be looking at. `onNeedsHuman`
        // already does this and has since 23 Aug; it was wired to one needle
        // list, and the failures that matter are the ones nobody listed.
        onNeedsHuman(Self.questionOnScreen(lastScreen ?? "") ?? screen)
    }

    /// The bottom of a captured screen with the blank lines squeezed out —
    /// what a person would read if they glanced at the pane.
    ///
    /// Bottom, not top: a TUI's answer is on its last lines (the prompt, the
    /// menu, the error), while the top is the banner that is identical on
    /// every launch. Bounded, because this goes in a log line, and a log line
    /// nobody can scan is the same problem one layer along.
    static func meaningfulTail(_ screen: String, lines: Int = 6, width: Int = 400) -> String {
        let kept = screen
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: " ⏎ ")
        return kept.count > width ? String(kept.prefix(width)) + "…" : kept
    }

    /// The one line of a stopped screen worth repeating to the user.
    ///
    /// A capture is a rectangle of terminal, most of it chrome: box rules,
    /// a menu of numbered options, an ANSI-styled cursor glyph. The sentence
    /// a human needs is almost always the first one with words in it —
    /// "Update available! 0.149.0 -> 0.150.0", "Do you trust the contents of
    /// this directory?" — so that is what this takes, with the decoration in
    /// front of it (✨, ›, ❯, ─) trimmed off so the line starts where the
    /// words do.
    ///
    /// `nil` for a screen with nothing to say — an empty pane, a lone box
    /// rule — and that nil is load-bearing: it is what stops a pane that is
    /// merely slow to paint anything at all from being announced as a
    /// question. Four characters of actual word, minimum.
    public static func questionOnScreen(_ screen: String) -> String? {
        for raw in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = line.drop(while: { !$0.isLetter && !$0.isNumber })
            guard words.count >= 4 else { continue }
            return String(words.prefix(140))
        }
        return nil
    }
}
