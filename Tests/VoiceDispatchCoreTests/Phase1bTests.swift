import XCTest
@testable import VoiceDispatchCore

/// Phase 1b: tuned prompt port, mechanical callsign prefix, callsign minting,
/// digit grounding, tolerances, and the sanitizer speakable-names allowlist.
final class Phase1bTests: XCTestCase {
    let sanitizer = SpokenTextSanitizer()

    // MARK: - Callsign directory word

    func testDirectoryWordUsesTheWorktreeName() {
        // Split into plain words for the voice (ruled 06 Aug — TTS mangles
        // joined compounds), keeping the last two: the tail of a kebab-case
        // name is where the specific part lives.
        let cwd = NSHomeDirectory()
            + "/Projects/kopi/promotions/.claude/worktrees/product-image-binding/promotions"
        XCTAssertEqual(Callsign.directoryWord(cwd: cwd), "image binding")
    }

    func testDirectoryWordSplitsJoinedCompoundsForTheVoice() {
        // The bug that forced the ruling: "facts-cache" garbled on every
        // announcement. Underscores are the same disease.
        let cwd = NSHomeDirectory()
            + "/Projects/kopi/promotions/.claude/worktrees/facts-cache/promotions"
        XCTAssertEqual(Callsign.directoryWord(cwd: cwd), "facts cache")
        XCTAssertEqual(Callsign.directoryWord(cwd: "/Users/x/Projects/voice_dispatch"),
                       "voice dispatch")
    }

    func testDirectoryWordMapsHomeToHome() {
        XCTAssertEqual(Callsign.directoryWord(cwd: NSHomeDirectory()), "home")
        XCTAssertEqual(Callsign.directoryWord(cwd: NSHomeDirectory() + "/"), "home")
    }

    func testDirectoryWordFallsBackToLastComponent() {
        XCTAssertEqual(Callsign.directoryWord(cwd: "/Users/x/Projects/Promotions"), "promotions")
        XCTAssertEqual(Callsign.directoryWord(cwd: nil), "session")
    }

    // MARK: - Callsign minting

    func testMintPicksTheMostDistinctiveTopicWord() {
        // Longest non-stopword that is not the directory word.
        let callsign = Callsign.mint(
            directoryWord: "promotions", topic: "hero copy rewrite", existingCallsigns: [])
        XCTAssertEqual(callsign, "promotions rewrite")
    }

    func testMintSkipsStopwordsAndTheDirectoryWord() {
        let callsign = Callsign.mint(
            directoryWord: "promotions", topic: "the promotions copy", existingCallsigns: [])
        XCTAssertEqual(callsign, "promotions copy")
    }

    func testMintRejectsExactAndNearCollisions() {
        // "rewrite" collides exactly with kopi's topic word; "hero" is clear.
        let callsign = Callsign.mint(
            directoryWord: "promotions", topic: "hero copy rewrite",
            existingCallsigns: ["kopi rewrite"])
        XCTAssertEqual(callsign, "promotions hero")

        // Near-collision: "copy" vs "code" is Levenshtein 2 — confusable at
        // speech speed, so it is rejected too.
        let near = Callsign.mint(
            directoryWord: "promotions", topic: "copy fixes",
            existingCallsigns: ["syndit code"])
        XCTAssertEqual(near, "promotions fixes")
    }

    func testMintExhaustionAppendsADistinguishingWord() {
        // Both candidates collide; the most distinctive word gets a second word
        // from the topic appended rather than failing.
        let callsign = Callsign.mint(
            directoryWord: "promotions", topic: "copy edit",
            existingCallsigns: ["kopi copy", "syndit edit"])
        XCTAssertEqual(callsign, "promotions copy edit")
    }

    func testTwoWordDirectoryMintsAtMostThreeSpokenWords() {
        // Ordinary path: two dir words + one topic word = the three-word
        // ceiling exactly.
        let callsign = Callsign.mint(
            directoryWord: "facts cache", topic: "inventory sweep",
            existingCallsigns: [])
        XCTAssertEqual(callsign, "facts cache inventory")

        // Exhaustion path: the two-word prefix gives up its first word so the
        // distinguishing word never pushes the sign past three.
        let exhausted = Callsign.mint(
            directoryWord: "facts cache", topic: "inventory sweep",
            existingCallsigns: ["kopi inventory", "syndit sweep"])
        XCTAssertEqual(exhausted, "cache inventory sweep")
        XCTAssertLessThanOrEqual(exhausted!.split(separator: " ").count, 3)
    }

    func testTopicWordMatchingAnyDirectoryComponentIsSkipped() {
        // "cache" repeats a directory component — "facts cache cache" is not a
        // name; the next candidate wins.
        let callsign = Callsign.mint(
            directoryWord: "facts cache", topic: "cache timeout",
            existingCallsigns: [])
        XCTAssertEqual(callsign, "facts cache timeout")
    }

