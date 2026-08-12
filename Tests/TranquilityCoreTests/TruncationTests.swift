import AVFoundation
import XCTest
@testable import TranquilityCore

/// The ElevenLabs-then-robot double-read, pinned from both directions.
///
/// `checkForTruncation` used to re-read `audio.currentTime` after the playback
/// loop exited. AVAudioPlayer resets `currentTime` to 0 on natural completion —
/// its post-terminal state is bit-identical to its pre-initial state — so every
/// COMPLETED announcement was reported as `truncated(playedSeconds: 0)`, which
/// sat under the chain's 2s "heard nothing" threshold and restarted the whole
/// announcement in the system voice. The check was never right: it shipped
/// broken on 02 Aug, was misdiagnosed as a tolerance problem the same night,
/// went unreachable behind the `isPaused` latch six minutes later, and returned
/// verbatim when d552b0b fixed the latch on 11 Aug.
///
/// The fix measures completion while playing (a high-water mark inside the
/// loop) and makes the check a pure function of the measurement. These tests
/// pin the pure function with the incident's own numbers, then drive the wired
/// path with real (silent) audio — including a staged GENUINE truncation, so
/// silencing the false positive is proven not to have silenced the true one.
final class TruncationTests: XCTestCase {

    // MARK: - The pure function

    /// The incident, with its measured numbers: a 3.227s clip whose last
    /// in-loop sample was 3.204s. Under the old code this pair was never seen —
    /// the check read 0.000 off the reset player and threw.
    func testCompletedClipIsNotTruncated() {
        XCTAssertNoThrow(try ElevenLabsSpeechProvider.checkForTruncation(
            played: 3.204, duration: 3.227, generation: 1, current: 1))
    }

    /// Genuine truncation throws, and the payload is the measurement — the
    /// chain branches on `playedSeconds < 2` to decide restart-vs-report, so
    /// the numbers are load-bearing, not diagnostic garnish.
    func testGenuineTruncationThrowsWithItsMeasurement() {
        XCTAssertThrowsError(try ElevenLabsSpeechProvider.checkForTruncation(
            played: 1.1, duration: 12.0, generation: 1, current: 1)) { error in
            guard case SpeechError.truncated(let played, let total) = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
            XCTAssertEqual(played, 1.1, accuracy: 0.001)
            XCTAssertEqual(total, 12.0, accuracy: 0.001)
        }
    }

