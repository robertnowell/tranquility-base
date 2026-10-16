import XCTest
@testable import TranquilityCore

/// Muted is a silent version, not a quiet one (ruled 16 Oct 2026): no
/// provider is asked for anything, and the line still counts as delivered,
/// because the card showed it.
final class VoiceMuteTests: XCTestCase {

    /// Counts every call so "nothing was synthesized" is an assertion, not a hope.
    final class CountingProvider: SpeechProvider, @unchecked Sendable {
        let name: String
        var isConfigured: Bool { true }
        var isSpeaking: Bool { false }
        private(set) var speaks = 0
        init(_ name: String) { self.name = name }
        func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
            speaks += 1
            onWord?(0..<text.text.count)
        }
        func stop() {}
    }

    final class Flag: @unchecked Sendable { var on: Bool; init(_ on: Bool) { self.on = on } }

    private let line = SpokenTextSanitizer().sanitize("Three tests failed in the parser.")

    func testMutedSpeaksNothingAndCountsAsDelivered() async {
        let preferred = CountingProvider("cloud"), fallback = CountingProvider("system")
        let chain = SpeechChain(preferred: preferred, fallback: fallback, isMuted: { true })
        let words = Flag(false)
        let spoken = await chain.speak(line, onWord: { _ in words.on = true })
        XCTAssertEqual(preferred.speaks, 0, "muted must not reach the cloud voice")
        XCTAssertEqual(fallback.speaks, 0, "muted is not a reason to fall back")
        XCTAssertFalse(words.on, "no audio, so no word events to follow")
        XCTAssertEqual(spoken.provider, SpeechChain.mutedProvider)
        XCTAssertTrue(spoken.completed, "a completed return is what lights the whole card")
        XCTAssertTrue(spoken.heardAny, "the card showed it, so the turn is opened")
        XCTAssertNil(spoken.failure)
        XCTAssertNil(spoken.degraded, "silence by choice is not a degraded voice")
    }

    /// Unmuting takes effect on the very next utterance: the flag is read per
    /// call, never captured at construction.
    func testUnmuteTakesEffectOnTheNextUtterance() async {
        let preferred = CountingProvider("cloud"), fallback = CountingProvider("system")
        let muted = Flag(true)
        let chain = SpeechChain(preferred: preferred, fallback: fallback, isMuted: { muted.on })
        _ = await chain.speak(line)
        XCTAssertEqual(preferred.speaks, 0)
        muted.on = false
        let spoken = await chain.speak(line)
        XCTAssertEqual(preferred.speaks, 1)
        XCTAssertEqual(spoken.provider, "cloud")
    }

    func testMutedPrewarmRendersNothing() async {
        let chain = SpeechChain(preferred: ElevenLabsSpeechProvider(), isMuted: { true })
        let warmed = await chain.prewarm(line)
        XCTAssertFalse(warmed)
    }

    func testFlagDefaultsOffAndPersists() {
        let suite = "VoiceMuteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let saved = VoiceMute.defaults
        VoiceMute.defaults = defaults
        defer { VoiceMute.defaults = saved; defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(VoiceMute.isOn, "absent means the voice is on")
        VoiceMute.isOn = true
        XCTAssertTrue(defaults.bool(forKey: VoiceMute.key))
        VoiceMute.isOn = false
        XCTAssertFalse(VoiceMute.isOn)
    }
}
