import XCTest
@testable import TranquilityCore

final class TranscriptionDiagnosticsTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        super.setUp()
        Track.resetForTesting()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        Track.configure(directory: directory, installId: "diagnostic-test")
    }
    override func tearDown() {
        Track.flush()
        Track.resetForTesting()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }
    private func events() -> [[String: Any]] {
        Track.flush()
        let text = (try? String(contentsOf: Track.eventsURL!, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
    private struct Provider: RecoveryTranscriptionProvider {
        var name: String
        var isConfigured = true
        var failure: TranscriptionFailure? = nil
        var text = ""
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            if let failure { throw failure }
            return .init(text: text, finality: .recoveryForcedFinal, provider: name)
        }
    }
    private func run(_ providers: [any RecoveryTranscriptionProvider]) async -> RecoveryChain.Outcome {
        await RecoveryChain(providers: providers, maxAttemptsPerProvider: 1, backoff: [0], floorAfter: nil)
            .transcribe(fileAt: directory.appendingPathComponent("fixture.wav"))
    }

    func testNoSpeechIsSeparateFromServiceFailure() async {
        let outcome = await run([Provider(name: "cloud", failure: .noSpeechDetected),
                                 Provider(name: "device", failure: .noSpeechDetected)])
        XCTAssertEqual(outcome.disposition, .noSpeechDetected)
        XCTAssertEqual(outcome.diagnostics.map(\.errorCode), ["no_speech_detected", "no_speech_detected"])
    }

    private struct CancelledProvider: RecoveryTranscriptionProvider {
        let name = "cancelled"
        let isConfigured = true
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
    }

    func testCancellationAfterAnEmptyAnswerIsNotNoSpeech() async {
        let task = Task {
            await RecoveryChain(providers: [Provider(name: "empty", failure: .noSpeechDetected),
                                            CancelledProvider()],
                                maxAttemptsPerProvider: 1, floorAfter: nil)
                .transcribe(fileAt: URL(fileURLWithPath: "/unused.wav"))
        }
        let outcome = await task.value
        XCTAssertEqual(outcome.disposition, .cancelled)
    }

    private struct PartialThenFailure: LiveTranscriptionProvider {
        let name = "partial-fixture"
        let isConfigured = true
        func startSession(
            onPartial: @escaping @Sendable (String) -> Void,
            onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
            onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
        ) async throws -> any LiveTranscriptionSession {
            onPartial("private unfinished speech")
            throw TranscriptionFailure.truncatedNoFinality(partial: "private unfinished speech")
        }
    }

    func testPartialSpeechThenEmptyRecoveryRemainsUnresolved() async throws {
        let stream = StreamedUtterance(provider: PartialThenFailure())
        await stream.start()
        let final = await stream.finish()
        XCTAssertNil(final)
        XCTAssertTrue(stream.hasRecognizedText)
        let store = try QueueStore(url: directory.appendingPathComponent("queue.sqlite"))
        let utterance = try await store.captureAndTranscribe(
            pcm16: Data(count: 32000), sampleRate: 16000,
            audioStore: AudioStore(directory: directory.appendingPathComponent("audio")),
            chain: RecoveryChain(providers: [Provider(name: "empty", failure: .noSpeechDetected)], floorAfter: nil),
            streamed: final, streamHadRecognizedText: stream.hasRecognizedText)
        XCTAssertEqual(utterance.transcriptionOutcome, "unresolved")
        XCTAssertEqual(utterance.status, .transcriptionFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(utterance.audioPath)))
        XCTAssertEqual(events().last?["speech_evidence"] as? String, "provider_text")
        XCTAssertFalse(events().description.contains("private unfinished speech"))
    }

    private func emptyCapture() async throws -> (QueueStore, Utterance) {
        let store = try QueueStore(url: directory.appendingPathComponent("queue.sqlite"))
        let row = try await Track.$captureID.withValue("original-capture") {
            try await store.captureAndTranscribe(pcm16: Data(count: 32000), sampleRate: 16000,
                audioStore: AudioStore(directory: directory.appendingPathComponent("audio")),
                chain: RecoveryChain(providers: [Provider(name: "empty", failure: .noSpeechDetected)], floorAfter: nil))
        }
        return (store, row)
    }

    func testManualRetriesRefreshDiagnosisAndKeepCaptureWithDistinctAttempts() async throws {
        let (store, row) = try await emptyCapture()
        let failed = try await store.retryTranscription(utteranceId: row.id,
            chain: RecoveryChain(providers: [Provider(name: "auth", failure: .authenticationFailed)], floorAfter: nil))
        XCTAssertEqual(failed?.transcriptionOutcome, "provider_error")
        let completed = try await store.retryTranscription(utteranceId: row.id,
            chain: RecoveryChain(providers: [Provider(name: "success", text: "recovered")], floorAfter: nil))
        XCTAssertEqual(completed?.transcriptionOutcome, "completed")
        XCTAssertEqual(completed?.status, .transcribed)
        XCTAssertEqual(try store.utterance(id: row.id)?.transcriptionOutcome, "completed")
        let retries = events().filter { $0["trigger"] as? String == "manual_retry" }
        XCTAssertEqual(retries.count, 2)
        XCTAssertEqual(Set(retries.compactMap { $0["attempt_id"] as? String }).count, 2)
        XCTAssertTrue(retries.allSatisfy { $0["capture_id"] as? String == Track.hash("original-capture").tokenString })
    }

    func testFailedBatchRetryReplacesStaleNoSpeechDiagnosis() async throws {
        let (store, row) = try await emptyCapture()
        let recovered = try await store.retryFailedTranscriptions(
            chain: RecoveryChain(providers: [Provider(name: "auth", failure: .authenticationFailed)], floorAfter: nil))
        XCTAssertTrue(recovered.isEmpty)
        let saved = try XCTUnwrap(store.utterance(id: row.id))
        XCTAssertEqual(saved.transcriptionOutcome, "provider_error")
        XCTAssertEqual(saved.status, .transcriptionFailed)
        XCTAssertEqual(events().last?["capture_id"] as? String, Track.hash("original-capture").tokenString)
    }

    func testSuccessfulBatchRetryClearsNoSpeechDiagnosis() async throws {
        let (store, row) = try await emptyCapture()
        let recovered = try await store.retryFailedTranscriptions(
            chain: RecoveryChain(providers: [Provider(name: "success", text: "recovered")], floorAfter: nil))
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(try store.utterance(id: row.id)?.transcriptionOutcome, "completed")
        XCTAssertEqual(events().last?["trigger"] as? String, "retry_failed")
    }

    func testOneNoSpeechAnswerDoesNotEraseAnAuthenticationFailure() async {
        let outcome = await run([Provider(name: "cloud", failure: .authenticationFailed),
                                 Provider(name: "device", failure: .noSpeechDetected)])
        XCTAssertEqual(outcome.disposition, .providerError)
    }

    func testNoConfiguredProvidersIsNotEvidenceOfSilence() async {
        let outcome = await run([Provider(name: "cloud", isConfigured: false)])
        XCTAssertEqual(outcome.disposition, .providerError)
        XCTAssertEqual(outcome.diagnostics.first?.outcome, "skipped")
        XCTAssertEqual(outcome.diagnostics.first?.ordinal, 0)
    }

    func testEmptySuccessfulResultDoesNotStopRecovery() async {
        let outcome = await run([Provider(name: "empty", text: "  \n"),
                                 Provider(name: "fallback", text: "usable words")])
        XCTAssertEqual(outcome.result?.provider, "fallback")
        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.diagnostics.first?.errorCode, "no_speech_detected")
        XCTAssertFalse(events().description.contains("usable words"))
    }

    func testDetailedFailureTextCannotBecomeRemoteSpeechContent() async {
        _ = await run([Provider(name: "cloud", failure: .truncatedNoFinality(partial: "private dictated words"))])
        let all = events()
        XCTAssertEqual(all.first?["error_code"] as? String, "missing_finality")
        XCTAssertFalse(all.description.contains("private dictated words"))
    }

    func testNoSpeechClassificationAndAudioSurviveReload() async throws {
        let store = try QueueStore(url: directory.appendingPathComponent("queue.sqlite"))
        let utterance = try await Track.$captureID.withValue("capture-one") {
            try await store.captureAndTranscribe(pcm16: Data(count: 32000), sampleRate: 16000,
                audioStore: AudioStore(directory: directory.appendingPathComponent("audio")),
                chain: RecoveryChain(providers: [Provider(name: "device", failure: .noSpeechDetected)],
                                     maxAttemptsPerProvider: 1, floorAfter: nil))
        }
        let saved = try XCTUnwrap(store.utterance(id: utterance.id))
        XCTAssertEqual(saved.transcriptionOutcome, "no_speech_detected")
        XCTAssertEqual(saved.captureId, "capture-one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(saved.audioPath)))
        let final = try XCTUnwrap(events().last)
        XCTAssertEqual(final["outcome"] as? String, "no_speech_detected")
        XCTAssertEqual(final["speech_evidence"] as? String, "unknown")
    }

    func testConcurrentCapturesKeepTheirOwnCorrelationAndSequence() async {
        await withTaskGroup(of: Void.self) { group in
            for id in ["one", "two"] {
                group.addTask {
                    await Track.$captureID.withValue(id) {
                        await Task.yield()
                        Track.record("fixture", ["which": .token(id)])
                    }
                }
            }
        }
        let all = events()
        XCTAssertEqual(all.count, 2)
        for event in all {
            XCTAssertEqual(event["capture_id"] as? String, Track.hash(event["which"] as! String).tokenString)
            XCTAssertNotNil(event["source_time_ms"])
        }
        XCTAssertEqual(Set(all.compactMap { $0["event_sequence"] as? Int }).count, 2)
        XCTAssertEqual(Set(all.compactMap { $0["event_process_id"] as? String }).count, 1)
    }

    func testRoutineSecretReadsDoNotEvictUsefulBreadcrumbs() {
        let crumbs = Breadcrumbs(capacity: 2)
        XCTAssertTrue(crumbs.record("mic: audio opened"))
        for _ in 0..<100 { XCTAssertFalse(crumbs.record("secrets: read /fixture -> keys [key]")) }
        XCTAssertEqual(crumbs.recent.count, 1)
        XCTAssertTrue(crumbs.record("secrets: read failed: unavailable"))
    }

    func testHTTPStatusAndStageHaveDistinctBoundedCodes() {
        XCTAssertEqual(TranscriptionFailure.providerHTTP(status: 429, stage: "create").diagnosticCode, "create_http_429")
        XCTAssertTrue(TrackValue.token(TranscriptionFailure.providerHTTP(status: 400, stage: "poll").diagnosticCode).isAdmissible)
    }
}
