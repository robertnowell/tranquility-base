import Foundation
import XCTest
@testable import TranquilityCore

/// A `.wav.live` file is written from the first frame, before any row exists for
/// it. A process that dies in that window leaves audio the row-driven reap
/// cannot see by construction — nothing points at it.
///
/// Left alone that is unbounded growth at 32KB/s of uncompressed WAV, which is
/// how the audio directory reached 339MB across 2,586 files without anyone
/// noticing. These tests hold the second pass honest, and — more importantly —
/// hold it back from deleting a recording that is still being spoken.
final class AbandonedLiveCaptureReapTests: XCTestCase {
    private var dir: URL!
    private var store: QueueStore!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reap-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try QueueStore(url: dir.appendingPathComponent("q.sqlite"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Age is the only signal available, so it has to be settable. Stamped
    /// rather than slept: a test that waits three days is a test nobody runs.
    private func makeLive(_ id: String, secondsOfAudio: Double, ageHours: Double) throws -> URL {
        let capture = try LiveAudioCapture(utteranceId: id, sampleRate: 16000, directory: dir)
        try capture.append(pcm16: Data(count: Int(secondsOfAudio * 16000) * 2))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageHours * 3600)],
            ofItemAtPath: capture.url.path)
        return capture.url
    }

    func testAnAbandonedLiveCaptureOlderThanTheIntervalIsDeleted() throws {
        let url = try makeLive("old", secondsOfAudio: 30, ageHours: 96)
        let n = try store.reapAbandonedLiveCaptures(olderThan: 72 * 3600, in: dir)
        XCTAssertEqual(n, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testARecordingStillBeingSpokenIsNeverDeleted() throws {
        // The failure that would matter most: reaping a live file belonging to a
        // capture in progress. Age is generous precisely to make this impossible.
        let url = try makeLive("in-progress", secondsOfAudio: 4, ageHours: 0)
        let n = try store.reapAbandonedLiveCaptures(olderThan: 72 * 3600, in: dir)
        XCTAssertEqual(n, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a file still being appended to is a recording, not debris")
    }

    func testALiveCaptureAClaimedRowStillPointsAtIsLeftToTheRowDrivenPass() throws {
        let url = try makeLive("claimed", secondsOfAudio: 20, ageHours: 96)
        var u = Utterance(status: .recorded)
        u.id = "claimed"
        u.audioPath = url.deletingPathExtension().path
        try store.update(utterance: u)

        let n = try store.reapAbandonedLiveCaptures(olderThan: 72 * 3600, in: dir)
        XCTAssertEqual(n, 0, "a row still claims it; only the row-driven pass knows its status")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFinishedRecordingsAreUntouchedByThisPass() throws {
        let audio = AudioStore(directory: dir)
        try audio.write(pcm16Data: Data(count: 32000), sampleRate: 16000, utteranceId: "done")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-96 * 3600)],
            ofItemAtPath: audio.url(for: "done").path)

        let n = try store.reapAbandonedLiveCaptures(olderThan: 72 * 3600, in: dir)
        XCTAssertEqual(n, 0, "this pass owns .wav.live only; .wav belongs to the row-driven one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url(for: "done").path))
    }

    func testTheSweepIsQuietWhenThereIsNothingToDo() throws {
        XCTAssertEqual(try store.reapAbandonedLiveCaptures(olderThan: 72 * 3600, in: dir), 0)
    }
}
