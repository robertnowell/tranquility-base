import Foundation

// MARK: - Socket seam
//
// The websocket is behind a protocol for one reason: the turn state machine —
// partials accumulate, end-of-turn finalizes, termination decides whether the
// result is trustworthy — is exactly the logic that silently truncated
// transcripts in the donor codebases, so it has to be testable without a
// network. `URLSessionStreamingSocket` is the only production conformer.

public enum StreamingSocketEvent: Sendable, Equatable {
    case text(String)
    case data(Data)
}

public protocol StreamingSocket: AnyObject, Sendable {
    func send(data: Data) async throws
    func send(text: String) async throws
    func receive() async throws -> StreamingSocketEvent
    func close()
}

final class URLSessionStreamingSocket: StreamingSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func send(data: Data) async throws { try await task.send(.data(data)) }
    func send(text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> StreamingSocketEvent {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: return .data(Data())
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

// MARK: - Provider

/// Live transcription over AssemblyAI's v3 Universal-Streaming websocket
/// (`wss://streaming.assemblyai.com/v3/ws`). The first — and so far only —
/// `LiveTranscriptionProvider` conformer.
///
/// The reliability contract, stated once and relied on everywhere: streaming may
/// only ever ADD speed, never subtract reliability. This provider is never the
/// durability path — the audio file is written exactly as before, and any
/// failure here (network, key, API) surfaces as a callback the caller answers
/// by falling back to the file-based `RecoveryChain`. See
/// `QueueStore.captureAndTranscribe(streamed:)` and `StreamedUtterance`.
public struct AssemblyAIStreaming: LiveTranscriptionProvider {
    public let name = "assemblyai-streaming"
    public var endpoint: URL
    /// The v3 API expects 16 kHz mono PCM16 by default (`encoding=pcm_s16le`),
    /// which is also the app's capture format after `BuddyPCM16Converter`.
    public var sampleRate: Int

    /// Per-event visibility into the one path that had none.
    ///
    /// The 12 Aug outage proved the cost of silence here: every streaming
    /// session died at the same server error for seven hours, the DB was the
    /// only witness, and the app's log did not contain the string "assembly"
    /// once. Session open, conclusion, and server Error frames now say so —
    /// same pattern and same disclosure line as `AppleSpeechRecovery.trace`.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// Test seams: a key source instead of Secrets (so tests neither depend on
    /// nor mutate the machine's real credential file), and a socket factory
    /// instead of a real connection. Production uses neither.
    var keySource: @Sendable () -> String? = { Secrets.read(.assemblyAIAPIKey) }
    var socketFactory: (@Sendable (URLRequest) -> any StreamingSocket)?

    /// Overridable only so a probe can drive a DIFFERENT model through the
    /// real client path — which is the only way to check that the coverage
    /// guard still catches the next promoted model before it reaches Robert.
    /// The app never sets it.
    public var speechModel = AssemblyAIStreaming.speechModel

    public init(sampleRate: Int = 16000) {
        self.endpoint = URL(string: "wss://streaming.assemblyai.com/v3/ws")!
        self.sampleRate = sampleRate
    }

    init(
        sampleRate: Int = 16000, keyOverride: String?,
        socketFactory: (@Sendable (URLRequest) -> any StreamingSocket)?
    ) {
        self.init(sampleRate: sampleRate)
        self.keySource = { keyOverride }
        self.socketFactory = socketFactory
    }

    public var isConfigured: Bool { keySource() != nil }

    /// v3 keyterms limits: at most 100 terms, each at most 50 characters.
    /// The lexicon is priority-ordered (callsigns and labels first), so
    /// truncation from the tail drops the least valuable terms — same rule as
    /// the Whisper prompt.
    public static func keyterms(from vocabulary: [String]) -> [String] {
        Array(vocabulary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 50 }
            .prefix(100))
    }

    /// PINNED, never defaulted — and pinned to the model v3 hands out TODAY,
    /// which is the counter-intuitive half.
    ///
    /// 13 Sep 2026: AssemblyAI promoted the v3 default to `universal-3-5-pro`.
    /// On some recordings it transcribes the first turn, then emits nothing at
    /// all — no `SpeechStarted`, no further `Turn` — for the rest of the
    /// session, and closes with a clean `Termination` reporting every byte
    /// received. Three of Robert's captures lost 306, 237 and 261 characters
    /// off the tail, each a clean suffix, each shipped as a trustworthy final.
    ///
    /// The obvious repair is to pin the PREVIOUS model, which does transcribe
    /// those files end to end. Measured over 16 real captures, that repair is
    /// worse than the bug: `universal-streaming-english` returns complete but
    /// materially wrong text on every capture, not just the affected ones
    /// ("user heard Snape" for "user heard state", "the ladd. Er." for "the
    /// ladder"), and a wrong transcript that covers the whole recording is
    /// undetectable in a way a truncated one is not. It also endpoints so
    /// loosely that it tripped the coverage guard on a capture it had not
    /// truncated.
    ///
    /// So: pin the accurate model, and let `maxUncoveredTailMs` below catch
    /// the truncation — which it did on 4 of 16 captures with no false
    /// positives. Pinning buys determinism (an alias like `universal-3-5-pro`
    /// can be repointed under us); the guard, not the pin, is what survives
    /// the next silent promotion.
    public static let speechModel = "u3-rt-pro"

    public func startSession(
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
        onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
    ) async throws -> any LiveTranscriptionSession {
        try await startSession(boosting: [], onPartial: onPartial,
                               onFinal: onFinal, onFailure: onFailure)
    }

    public func startSession(
        boosting vocabulary: [String],
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
        onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
    ) async throws -> any LiveTranscriptionSession {
        guard let key = keySource() else {
            throw TranscriptionFailure.notConfigured
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "speech_model", value: speechModel),
        ]
        let terms = Self.keyterms(from: vocabulary)
        if !terms.isEmpty,
           let json = try? JSONSerialization.data(withJSONObject: terms),
           let jsonString = String(data: json, encoding: .utf8) {
            // The A7 lexicon, as the streaming API's boost mechanism: a
            // JSON-array `keyterms_prompt` query parameter, fixed at session
            // open — which is why callers harvest immediately before opening.
            query.append(URLQueryItem(name: "keyterms_prompt", value: jsonString))
        }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        // Raw key, no "Bearer" prefix — that is the v3 contract.
        request.setValue(key, forHTTPHeaderField: "Authorization")

        let socket = socketFactory?(request) ?? URLSessionStreamingSocket(request: request)
        Self.trace?("session open: model=\(speechModel), sample_rate=\(sampleRate), "
                    + "\(terms.count) keyterm(s)")
        return AssemblyAIStreamingSession(
            socket: socket, providerName: name, sampleRate: sampleRate,
            onPartial: onPartial, onFinal: onFinal, onFailure: onFailure)
    }
}

