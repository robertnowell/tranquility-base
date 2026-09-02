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
        XCTAssertTrue(spec!.neverAutoAcceptNeedles.contains { $0.needle == "Hooks need review" })
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
                                 press: { _ in pressed = true },
                                 pollInterval: 0.001)
        XCTAssertTrue(pressed)
    }

    /// The 27 Aug regression, as a fixture: `capture-pane -p -J` output from a
    /// pane TB had just launched, trimmed to the menu. The cursor is on the
    /// REFUSING row, so the bare Return this watcher used to send exited
    /// Claude Code with status 1 and the launch died as "Couldn't confirm the
    /// new agent started."
    private static let liveClaudeTrustScreen = """
     Accessing workspace:
     /Users/robertnowell
     Quick safety check: Is this a project you created or one you trust?
     Claude Code'll be able to read, edit, and execute files here.
     Security guide
     ❯ No, exit
       Yes, I trust this folder
     Enter to confirm · Esc to cancel
    """

    func testWatcherNavigatesToTheAcceptingRowRatherThanPressingWhereTheCursorSits() {
        let spec = ClaudeCodeAdapter().trustPrompt!
        var steps: Int?
        var reads = [Self.liveClaudeTrustScreen]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { steps = $0 },
                                 pollInterval: 0.001)
        XCTAssertEqual(steps, 1,
            "the accepting row is one below the cursor; pressing Return where it sits picks \"No, exit\"")
    }

    func testClaudeCodeStillAcceptsTheNumberedV21Screen() {
        // The older wording, kept working: same two rows, accepting one first
        // and numbered, cursor already on it. Zero travel, bare Return — the
        // behaviour that was correct before the screen changed under us.
        let spec = ClaudeCodeAdapter().trustPrompt!
        let v21 = """
         Do you trust the files in this folder?
         ❯ 1. Yes, I trust this folder
           2. No, exit
        """
        XCTAssertEqual(spec.stepsToAccept(on: v21), 0)
    }

    func testWatcherRefusesToPressAMenuItCannotRead() {
        // A trust prompt whose accepting row this build has no name for. The
        // old loop would press Return into it and hope; the whole point of
        // the 27 Aug fix is that hoping is what declined three launches.
        let spec = ClaudeCodeAdapter().trustPrompt!
        var pressed = false
        var neededHuman = false
        var reads = ["Quick safety check: do you trust this folder?\n ❯ Nope\n   Affirmative"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in pressed = true },
                                 pollInterval: 0.001,
                                 onNeedsHuman: { _ in neededHuman = true })
        XCTAssertFalse(pressed, "an unrecognised menu must never be pressed blind")
        XCTAssertTrue(neededHuman, "and it must open a window rather than fail silently")
    }

    func testWatcherStopsOnNoPromptSentinelWithoutPressing() {
        let spec = TrustPromptSpec(promptNeedles: ["trust this folder"],
                                   startedWithNoPromptNeedle: "? for shortcuts",
                                   settledBannerNeedle: "Claude")
        var pressed = false
        var reads = ["Claude Code v2 — ? for shortcuts"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in pressed = true },
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
                                 press: { _ in pressed = true },
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
                                   neverAutoAcceptNeedles: [.init("Hooks need review",
                                                                says: "Codex wants its hooks reviewed.")])
        var pressed = false
        var reads = ["Hooks need review… Trust all and continue"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in pressed = true },
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
                                   neverAutoAcceptNeedles: [.init("Hooks need review",
                                                                says: "Codex wants its hooks reviewed.")])
        var pressed = false
        var reads = ["Hooks need review… Trust all and continue"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in pressed = true },
                                 pollInterval: 0.001)
        XCTAssertFalse(pressed, "the screen matches BOTH needle lists; never-auto-accept must still win")
    }

    // MARK: The screen that stopped changing (27 Aug)

    /// codex-cli 0.150.0's update menu, transcribed off a real stuck pane.
    ///
    /// It IS known now, as a `neverAutoAcceptNeedles` entry (29 Aug), so it no
    /// longer exercises the unknown-screen path and
    /// `testAnUnknownScreenThatStopsChangingIsReportedEarly` uses
    /// `unknownStuckScreen` below instead. Kept because the never-accept tests
    /// want the real thing.
    ///
    /// The comment here used to read "No needle in this app knows it, and none
    /// needs to: it stops changing." That was right about THIS watcher and
    /// wrong about the other loop. `SessionLauncher.attemptCodexResume` runs
    /// its own settle poll with no stuck detection at all — it checks the
    /// never-accept needles, classifies, and otherwise waits out its twenty
    /// seconds. So on 29 Aug, when 0.151.0 shipped and this screen appeared on
    /// every resume, the launcher could only report that the session never
    /// settled. The heuristic that made a needle unnecessary does not run
    /// there.
    private static let codexUpdateScreen = [
        "",
        "  \u{2728} Update available! 0.149.0 -> 0.150.0",
        "",
        "  Release notes: https://github.com/openai/codex/releases/latest",
        "",
        "\u{203A} 1. Update now",
        "  2. Skip",
        "  3. Skip until next version",
        "",
        "  Press enter to continue",
    ].joined(separator: "\n")

    /// A screen nothing in this app recognises, which stops changing.
    ///
    /// Deliberately not any real prompt: the point of the stuck heuristic is
    /// screens nobody predicted, so a fixture that some needle might one day
    /// match would quietly stop testing it. That is what happened to the
    /// update menu.
    private static let unknownStuckScreen = [
        "",
        "  Workspace configuration changed",
        "",
        "\u{203A} 1. Reload it",
        "  2. Keep the current one",
        "",
        "  Press enter to continue",
    ].joined(separator: "\n")

    /// The early exit and the give-up exit BOTH open a window now (the
    /// give-up one since `98cc767`), so "did onNeedsHuman fire" no longer
    /// separates them. The trace does: only the stability test says "has
    /// stopped on a screen", and only it can say it before the loop has spent
    /// its thirty seconds. That difference is the whole point — it is twenty-two
    /// seconds of spinner, on every launch, for every user of a harness that
    /// has started asking something new.
    private static let stoppedEarly = "has stopped on a screen"

    /// `trace` is `@Sendable`, so its sink cannot be a captured local var.
    private final class Traced: @unchecked Sendable {
        var lines: [String] = []
        var sawStoppedEarly: Bool { lines.contains { $0.contains(stoppedEarly) } }
    }

    func testAnUnknownScreenThatStopsChangingIsReportedEarly() {
        let spec = CodexAdapter().trustPrompt!
        var pressed = false
        var asked: String?
        let traced = Traced()
        var reads = Array(repeating: Self.unknownStuckScreen, count: 9)
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in pressed = true },
                                 trace: { traced.lines.append($0) },
                                 pollInterval: 0.001, maxPolls: 9,
                                 onNeedsHuman: { asked = $0 })
        XCTAssertFalse(pressed, "an unrecognized screen is never pressed through")
        // The panel is told what the pane SAYS, and told that is all this is.
        // It used to be handed the first line of the pane as though it were the
        // question; the assertion below is the same intent stated honestly, and
        // it now carries the options too, which is what a person acts on.
        let said = try! XCTUnwrap(asked)
        XCTAssertTrue(said.contains("does not recognise"), said)
        XCTAssertTrue(said.contains("Workspace configuration changed"), said)
        XCTAssertTrue(said.contains("1. Reload it"), said)
        XCTAssertTrue(traced.sawStoppedEarly)
        XCTAssertEqual(reads.count, 6,
                       "called it on the third identical screen, not after fifteen polls")
    }

    func testABootingPaneIsNotCalledStoppedWhileItIsStillRedrawing() {
        // The screen changes on every poll — a TUI drawing itself. It may
        // still be escalated when the loop finally gives up; what it may not
        // be is called STOPPED while it is visibly moving.
        let spec = CodexAdapter().trustPrompt!
        let traced = Traced()
        var reads = ["booting one", "booting two", "booting three",
                     "booting four", "booting five"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in },
                                 trace: { traced.lines.append($0) },
                                 pollInterval: 0.001, maxPolls: 5,
                                 onNeedsHuman: { _ in })
        XCTAssertFalse(traced.sawStoppedEarly)
    }

    func testASettledComposerIsNeverEscalatedEvenThoughItAlsoStopsChanging() {
        // The one screen that is BOTH stable and perfectly fine. Settled
        // (threshold 2) must beat stuck (threshold 3), or every ordinary
        // launch would be announced as a question.
        let spec = CodexAdapter().trustPrompt!
        var asked: String?
        var reads = Array(repeating: "  Ask Codex to do anything", count: 9)
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in },
                                 pollInterval: 0.001, maxPolls: 9,
                                 onNeedsHuman: { asked = $0 })
        XCTAssertNil(asked, "starting an agent that works is still a background act")
    }

    func testAPaneWithNothingOnItIsNotCalledStoppedEarly() {
        // Stable, and with nothing to say. It still earns a window at the
        // give-up — an empty pane thirty seconds in is its own kind of wrong —
        // but there is no question to put on a card, so the early exit that
        // exists to NAME one must not take it.
        let spec = CodexAdapter().trustPrompt!
        let traced = Traced()
        var reads = Array(repeating: "\n   \n  \u{2500}\u{2500}\u{2500}\n", count: 9)
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in },
                                 trace: { traced.lines.append($0) },
                                 pollInterval: 0.001, maxPolls: 9,
                                 onNeedsHuman: { _ in })
        XCTAssertFalse(traced.sawStoppedEarly)
    }

    /// Replaces `testQuestionOnScreenSkipsDecorationAndTakesTheFirstRealLine`.
    ///
    /// That test passed for two weeks against a fixture whose entire content
    /// was the dialog. Every real pane has something above the dialog, and the
    /// function it guarded returned that instead. The premise was the bug, so
    /// the test went with the function; what replaces it asserts the property
    /// that actually matters, against a REAL capture.
    /// Captured live, 1 Sep, from `claude` in a fresh directory. Kept verbatim
    /// (paths shortened) because every assertion about naming a prompt is only
    /// worth what its screen is worth, and a hand-written dialog is exactly the
    /// fixture that let `questionOnScreen` look correct for two weeks.
    static let realClaudeTrustScreen = """
    Permission allow rule (~/.claude/settings.json): Bash(cp /tmp/x/*.otf ~/Library/Fonts/) \
    has a wildcard before the rest of the command, so it also matches any options inserted \
    at that position and approves them without a prompt.

    \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}

     Accessing workspace:

     /private/tmp/probes/trustdir

     Quick safety check: Is this a project you created or one you trust?

     Claude Code'll be able to read, edit, and execute files here.

     Security guide

     \u{276F} No, exit
       Yes, I trust this folder

     Enter to confirm \u{00B7} Esc to cancel
    """

    func testTheTailOfARealTrustPromptEndsOnTheChoice() {
        // Captured live, 1 Sep, from `claude` in a fresh directory. Note the
        // first line: a settings warning, printed ABOVE the dialog. The old
        // lifter returned exactly that as "the question the agent is asking".
        let screen = Self.realClaudeTrustScreen
        let tail = TrustPromptWatcher.meaningfulTail(screen)
        // What a person needs in order to act is the choice, and the tail ends
        // on it. Six lines rather than eight is deliberate: eight reaches the
        // question, but the width cap then cuts before the options.
        XCTAssertTrue(tail.hasSuffix("Enter to confirm \u{00B7} Esc to cancel"), tail)
        XCTAssertTrue(tail.contains("Yes, I trust this folder"), tail)
        // And it never reaches the settings warning at the top of the pane.
        XCTAssertFalse(tail.contains("Permission allow rule"), tail)
    }

    /// The nil that was load-bearing in the deleted function survives as the
    /// empty string this one returns: a pane with nothing on it must not be
    /// announced as a question.
    func testAnEmptyPaneSaysNothing() {
        let bare = "\n \n  \u{2502}\n"
        XCTAssertTrue(TrustPromptWatcher.meaningfulTail(bare)
            .trimmingCharacters(in: .whitespaces).count <= 1)
    }

    /// The real trust prompt, driven through the real watcher.
    ///
    /// The unit above asserts what the pane's tail says; this asserts what the
    /// WATCHER does with the same bytes, which is the half a fixture cannot
    /// fake: it must still find "Yes, I trust this folder" one row below the
    /// cursor and press Down once before Return. The 27 Aug regression this
    /// guards (cursor starts on "No, exit", so a bare Return declines and the
    /// launch dies claiming success) is the reason `acceptOptionNeedles`
    /// exists, and nothing about naming prompts is allowed to disturb it.
    func testTheRealTrustPromptIsStillPressedThroughCorrectly() {
        let spec = ClaudeCodeAdapter().trustPrompt!
        var steps: [Int] = []
        var asked: String?
        var reads = [Self.realClaudeTrustScreen]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { steps.append($0) },
                                 pollInterval: 0.001, maxPolls: 3,
                                 onNeedsHuman: { asked = $0 })
        XCTAssertEqual(steps, [1], "the accepting row is one Down from the cursor")
        XCTAssertNil(asked, "standing consent covers directory trust; no card is owed")
    }

    /// And the branch where it CANNOT find the accepting row: the sentence is
    /// the harness's own, never a line off the pane. Same real screen with the
    /// accepting row renamed, which is exactly the shape of the 27 Aug rot.
    func testAnUnfindableAcceptRowNamesTheHarnessesOwnPrompt() {
        let spec = ClaudeCodeAdapter().trustPrompt!
        var pressed = false
        var asked: String?
        // The CURSOR is removed, not the accepting row: dropping the row's words
        // would also drop the only "trust this folder" on the screen, and the
        // prompt would stop being recognised as a trust prompt at all. (Which
        // is itself worth knowing: Claude Code's current dialog asks "Is this a
        // project you created or one you trust?", so `promptNeedles` matches
        // this screen through the BUTTON, not through the question.)
        var reads = [Self.realClaudeTrustScreen
            .replacingOccurrences(of: "\u{276F} No, exit", with: "  No, exit")]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { _ in pressed = true },
                                 pollInterval: 0.001, maxPolls: 3,
                                 onNeedsHuman: { asked = $0 })
        XCTAssertFalse(pressed, "never press blind at a menu whose accepting row is unknown")
        XCTAssertEqual(asked, "It is asking whether you trust this folder.")
        // The thing it must never say: the settings warning at the top of the pane.
        XCTAssertFalse(asked?.contains("Permission allow rule") ?? true)
    }

    /// Both harnesses, both recognised screens, one property: a screen we
    /// matched is described by a sentence we wrote, and that sentence never
    /// contains the needle. A needle is an implementation detail ("1. Update
    /// now"); a person needs to be told what it means.
    func testEveryRecognizedPromptSaysSomethingAPersonCanAct() {
        for adapter in [ClaudeCodeAdapter().trustPrompt, CodexAdapter().trustPrompt] {
            let spec = try! XCTUnwrap(adapter)
            XCTAssertFalse(spec.neverAutoAcceptNeedles.isEmpty)
            for prompt in spec.neverAutoAcceptNeedles {
                XCTAssertGreaterThan(prompt.says.count, 25, prompt.needle)
                XCTAssertFalse(prompt.says.contains(prompt.needle),
                               "\(prompt.needle): the sentence is repeating the needle")
                XCTAssertTrue(prompt.says.hasSuffix("."), prompt.says)
            }
            XCTAssertGreaterThan(spec.trustPromptSays.count, 25)
        }
    }

    /// The live values, named, because these are the two sentences Robert will
    /// actually read on a stopped launch and they should not drift silently.
    func testTheTwoHarnessesNameTheirOwnPrompts() {
        let codex = CodexAdapter().trustPrompt!
        XCTAssertEqual(codex.neverAutoAcceptNeedles.first { $0.needle == "1. Update now" }?.says,
                       "Codex is asking whether to update itself before it starts.")
        XCTAssertTrue(codex.trustPromptSays.contains("this directory"))
        let claude = ClaudeCodeAdapter().trustPrompt!
        XCTAssertTrue(claude.neverAutoAcceptNeedles
            .first { $0.needle.hasPrefix("Resuming") }?.says
            .contains("resume the full session") ?? false)
        XCTAssertTrue(claude.trustPromptSays.contains("this folder"))
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

/// Screens TB must never press through on Codex.
///
/// One is a consent (hook trust). The other is an INSTALL: the update chooser's
/// default row runs `curl -fsSL …/install.sh | sh`, and this watcher's way of
/// dismissing a recognised prompt is to press Return where the selection
/// stands. Correct for Codex's yes-defaulting trust prompt; software
/// installation on the update chooser.
extension HarnessAdapterTests {

    func testCodexNeverAutoAcceptsTheUpdateChooser() {
        let needles = CodexAdapter().trustPrompt!.neverAutoAcceptNeedles
        XCTAssertTrue(needles.contains { $0.needle == "1. Update now" },
                      "pressing Return here runs a curl-pipe-sh installer")
    }

    func testCodexNeverAutoAcceptsHookReview() {
        XCTAssertTrue(CodexAdapter().trustPrompt!
            .neverAutoAcceptNeedles.contains { $0.needle == "Hooks need review" })
    }

    /// The never-accept list must win over the press list, for every needle in
    /// it. Asserted against the real spec rather than a fixture, because the
    /// guarantee is only worth anything on the object the launcher uses.
    func testNoNeverAcceptNeedleIsAlsoAPressableOne() {
        let spec = CodexAdapter().trustPrompt!
        for prompt in spec.neverAutoAcceptNeedles {
            XCTAssertFalse(spec.promptNeedles.contains(prompt.needle),
                           "\(prompt.needle) is on both lists; the safe one must be the only one")
        }
    }
}
