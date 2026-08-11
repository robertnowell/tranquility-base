import AVFoundation
import Foundation
import XCTest
@testable import TranquilityCore

/// The property under test is the one the 08 Aug loss needed and did not have:
/// **a recording is readable from disk while it is still being spoken**, and a
/// process that dies mid-utterance leaves a file rather than nothing.
///
/// "Killed mid-utterance" is simulated by never calling `finish()` — which is
/// exactly what a `kill` does to the object, minus the deinit.
final class LiveAudioCaptureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Silence is fine: the test is about byte plumbing, not audio content.
    private func pcm(frames: Int) -> Data { Data(count: frames * 2) }

    // MARK: - Durable while live

    func testFileIsAValidWAVBeforeTheCaptureEnds() throws {
        let capture = try LiveAudioCapture(utteranceId: "u1", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(frames: 16000))   // 1s
        try capture.append(pcm16: pcm(frames: 8000))    // +0.5s

        // Read it while the capture object is still open — no finish(), no close.
        let file = try AVAudioFile(forReading: capture.url)
        XCTAssertEqual(file.length, 24000, "every appended frame is on disk and addressable")
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
    }

    func testHeaderLengthsTrackEveryAppend() throws {
        let capture = try LiveAudioCapture(utteranceId: "u2", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(frames: 100))

        func le32(at offset: Int, in data: Data) -> UInt32 {
            data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            }
        }
        var data = try Data(contentsOf: capture.url)
        XCTAssertEqual(le32(at: 40, in: data), 200, "data chunk size after one append")
        XCTAssertEqual(le32(at: 4, in: data), 236, "RIFF size after one append")

        try capture.append(pcm16: pcm(frames: 100))
        data = try Data(contentsOf: capture.url)
        XCTAssertEqual(le32(at: 40, in: data), 400, "data chunk size after the second")
        XCTAssertEqual(le32(at: 4, in: data), 436, "RIFF size after the second")
    }

    func testAnEmptyCaptureIsStillAValidFileNotAZeroByteOne() throws {
        let capture = try LiveAudioCapture(utteranceId: "u3", sampleRate: 16000, directory: dir)
        let size = try FileManager.default
            .attributesOfItem(atPath: capture.url.path)[.size] as? Int
        XCTAssertEqual(size, 44, "header written at open, before any audio arrives")
    }

    // MARK: - The 08 Aug scenario

    func testAProcessThatDiesMidUtteranceLeavesRecoverableAudio() throws {
        let capture = try LiveAudioCapture(utteranceId: "u4", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(frames: 16000 * 12))   // twelve seconds in

        // The process goes away here. No finish(), no abandon().
        let interrupted = LiveAudioCapture.interrupted(in: dir)
        XCTAssertEqual(interrupted.count, 1)
        XCTAssertEqual(interrupted[0].utteranceId, "u4")
        XCTAssertEqual(interrupted[0].durationMs(), 12000, "twelve seconds survived")

        let adopted = try LiveAudioCapture.adopt(interrupted[0])
        XCTAssertEqual(adopted.pathExtension, "wav")
        let file = try AVAudioFile(forReading: adopted)
        XCTAssertEqual(file.length, 16000 * 12, "and it transcribes by the ordinary path")
        XCTAssertTrue(LiveAudioCapture.interrupted(in: dir).isEmpty, "adoption clears it")
    }

    func testACaptureThatDiedBeforeAnyAudioIsNotOffered() throws {
        _ = try LiveAudioCapture(utteranceId: "u5", sampleRate: 16000, directory: dir)
        XCTAssertTrue(
            LiveAudioCapture.interrupted(in: dir).isEmpty,
            "a header with no frames is nothing to give back, and offering it is worse than silence")
    }

    // MARK: - Ordinary endings leave nothing behind

    func testFinishPromotesToAPlainWavAndLeavesNoLiveFile() throws {
        let capture = try LiveAudioCapture(utteranceId: "u6", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(frames: 16000))
        let stored = try capture.finish()

        XCTAssertEqual(stored.url.pathExtension, "wav")
        XCTAssertEqual(stored.durationMs, 1000)
        XCTAssertEqual(stored.byteCount, 32044, "44-byte header plus one second of PCM16")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.url.path))
        XCTAssertTrue(
            LiveAudioCapture.interrupted(in: dir).isEmpty,
            "a finished recording must never look interrupted to the boot sweep")
    }

    func testAbandonRemovesTheFileEntirely() throws {
        let capture = try LiveAudioCapture(utteranceId: "u7", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(frames: 640))   // an arm-window discard
        capture.abandon()

        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.url.path))
        XCTAssertTrue(LiveAudioCapture.interrupted(in: dir).isEmpty)
    }

    func testAppendAfterAnEndingIsIgnoredRatherThanCorrupting() throws {
        let capture = try LiveAudioCapture(utteranceId: "u8", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(frames: 100))
        let stored = try capture.finish()

        XCTAssertNoThrow(try capture.append(pcm16: pcm(frames: 100)),
                         "a late tap callback must not throw into the audio thread")
        let data = try Data(contentsOf: stored.url)
        XCTAssertEqual(data.count, 244, "and must not append to the promoted file")
    }

    func testInterruptedRecordingsComeBackNewestFirst() throws {
        for id in ["old", "new"] {
            let capture = try LiveAudioCapture(utteranceId: id, sampleRate: 16000, directory: dir)
            try capture.append(pcm16: pcm(frames: 16000))
            // Stamp rather than sleep: mtime ordering is the contract, and a
            // test that waits a second to prove it is a test nobody runs.
            let when = id == "old" ? Date(timeIntervalSince1970: 1_000_000) : Date()
            try FileManager.default.setAttributes(
                [.modificationDate: when], ofItemAtPath: capture.url.path)
        }
        XCTAssertEqual(LiveAudioCapture.interrupted(in: dir).map(\.utteranceId), ["new", "old"])
    }

    // MARK: - Closing without a claimant

    /// Shipped and leaked on 10 Aug: key-up used to promote the file to `.wav`.
    /// Not every capture that stops gets submitted — the silence gate refuses
    /// short ones, a replaced reply drops its predecessor — and each of those
    /// left a `.wav` no row pointed at, invisible to both reap passes.
    func testCloseLeavesTheFileClaimableRatherThanPromotingIt() throws {
        let capture = try LiveAudioCapture(utteranceId: "u9", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(frames: 16000 * 3))
        let url = try capture.close()

        XCTAssertEqual(url.lastPathComponent, "u9.wav.live")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.deletingPathExtension().path),
            "closing must not promote — a file with no claimant keeps the extension that says so")
        XCTAssertEqual(
            LiveAudioCapture.interrupted(in: dir).map(\.utteranceId), ["u9"],
            "and it stays reachable by the sweep that cleans up after nobody")
    }

    func testAClosedFileIsCompleteAndReadable() throws {
        let capture = try LiveAudioCapture(utteranceId: "u10", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(frames: 16000 * 2))
        let url = try capture.close()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 32000, "every frame is there, extension notwithstanding")
    }

}