// MARK: - Turn state machine
//
// Pure: consumes server JSON messages, returns what the session should do.
// v3 message shapes (verified against the published API reference, Aug 2026):
//   {"type":"Begin", "id":…}
//   {"type":"Turn", "turn_order":0, "transcript":"…", "end_of_turn":bool,
//    "turn_is_formatted":bool, …}
//   {"type":"Termination", "audio_duration_seconds":…}
struct AssemblyAITurnReducer {
    /// Finalized turns by `turn_order`. A formatted re-send of the same turn
    /// overwrites its unformatted first pass, keyed identically.
    private var finalized: [Int: String] = [:]
    /// In-flight partial per turn, cleared when the turn finalizes.
    private var partials: [Int: String] = [:]
    /// End of the last word the server ever timestamped, in ms from the start
    /// of the session. The coverage guard's numerator.
    private var lastWordEndMs: Int?
    /// What the guard measured, kept so a PASSING stream can report its margin
    /// too. `maxUncoveredTailMs` is a judgement call made on four incidents;
    /// logging the gap on every stream is what turns it into a measurement.
    private(set) var coverage: (coveredMs: Int, audioMs: Int)?

    /// How much audio may end after the last transcribed word before the
    /// transcript stops being trustworthy. A capture ends on key-up, a beat
    /// after the last thing said, so a healthy tail is a second or two; the
    /// 13 Sep truncations left 41s, 105s and more uncovered. Eight seconds sits
    /// far above the first and far below the second, and the cost of being
    /// wrong is one file-recovery pass (~4s) that returns the right words
    /// anyway — never a lost tail, which is the failure this exists to stop.
    static let maxUncoveredTailMs = 8_000

