import XCTest
@testable import TranquilityCore

final class HarnessAdapterTests: XCTestCase {

    func testClaudeCodeResumeArguments() {
        let adapter = ClaudeCodeAdapter()
        XCTAssertEqual(adapter.resumeArguments(sessionId: "abc-123"), ["--resume", "abc-123"])
    }

    func testClaudeCodeCapabilitiesMatchWhatWasMeasuredLive() {
        // These are measurements (19 Aug tmux battery), not defaults — a
        // regression here silently reintroduces the strict-landing-check gap
        // the M1 gate closed.
        let caps = ClaudeCodeAdapter().capabilities
        XCTAssertTrue(caps.echoesPaste)
        XCTAssertEqual(caps.promptGlyph, "❯")
        XCTAssertTrue(caps.queuesInputMidTurn)
        XCTAssertTrue(caps.registersWithLiveness)
        XCTAssertTrue(caps.hasHooks)
    }

    func testClaudeCodeTrustPromptNeedles() {
        let spec = ClaudeCodeAdapter().trustPrompt
        XCTAssertNotNil(spec)
        XCTAssertTrue(spec!.promptNeedles.contains("trust this folder"))
        XCTAssertTrue(spec!.promptNeedles.contains("Do you trust"))
        XCTAssertEqual(spec!.startedWithNoPromptNeedle, "? for shortcuts")
        XCTAssertEqual(spec!.settledBannerNeedle, "Claude")
    }

