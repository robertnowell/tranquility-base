import XCTest
@testable import TranquilityCore

/// The streaming state machine and the reliability invariant, with a fake
/// socket — no network, no key, no AssemblyAI. The live path is exercised
/// separately by `tbase transcribe-stream` against a real saved recording.
final class AssemblyAIStreamingTests: XCTestCase {

    // MARK: - Fake socket

    /// Scripted server: tests push events (or an error) and inspect what the
    /// client sent. `receive` suspends until an event is available, exactly as
    /// a real socket would.
    final class FakeSocket: StreamingSocket, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sentTexts: [String] = []
        private(set) var sentData: [Data] = []
        private(set) var closed = false

        private var iterator: AsyncStream<Result<StreamingSocketEvent, Error>>.Iterator
        private let feed: AsyncStream<Result<StreamingSocketEvent, Error>>.Continuation

        init() {
            var continuation: AsyncStream<Result<StreamingSocketEvent, Error>>.Continuation!
            let stream = AsyncStream<Result<StreamingSocketEvent, Error>>(
                bufferingPolicy: .unbounded) { continuation = $0 }
            feed = continuation
            iterator = stream.makeAsyncIterator()
        }

        func emit(_ json: String) { feed.yield(.success(.text(json))) }
        func fail(_ error: Error) { feed.yield(.failure(error)) }

        // Sync helpers: NSLock may not be taken inside an async body.
        private func recordData(_ data: Data) { lock.lock(); sentData.append(data); lock.unlock() }
        private func recordText(_ text: String) { lock.lock(); sentTexts.append(text); lock.unlock() }

        func send(data: Data) async throws { recordData(data) }
        func send(text: String) async throws { recordText(text) }

        func receive() async throws -> StreamingSocketEvent {
            guard let next = await iterator.next() else { throw CancellationError() }
            return try next.get()
        }

