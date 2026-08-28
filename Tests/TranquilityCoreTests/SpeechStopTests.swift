import AVFoundation
import XCTest
@testable import TranquilityCore

/// `stop()` must not do audio teardown on the caller's thread.
///
/// Every `stop()` call site in the app is on the main actor. On 28 Aug a live
/// `sample` of a wedged instance showed `AVAudioPlayer.stop()` blocking the main
/// thread forever behind a `play()` that was itself waiting on `coreaudiod` for a
/// default-device lookup. The app was not crashed, it was deadlocked — and the
/// microphone looked broken because the push-to-talk handler could not run.
///
/// These pin the split the fix depends on: the LOGICAL cancel stays synchronous
/// and ordered, the AUDIO teardown does not. A timing assertion would not catch a
/// regression here (the blocking call is instant unless CoreAudio is wedged), so
/// what is pinned instead is the observable consequence — the caller no longer
/// holds the player by the time `stop()` returns.
final class SpeechStopTests: XCTestCase {

    private func clip(seconds: Double) -> SpokenClip {
        SpokenClip(audio: silentWAV(seconds: seconds), starts: nil)
    }

    /// Same 44-byte RIFF header the truncation tests use: real enough for
    /// AVAudioPlayer to play at real speed, which is what these need.
    private func silentWAV(seconds: Double) -> Data {
        let sampleRate = 8000, bytesPerSample = 2
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
    private func text() -> SanitizedSpokenText {
        SpokenTextSanitizer().sanitize("stop test tone")
    }

    /// The synchronous half: when `stop()` returns, the caller is no longer the
    /// owner of the player. If teardown were still inline this would also hold,
    /// so this is the contract rather than the regression — it is what makes the
    /// asynchronous teardown safe, because nothing else can reach the object.
    func testStopDetachesThePlayerSynchronously() async throws {
        let provider = ElevenLabsSpeechProvider()
        let c = clip(seconds: 3.0), t = text()
        let playing = Task { try await provider.play(c, text: t, onWord: nil) }

        for _ in 0..<40 where provider.player == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(provider.player, "the clip should be playing before we stop it")

        provider.stop()
        XCTAssertNil(provider.player,
                     "stop() must release the player before it returns, so the "
                     + "off-thread teardown owns the only remaining reference")
        _ = try? await playing.value
    }

    /// The ordering half, and the one that matters: bumping the generation is
    /// what abandons in-flight synthesis, and it must have happened by the time
    /// `stop()` returns. If it were moved off-thread with the teardown, a response
    /// landing a moment later would play over whatever started next — the exact
    /// bug the generation counter was introduced to fix.
    func testStopCancelsInFlightPlaybackBeforeReturning() async throws {
        let provider = ElevenLabsSpeechProvider()
        let c = clip(seconds: 3.0), t = text()
        let playing = Task { try await provider.play(c, text: t, onWord: nil) }

        for _ in 0..<40 where provider.player == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        provider.stop()

        do {
            try await playing.value
            XCTFail("a stopped playback must not report success")
        } catch {
            // Interrupted (generation bumped) is the expected shape. A truncation
            // would mean the generation had NOT been bumped by the time the
            // transport went away, which is the regression this guards.
            if case SpeechError.truncated = error {
                XCTFail("stop() bumped the generation too late: the transport "
                        + "disappearing read as a genuine truncation")
            }
        }
    }

    /// Repeated stops, and a stop with nothing playing, must be harmless — the
    /// teardown queue is serial and the player is already nil.
    func testRepeatedAndIdleStopsAreSafe() {
        let provider = ElevenLabsSpeechProvider()
        provider.stop()
        provider.stop()
        XCTAssertNil(provider.player)
    }
}