    enum Action: Equatable {
        case none
        /// Accumulated text so far — finalized turns plus in-flight partials.
        case partial(String)
        /// The trustworthy transcript: every turn ended with an explicit
        /// end-of-turn and the server closed cleanly.
        case final(String)
        /// The session closed without finalizing everything. `partial` carries
        /// whatever text existed — suspect, never to be treated as final.
        case endedWithoutFinal(partial: String?)
        /// A clean final the coverage guard could not check, because the
        /// server sent no word timings or no audio duration. Trusted exactly as
        /// it was before the guard existed — and traced, because a guard that
        /// quietly stops guarding is the failure this whole change is about.
        case finalUnverified(String)
        /// Every turn ended cleanly and the server closed cleanly, but the
        /// transcript stops far short of the audio the server says it received.
        /// Structurally a final; substantively a truncation. See `speechModel`.
        case stoppedShort(partial: String, coveredMs: Int, audioMs: Int)
        /// The server said why it is about to hang up.
        ///
        /// This case exists because its absence cost seven hours of silent
        /// fallbacks (12 Aug): every session died at `Error 3007: Input
        /// Duration Violation`, the unknown type fell into `.none`, and the
        /// only observable symptom was the recovery chain quietly answering
        /// every utterance. An error the server spells out must reach a log.
        case serverError(String)
    }

    var hasAnyTranscript: Bool {
        !finalized.isEmpty || partials.values.contains { !$0.isEmpty }
    }

    private var accumulated: String {
        let done = finalized.sorted { $0.key < $1.key }.map(\.value)
        let pending = partials.sorted { $0.key < $1.key }.map(\.value)
        return (done + pending).filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func apply(_ text: String) -> Action {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return .none }

        switch type {
        case "Turn":
            let order = object["turn_order"] as? Int ?? 0
            let transcript = (object["transcript"] as? String) ?? ""
            // Formatted and unformatted sends of a turn both carry `words`;
            // a turn that ends empty carries none, and max ignores it.
            for word in (object["words"] as? [[String: Any]]) ?? [] {
                guard let end = word["end"] as? Int else { continue }
                lastWordEndMs = max(lastWordEndMs ?? 0, end)
            }
            if (object["end_of_turn"] as? Bool) == true {
                finalized[order] = transcript
                partials[order] = nil
            } else {
                partials[order] = transcript
            }
            return .partial(accumulated)

        case "Termination":
            // Trust rule: any un-finalized partial at close means the tail may
            // be missing — and a truncated transcript must never pass as final.
            let trailing = partials.values.contains { !$0.isEmpty }
            if !finalized.isEmpty, !trailing {
                // Coverage, not finality. A server that stops listening still
                // signs off correctly, so finality alone cannot tell a finished
                // turn from an abandoned one — only the clock can. Measurable
                // ONLY when the server gave both numbers; when it gives
                // neither the transcript is trusted exactly as it was before
                // this guard existed, and says so in the trace.
                let audioMs = Int(((object["audio_duration_seconds"] as? Double) ?? 0) * 1000)
                if let coveredMs = lastWordEndMs, audioMs > 0 {
                    coverage = (coveredMs, audioMs)
                    if audioMs - coveredMs > Self.maxUncoveredTailMs {
                        return .stoppedShort(
                            partial: accumulated, coveredMs: coveredMs, audioMs: audioMs)
                    }
                    return .final(accumulated)
                }
                return .finalUnverified(accumulated)
            }
            return .endedWithoutFinal(partial: hasAnyTranscript ? accumulated : nil)

        case "Error":
            let code = (object["error_code"] as? Int).map { "\($0): " } ?? ""
            let message = (object["error"] as? String) ?? "unspecified"
            return .serverError(code + message)

        default:
            return .none
        }
    }
}

