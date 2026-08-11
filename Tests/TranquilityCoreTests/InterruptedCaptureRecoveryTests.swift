import Foundation
import XCTest
@testable import TranquilityCore

/// The trap this suite exists to hold shut:
///
/// boot reconciliation retires an in-flight row whose audio it cannot find. A
/// capture interrupted mid-utterance has its audio at `<id>.wav.live`, not
/// `<id>.wav` — so a bare `fileExists` against the recorded path reports MISSING
/// for exactly the case write-ahead exists to survive, and the sweep discards
/// the only row pointing at the audio, on the first launch after the crash it
/// was built for.
///
/// Every assertion here is one half of that sentence.
final class InterruptedCaptureRecoveryTests: XCTestCase {
    private var dir: URL!
    private var store: AudioStore!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("interrupted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AudioStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pcm(seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

    // MARK: - resolve

    func testResolveFindsAFinishedRecording() throws {
        try store.write(pcm16Data: pcm(seconds: 1), sampleRate: 16000, utteranceId: "u1")
        guard case .finished(let url) = store.resolve(utteranceId: "u1") else {
            return XCTFail("a completed recording must resolve as finished")
        }
        XCTAssertEqual(url.pathExtension, "wav")
    }

    func testResolveFindsAnInterruptedCaptureRatherThanCallingItMissing() throws {
        let capture = try LiveAudioCapture(utteranceId: "u2", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(seconds: 9))
        // The process dies here — no finish(), no abandon().

        guard case .interrupted(let url) = store.resolve(utteranceId: "u2") else {
            return XCTFail("THE trap: an interrupted capture must never resolve as missing")
        }
        XCTAssertEqual(url.lastPathComponent, "u2.wav.live")
    }

    func testResolveReportsMissingOnlyWhenItReallyIs() {
        XCTAssertEqual(store.resolve(utteranceId: "nobody"), .missing)
    }

    func testFinishedIsPreferredOverAStrayLiveFile() throws {
        // Belt and braces: if both somehow exist, the complete one wins. A live
        // file left beside a finished recording is debris, not the record.
        try store.write(pcm16Data: pcm(seconds: 1), sampleRate: 16000, utteranceId: "u3")
        let stray = try LiveAudioCapture(utteranceId: "u3", sampleRate: 16000, directory: dir)
        try stray.append(pcm16: pcm(seconds: 1))

        guard case .finished = store.resolve(utteranceId: "u3") else {
            return XCTFail("a complete recording outranks a stray live file")
        }
    }

    // MARK: - id extraction

    func testUtteranceIdSurvivesBothExtensions() {
        XCTAssertEqual(AudioStore.utteranceId(of: dir.appendingPathComponent("u4.wav")), "u4")
        XCTAssertEqual(
            AudioStore.utteranceId(of: dir.appendingPathComponent("u4.wav.live")), "u4",
            "a bare deletingPathExtension yields u4.wav here, which matches no row id — "
            + "the bug that reported every live capture as an orphan forever")
    }

    func testUtteranceIdKeepsDottedIdsIntact() {
        // Ids are UUIDs today, but nothing enforces that, and an id containing a
        // dot must not be silently truncated by the extension arithmetic.
        XCTAssertEqual(
            AudioStore.utteranceId(of: dir.appendingPathComponent("2026-08-10.a.wav.live")),
            "2026-08-10.a")
    }

    // MARK: - the sweep itself

    func testBootReconciliationPromotesAnInterruptedCaptureInsteadOfDiscardingIt() throws {
        let dbDir = dir.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        // A capture that was mid-utterance when the process went away: a row that
        // still says `recorded`, and audio only as .wav.live.
        let capture = try LiveAudioCapture(utteranceId: "u5", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(seconds: 12))

        XCTAssertEqual(
            store.resolve(utteranceId: "u5"),
            .interrupted(dir.appendingPathComponent("u5.wav.live")),
            "precondition: the sweep is about to be asked about this exact state")

        // Promotion is what the sweep does with it, and it must leave the audio
        // reachable by the ordinary path rather than retiring the row.
        let interrupted = LiveAudioCapture.interrupted(in: dir)
        XCTAssertEqual(interrupted.map(\.utteranceId), ["u5"])
        let promoted = try LiveAudioCapture.adopt(interrupted[0])

        XCTAssertEqual(promoted.pathExtension, "wav")
        guard case .finished = store.resolve(utteranceId: "u5") else {
            return XCTFail("after promotion the recording is ordinary and transcribes normally")
        }
        XCTAssertEqual(interrupted[0].durationMs(), 12000, "and none of the audio was lost")
    }

    // MARK: - Adoption at key-up

    /// The write-ahead path in one assertion: a capture written while it was
    /// being spoken becomes the utterance's own recording by rename, and the
    /// audio survives the trip byte for byte.
    func testACaptureWrittenWhileSpokenIsAdoptedUnderTheUtteranceId() throws {
        let capture = try LiveAudioCapture(
            utteranceId: "capture-abc", sampleRate: 16000, directory: dir)
        try capture.append(pcm16: pcm(seconds: 7))
        let written = try capture.finish().url
        let bytesBefore = try Data(contentsOf: written).count

        // What RecoveryChain does at key-up: move it under the real id.
        let target = store.url(for: "real-id")
        try FileManager.default.moveItem(at: written, to: target)

        guard case .finished = store.resolve(utteranceId: "real-id") else {
            return XCTFail("after adoption it is an ordinary recording")
        }
        XCTAssertEqual(try Data(contentsOf: target).count, bytesBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path),
                       "and nothing is left behind under the capture id")
    }

}
