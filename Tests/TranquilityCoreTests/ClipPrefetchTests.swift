import XCTest
@testable import TranquilityCore

/// The prefetch path, which exists to take the ElevenLabs round trip off the
/// critical path — measured p50 1s but with an 11s tail, spent looking at a card
/// of grey text with nothing moving on it.
///
/// Every test here pins a way the optimisation could go wrong in a way that is
/// WORSE than the latency it removes: speaking yesterday's sentence, eating the
/// summary it was warming, paying twice, or waiting forever on a link that never
/// quite dies.
final class ClipPrefetchTests: XCTestCase {

    private func clip(_ byte: UInt8) -> SpokenClip {
        SpokenClip(audio: Data([byte]), starts: nil)
    }

    // MARK: - Identity

    /// The failure this key shape exists to prevent: a cache that answers for
    /// text it did not render. A path- or session-keyed cache shipped stale
    /// narration once already, so identity is the CONTENT.
    func testOneChangedWordMisses() async {
        let cache = ClipCache()
        let voice = "voice-a"
        let first = ClipCache.key(text: "Finished the poller. Proceed?", voice: voice, model: "m")
        let second = ClipCache.key(text: "Finished the parser. Proceed?", voice: voice, model: "m")
        XCTAssertNotEqual(first, second)

        await cache.store(clip(1), for: first)
        let hit = await cache.cached(first)
        let miss = await cache.cached(second)
        XCTAssertEqual(hit?.audio, Data([1]))
        XCTAssertNil(miss, "a summary that changed by one word must re-render, not replay")
    }

    /// Same words, different session voice. The whole point of the durable
    /// per-session voice is that two sessions on one subject stop being
    /// confusable — a cache that ignored the voice would undo exactly that.
    func testSameTextInAnotherVoiceMisses() async {
        let cache = ClipCache()
        let text = "Finished the poller. Proceed?"
        let a = ClipCache.key(text: text, voice: "voice-a", model: "m")
        let b = ClipCache.key(text: text, voice: "voice-b", model: "m")
        XCTAssertNotEqual(a, b)

        await cache.store(clip(1), for: a)
        let wrongVoice = await cache.cached(b)
        XCTAssertNil(wrongVoice, "a prefetch must never lend its audio to another voice")
    }

    // MARK: - Cost

    /// A press landing while its own prefetch is still in flight must WAIT on
    /// that render, not start a second one. Both the credits and the wall clock
    /// depend on it — two renders of the same sentence is the one outcome worse
    /// than no prefetch at all.
    func testConcurrentCallersRenderOnce() async throws {
        let cache = ClipCache()
        let renders = Counter()
        let key = ClipCache.key(text: "one", voice: "v", model: "m")

        async let first = cache.clip(for: key) {
            await renders.bump()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return SpokenClip(audio: Data([7]), starts: nil)
        }
        async let second = cache.clip(for: key) {
            await renders.bump()
            return SpokenClip(audio: Data([9]), starts: nil)
        }
        let (a, b) = try await (first, second)

        let count = await renders.value
        XCTAssertEqual(count, 1, "a prefetch in flight must be awaited, never duplicated")
        XCTAssertEqual(a.audio, b.audio, "both callers get the same clip")
    }

    /// Announcing all day must not accumulate a day of audio in memory.
    func testOldestClipIsEvicted() async {
        let cache = ClipCache(limit: 2)
        let keys = (0..<3).map { ClipCache.key(text: "utterance \($0)", voice: "v", model: "m") }
        for (index, key) in keys.enumerated() {
            await cache.store(clip(UInt8(index)), for: key)
        }
        let oldest = await cache.cached(keys[0])
        let newest = await cache.cached(keys[2])
        XCTAssertNil(oldest, "the bound has to actually bind")
        XCTAssertNotNil(newest)
    }

    // MARK: - Deadline

    /// The bug that made the fallback unreachable: `timeoutInterval` is
    /// URLSession's INACTIVITY timeout, so a connection trickling bytes resets
    /// it indefinitely and the system-voice degradation never fires. Only a
    /// wall-clock bound ends that, and this is it.
    func testSlowRenderLosesToTheDeadline() async {
        do {
            _ = try await ElevenLabsSpeechProvider.withDeadline(0.1) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            XCTFail("a render that outruns the deadline must throw, not wait")
        } catch let error as SpeechError {
            guard case .synthesisFailed(let why) = error else {
                return XCTFail("expected synthesisFailed, got \(error)")
            }
            XCTAssertTrue(why.contains("no audio"), "the reason should name the wait: \(why)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// And the deadline must be invisible when it is not needed.
    func testFastRenderIsUntouched() async throws {
        let value = try await ElevenLabsSpeechProvider.withDeadline(5) { 42 }
        XCTAssertEqual(value, 42)
    }

    // MARK: - Warming must not consume

    /// `take` is destructive on purpose — it is what stops one summary being
    /// spoken twice. Warming the audio reads the same slot, so if it used
    /// `take` the prefetch would swallow the very summary it was speeding up
    /// and the press would pay for a fresh model call.
    func testPeekLeavesTheSummaryForTheAnnouncement() async {
        let prepared = Coordinator.PreparedSummaries()
        let summary = Summary(
            spoken: SpokenTextSanitizer().sanitize("Finished the poller. Proceed?"),
            brief: SessionBrief(topic: "poller", happened: "done",
                                recap: "Finished the poller.", proposal: "Proceed?"),
            provider: "test", latencyMs: 1)
        await prepared.put(summary, for: "sess-1", latest: 7)

        let peeked = await prepared.peek("sess-1", latest: 7)
        XCTAssertNotNil(peeked, "warming needs to read it")
        let taken = await prepared.take("sess-1", latest: 7)
        XCTAssertNotNil(taken, "and must still be there for the announcement")
        let again = await prepared.take("sess-1", latest: 7)
        XCTAssertNil(again, "take stays destructive")
    }

    /// Staleness beats speed: a summary prepared for an older turn must not be
    /// peeked into a newer one's announcement.
    func testPeekRefusesAnotherEvent() async {
        let prepared = Coordinator.PreparedSummaries()
        let summary = Summary(
            spoken: SpokenTextSanitizer().sanitize("Old news."),
            brief: SessionBrief(topic: "old", happened: "done",
                                recap: "Old news.", proposal: "Proceed?"),
            provider: "test", latencyMs: 1)
        await prepared.put(summary, for: "sess-1", latest: 7)
        let wrongEvent = await prepared.peek("sess-1", latest: 8)
        XCTAssertNil(wrongEvent)
    }
}

/// Counts renders across concurrent callers.
private actor Counter {
    var value = 0
    func bump() { value += 1 }
}