// MARK: - Session

final class AssemblyAIStreamingSession: LiveTranscriptionSession, @unchecked Sendable {
    private let socket: any StreamingSocket
    private let providerName: String
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (TranscriptionResult) -> Void
    private let onFailure: @Sendable (TranscriptionFailure) -> Void

    /// The v3 API accepts 50–1000ms of audio per message and hangs up on less
    /// (`Error 3007: Input Duration Violation`). The caller's cadence is
    /// whatever the audio stack delivers — the AVAudioEngine tap fed ~102ms
    /// buffers and streaming worked; the AUHAL rewrite fed the render
    /// callback's ~10.7ms buffers and every session died at the first chunks
    /// (12 Aug, seven silent hours). The wire contract is this session's to
    /// keep, not the microphone's: audio accumulates here and goes out in
    /// `targetChunkMs` messages, whatever size it arrives in.
    static let minChunkMs = 50
    static let targetChunkMs = 100

    private let minChunkBytes: Int
    private let targetChunkBytes: Int
    /// Audio accumulated toward the next wire message, guarded by `lock`.
    private var pending = Data()

    private let lock = NSLock()
    private var reducer = AssemblyAITurnReducer()
    /// Callbacks stop for good once the session concludes (final, failure, or
    /// cancel) — a late socket read must never resurrect a closed utterance.
    private var concluded = false
    private var finalRequested = false

