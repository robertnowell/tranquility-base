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

    // MARK: - Synchronising on PLAYBACK, not on the wall clock

    /// Wait until the player has actually reached `seconds` of audio.
    ///
    /// Every wired test below used to `Task.sleep` for its offset and then act,
    /// which quietly assumes that N seconds of wall clock buys N seconds of
    /// PLAYBACK. It does not, and under a full-suite run it routinely does not:
    /// the play Task has to be scheduled at all, `AVAudioPlayer(data:)` and
    /// `prepareToPlay()` have to run, and `play()` returns before `isPlaying`
    /// flips (the provider itself waits up to 500ms for that). On a loaded
    /// machine those costs land inside the test's sleep, so "stop it at 0.5s"
    /// stopped it at 0.12s and the suite failed roughly two runs in three —
    /// while passing every time it was run alone, which is what made it look
    /// like nondeterminism instead of a missing barrier (issue 16).
    ///
    /// The deadline is wall clock and deliberately generous: it exists to fail
    /// a HUNG test, not to time a fast one. Nothing here asserts on it.
    @discardableResult
    private func awaitPlayback(
        _ provider: ElevenLabsSpeechProvider, reaches seconds: Double,
        deadline: Double = 20, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Double {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            let now = provider.player?.currentTime ?? 0
            if now >= seconds { return now }
            // Finished early: the clip ran out before reaching the mark, which
            // is a real answer for the caller, not a timeout.
            if let p = provider.player, !p.isPlaying, p.currentTime == 0, now == 0,
               Date().timeIntervalSince(start) > 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let reached = provider.player?.currentTime ?? 0
        XCTAssertGreaterThanOrEqual(
            reached, seconds,
            "playback never reached \(seconds)s within \(deadline)s — hung, not slow",
            file: file, line: line)
        return reached
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
        try await awaitPlayback(provider, reaches: 0.5)
        // Sampled immediately before the stop, so the assertion below compares
        // the payload against where playback ACTUALLY was rather than against
        // where a sleep hoped it would be.
        let atStop = provider.player?.currentTime ?? 0
        // The player, not the provider: provider.stop() bumps the generation,
        // which is a recorded intent. This is the unasked-for stop.
        provider.player?.stop()
        do {
            try await playing.value
            XCTFail("an unasked-for stop at \(atStop)s of 3.0s must throw .truncated")
        } catch SpeechError.truncated(let played, let total) {
            XCTAssertEqual(total, 3.0, accuracy: 0.1)
            XCTAssertGreaterThan(played, 0.2, "the high-water mark must have seen real progress")
            XCTAssertEqual(played, atStop, accuracy: 0.35,
                           "playedSeconds is the stop point, not the duration")
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
        try await awaitPlayback(provider, reaches: 0.5)
        provider.pause()
        // Wall clock is the right unit HERE: the claim is that time passing
        // while paused does not count against the clip, so the test has to
        // spend real time not playing.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        provider.resume()
        try await playing.value
    }

    /// The resume window, pinned directly rather than as a side effect of the
    /// pause test.
    ///
    /// `resume()` used to clear the pause latch and THEN restart the player.
    /// `play()` returns before `isPlaying` flips, so a loop poll landing in
    /// between saw neither playing nor paused, exited, and reported a clip you
    /// were still listening to as truncated at the pause point. This resumes
    /// and immediately hammers the observable state, which is where the race
    /// lived; playback must advance again before an intentional stop.
    func testResumeDoesNotBrieflyLookStopped() async throws {
        let provider = ElevenLabsSpeechProvider()
        // A long clip removes completion as a competing transition. The test
        // stops it explicitly after proving resumed playback made progress, so
        // this adds headroom without adding 30 seconds to the suite.
        let c = clip(seconds: 30.0), t = text(6)
        let playing = Task { try await provider.play(c, text: t, onWord: nil) }
        try await awaitPlayback(provider, reaches: 0.4)
        provider.pause()
        XCTAssertTrue(provider.isPaused, "a pause the user asked for is recorded")
        provider.resume()
        // The latch may only drop once playback is genuinely running again —
        // never in the gap that produced the false truncation.
        for _ in 0..<50 {
            if provider.player?.isPlaying == true { break }
            XCTAssertTrue(provider.isPaused,
                          "the latch must hold until the player is observed running")
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(provider.player?.isPlaying == true,
                      "resume must restart the player")
        try await awaitPlayback(provider, reaches: 0.8)
        XCTAssertFalse(provider.isPaused,
                       "the playback loop clears the latch after observing resumed audio")
        provider.stop()
        do {
            try await playing.value
            XCTFail("an intentional stop must interrupt the playback task")
        } catch SpeechError.interrupted {
            // Expected: proves the resume window did not exit early as truncated.
        } catch {
            XCTFail("expected .interrupted after the intentional stop, got \(error)")
        }
    }

    /// A deliberate stop is `.interrupted` — the caller asked, so nothing about
    /// it is a playback fault, however little audio was heard.
    func testDeliberateStopIsInterruptedNotTruncated() async throws {
        let provider = ElevenLabsSpeechProvider()
        let c = clip(seconds: 3.0), t = text(5)
        let playing = Task {
            try await provider.play(c, text: t, onWord: nil)
        }
        // Waiting for real playback is what makes the "never started" outcome
        // impossible: this test used to stop a player that, on a loaded
        // machine, had not begun, and got synthesisFailed("playback never
        // started") — a genuine fault surfacing where the test expected a
        // choice, and indistinguishable in the log from the bug it guards.
        try await awaitPlayback(provider, reaches: 0.3)
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