    /// The 0.75s tolerance, pinned from both sides so a future edit fails a
    /// test instead of silently reopening the double-read. It must exceed the
    /// largest poll interval (200ms) plus sleep overshoot and format rounding;
    /// measured worst-case shortfall on completed clips is 0.105s.
    func testToleranceBoundary() {
        XCTAssertNoThrow(try ElevenLabsSpeechProvider.checkForTruncation(
            played: 10.0 - 0.70, duration: 10.0, generation: 1, current: 1))
        XCTAssertThrowsError(try ElevenLabsSpeechProvider.checkForTruncation(
            played: 10.0 - 0.80, duration: 10.0, generation: 1, current: 1)) { error in
            guard case SpeechError.truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    /// A bumped generation means somebody asked. That is `.interrupted`, never
    /// `.truncated` — intent is recorded, not inferred, and a deliberate stop
    /// must not be reported as a fault regardless of how far playback got.
    func testBumpedGenerationIsInterruptedNeverTruncated() {
        XCTAssertThrowsError(try ElevenLabsSpeechProvider.checkForTruncation(
            played: 0.0, duration: 10.0, generation: 1, current: 2)) { error in
            guard case SpeechError.interrupted = error else {
                return XCTFail("expected .interrupted, got \(error)")
            }
        }
    }

    // MARK: - The wired path, with real audio

    /// A silent PCM WAV, built in memory: 8kHz mono 16-bit zeros behind a
    /// 44-byte RIFF header. Real enough for AVAudioPlayer to play at real
    /// speed, which is the property under test. (A header that LIES about its
    /// length cannot stage a truncation — the player recomputes `duration`
    /// from the bytes actually present; measured, so nobody re-tries it.)
    private func silentWAV(seconds: Double) -> Data {
        let sampleRate = 8000
        let bytesPerSample = 2
        let dataSize = Int(seconds * Double(sampleRate)) * bytesPerSample
        var wav = Data()
        func append(_ s: String) { wav.append(contentsOf: s.utf8) }
        func append32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * bytesPerSample)
        append16(bytesPerSample); append16(16)
        append("data"); append32(dataSize)
        wav.append(Data(count: dataSize))
        return wav
    }

    private func clip(seconds: Double, starts: [Double]? = nil) -> SpokenClip {
        SpokenClip(audio: silentWAV(seconds: seconds), starts: starts)
    }

    /// Distinctive first words on purpose: play() archives every clip to the
    /// spoken/ folder (pruned to 20), and the filename slug should announce
    /// itself as a test rather than evicting a real clip anonymously.
    private func text(_ n: Int) -> SanitizedSpokenText {
        SpokenTextSanitizer().sanitize("truncation test tone \(n)")
    }

    /// THE regression test: a clip that plays to natural completion must
    /// return, not throw. Fails on the pre-fix code with `truncated(0, 1.5)` —
    /// this is the no-highlight branch, the one every real announcement takes.
    func testNaturalCompletionReturnsWithoutThrowing() async throws {
        let provider = ElevenLabsSpeechProvider()
        try await provider.play(clip(seconds: 1.5), text: text(1), onWord: nil)
    }

    /// The same completion through the highlight branch. The second assertion
    /// is the point: `onWord` firing proves WHICH loop ran, so a fix applied
    /// to only one exit cannot pass both completion tests.
    func testNaturalCompletionWithHighlightDrivesWordsAndReturns() async throws {
        let provider = ElevenLabsSpeechProvider()
        let fired = ManagedAtomic()
        try await provider.play(
            clip(seconds: 1.5, starts: [0.0, 0.4, 0.8]), text: text(2),
            onWord: { _ in fired.set() })
        XCTAssertTrue(fired.get(), "the highlight loop must have driven onWord")
    }

    /// The direction the fix must NOT have silenced: a transport stop with the
    /// generation untouched — what a route change or dying device looks like —
    /// is a genuine truncation and must still throw, with the high-water mark
    /// as its payload.
    func testTransportStopMidPlayIsStillTruncation() async throws {
        let provider = ElevenLabsSpeechProvider()
        // Hoisted: the Task closure may capture only Sendables, not the test case.
        let c = clip(seconds: 3.0), t = text(3)
        let playing = Task {
            try await provider.play(c, text: t, onWord: nil)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        // The player, not the provider: provider.stop() bumps the generation,
        // which is a recorded intent. This is the unasked-for stop.
        provider.player?.stop()
        do {
            try await playing.value
            XCTFail("an unasked-for stop at 0.5s of 3.0s must throw .truncated")
        } catch SpeechError.truncated(let played, let total) {
            XCTAssertEqual(total, 3.0, accuracy: 0.1)
            XCTAssertGreaterThan(played, 0.2, "the high-water mark must have seen real progress")
            XCTAssertLessThan(played, 1.2, "playedSeconds must be the stop point, not the duration")
        }
    }

    /// Pause across the clip, resume, play to the end: completion, not
    /// truncation. Under a pause the player does not advance, so the high-water
    /// mark's staleness is bounded by one poll of PLAYBACK, never wall clock.
    func testPauseThenResumeToCompletionIsNotTruncation() async throws {
        let provider = ElevenLabsSpeechProvider()
        let c = clip(seconds: 2.0), t = text(4)
        let playing = Task {
            try await provider.play(c, text: t, onWord: nil)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        provider.pause()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        provider.resume()
        try await playing.value
    }

    /// A deliberate stop is `.interrupted` — the caller asked, so nothing about
    /// it is a playback fault, however little audio was heard.
    func testDeliberateStopIsInterruptedNotTruncated() async throws {
        let provider = ElevenLabsSpeechProvider()
        let c = clip(seconds: 3.0), t = text(5)
        let playing = Task {
            try await provider.play(c, text: t, onWord: nil)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        provider.stop()
        do {
            try await playing.value
            // Acceptable: stop landed after completion on a loaded machine.
        } catch SpeechError.interrupted {
            // The expected path.
        } catch {
            XCTFail("a deliberate stop must never surface as \(error)")
        }
    }
}

/// The smallest thread-safe flag XCTest needs here; `os_unfair_lock` and
/// friends are more machinery than a boolean deserves.
private final class ManagedAtomic: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.atomic")
    private var value = false
    func set() { queue.sync { value = true } }
    func get() -> Bool { queue.sync { value } }
}