    private enum Outbound { case audio(Data), text(String), end }
    private let outbox: AsyncStream<Outbound>.Continuation
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(
        socket: any StreamingSocket, providerName: String, sampleRate: Int = 16000,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
        onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
    ) {
        self.socket = socket
        self.providerName = providerName
        let bytesPerMs = sampleRate * 2 / 1000  // PCM16 mono
        self.minChunkBytes = Self.minChunkMs * bytesPerMs
        self.targetChunkBytes = Self.targetChunkMs * bytesPerMs
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onFailure = onFailure

        // One consumer task drains the outbox in order — an AsyncStream is the
        // ordering guarantee that fire-and-forget Tasks would not give, and
        // audio chunks out of order would corrupt the transcript silently.
        var continuation: AsyncStream<Outbound>.Continuation!
        let stream = AsyncStream<Outbound>(bufferingPolicy: .unbounded) { continuation = $0 }
        outbox = continuation

        sendTask = Task { [socket] in
            for await item in stream {
                do {
                    switch item {
                    case .audio(let chunk): try await socket.send(data: chunk)
                    case .text(let message): try await socket.send(text: message)
                    case .end: return
                    }
                } catch {
                    // Delivery failure surfaces through the receive loop, which
                    // sees the socket die; nothing to do here.
                    return
                }
            }
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func append(pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        lock.lock()
        pending.append(pcm16)
        var ready: [Data] = []
        while pending.count >= targetChunkBytes {
            ready.append(pending.subdata(in: 0..<targetChunkBytes))
            pending = pending.subdata(in: targetChunkBytes..<pending.count)
        }
        lock.unlock()
        for chunk in ready { outbox.yield(.audio(chunk)) }
    }

    /// The user finished speaking: flush the accumulated tail, force it into a
    /// final turn, then terminate. The server answers with the remaining Turn
    /// message(s) and a Termination, which is where the final is decided.
    func requestFinal() {
        lock.lock()
        var tail = pending
        pending = Data()
        finalRequested = true
        lock.unlock()
        if !tail.isEmpty {
            // A tail shorter than the wire minimum is padded with silence
            // rather than dropped: 3007 hangs up the whole session over one
            // undersized message, and the padding is at most 50ms of quiet
            // after the last thing said — the endpointer's food, not speech.
            if tail.count < minChunkBytes { tail.append(Data(count: minChunkBytes - tail.count)) }
            outbox.yield(.audio(tail))
        }
        outbox.yield(.text(#"{"type":"ForceEndpoint"}"#))
        outbox.yield(.text(#"{"type":"Terminate"}"#))
        outbox.yield(.end)
        outbox.finish()
    }

    func cancel() {
        lock.lock()
        let alreadyConcluded = concluded
        concluded = true
        lock.unlock()
        outbox.finish()
        receiveTask?.cancel()
        socket.close()
        _ = alreadyConcluded  // no callback either way: cancel is silent by contract
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            let event: StreamingSocketEvent
            do {
                event = try await socket.receive()
            } catch {
                conclude { hadPartial in .failure(.connectionDropped(
                    hadPartialTranscript: hadPartial)) }
                return
            }
            guard case .text(let text) = event else { continue }

            guard let action = applyUnlessConcluded(text) else { return }

            switch action {
            case .none:
                continue
            case .partial(let accumulated):
                onPartial(accumulated)
            case .final(let transcript):
                let margin = coverageMargin()
                conclude { _ in
                    if let margin {
                        AssemblyAIStreaming.trace?(
                            "coverage: \(margin.coveredMs / 1000)s of "
                            + "\(margin.audioMs / 1000)s audio, "
                            + "\((margin.audioMs - margin.coveredMs) / 1000)s uncovered")
                    }
                    return .final(TranscriptionResult(
                        text: transcript, finality: .explicitEndOfTurn,
                        provider: providerName))
                }
                return
            case .finalUnverified(let transcript):
                conclude { _ in
                    AssemblyAIStreaming.trace?(
                        "coverage: UNCHECKED — server sent no word timings or no "
                        + "audio duration; trusting finality alone, as before the guard")
                    return .final(TranscriptionResult(
                        text: transcript, finality: .explicitEndOfTurn,
                        provider: providerName))
                }
                return
            case .stoppedShort(let partial, let coveredMs, let audioMs):
                let gap = (audioMs - coveredMs) / 1000
                conclude { _ in
                    AssemblyAIStreaming.trace?(
                        "coverage: transcript ends at \(coveredMs / 1000)s of "
                        + "\(audioMs / 1000)s audio — \(gap)s uncovered; not trusted")
                    return .failure(.coverageShort(partial: partial))
                }
                return
            case .endedWithoutFinal(let partial):
                let requested = didRequestFinal()
                conclude { _ in
                    if let partial, !partial.isEmpty {
                        return .failure(.truncatedNoFinality(partial: partial))
                    }
                    return .failure(requested ? .noSpeechDetected : .sessionExpired)
                }
                return
            case .serverError(let message):
                conclude { hadPartial in
                    _ = hadPartial
                    return .failure(.providerUnavailable("server error \(message)"))
                }
                return
            }
        }
    }

    /// Synchronous on purpose — NSLock is not async-safe, so every locked
    /// region lives in a sync function the async loop calls.
    private func coverageMargin() -> (coveredMs: Int, audioMs: Int)? {
        lock.lock(); defer { lock.unlock() }
        return reducer.coverage
    }

    private func didRequestFinal() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return finalRequested
    }

    private func applyUnlessConcluded(_ text: String) -> AssemblyAITurnReducer.Action? {
        lock.lock()
        defer { lock.unlock() }
        guard !concluded else { return nil }
        return reducer.apply(text)
    }

    private enum Conclusion {
        case final(TranscriptionResult)
        case failure(TranscriptionFailure)
    }

    /// Exactly one conclusion per session, decided under the lock.
    private func conclude(_ decide: (Bool) -> Conclusion) {
        lock.lock()
        guard !concluded else { lock.unlock(); return }
        concluded = true
        let hadPartial = reducer.hasAnyTranscript
        lock.unlock()

        socket.close()
        switch decide(hadPartial) {
        case .final(let result):
            AssemblyAIStreaming.trace?("session final: \(result.text.count) chars")
            onFinal(result)
        case .failure(let failure):
            AssemblyAIStreaming.trace?("session failed: \(failure)")
            onFailure(failure)
        }
    }
}

// MARK: - One live utterance, invariant included
//
// The piece the app talks to. It owns the streaming attempt for one utterance
// and encodes the reliability invariant in its shape: `feed` never blocks and
// never throws, `finish` returns a transcript ONLY when the stream produced a
// trustworthy final, and everything else — start failure, mid-stream drop,
// truncation, timeout — comes back as nil, which the caller answers by handing
// the (always-saved) audio file to the RecoveryChain as it does today.

public final class StreamedUtterance: @unchecked Sendable {
    /// The nil at `finish` is a designed outcome, but it must not be a silent
    /// one: for seven hours on 12 Aug every stream died the same way and the
    /// app's log never said so. One line per utterance, stating which way the
    /// stream concluded, is what turns the next such outage into a grep.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    private let provider: any LiveTranscriptionProvider
    private let lexicon: [String]
    private let onPartial: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var session: (any LiveTranscriptionSession)?
    /// Audio fed before the handshake completes is buffered and flushed on
    /// open — dropping the first chunks would produce a *plausible but
    /// incomplete* final, which is the one failure worse than no stream at all.
    private var preOpenBuffer: [Data] = []
    private var outcome: Outcome = .pending
    public var diagnosticCaptureID: String?
    private var bytesFed = 0
    private var partialChars = 0

    /// A recognizer observed text, even if finality failed. No text leaves here.
    public var hasRecognizedText: Bool {
        lock.lock(); defer { lock.unlock() }
        if partialChars > 0 { return true }
        switch outcome {
        case .final(let result):
            return !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .failed(.truncatedNoFinality(let partial)),
             .failed(.coverageShort(let partial)):
            return !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .failed(.connectionDropped(let hadPartialTranscript)):
            return hadPartialTranscript
        default: return false
        }
    }

    /// A completed provider assessment of fed audio, with no recognized text.
    /// Read after finish(): nil also covers transport failure, timeout, missing
    /// credentials, and a partial transcript, all of which still need recovery.
    public var noSpeechProvider: String? {
        lock.lock(); defer { lock.unlock() }
        guard bytesFed > 0, partialChars == 0 else { return nil }
        switch outcome {
        case .failed(.noSpeechDetected): return provider.name
        case .final(let result) where result.finality == .explicitEndOfTurn
            && result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return provider.name
        default: return nil
        }
    }

    /// Where each partial is also written to disk (`LiveAudioCapture
    /// .notePartial`). Attached by the recorder after the factory builds the
    /// stream, because the factory does not know the capture. Distinct from
    /// `onPartial`, which is the panel's live caption and may be nil.
    public var partialSink: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedPartialSink }
        set { lock.lock(); storedPartialSink = newValue; lock.unlock() }
    }
    private var storedPartialSink: (@Sendable (String) -> Void)?

    private func observePartial(_ text: String) {
        lock.lock()
        partialChars = max(partialChars, text.count)
        let sink = storedPartialSink
        lock.unlock()
        onPartial?(text)
        sink?(text)
    }

    private func recordFinish(_ outcome: String, code: String? = nil, chars: Int = 0, began: Date) {
        lock.lock(); let bytes = bytesFed; let partial = partialChars; lock.unlock()
        var props: [String: TrackValue] = [
            "provider": Track.token(from: provider.name), "phase": "streaming",
            "outcome": .token(outcome), "configured": .bool(provider.isConfigured),
            "audio_bytes": .int(bytes), "partial_chars_max": .int(partial), "chars": .int(chars),
            "finish_wait_ms": .int(max(0, Int(Date().timeIntervalSince(began) * 1000))),
            "speech_evidence": chars > 0 || hasRecognizedText ? "provider_text" : "unknown",
        ]
        if let diagnosticCaptureID { props["capture_id"] = Track.hash(diagnosticCaptureID) }
        if let code { props["error_code"] = .token(code) }
        Track.record("transcription_attempt", props)
    }

    private enum Outcome {
        case pending
        case final(TranscriptionResult)
        case failed(TranscriptionFailure)
    }

    public init(
        provider: any LiveTranscriptionProvider,
        lexicon: [String] = [],
        onPartial: (@Sendable (String) -> Void)? = nil
    ) {
        self.provider = provider
        self.lexicon = lexicon
        self.onPartial = onPartial
    }

    // NSLock is not async-safe, so every locked region lives in one of these
    // sync helpers, called from the async methods below.
    private func resolve(_ new: Outcome) {
        lock.lock()
        if case .pending = outcome { outcome = new }
        lock.unlock()
    }

    private func adopt(_ opened: any LiveTranscriptionSession) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        session = opened
        let buffered = preOpenBuffer
        preOpenBuffer = []
        return buffered
    }

    private func currentSession() -> (any LiveTranscriptionSession)? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    private func currentOutcome() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    /// Open the streaming session. Never throws: a failed open just means this
    /// utterance streams nothing and recovers from the file like every
    /// utterance did before streaming existed.
    public func start() async {
        guard provider.isConfigured else {
            resolve(.failed(.notConfigured))
            return
        }
        do {
            let opened = try await provider.startSession(
                boosting: lexicon,
                onPartial: { [weak self] text in self?.observePartial(text) },
                onFinal: { [weak self] result in self?.resolve(.final(result)) },
                onFailure: { [weak self] failure in self?.resolve(.failed(failure)) })
            for chunk in adopt(opened) { opened.append(pcm16: chunk) }
        } catch let failure as TranscriptionFailure {
            resolve(.failed(failure))
        } catch {
            resolve(.failed(.providerUnavailable("\(error)")))
        }
    }

    /// Feed one PCM16 mono chunk at the provider's sample rate (the app's tap
    /// converts with `BuddyPCM16Converter` — see docs/log/wiring-streaming.md).
    /// Cheap, non-blocking, safe to call before `start` completes.
    public func feed(pcm16: Data) {
        lock.lock()
        bytesFed += pcm16.count
        if let session {
            lock.unlock()
            session.append(pcm16: pcm16)
        } else {
            preOpenBuffer.append(pcm16)
            lock.unlock()
        }
    }

    /// Key-up: ask for the final and wait briefly. Returns the transcript only
    /// on a trustworthy explicit end-of-turn. Nil with `noSpeechProvider` ends
    /// the capture without recovery; other nil results need the file chain. The timeout is the
    /// cap on how long streaming may delay the reply flow — the fallback path
    /// is never slower than it was before streaming existed, minus this bound.
    public func finish(timeout: TimeInterval = 3.0) async -> TranscriptionResult? {
        let began = Date()
        let current = currentSession()
        current?.requestFinal()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch currentOutcome() {
            case .final(let result):
                if result.finality == .explicitEndOfTurn {
                    let empty = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    recordFinish(empty ? "no_speech_detected" : "completed",
                                 code: empty ? "no_speech_detected" : nil,
                                 chars: result.text.count, began: began)
                    Self.trace?("finish: final accepted, \(result.text.count) chars")
                    return result
                }
                recordFinish("unresolved", code: "missing_finality", chars: result.text.count, began: began)
                Self.trace?("finish: nil — final arrived without explicit "
                    + "end-of-turn (\(result.finality.rawValue)); file chain answers")
                return nil
            case .failed(let failure):
                recordFinish(noSpeechProvider != nil ? "no_speech_detected" : "failed",
                             code: failure.diagnosticCode, began: began)
                Self.trace?(noSpeechProvider != nil
                    ? "finish: no_speech_detected; no automatic file recovery"
                    : "finish: nil — stream failed (\(failure)); file chain answers")
                return nil
            case .pending:
                if Task.isCancelled {
                    current?.cancel()
                    recordFinish("cancelled", code: "cancelled", began: began)
                    return nil
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        current?.cancel()
        recordFinish("unresolved", code: "final_timeout", began: began)
        Self.trace?("finish: nil — no conclusion within \(timeout)s; file chain answers")
        return nil
    }

    public func cancel() {
        resolve(.failed(.connectionDropped(hadPartialTranscript: false)))
        currentSession()?.cancel()
    }
}
