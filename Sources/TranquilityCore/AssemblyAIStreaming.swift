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

    /// Test seams: a key source instead of Secrets (so tests neither depend on
    /// nor mutate the machine's real credential file), and a socket factory
    /// instead of a real connection. Production uses neither.
    var keySource: @Sendable () -> String? = { Secrets.read(.assemblyAIAPIKey) }
    var socketFactory: (@Sendable (URLRequest) -> any StreamingSocket)?

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
        return AssemblyAIStreamingSession(
            socket: socket, providerName: name,
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
                return .final(accumulated)
            }
            return .endedWithoutFinal(partial: hasAnyTranscript ? accumulated : nil)

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

    private let lock = NSLock()
    private var reducer = AssemblyAITurnReducer()
    /// Callbacks stop for good once the session concludes (final, failure, or
    /// cancel) — a late socket read must never resurrect a closed utterance.
    private var concluded = false

    private enum Outbound { case audio(Data), text(String), end }
    private let outbox: AsyncStream<Outbound>.Continuation
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(
        socket: any StreamingSocket, providerName: String,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
        onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
    ) {
        self.socket = socket
        self.providerName = providerName
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
        outbox.yield(.audio(pcm16))
    }

    /// The user finished speaking: force the buffered tail into a final turn,
    /// then terminate. The server answers with the remaining Turn message(s)
    /// and a Termination, which is where the final is decided.
    func requestFinal() {
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
                conclude { _ in .final(TranscriptionResult(
                    text: transcript, finality: .explicitEndOfTurn,
                    provider: providerName)) }
                return
            case .endedWithoutFinal(let partial):
                conclude { _ in
                    if let partial, !partial.isEmpty {
                        return .failure(.truncatedNoFinality(partial: partial))
                    }
                    return .failure(.noSpeechDetected)
                }
                return
            }
        }
    }

    /// Synchronous on purpose — NSLock is not async-safe, so every locked
    /// region lives in a sync function the async loop calls.
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
        case .final(let result): onFinal(result)
        case .failure(let failure): onFailure(failure)
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
                onPartial: { [weak self] text in self?.onPartial?(text) },
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
    /// converts with `BuddyPCM16Converter` — see docs/wiring-streaming.md).
    /// Cheap, non-blocking, safe to call before `start` completes.
    public func feed(pcm16: Data) {
        lock.lock()
        if let session {
            lock.unlock()
            session.append(pcm16: pcm16)
        } else {
            preOpenBuffer.append(pcm16)
            lock.unlock()
        }
    }

    /// Key-up: ask for the final and wait briefly. Returns the transcript only
    /// on a trustworthy explicit end-of-turn; nil on ANY failure or timeout,
    /// which the caller answers with the file-based chain. The timeout is the
    /// cap on how long streaming may delay the reply flow — the fallback path
    /// is never slower than it was before streaming existed, minus this bound.
    public func finish(timeout: TimeInterval = 3.0) async -> TranscriptionResult? {
        let current = currentSession()
        current?.requestFinal()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch currentOutcome() {
            case .final(let result):
                return result.finality == .explicitEndOfTurn ? result : nil
            case .failed:
                return nil
            case .pending:
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        current?.cancel()
        return nil
    }

    public func cancel() {
        resolve(.failed(.connectionDropped(hadPartialTranscript: false)))
        currentSession()?.cancel()
    }
}
