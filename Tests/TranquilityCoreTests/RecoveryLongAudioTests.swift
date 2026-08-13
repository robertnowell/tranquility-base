import XCTest
@testable import TranquilityCore

/// The pure arithmetic under the 12 Aug long-recording fixes: where a
/// continuation pass resumes, where an over-cap upload is cut, and how settled
/// spans report coverage. The recognisers and the network stay out — what runs
/// here is exactly the logic whose absence let a 27-minute dictation ship as
/// 525 characters.
final class RecoveryLongAudioTests: XCTestCase {

    // MARK: - Apple floor: slicing the remainder

    func testPcmSliceStartsAtTheRequestedSecondSampleAligned() {
        // 1 second of 16 kHz PCM16 is 32,000 bytes; slicing from 0.5s drops
        // exactly the first 16,000.
        let pcm = Data((0..<64_000).map { UInt8($0 % 251) })
        let slice = AppleSpeechRecovery.pcmSlice(of: pcm, from: 0.5, sampleRate: 16000)
        XCTAssertEqual(slice.count, 48_000)
        XCTAssertEqual(slice.first, pcm[16_000])
    }

    func testPcmSlicePastTheEndIsEmptyNotACrash() {
        let pcm = Data(count: 32_000)
        XCTAssertEqual(AppleSpeechRecovery.pcmSlice(of: pcm, from: 5, sampleRate: 16000).count, 0)
    }

    func testPcmSliceFromZeroIsTheWholeRecording() {
        let pcm = Data(count: 32_000)
        XCTAssertEqual(AppleSpeechRecovery.pcmSlice(of: pcm, from: 0, sampleRate: 16000).count,
                       pcm.count)
    }

    // MARK: - Settled spans

    func testLastEndReportsTheFurthestSettledUtterance() {
        let u = AppleSpeechRecovery.Utterances()
        u.record(start: 0.87, end: 7.41, text: "first")
        u.record(start: 55.05, end: 60.21, text: "last")
        u.record(start: 17.28, end: 21.24, text: "middle")
        XCTAssertEqual(u.lastEnd, 60.21, accuracy: 0.001,
                       "coverage is measured by where recognition actually reached")
    }

    func testEntriesComeBackInSpokenOrderWithTheirSpans() {
        let u = AppleSpeechRecovery.Utterances()
        u.record(start: 10, end: 12, text: "second")
        u.record(start: 1, end: 3, text: "first")
        let entries = u.entries()
        XCTAssertEqual(entries.map(\.text), ["first", "second"])
        XCTAssertEqual(entries.map(\.end), [3, 12])
    }

    func testEmptyAccumulatorHasZeroLastEnd_theSilencePath() {
        // lastEnd == 0 is what ends the continuation loop on a silent
        // remainder — it must not be an optional crash or a negative sentinel.
        XCTAssertEqual(AppleSpeechRecovery.Utterances().lastEnd, 0)
    }

    // MARK: - OpenAI: cutting an over-cap upload at a pause

    /// One second of loud PCM16, with `quietAt` marking a 100ms silent hole.
    private func loudPCM(seconds: Int, quietAtMs: Int?) -> Data {
        var samples = [Int16](repeating: 12_000, count: seconds * 16_000)
        if let quietAtMs {
            let start = quietAtMs * 16
            for i in start..<(start + 1600) { samples[i] = 0 }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    func testSliceBoundaryFindsTheQuietHoleBeforeTheTarget() {
        // 30s of loud audio with one silent 100ms at 24.0s; a cut targeted at
        // 25s must land on the silence, not mid-shout.
        let pcm = loudPCM(seconds: 30, quietAtMs: 24_000)
        let target = 25 * 16_000 * 2
        let cut = OpenAIRecovery.sliceBoundary(pcm: pcm, target: target)
        XCTAssertEqual(cut, 24_000 * 16 * 2, "the seam falls in the pause")
        XCTAssertEqual(cut % 2, 0, "always on a whole sample")
    }

    func testSliceBoundaryWithNoQuietSpotStaysNearTheTarget() {
        let pcm = loudPCM(seconds: 30, quietAtMs: nil)
        let target = 25 * 16_000 * 2
        let cut = OpenAIRecovery.sliceBoundary(pcm: pcm, target: target)
        XCTAssertLessThanOrEqual(cut, target)
        XCTAssertGreaterThanOrEqual(cut, target - 10 * 16_000 * 2,
                                    "never rewinds past the search window")
    }

    func testSliceBoundaryDegenerateTargetsClampInsteadOfCrashing() {
        let pcm = loudPCM(seconds: 1, quietAtMs: nil)
        XCTAssertEqual(OpenAIRecovery.sliceBoundary(pcm: pcm, target: pcm.count + 999),
                       pcm.count, "past the end clamps to the end")
        XCTAssertEqual(OpenAIRecovery.sliceBoundary(pcm: pcm, target: 100), 100,
                       "a window too small to scan returns the target untouched")
    }
}