    func testClaudeCodePathCandidatesMatchWhatResolveBinaryAlreadySearches() {
        // The two lists describe the same install locations for two
        // different consumers (ClaudeAgentsCLI.resolveBinary() appends the
        // filename; this one is joined straight into a PATH) — same set
        // of directories, so a real machine's install method is found by
        // both or neither.
        let candidates = ClaudeCodeAdapter().pathCandidates
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin",
                    "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin"] {
            XCTAssertTrue(candidates.contains(dir), "missing \(dir)")
        }
        XCTAssertFalse(candidates.isEmpty)
    }

    // MARK: CodexAdapter — measured live 21 Aug, codex-cli 0.149.0, real tmux pane

    func testCodexResumeArguments() {
        let adapter = CodexAdapter()
        XCTAssertEqual(adapter.resumeArguments(sessionId: "abc-123"), ["resume", "abc-123"])
    }

    func testCodexCapabilitiesMatchWhatWasMeasuredLive() {
        let caps = CodexAdapter().capabilities
        XCTAssertTrue(caps.echoesPaste, "confirmed live: composer shows pasted text before Enter")
        XCTAssertEqual(caps.promptGlyph, "›", "distinct from Claude Code's ❯")
        XCTAssertTrue(caps.queuesInputMidTurn,
                      "confirmed live: a plain Enter mid-turn queued a second message, " +
                      "answered as its own turn once the first completed")
        XCTAssertFalse(caps.registersWithLiveness, "no `agents --json` equivalent exists")
        XCTAssertTrue(caps.hasHooks, "confirmed live: two real SessionStart firings")
        XCTAssertFalse(caps.allowsConcurrentResume,
                       "measured live: a second resume on a held thread fails with -32600")
    }

    func testCodexTrustPromptNeedles() {
        let spec = CodexAdapter().trustPrompt
        XCTAssertNotNil(spec)
        XCTAssertTrue(spec!.promptNeedles.contains("Do you trust the contents of this directory?"))
        XCTAssertNil(spec!.startedWithNoPromptNeedle,
                     "no reliable Codex equivalent found: a plain (non-scrollback) " +
                     "capture-pane read — the exact read SessionLauncher does — shows " +
                     "ONLY the prompt block on an untrusted-dir screen; no hint line, " +
                     "no banner, both are already in scrollback (gate finding, 21 Aug)")
        XCTAssertEqual(spec!.settledBannerNeedle, "Ask Codex to do anything",
                       "not the header box — measured to scroll into scrollback within " +
                       "~1s of any real output; the composer's own idle placeholder " +
                       "sits at the bottom of the pane and survives (gate finding, 21 Aug)")
        XCTAssertTrue(spec!.neverAutoAcceptNeedles.contains("Hooks need review"))
    }

    func testCodexPathCandidatesIncludeCargoAheadOfTheGenericPaths() {
        let candidates = CodexAdapter().pathCandidates
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cargo = "\(home)/.cargo/bin"
        XCTAssertTrue(candidates.contains(cargo))
        XCTAssertTrue(candidates.contains("\(home)/.local/bin"))
        XCTAssertLessThan(candidates.firstIndex(of: cargo)!,
                          candidates.firstIndex(of: "/opt/homebrew/bin")!,
                          "a cargo-built codex should be found before falling through " +
                          "to the generic homebrew/usr paths")
        XCTAssertFalse(candidates.isEmpty)
    }

    // MARK: TrustPromptWatcher — the one loop both transports now share

    func testWatcherAcceptsOnPromptNeedle() {
        let spec = TrustPromptSpec(promptNeedles: ["trust this folder"],
                                   startedWithNoPromptNeedle: nil,
                                   settledBannerNeedle: "Claude")
        var pressed = false
        var reads = ["", "  Do you trust this folder …"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { pressed = true },
                                 pollInterval: 0.001)
        XCTAssertTrue(pressed)
    }

    func testWatcherStopsOnNoPromptSentinelWithoutPressing() {
        let spec = TrustPromptSpec(promptNeedles: ["trust this folder"],
                                   startedWithNoPromptNeedle: "? for shortcuts",
                                   settledBannerNeedle: "Claude")
        var pressed = false
        var reads = ["Claude Code v2 — ? for shortcuts"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { pressed = true },
                                 pollInterval: 0.001)
        XCTAssertFalse(pressed)
    }

    func testWatcherStopsAfterSettledThresholdWithNoPrompt() {
        let spec = TrustPromptSpec(promptNeedles: ["trust this folder"],
                                   startedWithNoPromptNeedle: nil,
                                   settledBannerNeedle: "Claude", settledThreshold: 2)
        var reads = ["Claude banner", "Claude banner", "trust this folder — too late"]
        var pressed = false
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { pressed = true },
                                 pollInterval: 0.001)
        // Settled twice on the banner before a (late) prompt needle ever
        // showed up — the watcher must already have stood down.
        XCTAssertFalse(pressed)
        XCTAssertEqual(reads.count, 1, "watcher should have stopped, leaving the third read unconsumed")
    }

    func testWatcherNeverPressesThroughAHookReviewDialog() {
        // Codex's hooks-review dialog: hook-trust is the user's own choice,
        // never auto-accepted, unlike the directory-trust prompt this same
        // loop DOES press through under standing 05 Aug consent.
        let spec = TrustPromptSpec(promptNeedles: ["Do you trust"],
                                   startedWithNoPromptNeedle: nil,
                                   settledBannerNeedle: "OpenAI Codex",
                                   neverAutoAcceptNeedles: ["Hooks need review"])
        var pressed = false
        var reads = ["Hooks need review… Trust all and continue"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { pressed = true },
                                 pollInterval: 0.001)
        XCTAssertFalse(pressed, "a dialog needing a human choice must never be pressed through")
    }

    func testNeverAutoAcceptWinsEvenWhenTheSameScreenAlsoMatchesAPromptNeedle() {
        // Gate finding (21 Aug): the prior test's fixture never actually
        // exercised the overlap it claimed to — "Hooks need review… Trust
        // all and continue" does not contain "Do you trust" (capital
        // "Trust", not "trust"). This one genuinely overlaps both needle
        // lists on the SAME screen, so the never-first ordering is the only
        // thing standing between this and a press.
        let spec = TrustPromptSpec(promptNeedles: ["Trust all"],   // matches exactly (needles are case-sensitive)
                                   startedWithNoPromptNeedle: nil,
                                   settledBannerNeedle: "OpenAI Codex",
                                   neverAutoAcceptNeedles: ["Hooks need review"])
        var pressed = false
        var reads = ["Hooks need review… Trust all and continue"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { pressed = true },
                                 pollInterval: 0.001)
        XCTAssertFalse(pressed, "the screen matches BOTH needle lists; never-auto-accept must still win")
    }

    // MARK: reviveCommand goes through the adapter now, not a second literal

    // MARK: empty resumeArguments must refuse, never emit broken AppleScript

    func testEmptyResumeArgumentsRefusesRatherThanBuildingBrokenScript() {
        struct SilentAdapter: HarnessAdapter {
            let id = "silent"
            let processCommandFragment = "silent"
            func resumeArguments(sessionId: String) -> [String] { [] }
            var trustPrompt: TrustPromptSpec? { nil }
            var pathCandidates: [String] { [] }
            var capabilities: HarnessCapabilities {
                HarnessCapabilities(echoesPaste: false, promptGlyph: "", queuesInputMidTurn: false,
                                    registersWithLiveness: false, hasHooks: false,
                                    allowsConcurrentResume: false)
            }
        }
        let result = SessionLauncher.resume(
            sessionId: "x", directory: NSTemporaryDirectory(),
            launch: HarnessLaunch(adapter: SilentAdapter(), command: "true"),
            acceptTrustPrompt: false)
        guard case .failure(let error) = result else {
            return XCTFail("an adapter with no resume arguments must refuse, not run AppleScript")
        }
        XCTAssertTrue(error.message.contains("silent"))
    }

    func testResumeTmuxRefusesRatherThanSpawningWithNothingToResume() {
        // The tmux twin of the test above: `resumeTmux` is the mechanism
        // BOTH Claude Code's dual-live twin and Codex's graceful-end-then-
        // resume adoption need underneath, so it owes the same refusal
        // `resume` (Terminal.app) already does.
        struct SilentAdapter: HarnessAdapter {
            let id = "silent"
            let processCommandFragment = "silent"
            func resumeArguments(sessionId: String) -> [String] { [] }
            var trustPrompt: TrustPromptSpec? { nil }
            var pathCandidates: [String] { [] }
            var capabilities: HarnessCapabilities {
                HarnessCapabilities(echoesPaste: false, promptGlyph: "", queuesInputMidTurn: false,
                                    registersWithLiveness: false, hasHooks: false,
                                    allowsConcurrentResume: false)
            }
        }
        let result = SessionLauncher.resumeTmux(
            sessionId: "x", directory: NSTemporaryDirectory(),
            launch: HarnessLaunch(adapter: SilentAdapter(), command: "true"),
            acceptTrustPrompt: false)
        guard case .failure(let error) = result else {
            return XCTFail("an adapter with no resume arguments must refuse, not spawn a pane")
        }
        XCTAssertTrue(error.message.contains("silent"))
    }

    // MARK: shellQuoted — the one implementation resumeTmux's arguments and
    // launchTmux's directory both go through now

    func testShellQuotedWrapsAPlainString() {
        XCTAssertEqual(SessionLauncher.shellQuoted("01a02782-25fd-7342-b383-eb0fa5323b92"),
                       "'01a02782-25fd-7342-b383-eb0fa5323b92'")
    }

    func testShellQuotedEscapesEmbeddedSingleQuotes() {
        // A resume argument reaches `resumeTmux` from data — a session id
        // read out of a filename, or, for Codex, out of a rollout's own
        // JSON — not from a constant. This is what stands between that and
        // shell injection if one were ever adversarial.
        XCTAssertEqual(SessionLauncher.shellQuoted("it's"), "'it'\\''s'")
    }

    func testShellQuotedHandlesEmptyString() {
        XCTAssertEqual(SessionLauncher.shellQuoted(""), "''")
    }

    // MARK: classifyCodexResumeScreen — the pure half of attemptCodexResume

    func testClassifyCodexResumeScreenRecognizesTheRealRefusalText() {
        // Captured live, 22 Aug, against real codex-cli 0.149.0: a second
        // `codex resume <id>` while the first process stayed alive. Verbatim
        // screen text, not a paraphrase.
        let screen = """
        ╭────────────────────────────────────────────────────╮
        │ >_ OpenAI Codex (v0.149.0)                         │
        │                                                    │
        │ model:     loading   /model to change              │
        │ directory: ~/Projects/…/.claude/worktrees/arc-work │
        ╰────────────────────────────────────────────────────╯
          Resuming session…

        › Error: Failed to resume session from /Users/robertnowell/.codex/sessions/2026/08/22/rollout-2026-08-22T10-29-11-01a02a84-f33c-7223-88f0-f5c6e7ecc7ff.jsonl: thread/resume failed during TUI bootstrap: thread/resume failed: thread 01a02a84-f33c-7223-88f0-f5c6e7ecc7ff already has an active writer (code -32600)
          ? for shortcuts
        """
        XCTAssertEqual(
            SessionLauncher.classifyCodexResumeScreen(screen, settledNeedle: "Ask Codex to do anything"),
            .alreadyLive)
    }

    func testClassifyCodexResumeScreenRecognizesASuccessfulAttach() {
        let screen = "› Ask Codex to do anything\n\n  gpt-5.6-sol high · ~/Projects/foo"
        XCTAssertEqual(
            SessionLauncher.classifyCodexResumeScreen(screen, settledNeedle: "Ask Codex to do anything"),
            .attached)
    }

    func testClassifyCodexResumeScreenIsInconclusiveMidBoot() {
        // Neither needle has appeared yet — the boot banner alone proves
        // nothing either way, and must not be misread as either outcome.
        let screen = "╭──────────────────╮\n│ >_ OpenAI Codex   │\n╰──────────────────╯\n  Resuming session…"
        XCTAssertEqual(
            SessionLauncher.classifyCodexResumeScreen(screen, settledNeedle: "Ask Codex to do anything"),
            .inconclusive)
    }

    func testClassifyCodexResumeScreenRefusalWinsEvenIfTextCoincidentallyOverlaps() {
        // The refusal check runs first: a screen carrying both substrings
        // (implausible live, but the ordering itself is the contract worth
        // pinning) must still read as the refusal, never the success.
        let screen = "already has an active writer (code -32600) ... Ask Codex to do anything"
        XCTAssertEqual(
            SessionLauncher.classifyCodexResumeScreen(screen, settledNeedle: "Ask Codex to do anything"),
            .alreadyLive)
    }

    func testCodexAdapterResumeConflictNeedleMatchesWhatWasMeasured() {
        XCTAssertEqual(CodexAdapter.resumeConflictNeedle, "already has an active writer")
    }

    // MARK: capabilities parity — until TmuxTransport reads these values live,
    // a test is what stops them silently drifting from what it hardcodes
    // (M2 gate finding: capability fields had zero consumers; still true
    // with CodexAdapter landed — the wiring itself is separate work).

    func testClaudeCodeEchoesPasteMatchesWhatTmuxTransportAssumes() {
        // TmuxTransport.swift's landing check is unconditional on the belief
        // that "every target echoes" — true for Claude Code (measured 19
        // Aug) and for the raw-mode test harness (which writes its own
        // echo), AND true for Codex (measured 21 Aug) — so the belief
        // happens to hold for both real harnesses today, coincidentally,
        // not because it was ever checked per-target. This pins the Claude
        // Code half specifically, so the day the two diverge, THIS fails
        // instead of a delivery silently misbehaving.
        XCTAssertTrue(ClaudeCodeAdapter().capabilities.echoesPaste,
                      "TmuxTransport's landing check assumes every target echoes; " +
                      "wiring it to read this value per-target is still open work")
        XCTAssertTrue(CodexAdapter().capabilities.echoesPaste,
                      "the SAME hardcoded assumption, now also true for the second " +
                      "real harness — coincidence, not verification; still not read per-target")
    }

    /// The cwd moved off `/tmp/x` on 24 Aug: `reviveCommand` now resolves where
    /// to land rather than echoing the recorded path, and nothing reopens under
    /// a reaped temp directory. This test is about the ADAPTER's arguments, so
    /// it states its case with a directory that exists and stays out of that.
    func testReviveCommandUsesAdapterResumeArguments() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let session = SessionDiscovery.Session(
            sessionId: "sess-1", cwd: home, transcriptPath: home + "/x.jsonl",
            title: nil, lastActivityAt: Date(), answered: true, activity: nil,
            liveness: .gone, revivable: true)
        XCTAssertEqual(session.reviveCommand?.arguments, ["--resume", "sess-1"])
        XCTAssertEqual(session.reviveCommand?.cwd, home)
    }
}
