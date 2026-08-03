import XCTest
@testable import VoiceDispatchCore

/// The property these tests exist to protect: once the user has stopped speaking,
/// the audio is on disk and the row is committed — before anything touches the
/// network. Everything downstream may fail freely.
final class DurabilityTests: XCTestCase {

    /// The data directory holds every session's assistant messages and every
    /// recording of the user's voice. On a machine with more than one account those
    /// were readable by any other local user, because FileManager creates
    /// directories 0755 and GRDB creates the database 0644.
    func testStoredDataIsNotReadableByOtherLocalUsers() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-perms-\(UUID().uuidString)", isDirectory: true)
        let store = try QueueStore(url: dir.appendingPathComponent("queue.sqlite"))
        try store.insert(event: QueuedEvent(
            hookEvent: .stop, sessionId: "s", promptId: "p",
            cwd: "/tmp", lastAssistantMessage: "real work content"))
        defer { try? FileManager.default.removeItem(at: dir) }

        func mode(_ url: URL) throws -> Int {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        }

        XCTAssertEqual(try mode(dir) & 0o077, 0, "the directory must deny group and other")
        XCTAssertEqual(try mode(dir.appendingPathComponent("queue.sqlite")) & 0o077, 0,
                       "the queue holds real session content")
    }

    var tmpDir: URL!
    var store: QueueStore!
    var audio: AudioStore!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-dur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
        audio = AudioStore(directory: tmpDir.appendingPathComponent("audio"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 1 second of 16 kHz silence — enough to be a real, parseable file.
    private func samplePCM(seconds: Double = 1.0, sampleRate: Double = 16000) -> Data {
        Data(count: Int(seconds * sampleRate) * 2)
    }

    // MARK: - Providers that fail on demand

    private struct AlwaysFails: RecoveryTranscriptionProvider {
        let name: String
        let isConfigured = true
        let failure: TranscriptionFailure
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult { throw failure }
    }

    private struct Succeeds: RecoveryTranscriptionProvider {
        let name: String
        let isConfigured = true
        let text: String
        /// Records that the file actually existed when it was called — the ordering proof.
        let sawFile: FileWitness
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            sawFile.existed = FileManager.default.fileExists(atPath: url.path)
            sawFile.byteCount = (try? Data(contentsOf: url).count) ?? 0
            return TranscriptionResult(text: text, finality: .recoveryForcedFinal, provider: name)
        }
    }

    final class FileWitness: @unchecked Sendable {
        var existed = false
        var byteCount = 0
    }

    // MARK: - The invariant

    func testAudioIsOnDiskBeforeTranscriptionIsAttempted() async throws {
        let witness = FileWitness()
        let chain = RecoveryChain(providers: [Succeeds(name: "fake", text: "hello", sawFile: witness)])

        let utterance = try await store.captureAndTranscribe(
            pcm16: samplePCM(), sampleRate: 16000, audioStore: audio, chain: chain)

        XCTAssertTrue(witness.existed, "transcription ran before the audio was flushed to disk")
        XCTAssertGreaterThan(witness.byteCount, 32000, "file was incomplete when transcription started")
        XCTAssertEqual(utterance.status, .transcribed)
        XCTAssertEqual(utterance.transcriptText, "hello")
    }

    func testAudioSurvivesWhenEveryProviderFails() async throws {
        let chain = RecoveryChain(
            providers: [
                AlwaysFails(name: "cloud", failure: .connectionDropped(hadPartialTranscript: false)),
                AlwaysFails(name: "local", failure: .providerUnavailable("down")),
            ],
            maxAttemptsPerProvider: 1, backoff: [0])

        let utterance = try await store.captureAndTranscribe(
            pcm16: samplePCM(), sampleRate: 16000, audioStore: audio, chain: chain)

        XCTAssertEqual(utterance.status, .transcriptionFailed)
        XCTAssertNotNil(utterance.audioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: utterance.audioPath!),
                      "audio must survive total transcription failure — that is the whole point")
        XCTAssertNotNil(utterance.lastError, "the row must say why, not fail silently")
    }

    /// The recovery story: a failed utterance is re-transcribed from DISK, on a
    /// different provider than the one that failed, with no in-memory state.
    func testFailedUtteranceIsRecoveredFromDiskByADifferentProvider() async throws {
        let failing = RecoveryChain(
            providers: [AlwaysFails(name: "cloud", failure: .authenticationFailed)],
            maxAttemptsPerProvider: 1, backoff: [0])
        let failed = try await store.captureAndTranscribe(
            pcm16: samplePCM(), sampleRate: 16000, audioStore: audio, chain: failing)
        XCTAssertEqual(failed.status, .transcriptionFailed)

        let witness = FileWitness()
        let working = RecoveryChain(providers: [Succeeds(name: "local", text: "recovered", sawFile: witness)])
        let recovered = try await store.retryFailedTranscriptions(audioStore: audio, chain: working)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.transcriptText, "recovered")
        XCTAssertEqual(recovered.first?.transcriptProvider, "local")
        XCTAssertEqual(recovered.first?.status, .transcribed)
        XCTAssertNil(recovered.first?.lastError, "a recovered row should stop reporting the old failure")
        XCTAssertTrue(witness.existed, "recovery must read the saved file, not memory")
    }

    func testAuthFailureIsNotRetried() async throws {
        // A bad key does not get better on the second attempt; retrying just delays
        // the fallback to a provider that might actually work.
        actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
        let counter = Counter()

        struct CountingFail: RecoveryTranscriptionProvider {
            let name = "counting"
            let isConfigured = true
            let counter: Counter
            func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
                await counter.bump()
                throw TranscriptionFailure.authenticationFailed
            }
        }

        let chain = RecoveryChain(
            providers: [CountingFail(counter: counter)], maxAttemptsPerProvider: 3, backoff: [0])
        _ = await chain.transcribe(fileAt: audio.url(for: "nope"))
        let attempts = await counter.value()
        XCTAssertEqual(attempts, 1, "auth failures must not be retried")
    }

    // MARK: - The file itself

    func testWrittenFileIsAValidWavWithTheRightDuration() throws {
        let stored = try audio.write(
            pcm16Data: samplePCM(seconds: 2.0), sampleRate: 16000, utteranceId: "wav-test")

        let data = try Data(contentsOf: stored.url)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(stored.durationMs, 2000, accuracy: 50)
        XCTAssertEqual(stored.byteCount, Int64(data.count))
        XCTAssertFalse(stored.sha256.isEmpty)
    }

    func testChecksumDetectsACorruptedRecording() throws {
        let stored = try audio.write(pcm16Data: samplePCM(), sampleRate: 16000, utteranceId: "sum-test")
        XCTAssertTrue(audio.verify(utteranceId: "sum-test", expectedSha256: stored.sha256))

        try Data(repeating: 0xFF, count: 128).write(to: stored.url)
        XCTAssertFalse(audio.verify(utteranceId: "sum-test", expectedSha256: stored.sha256),
                       "a truncated or overwritten file must not pass verification")
    }

    /// No `.partial` file may be left behind — the boot sweep would otherwise have
    /// to guess whether it was a complete recording.
    func testNoPartialFilesRemainAfterWrite() throws {
        _ = try audio.write(pcm16Data: samplePCM(), sampleRate: 16000, utteranceId: "atomic-test")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: audio.directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "partial" } ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: - Crash recovery

    func testBootSweepRequeuesAnUtteranceStrandedMidTranscription() async throws {
        // Simulate dying between "audio written" and "transcript returned".
        let stored = try audio.write(pcm16Data: samplePCM(), sampleRate: 16000, utteranceId: "stranded")
        try store.update(utterance: Utterance(
            id: "stranded", status: .transcribing,
            audioPath: stored.url.path, audioSha256: stored.sha256))

        let report = try store.reconcileOnBoot()

        XCTAssertEqual(report.requeuedForTranscription, ["stranded"])
        XCTAssertEqual(try store.utterances().first?.status, .recorded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.url.path))
    }
}
