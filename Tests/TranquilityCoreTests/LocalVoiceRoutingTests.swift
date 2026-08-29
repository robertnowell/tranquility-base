import XCTest
@testable import TranquilityCore

/// The roster is MIXED — 15 ElevenLabs ids and 11 Apple ones on this machine,
/// because the voice picker lists both — and round-robin assignment walks it in
/// order. So a session's durable voice is a local one roughly two times in five,
/// and nothing in the chain asked which PROVIDER an id belonged to before
/// spending a network call on it.
///
/// What that cost, from `app.log`: one
/// `http 400 invalid_uid "An invalid ID has been received:
/// 'com.apple.ttsbundle.siri_Nicky_en-US_premium'"` every five seconds,
/// indefinitely, per prewarm.
///
/// Why it hid for weeks: it needs BOTH a readable key (`isConfigured`) and an
/// Apple id on the roster. A machine with no key never reaches the network, and
/// a machine whose roster is the untouched seed has no Apple ids in it — the
/// seed is fifteen ElevenLabs voices. Neither machine can see this, which is
/// why it is pinned here rather than left to a deploy to notice.
final class LocalVoiceRoutingTests: XCTestCase {

    /// Records whether it was asked to speak. Deliberately not an
    /// `ElevenLabsSpeechProvider`: the assertion is about the CHAIN's routing
    /// decision, which must not depend on the concrete cloud type.
    private final class RecordingProvider: SpeechProvider, @unchecked Sendable {
        let name: String
        let isConfigured = true
        /// Set to make the render fail, which is the whole point of a fallback.
        var fails = false
        private let lock = NSLock()
        private var asked = 0
        var askedCount: Int { lock.lock(); defer { lock.unlock() }; return asked }

        init(name: String) { self.name = name }

        /// Synchronous, because `NSLock` is unavailable from an async context.
        private func record() { lock.lock(); asked += 1; lock.unlock() }

        struct Failed: Error {}

        func speak(_ text: SanitizedSpokenText,
                   onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
            record()
            if fails { throw Failed() }
        }
        func stop() {}
        var isSpeaking: Bool { false }
        var isPaused: Bool { false }
    }

    private func sanitized(_ s: String) -> SanitizedSpokenText {
        SpokenTextSanitizer().sanitize(s)
    }

    // MARK: - The routing decision

    /// A legacy row from the single-roster era: the session's only assignment is
    /// an Apple id. It must not reach the cloud — not because the session prefers
    /// a local voice, but because it has no cloud voice, and ElevenLabs' own
    /// default would be a stranger rather than the agent you have been hearing.
    func testASessionWithNoCloudVoiceIsReadInItsOwnSystemVoice() async {
        let cloud = RecordingProvider(name: "cloud")
        let local = RecordingProvider(name: "local")
        let chain = SpeechChain(preferred: cloud, fallback: local)

        _ = await chain.speak(sanitized("Finished the poller. Proceed?"),
                              voice: "com.apple.ttsbundle.siri_Nicky_en-US_premium")

        XCTAssertEqual(cloud.askedCount, 0,
                       "an Apple identifier must never be handed to the cloud provider")
        XCTAssertEqual(local.askedCount, 1,
                       "the local voice still has to be read — skipping the cloud is not silence")
    }

    /// The other direction, which is what makes the first test mean anything:
    /// the guard must not have simply turned the cloud off.
    func testACloudVoiceStillReachesTheCloudProvider() async {
        let cloud = RecordingProvider(name: "cloud")
        let local = RecordingProvider(name: "local")
        let chain = SpeechChain(preferred: cloud, fallback: local)

        _ = await chain.speak(sanitized("Finished the poller. Proceed?"),
                              voice: "CwhRBWXzGAHq8TQ4Fs17")   // Roger, seed roster

        XCTAssertEqual(cloud.askedCount, 1,
                       "an ElevenLabs id must still be rendered by ElevenLabs")
        XCTAssertEqual(local.askedCount, 0,
                       "the fallback speaks only when the preferred provider does not")
    }

    /// No voice named at all is the pre-roster path and must be untouched: the
    /// provider resolves its own default, so the cloud still gets the call.
    func testNoVoiceNamedIsUnchanged() async {
        let cloud = RecordingProvider(name: "cloud")
        let local = RecordingProvider(name: "local")
        let chain = SpeechChain(preferred: cloud, fallback: local)

        _ = await chain.speak(sanitized("Finished the poller. Proceed?"), voice: nil)

        XCTAssertEqual(cloud.askedCount, 1,
                       "a nil voice is 'use your default', not 'you are a local voice'")
    }

    /// The design, in one assertion: with both voices assigned, ElevenLabs is
    /// what speaks. The system voice is a redundancy, never a competitor.
    func testWithBothAssignedTheCloudIsWhatSpeaks() async {
        let cloud = RecordingProvider(name: "cloud")
        let local = RecordingProvider(name: "local")
        let chain = SpeechChain(preferred: cloud, fallback: local)

        _ = await chain.speak(sanitized("Finished the poller. Proceed?"),
                              voice: "CwhRBWXzGAHq8TQ4Fs17",
                              systemVoice: "com.apple.voice.premium.en-US.Ava")

        XCTAssertEqual(cloud.askedCount, 1, "ElevenLabs is used whenever it is available")
        XCTAssertEqual(local.askedCount, 0, "the system voice is redundancy, not a competitor")
    }

    /// And the redundancy itself: when the cloud render FAILS, the session is
    /// still read — by the fallback. This is the path that has to be effortless,
    /// because it is the one nobody chooses to be on.
    func testAFailedCloudRenderFallsBackToTheSystemVoice() async {
        let cloud = RecordingProvider(name: "cloud")
        cloud.fails = true
        let local = RecordingProvider(name: "local")
        let chain = SpeechChain(preferred: cloud, fallback: local)

        let spoken = await chain.speak(sanitized("Finished the poller. Proceed?"),
                                       voice: "CwhRBWXzGAHq8TQ4Fs17",
                                       systemVoice: "com.apple.voice.premium.en-US.Ava")

        XCTAssertEqual(cloud.askedCount, 1, "the cloud is tried first")
        XCTAssertEqual(local.askedCount, 1, "a failed cloud render must still be read aloud")
        XCTAssertNotNil(spoken.degraded,
                        "a silent downgrade is exactly what `degraded` exists to surface")
    }

    // MARK: - The discriminator

    /// `isSystemVoice` is a prefix test, so it is only as good as its coverage
    /// of the id SHAPES Apple actually ships. Three distinct families appear in
    /// this machine's roster, and an earlier guess would have caught only one.
    func testTheDiscriminatorCoversEveryAppleFamilyInTheWild() {
        for id in ["com.apple.ttsbundle.siri_Nicky_en-US_premium",   // Siri bundle
                   "com.apple.voice.premium.en-US.Ava",              // premium
                   "com.apple.voice.enhanced.en-GB.Daniel",          // enhanced
                   "com.apple.speech.synthesis.voice.Alex"] {        // the old compact
            XCTAssertTrue(SystemVoiceCatalog.isSystemVoice(id), "\(id) is a local voice")
        }
    }

    /// And no ElevenLabs id may be mistaken for a local one — the seed roster is
    /// the exact set a fresh install speaks with, so a false positive here would
    /// silently send every new user to the system voice.
    func testNoSeedRosterVoiceIsMistakenForLocal() {
        for id in VoiceRoster.seed {
            XCTAssertFalse(SystemVoiceCatalog.isSystemVoice(id),
                           "\(id) is an ElevenLabs voice and must go to the cloud")
        }
    }
}
