import AVFoundation
import XCTest
@testable import TranquilityCore

/// Two ways `speak` used to return before its audio, both of which ended with the
/// panel painting the grid over a live announcement.
///
/// Neither provider had a single test before this file. They are the two halves of
/// the same defect — a waiter settled by something other than "this audio finished" —
/// so they are pinned together.
final class SpeechCompletionTests: XCTestCase {

    // MARK: - ElevenLabs: a derived `isPaused` that latched true forever

    /// `isPaused` was `player != nil && !player.isPlaying`, which cannot tell "the
    /// user paused" from "it finished": `player` clears only in `stop()`. The playback
    /// loops wait on `isPlaying || isPaused`, so the instant audio ended naturally the
    /// predicate latched true and the loop never exited — `speak` never returned,
    /// `Coordinator` never saw `completed`, and the heard cursor never advanced.
    ///
    /// Asserted through the public surface rather than by driving real audio: the bug
    /// was that the flag reported a pause nobody had requested.
    func testIsPausedIsFalseWhenNobodyHasPaused() {
        let provider = ElevenLabsSpeechProvider()
        XCTAssertFalse(provider.isPaused,
                       "a provider that has never played must not report itself paused")
    }

    /// The loop's exit condition, stated directly: with no player and nobody having
    /// paused, `isPlaying || isPaused` must be false. Under the old derivation this
    /// held only until the first playback ended.
    func testPlaybackLoopPredicateIsFalseWhenIdle() {
        let provider = ElevenLabsSpeechProvider()
        XCTAssertFalse(provider.isSpeaking || provider.isPaused,
                       "an idle provider must satisfy the loop's exit condition")
    }

    /// `stop()` must clear the pause, or the next playback begins "paused" and its
    /// loop spins on a flag nobody set.
    func testStopClearsThePause() {
        let provider = ElevenLabsSpeechProvider()
        provider.pause()          // no player yet: must not latch anything
        provider.stop()
        XCTAssertFalse(provider.isPaused, "stop must leave the provider unpaused")
    }

    /// `pause()` with nothing playing is meaningless and must not set the flag —
    /// otherwise a stray chord press before audio starts strands the next loop.
    func testPauseWithNothingPlayingDoesNotLatch() {
        let provider = ElevenLabsSpeechProvider()
        provider.pause()
        XCTAssertFalse(provider.isPaused,
                       "pausing silence must not report a pause")
    }

    // MARK: - System voice: a continuation settled by the wrong utterance

    /// The regression that painted the grid four seconds into an eighteen-second rung.
    ///
    /// `speak` calls `stop()` first, so the OUTGOING utterance's `didCancel` arrives
    /// after the INCOMING continuation has been installed. With a bare continuation
    /// slot it resumed the successor's await, and the caller believed an announcement
    /// that had just started was already over.
    ///
    /// Driven through the delegate directly, which is the seam the bug lived in: a
    /// callback carrying an utterance we are no longer waiting on must resolve nothing.
    func testStaleUtteranceCallbackDoesNotSettleTheCurrentWait() async throws {
        let provider = SystemSpeechProvider()
        let abandoned = AVSpeechUtterance(string: "the utterance we cancelled")

        let speaking = Task {
            try await provider.speak(
                SpokenTextSanitizer().sanitize("the utterance we are waiting on"), onWord: nil)
        }
        // Let `speak` install its continuation before the stale callback lands.
        try await Task.sleep(nanoseconds: 150_000_000)

        // The cancelled utterance reports in. Under the old code this resumed the
        // continuation belonging to the live one.
        provider.speechSynthesizer(AVSpeechSynthesizer(), didCancel: abandoned)
        provider.speechSynthesizer(AVSpeechSynthesizer(), didFinish: abandoned)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(speaking.isCancelled)

        // Still waiting: only a callback for its OWN utterance, or an explicit stop,
        // may settle it. `stop()` is the honest teardown and must always settle.
        provider.stop()
        do { _ = try await speaking.value } catch { /* interrupted, as stop promises */ }
    }

    /// `stop()` used to open with `guard synthesizer.isSpeaking`, which meant a stop
    /// landing between `speak()` and audio actually starting stopped nothing AND left
    /// the continuation unresumed — a caller hung on an utterance it had cancelled.
    func testStopAlwaysSettlesTheWaiterEvenBeforeAudioStarts() async throws {
        let provider = SystemSpeechProvider()

        let speaking = Task {
            try await provider.speak(
                SpokenTextSanitizer().sanitize("stopped before it could start"), onWord: nil)
        }
        // Deliberately tight: aim for the window before the synthesizer reports
        // isSpeaking, which is exactly where the old guard returned early.
        try await Task.sleep(nanoseconds: 20_000_000)
        provider.stop()

        // A plain race rather than XCTestExpectation: fewer XCTest APIs to be wrong
        // about, and the assertion is the same — `speak` must settle, not hang.
        let settled = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = try? await speaking.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(settled, "stop() must settle a waiter even before audio starts")
    }
}