    func testMintReturnsNilWhenTheTopicOffersNoWord() {
        // A deterministic-floor topic is just the label — nothing to mint from.
        XCTAssertNil(Callsign.mint(
            directoryWord: "promotions", topic: "promotions", existingCallsigns: []))
        XCTAssertNil(Callsign.mint(
            directoryWord: "promotions", topic: "", existingCallsigns: []))
    }

    // MARK: - Callsign freeze (GRDB)

    func testCallsignIsFrozenAtFirstMint() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-callsign-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try QueueStore(url: tmp)

        XCTAssertEqual(try store.mintCallsign("promotions copy", for: "s1"), "promotions copy")
        // A second mint LOSES: first write wins for the session's lifetime.
        XCTAssertEqual(try store.mintCallsign("promotions hero", for: "s1"), "promotions copy")
        XCTAssertEqual(try store.callsign(for: "s1"), "promotions copy")
    }

    func testActiveCallsignsExcludeSelfAndStaleSessions() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-callsign-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try QueueStore(url: tmp)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        _ = try store.insert(event: QueuedEvent(
            createdAtMs: now, hookEvent: .stop, sessionId: "fresh", cwd: "/tmp/a",
            lastAssistantMessage: "m"))
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: 1_000, hookEvent: .stop, sessionId: "stale", cwd: "/tmp/b",
            lastAssistantMessage: "m"))
        try store.mintCallsign("alpha copy", for: "fresh")
        try store.mintCallsign("beta copy", for: "stale")
        try store.mintCallsign("self copy", for: "me")

        let active = try store.activeCallsigns(excluding: "me")
        XCTAssertEqual(active, ["alpha copy"],
                       "stale sessions and the minting session itself do not compete")
    }

    // MARK: - Mechanical prefix

    func testModelWrittenLabelPrefixIsStrippedAndCallsignPrepended() {
        let spoken = sanitizer.sanitize("Promotions: poller live, three alerts posted.")
        let out = sanitizer.applyingCallsign(
            "promotions copy", strippingLabels: ["promotions"], to: spoken)
        XCTAssertEqual(out.text, "promotions copy: poller live, three alerts posted.")
    }

    /// "promotions: promotions:" must be impossible — stripping loops over every
    /// label-like prefix (label, live name, and the callsign itself) before the
    /// single mechanical prepend.
    func testDoubledPrefixIsImpossible() {
        let doubled = sanitizer.sanitize("promotions: promotions: poller live.")
        let once = sanitizer.applyingCallsign(
            "promotions copy", strippingLabels: ["promotions"], to: doubled)
        XCTAssertEqual(once.text, "promotions copy: poller live.")

        // Applying again (an interrupted announcement is re-prepared) stays fixed.
        let twice = sanitizer.applyingCallsign(
            "promotions copy", strippingLabels: ["promotions"], to: once)
        XCTAssertEqual(twice.text, once.text)
    }

    func testBrandSubstitutedPrefixStillGetsCorrectAttribution() {
        // The measured failure class: content about Kopi, session in promotions.
        // "Kopi:" is not a known label so it survives inside the text, but the
        // spoken line STARTS with the true callsign regardless.
        let spoken = sanitizer.sanitize("Kopi: migration script ready.")
        let out = sanitizer.applyingCallsign(
            "promotions copy", strippingLabels: ["promotions"], to: spoken)
        XCTAssertTrue(out.text.hasPrefix("promotions copy: "))
    }

    func testLiveSessionNamePrefixIsAlsoStripped() {
        let spoken = sanitizer.sanitize("promotions-49: tests green.")
        let out = sanitizer.applyingCallsign(
            "promotions copy", strippingLabels: ["promotions", "promotions-49"], to: spoken)
        XCTAssertEqual(out.text, "promotions copy: tests green.")
    }

    // MARK: - Digit grounding

    func testGroundedNumberPasses() {
        let request = SummaryRequest(
            lastAssistantMessage: "Deployed the poller; three alerts posted, 42 tests green.",
            projectLabel: "promotions")
        let pool = DigitGrounding.sourcePool(for: request)
        let brief = SessionBrief(topic: "poller", happened: "deployed",
                                 recap: "Promotions: 3 alerts posted, 42 tests green.")
        XCTAssertTrue(DigitGrounding.ungroundedTokens(in: brief, pool: pool).isEmpty,
                      "spelled 'three' grounds spoken '3'; '42' is verbatim")
    }

    func testUngroundedNumberIsCaught() {
        let request = SummaryRequest(
            lastAssistantMessage: "Deployed the poller and posted alerts.",
            projectLabel: "promotions")
        let pool = DigitGrounding.sourcePool(for: request)
        let brief = SessionBrief(topic: "poller", happened: "deployed",
                                 recap: "Promotions: 5 alerts posted.")
        XCTAssertEqual(DigitGrounding.ungroundedTokens(in: brief, pool: pool), ["5"])
    }

    func testSpelledSourceNumberGroundsSpokenDigits() {
        let request = SummaryRequest(
            lastAssistantMessage: "Fixed ten failures in the import step.",
            projectLabel: "syndit")
        let pool = DigitGrounding.sourcePool(for: request)
        let brief = SessionBrief(topic: "import", happened: "fixed",
                                 recap: "Syndit: 10 failures fixed.")
        XCTAssertTrue(DigitGrounding.ungroundedTokens(in: brief, pool: pool).isEmpty)
    }

    func testScrubRemovesTheMinimalClauseAndNeverTheWholeSummary() {
        let brief = SessionBrief(
            topic: "poller", happened: "deployed",
            recap: "Promotions: poller live, 5 alerts posted.",
            proposal: "Add the filter next. Go?")
        let scrubbed = DigitGrounding.scrub(brief, tokens: ["5"])
        XCTAssertFalse(scrubbed.recap?.contains("5") ?? false)
        XCTAssertTrue(scrubbed.recap?.contains("poller live") ?? false,
                      "only the offending clause goes")
        XCTAssertEqual(scrubbed.proposal, "Add the filter next. Go?")
    }

    /// The chain retries ONCE with a corrective line; a compliant retry is used.
    func testChainRetriesOnceWithACorrectiveNote() async {
        final class InventsThenCorrects: SummaryProvider, @unchecked Sendable {
            let name = "inventive"; let isConfigured = true
            var calls: [SummaryRequest] = []
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                calls.append(request)
                let recap = request.correctiveNote == nil
                    ? "Promotions: 5 alerts posted." : "Promotions: alerts posted."
                return SessionBrief(topic: "poller alerts", happened: "posted",
                                    recap: recap, proposal: "Proceed?")
            }
        }
        let provider = InventsThenCorrects()
        let chain = SummarizerChain(providers: [provider])
        let summary = await chain.summarize(SummaryRequest(
            lastAssistantMessage: "Deployed the poller and posted alerts.",
            projectLabel: "promotions"))

        XCTAssertEqual(provider.calls.count, 2)
        XCTAssertNil(provider.calls[0].correctiveNote)
        XCTAssertTrue(provider.calls[1].correctiveNote?.contains("5") ?? false,
                      "the corrective line names the invented number")
        XCTAssertFalse(summary.spoken.text.contains("5"))
        XCTAssertEqual(summary.provider, "inventive")
    }

    /// A retry that STILL invents numbers is scrubbed, never spoken, and tagged.
    func testPersistentlyUngroundedNumberIsScrubbedNotSpoken() async {
        struct AlwaysInvents: SummaryProvider {
            let name = "inventive"; let isConfigured = true
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                SessionBrief(topic: "poller alerts", happened: "posted",
                             recap: "Promotions: 5 alerts posted, tests green.",
                             proposal: "Proceed?")
            }
        }
        let chain = SummarizerChain(providers: [AlwaysInvents()])
        let summary = await chain.summarize(SummaryRequest(
            lastAssistantMessage: "Deployed the poller; tests green.",
            projectLabel: "promotions"))

        XCTAssertFalse(summary.spoken.text.contains("5"),
                       "the ungrounded number must never be spoken")
        XCTAssertTrue(summary.spoken.text.contains("tests green"))
        XCTAssertEqual(summary.provider, "inventive+digit-scrubbed")
    }

    // MARK: - Tolerances

    func testEmptyProposalSpeaksRecapAloneWithoutTrailingAwkwardness() {
        let brief = SessionBrief(topic: "cleanup", happened: "done",
                                 recap: "Syndit: nightly run green, nothing open.")
        XCTAssertEqual(brief.spokenText(), "Syndit: nightly run green, nothing open.")
    }

    func testEmptySourceNeverReachesAModel() async {
        final class MustNotBeCalled: SummaryProvider, @unchecked Sendable {
            let name = "model"; let isConfigured = true
            var calls = 0
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                calls += 1
                return SessionBrief(topic: "T", happened: "H")
            }
        }
        let provider = MustNotBeCalled()
        let chain = SummarizerChain(providers: [provider])
        let summary = await chain.summarize(SummaryRequest(
            lastAssistantMessage: "   \n\t ", projectLabel: "kopi"))

        XCTAssertEqual(provider.calls, 0, "an empty source burns no model call")
        XCTAssertEqual(summary.provider, "empty-source")
        XCTAssertFalse(summary.spoken.text.isEmpty, "the floor still says something true")
    }

    // MARK: - Sanitizer allowlist

    func testSourceEstablishedProductTokenIsSpeakable() {
        let source = "The iPhone build shipped and Klaviyo synced."
        let allow = SpokenTextSanitizer.speakableTerms(in: source)
        XCTAssertTrue(allow.contains("iPhone"))
        XCTAssertTrue(allow.contains("Klaviyo"))

        let kept = sanitizer.sanitize("Shipped the iPhone build.", allowing: allow)
        XCTAssertEqual(kept.text, "Shipped the iPhone build.")

        // Without the source having said it, the old stripping behavior stands.
        let stripped = sanitizer.sanitize("Shipped the iPhone build.")
        XCTAssertEqual(stripped.text, "Shipped the a variable build.")
    }

    func testIdentifiersAreStillStrippedEvenWithAnAllowlist() {
        let allow = SpokenTextSanitizer.speakableTerms(
            in: "Klaviyo synced via buildLockedLayoutAssets and legacy_import_step.")
        let result = sanitizer.sanitize(
            "Klaviyo synced via buildLockedLayoutAssets and legacy_import_step.",
            allowing: allow)
        XCTAssertFalse(result.text.contains("buildLockedLayoutAssets"))
        XCTAssertFalse(result.text.contains("legacy_import_step"))
        XCTAssertTrue(result.text.contains("Klaviyo"))
    }

    func testPathsAndHashesNeverBecomeSpeakableViaTheAllowlist() {
        let source = "Edited /Users/example/app/main.swift at a3f9c21b4e"
        let allow = SpokenTextSanitizer.speakableTerms(in: source)
        let result = sanitizer.sanitize(source, allowing: allow)
        XCTAssertFalse(result.text.contains("/Users"))
        XCTAssertFalse(result.text.contains("a3f9c21b4e"))
    }

    // MARK: - End to end: the spoken line opens with the callsign

    func testAnnouncementOpensWithTheMintedCallsignExactlyOnce() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-p1b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))

        struct PrefixWritingSummary: SummaryProvider {
            let name = "fixed"; let isConfigured = true
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                // The model obeys the prompt and writes the label itself — the
                // mechanical pass must not double it.
                SessionBrief(topic: "export refactor", happened: "tests pass",
                             recap: "promotions: export pipeline fixed, tests pass.",
                             proposal: "Run the migration next. Proceed?")
            }
        }
        final class Silent: SpeechProvider, @unchecked Sendable {
            let name = "silent"; let isConfigured = true; var isSpeaking = false
            func speak(_ text: SanitizedSpokenText,
                       onWord: (@Sendable (Range<Int>) -> Void)?) async throws {}
            func stop() {}
        }
        struct Agents: ClaudeAgentsReading {
            func sessions() -> [LiveSession]? {
                [LiveSession(pid: 1, sessionId: "sess-1", cwd: "/tmp/promotions",
                             status: "idle", name: "promotions", waitingFor: nil)]
            }
        }
        let coordinator = Coordinator(
            store: store,
            summarizer: SummarizerChain(providers: [PrefixWritingSummary()]),
            speech: SpeechChain(preferred: Silent(), fallback: Silent()),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            transport: TerminalAppTransport(),
            enrolment: EnrolmentRegistry(url: tmpDir.appendingPathComponent("e.json")),
            agents: Agents(),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))

        _ = try store.insert(event: QueuedEvent(
            hookEvent: .stop, sessionId: "sess-1", promptId: "p1",
            cwd: "/tmp/promotions", lastAssistantMessage: "Export pipeline fixed; tests pass."))

        guard case .spoke(let announcement) = try await coordinator.announceNext() else {
            return XCTFail("expected an announcement")
        }
        // Directory word "promotions", most distinctive topic word "refactor".
        XCTAssertTrue(announcement.spoken.text.hasPrefix("promotions refactor: export"),
                      "got: \(announcement.spoken.text)")
        XCTAssertFalse(announcement.spoken.text.contains("promotions: promotions"),
                       "a doubled prefix must be impossible")
        XCTAssertEqual(try store.callsign(for: "sess-1"), "promotions refactor")

        // The callsign is frozen: a later turn with a different topic keeps it.
        _ = try store.insert(event: QueuedEvent(
            hookEvent: .stop, sessionId: "sess-1", promptId: "p2",
            cwd: "/tmp/promotions", lastAssistantMessage: "Now doing something else."))
        guard case .spoke(let second) = try await coordinator.announceNext() else {
            return XCTFail("expected a second announcement")
        }
        XCTAssertTrue(second.spoken.text.hasPrefix("promotions refactor: "))
        XCTAssertEqual(second.event.callsign, "promotions refactor",
                       "exposed on WaitingSession for the UI")
    }
}
