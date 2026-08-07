import XCTest
@testable import TranquilityCore

/// A7: the shared lexicon — harvest window, cap, dedup, seeding, and the three
/// consumers (live transcription handshake, Apple recovery contextual strings,
/// sanitizer allowlist). All protocol-level; no live API is ever touched.
final class LexiconTests: XCTestCase {

    private func makeStore() throws -> (QueueStore, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-lexicon-\(UUID().uuidString).sqlite")
        return (try QueueStore(url: tmp), tmp)
    }

    private func ms(hoursAgo: Double, from now: Date) -> Int64 {
        Int64((now.timeIntervalSince1970 - hoursAgo * 3600) * 1000)
    }

    // MARK: - Harvest

    func testHarvestWindowExcludesStaleEvents() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()

        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms(hoursAgo: 1, from: now), hookEvent: .stop, sessionId: "fresh",
            cwd: "/tmp/promotions", lastAssistantMessage: "Klaviyo synced cleanly."))
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms(hoursAgo: 72, from: now), hookEvent: .stop, sessionId: "stale",
            cwd: "/tmp/syndit", lastAssistantMessage: "Zendesk import broke."))

        let lexicon = Lexicon.harvest(store: store, now: now)
        XCTAssertTrue(lexicon.terms.contains("Klaviyo"))
        XCTAssertFalse(lexicon.terms.contains("Zendesk"),
                       "a 72h-old mention is outside the rolling 48h window")
        XCTAssertFalse(lexicon.terms.contains("syndit"),
                       "the stale event's project label is outside the window too")
    }

    func testHarvestIsCappedButSeedsAlwaysSurvive() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()

        // 150 distinct capitalized names — more than the cap can hold.
        let flood = (0..<150).map { "Vendor\($0)" }.joined(separator: " and ")
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms(hoursAgo: 1, from: now), hookEvent: .stop, sessionId: "s1",
            cwd: "/tmp/promotions", lastAssistantMessage: flood))
        try store.mintCallsign("promotions copy", for: "s1")

        let lexicon = Lexicon.harvest(store: store, now: now)
        XCTAssertLessThanOrEqual(lexicon.terms.count, Lexicon.maxTerms)
        XCTAssertTrue(lexicon.terms.contains("promotions copy"),
                      "the callsign is seeded regardless of the flood")
        XCTAssertTrue(lexicon.terms.contains("promotions"),
                      "the project label is seeded regardless of the flood")
    }

    func testHarvestDedupesCaseInsensitively() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()

        // The label "promotions" is a seed; the message's capitalized
        // "Promotions" must not add a second entry.
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms(hoursAgo: 1, from: now), hookEvent: .stop, sessionId: "s1",
            cwd: "/tmp/promotions", lastAssistantMessage: "Promotions shipped. Klaviyo synced."))
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms(hoursAgo: 2, from: now), hookEvent: .stop, sessionId: "s2",
            cwd: "/tmp/kopi", lastAssistantMessage: "Klaviyo flow paused."))

        let lexicon = Lexicon.harvest(store: store, now: now)
        XCTAssertEqual(lexicon.terms.filter { $0.lowercased() == "promotions" }.count, 1)
        XCTAssertEqual(lexicon.terms.filter { $0.lowercased() == "klaviyo" }.count, 1)
    }

    func testRecencyOutranksAgeWithinTheWindow() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()

        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms(hoursAgo: 40, from: now), hookEvent: .stop, sessionId: "old",
            cwd: "/tmp/a", lastAssistantMessage: "Zendesk migrated."))
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: ms(hoursAgo: 1, from: now), hookEvent: .stop, sessionId: "new",
            cwd: "/tmp/b", lastAssistantMessage: "Klaviyo synced."))

        let terms = Lexicon.harvest(store: store, now: now).terms
        guard let klaviyo = terms.firstIndex(of: "Klaviyo"),
              let zendesk = terms.firstIndex(of: "Zendesk") else {
            return XCTFail("both terms should be inside the window: \(terms)")
        }
        XCTAssertLessThan(klaviyo, zendesk, "an hour-old name outranks a 40h-old one")
    }

    func testLiveSessionNamesAreSeeded() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let lexicon = Lexicon.harvest(store: store, liveSessionNames: ["promotions-49"])
        XCTAssertTrue(lexicon.terms.contains("promotions-49"))
    }

    func testAllowlistTermsIncludeTheWordsOfMultiWordCallsigns() {
        let lexicon = Lexicon(terms: ["promotions copy", "Klaviyo"])
        XCTAssertTrue(lexicon.allowlistTerms.contains("promotions copy"))
        XCTAssertTrue(lexicon.allowlistTerms.contains("promotions"),
                      "the sanitizer matches single tokens; phrases must be split")
        XCTAssertTrue(lexicon.allowlistTerms.contains("copy"))
        XCTAssertTrue(lexicon.allowlistTerms.contains("Klaviyo"))
    }

    // MARK: - Consumer 1: the live transcription handshake

    private final class RecordedSession: LiveTranscriptionSession, @unchecked Sendable {
        func append(pcm16: Data) {}
        func requestFinal() {}
        func cancel() {}
    }

    /// A provider that supports vocabulary boost receives the lexicon at
    /// session open — the streaming handshake takes it once.
    func testBoostSupportingProviderReceivesTheLexiconAtSessionOpen() async throws {
        final class Boostable: LiveTranscriptionProvider, @unchecked Sendable {
            let name = "mock-assemblyai"; let isConfigured = true
            var receivedVocabulary: [String]?
            func startSession(
                onPartial: @escaping @Sendable (String) -> Void,
                onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
                onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
            ) async throws -> any LiveTranscriptionSession { RecordedSession() }
            func startSession(
                boosting vocabulary: [String],
                onPartial: @escaping @Sendable (String) -> Void,
                onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
                onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
            ) async throws -> any LiveTranscriptionSession {
                receivedVocabulary = vocabulary
                return RecordedSession()
            }
        }
        let provider = Boostable()
        let lexicon = Lexicon(terms: ["promotions copy", "Klaviyo"])
        _ = try await provider.startSession(
            boosting: lexicon.terms, onPartial: { _ in }, onFinal: { _ in }, onFailure: { _ in })
        XCTAssertEqual(provider.receivedVocabulary, ["promotions copy", "Klaviyo"])
    }

    /// A provider without vocabulary support keeps working: the default
    /// forwards to the plain session open, dropping the boost.
    func testBoostDefaultForwardsForProvidersWithoutVocabularySupport() async throws {
        final class Plain: LiveTranscriptionProvider, @unchecked Sendable {
            let name = "plain"; let isConfigured = true
            var plainOpens = 0
            func startSession(
                onPartial: @escaping @Sendable (String) -> Void,
                onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
                onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
            ) async throws -> any LiveTranscriptionSession {
                plainOpens += 1
                return RecordedSession()
            }
        }
        let provider = Plain()
        _ = try await provider.startSession(
            boosting: ["Klaviyo"], onPartial: { _ in }, onFinal: { _ in }, onFailure: { _ in })
        XCTAssertEqual(provider.plainOpens, 1)
    }

    // MARK: - Consumer 2: Apple recovery

    func testRecoveryChainPlumbsTheLexiconIntoAppleSpeech() {
        let chain = RecoveryChain(lexicon: ["promotions copy", "Klaviyo"])
        let apple = chain.providers.compactMap { $0 as? AppleSpeechRecovery }.first
        XCTAssertEqual(apple?.lexicon, ["promotions copy", "Klaviyo"],
                       "the default chain hands the lexicon to the on-device floor")
    }

    // MARK: - Consumer 2b: the OpenAI Whisper prompt (the primary path today)

    func testRecoveryChainPlumbsTheLexiconIntoOpenAI() {
        let chain = RecoveryChain(lexicon: ["promotions copy", "Klaviyo"])
        let openai = chain.providers.compactMap { $0 as? OpenAIRecovery }.first
        XCTAssertEqual(openai?.lexicon, ["promotions copy", "Klaviyo"],
                       "the default chain hands the lexicon to the primary provider too")
    }

    func testWhisperPromptIsACommaJoinedTermListInLexiconOrder() {
        let prompt = OpenAIRecovery.lexiconPrompt(["promotions copy", "Klaviyo", "syndit"])
        XCTAssertEqual(prompt, "The recording may mention: promotions copy, Klaviyo, syndit.")
    }

    func testWhisperPromptIsNilForAnEmptyLexicon() {
        XCTAssertNil(OpenAIRecovery.lexiconPrompt([]),
                     "no lexicon means no prompt field, not an empty scaffold")
        XCTAssertNil(OpenAIRecovery.lexiconPrompt(["  ", ""]),
                     "whitespace-only terms compose nothing")
    }

    func testWhisperPromptRespectsTheTokenCap() {
        // 300 distinct names — far more than ~224 Whisper tokens can hold.
        let flood = (0..<300).map { "VendorNumber\($0)" }
        let prompt = try! XCTUnwrap(OpenAIRecovery.lexiconPrompt(flood))
        XCTAssertLessThanOrEqual(
            OpenAIRecovery.estimatedTokens(prompt), OpenAIRecovery.promptTokenBudget,
            "the composed prompt stays under the conservative budget")
        XCTAssertFalse(prompt.contains("VendorNumber299"),
                       "the tail must have been dropped to fit")
    }

    /// The lexicon puts seeds — callsigns and project labels — at the head, and
    /// the prompt truncates from the tail, so under pressure the words the user
    /// says back at the app always survive.
    func testWhisperPromptKeepsCallsignsAndLabelsWhenTruncating() {
        let seeds = ["promotions copy", "voice-dispatch", "m3-tracker"]
        let harvested = (0..<300).map { "HarvestedName\($0)" }
        let prompt = try! XCTUnwrap(OpenAIRecovery.lexiconPrompt(seeds + harvested))
        for seed in seeds {
            XCTAssertTrue(prompt.contains(seed), "seed \"\(seed)\" must survive the cap")
        }
        XCTAssertFalse(prompt.contains("HarvestedName299"))
    }

    // MARK: - Consumer 3: the sanitizer allowlist at announce time

    func testLexiconTermsSurviveSanitizationEvenWhenTheMessageDoesNotEstablishThem() async {
        struct WritesAKnownName: SummaryProvider {
            let name = "fixed"; let isConfigured = true
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                // "voice_dispatch" is snake_case — the identifier rule eats it
                // unless the lexicon vouches for it as an established name.
                SessionBrief(topic: "export", happened: "done",
                             recap: "promotions: voice_dispatch export green.")
            }
        }
        let chain = SummarizerChain(providers: [WritesAKnownName()])
        let request = SummaryRequest(
            lastAssistantMessage: "Export finished.", projectLabel: "promotions")

        let without = await chain.summarize(request)
        XCTAssertFalse(without.spoken.text.contains("voice_dispatch"),
                       "without the lexicon the identifier rule still wins")

        let with = await chain.summarize(request, lexicon: ["voice_dispatch"])
        XCTAssertTrue(with.spoken.text.contains("voice_dispatch"),
                      "a lexicon-established name survives speech: \(with.spoken.text)")
    }

    func testLexiconNeverMakesPathsOrHashesSpeakable() async {
        struct WritesAPath: SummaryProvider {
            let name = "fixed"; let isConfigured = true
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                SessionBrief(topic: "export", happened: "done",
                             recap: "promotions: edited /Users/x/app/file at a3f9c21b4e.")
            }
        }
        let chain = SummarizerChain(providers: [WritesAPath()])
        let summary = await chain.summarize(
            SummaryRequest(lastAssistantMessage: "Edited.", projectLabel: "promotions"),
            lexicon: ["/Users/x/app/file", "a3f9c21b4e"])
        XCTAssertFalse(summary.spoken.text.contains("/Users"))
        XCTAssertFalse(summary.spoken.text.contains("a3f9c21b4e"))
    }
}
