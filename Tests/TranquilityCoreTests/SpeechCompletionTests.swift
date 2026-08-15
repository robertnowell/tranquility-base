import AVFoundation
import XCTest
@testable import TranquilityCore

/// Two ways `speak` used to return before its audio, both of which ended with the
/// panel painting the grid over a live announcement.
///
/// Neither provider had a single test before this file. They are the two halves of
/// the same defect — a waiter settled by something other than "this audio finished" —
/// so they are pinned together.
///
/// SILENT BY CONSTRUCTION. The system-voice tests used to call the real
/// `AVSpeechSynthesizer`, so every `swift test` spoke its test phrases through
/// the user's speakers (ruled 15 Aug: never again). They now inject
/// `SilentSynthesizerSpy`; the regressions live in continuation bookkeeping,
/// which the spy exercises deterministically where the real engine only raced.
/// Nothing in this file may start audible playback.
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
        let spy = SilentSynthesizerSpy()
        let provider = SystemSpeechProvider(rate: 0.52, voiceIdentifier: nil, synthesizer: spy)
        let abandoned = AVSpeechUtterance(string: "the utterance we cancelled")

        // Settlement is observed through a flag the task marks itself. Racing
        // `speaking.value` in a task group deadlocks here: awaiting `Task.value`
        // is not cancellation-sensitive, so a group racing it against a timer
        // cannot exit while the wait is (correctly) still open.
        let settled = SettledFlag()
        let speaking = Task {
            defer { settled.mark() }
            try await provider.speak(
                SpokenTextSanitizer().sanitize("the utterance we are waiting on"), onWord: nil)
        }
        // The continuation is installed just before the synthesizer is handed the
        // utterance, so "the spy has seen it" means "the wait is live". Observed,
        // not slept for: the old 150ms guess was both slower and less certain.
        try await Self.eventually("speak reaches the synthesizer") { spy.spokenCount == 1 }

        // The cancelled utterance reports in. Under the old code this resumed the
        // continuation belonging to the live one.
        provider.speechSynthesizer(AVSpeechSynthesizer(), didCancel: abandoned)
        provider.speechSynthesizer(AVSpeechSynthesizer(), didFinish: abandoned)

        // The stale callbacks must resolve nothing: the live wait stays open. The
        // spy never finishes anything on its own, so a settle here could only be
        // the bug this test pins.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(settled.isSet,
                       "a stale utterance's callback must not settle the live wait")

        // Only a callback for its OWN utterance, or an explicit stop, may settle
        // it. `stop()` is the honest teardown and must always settle.
        provider.stop()
        try await Self.eventually("stop settles the waiter") { settled.isSet }
        // Awaiting an unsettled wait would hang the suite; if the settle failed,
        // `eventually` has already gone red and there is nothing left to check.
        guard settled.isSet else { return }
        do {
            _ = try await speaking.value
            XCTFail("stop must interrupt the wait, not complete it")
        } catch { /* interrupted, as stop promises */ }
    }

    /// `stop()` used to open with `guard synthesizer.isSpeaking`, which meant a stop
    /// landing between `speak()` and audio actually starting stopped nothing AND left
    /// the continuation unresumed — a caller hung on an utterance it had cancelled.
    ///
    /// The spy's `isSpeaking` is permanently false, so the whole test lives in the
    /// pre-start window the old guard fell through. The real-synthesizer version
    /// raced a 20ms sleep to land here and spoke its phrase whenever it lost.
    func testStopAlwaysSettlesTheWaiterEvenBeforeAudioStarts() async throws {
        let spy = SilentSynthesizerSpy()
        let provider = SystemSpeechProvider(rate: 0.52, voiceIdentifier: nil, synthesizer: spy)

        let settled = SettledFlag()
        let speaking = Task {
            defer { settled.mark() }
            try await provider.speak(
                SpokenTextSanitizer().sanitize("stopped before it could start"), onWord: nil)
        }
        try await Self.eventually("speak reaches the synthesizer") { spy.spokenCount == 1 }

        let stopsBefore = spy.stopCount
        provider.stop()
        // The teardown half of the old bug: the guard also skipped `stopSpeaking`,
        // so a not-yet-audible utterance went on to play after its cancellation.
        XCTAssertEqual(spy.stopCount, stopsBefore + 1,
                       "stop() must tear down the synthesizer even before audio starts")

        try await Self.eventually("stop settles a waiter whose audio never started") {
            settled.isSet
        }
        guard settled.isSet else { return }
        do {
            _ = try await speaking.value
            XCTFail("a stopped wait must throw interrupted, not complete")
        } catch { /* interrupted, as stop promises */ }
    }

    // MARK: - Helpers

    private static func eventually(
        _ what: String, timeout: UInt64 = 2_000_000_000, _ condition: () -> Bool
    ) async throws {
        var waited: UInt64 = 0
        while !condition() {
            guard waited < timeout else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 5_000_000)
            waited += 5_000_000
        }
    }
}

/// Marked by a task as its last act, so "has it settled" is a lock-protected
/// read instead of a race against `Task.value` (which does not respond to
/// cancellation and so cannot be raced inside a task group without deadlock).
private final class SettledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// A synthesizer that accepts utterances and never makes a sound, never starts,
/// and never settles anything on its own. Callbacks are the tests' to deliver,
/// which is the point: both pinned bugs were about WHO may settle the wait.
private final class SilentSynthesizerSpy: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?
    let isSpeaking = false

    private let lock = NSLock()
    private var spoken: [AVSpeechUtterance] = []
    private var stops = 0

    var spokenCount: Int { lock.lock(); defer { lock.unlock() }; return spoken.count }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }

    func speak(_ utterance: AVSpeechUtterance) {
        lock.lock(); spoken.append(utterance); lock.unlock()
    }

    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        lock.lock(); stops += 1; lock.unlock()
        return true
    }
}