        func close() { lock.lock(); closed = true; lock.unlock(); feed.finish() }
    }

    /// Collects session callbacks with expectations to await on.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var partials: [String] = []
        private(set) var final: TranscriptionResult?
        private(set) var failure: TranscriptionFailure?
        let concluded = XCTestExpectation(description: "final or failure")

        var onPartial: @Sendable (String) -> Void {
            { [self] text in lock.lock(); partials.append(text); lock.unlock() }
        }
        var onFinal: @Sendable (TranscriptionResult) -> Void {
            { [self] result in
                lock.lock(); final = result; lock.unlock(); concluded.fulfill()
            }
        }
        var onFailure: @Sendable (TranscriptionFailure) -> Void {
            { [self] f in lock.lock(); failure = f; lock.unlock(); concluded.fulfill() }
        }
    }

    private func openSession(
        socket: FakeSocket, sink: Sink, boosting: [String] = [],
        capturedRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) async throws -> any LiveTranscriptionSession {
        let provider = AssemblyAIStreaming(
            keyOverride: "test-key",
            socketFactory: { request in capturedRequest?(request); return socket })
        return try await provider.startSession(
            boosting: boosting, onPartial: sink.onPartial,
            onFinal: sink.onFinal, onFailure: sink.onFailure)
    }

    private func turn(
        _ transcript: String, order: Int = 0, endOfTurn: Bool = false,
        formatted: Bool = false
    ) -> String {
        """
        {"type":"Turn","turn_order":\(order),"transcript":"\(transcript)",\
        "end_of_turn":\(endOfTurn),"turn_is_formatted":\(formatted)}
        """
    }

    // MARK: - Partials accumulate

    func testPartialsAccumulateAcrossTurnMessages() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(#"{"type":"Begin","id":"abc"}"#)
        socket.emit(turn("send the"))
        socket.emit(turn("send the promotions"))
        socket.emit(turn("Send the promotions email.", endOfTurn: true))
        socket.emit(turn("then stop", order: 1))
        socket.emit(#"{"type":"Termination"}"#)

        await fulfillment(of: [sink.concluded], timeout: 2)
        XCTAssertEqual(sink.partials.first, "send the")
        XCTAssertTrue(sink.partials.contains("send the promotions"))
        XCTAssertTrue(sink.partials.contains("Send the promotions email. then stop"),
                      "finalized turns and the in-flight partial accumulate in order")
    }

    // MARK: - Final on end-of-turn

    func testEndOfTurnThenTerminationYieldsExplicitFinal() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(turn("yes go ahead", endOfTurn: true))
        socket.emit(#"{"type":"Termination","audio_duration_seconds":2}"#)

        await fulfillment(of: [sink.concluded], timeout: 2)
        let final = try XCTUnwrap(sink.final)
        XCTAssertEqual(final.text, "yes go ahead")
        XCTAssertEqual(final.finality, .explicitEndOfTurn,
                       "an end-of-turn final is the trustworthy kind")
        XCTAssertEqual(final.provider, "assemblyai-streaming",
                       "streamed transcripts must be distinguishable from recovered ones")
        XCTAssertNil(sink.failure)
    }

    func testFormattedTurnReplacesItsUnformattedFirstPass() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(turn("yes go ahead", endOfTurn: true))
        socket.emit(turn("Yes, go ahead.", endOfTurn: true, formatted: true))
        socket.emit(#"{"type":"Termination"}"#)

        await fulfillment(of: [sink.concluded], timeout: 2)
        XCTAssertEqual(sink.final?.text, "Yes, go ahead.",
                       "same turn_order overwrites; the formatted pass wins")
    }

    func testMultipleTurnsJoinInOrder() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(turn("First part.", order: 0, endOfTurn: true))
        socket.emit(turn("Second part.", order: 1, endOfTurn: true))
        socket.emit(#"{"type":"Termination"}"#)

        await fulfillment(of: [sink.concluded], timeout: 2)
        XCTAssertEqual(sink.final?.text, "First part. Second part.")
    }

    // MARK: - Never silently accept a truncated transcript

    func testTerminationWithoutEndOfTurnIsTruncatedNotFinal() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(turn("half a sen"))
        socket.emit(#"{"type":"Termination"}"#)

        await fulfillment(of: [sink.concluded], timeout: 2)
        XCTAssertNil(sink.final, "a transcript with no end-of-turn must never pass as final")
        XCTAssertEqual(sink.failure, .truncatedNoFinality(partial: "half a sen"))
    }

    func testTerminationWithTrailingPartialAfterAFinalTurnIsStillTruncated() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(turn("First part.", order: 0, endOfTurn: true))
        socket.emit(turn("and then the", order: 1))  // never finalized
        socket.emit(#"{"type":"Termination"}"#)

        await fulfillment(of: [sink.concluded], timeout: 2)
        XCTAssertNil(sink.final,
                     "an unfinalized tail means words may be missing; the whole result is suspect")
        XCTAssertEqual(sink.failure,
                       .truncatedNoFinality(partial: "First part. and then the"))
    }

    func testTerminationWithNoTranscriptAtAllIsNoSpeech() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(#"{"type":"Begin","id":"abc"}"#)
        socket.emit(#"{"type":"Termination"}"#)

        await fulfillment(of: [sink.concluded], timeout: 2)
        XCTAssertEqual(sink.failure, .noSpeechDetected)
    }

    func testSocketErrorMapsToConnectionDroppedWithPartialFlag() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(turn("some words"))
        socket.fail(URLError(.networkConnectionLost))

        await fulfillment(of: [sink.concluded], timeout: 2)
        XCTAssertEqual(sink.failure, .connectionDropped(hadPartialTranscript: true),
                       "the flag says whether anything is salvageable")
    }

    // MARK: - Handshake

    /// 100ms of 16 kHz PCM16 — the wire target every audio message is cut to.
    private var targetChunk: Int { 3200 }
    /// 50ms — the v3 minimum below which the server hangs up (Error 3007).
    private var minChunk: Int { 1600 }

    func testRequestFinalSendsForceEndpointThenTerminate() async throws {
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)

        session.append(pcm16: Data([1, 2, 3, 4]))
        session.requestFinal()

        // The outbox drains asynchronously; give it a beat.
        for _ in 0..<40 where socket.sentTexts.count < 2 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        var padded = Data([1, 2, 3, 4])
        padded.append(Data(count: minChunk - 4))
        XCTAssertEqual(socket.sentData, [padded],
                       "the tail flushes as binary, padded with silence to the "
                       + "50ms wire minimum — an undersized message kills the session (3007)")
        XCTAssertEqual(socket.sentTexts,
                       [#"{"type":"ForceEndpoint"}"#, #"{"type":"Terminate"}"#],
                       "flush the buffered tail into a final turn, then close")
        session.cancel()
    }

    func testRenderCallbackSizedChunksBatchToTheWireTarget() async throws {
        // The 12 Aug outage in miniature: the AUHAL render callback delivers
        // ~10.7ms (342-byte) buffers, and relaying them 1:1 got every session
        // killed by `Error 3007: Input Duration Violation`. The session — not
        // the microphone — owns the 50–1000ms wire contract.
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)

        for i in 0..<10 {  // 3420 bytes: one full wire chunk plus a remainder
            session.append(pcm16: Data(repeating: UInt8(i), count: 342))
        }
        for _ in 0..<40 where socket.sentData.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(socket.sentData.map(\.count), [targetChunk],
                       "nothing below the minimum ever reaches the socket; "
                       + "audio goes out in target-sized messages")

        session.requestFinal()
        for _ in 0..<40 where socket.sentData.count < 2 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(socket.sentData.count, 2, "the 220-byte remainder flushes at final")
        XCTAssertEqual(socket.sentData[1].count, minChunk,
                       "padded to the wire minimum, not sent undersized")
        // Order and content survive the re-chunking: concatenating what was
        // sent reproduces what was fed, plus the trailing silence pad.
        let fed = (0..<10).flatMap { Array(repeating: UInt8($0), count: 342) }
        let sent = socket.sentData.flatMap { [UInt8]($0) }
        XCTAssertEqual(Array(sent.prefix(fed.count)), fed)
        XCTAssertTrue(sent.suffix(sent.count - fed.count).allSatisfy { $0 == 0 })
        session.cancel()
    }

    func testServerErrorFrameConcludesAsFailureNotSilence() async throws {
        // The frame the 12 Aug outage sent seven hours of, into a reducer that
        // returned `.none`: the server names its reason, the session must die
        // reporting it — never loop on in silence.
        let socket = FakeSocket()
        let sink = Sink()
        let session = try await openSession(socket: socket, sink: sink)
        defer { session.cancel() }

        socket.emit(#"{"type":"Begin","id":"abc"}"#)
        socket.emit(#"{"type":"Error","error_code":3007,"error":"Input Duration Violation: 10.0 ms. Expected between 50 and 1000 ms"}"#)

        await fulfillment(of: [sink.concluded], timeout: 2)
        guard case .providerUnavailable(let reason)? = sink.failure else {
            return XCTFail("expected providerUnavailable, got \(String(describing: sink.failure))")
        }
        XCTAssertTrue(reason.contains("3007"), "the server's own code survives into the failure")
        XCTAssertTrue(socket.closed, "a fatal server error closes the socket")
    }

    func testKeytermsAreCappedAndOversizedTermsDropped() async throws {
        let vocabulary = ["promotions copy", String(repeating: "x", count: 51), "Klaviyo"]
            + (0..<150).map { "Vendor\($0)" }
        let keyterms = AssemblyAIStreaming.keyterms(from: vocabulary)
        XCTAssertEqual(keyterms.count, 100, "the v3 API allows at most 100 keyterms")
        XCTAssertEqual(keyterms.first, "promotions copy", "priority order is preserved")
        XCTAssertFalse(keyterms.contains(String(repeating: "x", count: 51)),
                       "terms over 50 characters are rejected by the API; drop them")

        // And they reach the handshake as the keyterms_prompt query parameter.
        let socket = FakeSocket()
        let sink = Sink()
        let captured = Captured()
        let session = try await openSession(
            socket: socket, sink: sink, boosting: ["promotions copy", "Klaviyo"],
            capturedRequest: { captured.set($0) })
        defer { session.cancel() }

        let request = try XCTUnwrap(captured.get())
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.absoluteString.hasPrefix("wss://streaming.assemblyai.com/v3/ws?"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "sample_rate" }?.value, "16000")
        let keytermsItem = try XCTUnwrap(items.first { $0.name == "keyterms_prompt" }?.value)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(keytermsItem.utf8)) as? [String],
            ["promotions copy", "Klaviyo"],
            "keyterms travel as a JSON array, per the v3 contract")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-key",
                       "raw key, no Bearer prefix")
    }

    final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var request: URLRequest?
        func set(_ r: URLRequest) { lock.lock(); request = r; lock.unlock() }
        func get() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
    }

    // MARK: - The reliability invariant: streaming only ever ADDS

    var tmpDir: URL!
    var store: QueueStore!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    struct FixedRecovery: RecoveryTranscriptionProvider {
        let name = "fixed-recovery"
        let isConfigured = true
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            TranscriptionResult(text: "recovered from file", finality: .recoveryForcedFinal,
                                provider: name)
        }
    }

    private func silence(seconds: Double = 0.5) -> Data { Data(count: Int(seconds * 16000) * 2) }

    func testTrustworthyStreamedFinalSkipsTheChainButTheAudioIsStillSaved() async throws {
        let utterance = try await store.captureAndTranscribe(
            pcm16: silence(), sampleRate: 16000,
            audioStore: AudioStore(directory: tmpDir.appendingPathComponent("audio")),
            chain: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]),
            streamed: TranscriptionResult(
                text: "streamed transcript", finality: .explicitEndOfTurn,
                provider: "assemblyai-streaming"))

        XCTAssertEqual(utterance.status, .transcribed)
        XCTAssertEqual(utterance.transcriptText, "streamed transcript")
        XCTAssertEqual(utterance.transcriptProvider, "assemblyai-streaming")
        XCTAssertEqual(utterance.transcriptFinality, .explicitEndOfTurn)
        let path = try XCTUnwrap(utterance.audioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "the audio file is saved exactly as before — non-negotiable")
    }

    func testUntrustworthyStreamedResultFallsBackToTheChain() async throws {
        let utterance = try await store.captureAndTranscribe(
            pcm16: silence(), sampleRate: 16000,
            audioStore: AudioStore(directory: tmpDir.appendingPathComponent("audio")),
            chain: RecoveryChain(providers: [FixedRecovery()],
                                 maxAttemptsPerProvider: 1, backoff: [0]),
            streamed: TranscriptionResult(
                text: "half a sen", finality: .fallbackTimeout, provider: "assemblyai-streaming"))

        XCTAssertEqual(utterance.transcriptText, "recovered from file",
                       "a non-explicit final is suspect; the file-based chain answers")
        XCTAssertEqual(utterance.transcriptProvider, "fixed-recovery")
    }

    func testNoStreamedResultBehavesExactlyAsBefore() async throws {
        let utterance = try await store.captureAndTranscribe(
            pcm16: silence(), sampleRate: 16000,
            audioStore: AudioStore(directory: tmpDir.appendingPathComponent("audio")),
            chain: RecoveryChain(providers: [FixedRecovery()],
                                 maxAttemptsPerProvider: 1, backoff: [0]),
            streamed: nil)
        XCTAssertEqual(utterance.transcriptText, "recovered from file")
        XCTAssertEqual(utterance.status, .transcribed)
    }

    /// The full failure story at the orchestrator level: the stream dies, the
    /// caller gets nil, and the utterance recovers from the file.
    func testStreamedUtteranceFailureYieldsNilSoTheChainAnswers() async throws {
        let socket = FakeSocket()
        let provider = AssemblyAIStreaming(
            keyOverride: "test-key", socketFactory: { _ in socket })
        let stream = StreamedUtterance(provider: provider)
        await stream.start()
        stream.feed(pcm16: silence())
        socket.fail(URLError(.networkConnectionLost))

        let streamed = await stream.finish(timeout: 2)
        XCTAssertNil(streamed, "a dead stream must yield nil, never a suspect transcript")

        let utterance = try await store.captureAndTranscribe(
            pcm16: silence(), sampleRate: 16000,
            audioStore: AudioStore(directory: tmpDir.appendingPathComponent("audio")),
            chain: RecoveryChain(providers: [FixedRecovery()],
                                 maxAttemptsPerProvider: 1, backoff: [0]),
            streamed: streamed)
        XCTAssertEqual(utterance.transcriptText, "recovered from file",
                       "the fallback is transparent: same outcome as before streaming existed")
    }

    /// An unconfigured provider (no key) is a quiet no-op, not an error.
    func testStreamedUtteranceWithoutAKeyIsAQuietNoOp() async throws {
        let provider = AssemblyAIStreaming(keyOverride: nil, socketFactory: { _ in
            XCTFail("no socket may be opened without a key"); return FakeSocket()
        })
        let stream = StreamedUtterance(provider: provider)
        await stream.start()
        stream.feed(pcm16: silence())
        let streamed = await stream.finish(timeout: 1)
        XCTAssertNil(streamed)
    }

    /// Audio fed before the handshake completes must reach the socket once it
    /// opens — dropping leading chunks would produce a plausible but
    /// incomplete "final", the one failure worse than no stream at all.
    func testAudioFedBeforeOpenIsBufferedAndFlushed() async throws {
        let socket = FakeSocket()
        let provider = AssemblyAIStreaming(
            keyOverride: "test-key", socketFactory: { _ in socket })
        let stream = StreamedUtterance(provider: provider)

        stream.feed(pcm16: Data([9, 9]))  // before start() has run at all
        await stream.start()
        stream.feed(pcm16: Data([7, 7]))
        // Both chunks are below the wire minimum, so nothing may hit the
        // socket until the final flush — where they arrive as ONE padded
        // message, pre-open audio first.
        _ = await stream.finish(timeout: 0.5)

        for _ in 0..<40 where socket.sentData.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        var expected = Data([9, 9, 7, 7])
        expected.append(Data(count: minChunk - expected.count))
        XCTAssertEqual(socket.sentData, [expected],
                       "pre-open audio arrives first, order preserved through batching")
        stream.cancel()
    }
}
