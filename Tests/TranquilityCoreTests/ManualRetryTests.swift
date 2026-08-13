import XCTest
@testable import TranquilityCore

/// The single-row manual retry behind the recent-audio pane (ruled 13 Aug:
/// humans retry transcriptions, the machine does not). What these pin: a
/// retry rewrites the transcript in place, promotes only rows that never had
/// one, never rewinds a lifecycle, and records a failure without inventing
/// one.
final class ManualRetryTests: XCTestCase {

    var tmpDir: URL!
    var store: QueueStore!
    var audio: AudioStore!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
        audio = AudioStore(directory: tmpDir.appendingPathComponent("audio"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func samplePCM() -> Data { Data(count: 32_000) }  // 1s of 16 kHz silence

    private struct Fails: RecoveryTranscriptionProvider {
        let name = "fails"
        let isConfigured = true
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            throw TranscriptionFailure.providerUnavailable("down")
        }
    }

    private struct Says: RecoveryTranscriptionProvider {
        let name = "says"
        let isConfigured = true
        let text: String
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            TranscriptionResult(text: text, finality: .recoveryForcedFinal, provider: name)
        }
    }

    func testRetryPromotesAFailedRowAndRewritesItsTranscript() async throws {
        let failed = try await store.captureAndTranscribe(
            pcm16: samplePCM(), sampleRate: 16000, audioStore: audio,
            chain: RecoveryChain(providers: [Fails()]))
        XCTAssertEqual(failed.status, .transcriptionFailed)

        let retried = try await store.retryTranscription(
            utteranceId: failed.id,
            chain: RecoveryChain(providers: [Says(text: "second try heard this")]))

        XCTAssertEqual(retried?.status, .transcribed)
        XCTAssertEqual(retried?.transcriptText, "second try heard this")
        XCTAssertEqual(retried?.transcriptProvider, "says")
        XCTAssertNil(retried?.lastError, "a recovered row does not keep its old failure")
    }

    func testRetryOfALifecycledRowImprovesTheRecordWithoutRewindingIt() async throws {
        var confirmed = try await store.captureAndTranscribe(
            pcm16: samplePCM(), sampleRate: 16000, audioStore: audio,
            chain: RecoveryChain(providers: [Says(text: "the truncated first minute")]))
        confirmed.status = .confirmed
        try store.update(utterance: confirmed)

        let retried = try await store.retryTranscription(
            utteranceId: confirmed.id,
            chain: RecoveryChain(providers: [Says(text: "the whole dictation this time")]))

        XCTAssertEqual(retried?.transcriptText, "the whole dictation this time")
        XCTAssertEqual(retried?.status, .confirmed,
                       "a retry improves the transcript; it must never rewind a lifecycle")
    }

    func testFailedRetryRecordsTheErrorAndChangesNothingElse() async throws {
        let row = try await store.captureAndTranscribe(
            pcm16: samplePCM(), sampleRate: 16000, audioStore: audio,
            chain: RecoveryChain(providers: [Says(text: "what it said")]))

        let retried = try await store.retryTranscription(
            utteranceId: row.id, chain: RecoveryChain(providers: [Fails()]))

        XCTAssertEqual(retried?.transcriptText, "what it said",
                       "a failed retry must not eat the transcript it was asked to improve")
        XCTAssertEqual(retried?.status, .transcribed)
        XCTAssertNotNil(retried?.lastError)
    }

    func testRetryOfAMissingRowOrMissingAudioIsNilNotAnInvention() async throws {
        let ghost = try await store.retryTranscription(
            utteranceId: "never-existed", chain: RecoveryChain(providers: [Says(text: "x")]))
        XCTAssertNil(ghost)

        let orphan = try await store.captureAndTranscribe(
            pcm16: samplePCM(), sampleRate: 16000, audioStore: audio,
            chain: RecoveryChain(providers: [Says(text: "x")]))
        // The row stays; only its file goes — the reaped-audio case.
        try FileManager.default.removeItem(atPath: orphan.audioPath!)
        let gone = try await store.retryTranscription(
            utteranceId: orphan.id, chain: RecoveryChain(providers: [Says(text: "y")]))
        XCTAssertNil(gone, "no audio means nothing to retry — never a fabricated transcript")
    }
}
