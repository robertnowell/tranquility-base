import AVFoundation
import Foundation
import Speech

// MARK: - Result
//
// A transcript is never a bare String. Clicky's silent-truncation bug came from
// treating a timed-out partial exactly like a real final: there was no way for the
// caller to know which it had, so it always assumed the good case.

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let finality: TranscriptFinality
    public let provider: String
    public let confidence: Double?

    public init(text: String, finality: TranscriptFinality, provider: String, confidence: Double? = nil) {
        self.text = text
        self.finality = finality
        self.provider = provider
        self.confidence = confidence
    }
}

public enum TranscriptionFailure: Error, Sendable, Equatable {
    case notConfigured
    case authenticationFailed
    /// Socket died. The flag says whether anything is salvageable from what arrived.
    case connectionDropped(hadPartialTranscript: Bool)
    case sessionExpired
    case audioRateExceeded
    case noSpeechDetected
    /// Closed without an end-of-turn signal. Carries whatever partial existed —
    /// but the caller must treat it as suspect, never as final.
    case truncatedNoFinality(partial: String)
    case fileUnreadable
    case providerUnavailable(String)
}

// MARK: - Protocols
//
// Two protocols rather than one, because they are not the same capability.
// AssemblyAI streams and cannot transcribe a file; a recovery pass over saved audio
// therefore has to be able to run on a *different* vendor than the live attempt.
// A single protocol would have hidden that and left recovery impossible.

public protocol LiveTranscriptionProvider: Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    func startSession(
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
        onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
    ) async throws -> any LiveTranscriptionSession

    /// A7: open a session with the shared lexicon as the provider's boost
    /// vocabulary. For AssemblyAI this is `word_boost` on the realtime
    /// handshake (`keyterms_prompt` on the v3 streaming API); either way the
    /// vocabulary is fixed at session open — streaming handshakes take it once
    /// — so callers compute `Lexicon.harvest` immediately before opening.
    /// Providers that support boosting implement this; the default forwards to
    /// the plain `startSession`, so a provider without vocabulary support keeps
    /// working unmodified.
    func startSession(
        boosting vocabulary: [String],
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
        onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
    ) async throws -> any LiveTranscriptionSession
}

extension LiveTranscriptionProvider {
    public func startSession(
        boosting vocabulary: [String],
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscriptionResult) -> Void,
        onFailure: @escaping @Sendable (TranscriptionFailure) -> Void
    ) async throws -> any LiveTranscriptionSession {
        try await startSession(onPartial: onPartial, onFinal: onFinal, onFailure: onFailure)
    }
}

public protocol LiveTranscriptionSession: AnyObject, Sendable {
    func append(pcm16: Data)
    func requestFinal()
    func cancel()
}

/// File-based. This is the one that makes "never lose an utterance" true: it runs
/// against audio already on disk, so it works after a crash, after a network
/// outage, and on a different provider than the one that failed.
public protocol RecoveryTranscriptionProvider: Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    func transcribe(fileAt url: URL) async throws -> TranscriptionResult
}

// MARK: - Apple Speech (the floor)

/// On-device, no key, no network. Quality is not the point — availability is. This
/// is what guarantees an utterance can always be turned into *something*, which is
/// why it sits at the end of the recovery chain rather than being relied on.
public struct AppleSpeechRecovery: RecoveryTranscriptionProvider {
    public let name = "apple-speech"

    /// A7: the shared lexicon, applied as `contextualStrings` so the recognizer
    /// biases toward the proper nouns recent sessions actually used ("Klaviyo",
    /// "promotions copy") instead of their dictionary near-neighbours.
    public var lexicon: [String]

    public init(lexicon: [String] = []) {
        self.lexicon = lexicon
    }

    /// Per-callback visibility into the recogniser, transcript text included.
    ///
    /// A transcript that is quietly a fraction of what was said is indistinguishable
    /// from one that is simply wrong — unless you can see how many utterances arrived,
    /// what span each covered, and **what each one said**. The recogniser was the one
    /// unobservable stage in the chain, which is how a bug that kept only the last
    /// utterance of every paused recording survived (harvested from PR #1).
    ///
    /// Logging your words is consistent with where this project already draws the
    /// line: the same 0700 directory holds the recordings, `utterances.transcriptText`,
    /// and `model-calls.jsonl` with full session content. README says plainly that
    /// `app.log` contains what you dictated — it is the file you'd attach to an issue.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// How long to wait for `recognitionTask` before declaring the provider
    /// unavailable. See the guard in `transcribe` for what this is insuring
    /// against; it should never be reached.
    static let callbackTimeout: TimeInterval = 120

    public var isConfigured: Bool {
        // Authorisation counts as configuration. Without it this provider cannot
        // do anything except hang, and `RecoveryChain` already knows how to skip
        // a provider that is not configured — which is a cheaper and more honest
        // outcome than an attempt that will time out.
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && (SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.isAvailable ?? false)
    }

    public func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionFailure.fileUnreadable
        }
        // Authorisation first, because an UNAUTHORISED recogniser does not refuse
        // — it accepts the work and never calls back at all. Measured 10 Aug in a
        // bundle reporting `notDetermined`: the task started on 54,400 samples
        // and produced neither a result nor an error, ever.
        //
        // That matters more here than anywhere else. This provider is the last in
        // `RecoveryChain`, chosen because it "can never be unavailable" — and a
        // provider that hangs is worse than one that is unavailable, because the
        // chain never reaches the end and the utterance never resolves. Failing
        // fast is what lets the chain do its job.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionFailure.providerUnavailable(
                "speech recognition not authorised (status "
                + "\(SFSpeechRecognizer.authorizationStatus().rawValue))")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else { throw TranscriptionFailure.providerUnavailable("speech recognizer unavailable") }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        if !lexicon.isEmpty { request.contextualStrings = lexicon }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()

            // Belt as well as braces. The guard above closes the failure we have
            // actually seen; this closes the class it belongs to — a third-party
            // callback that may simply never arrive, on the one provider whose
            // whole job is to be the floor under everything else.
            //
            // Generous, because this is off the critical path: the user is not
            // waiting on it (RecoveryChain runs after the fact) and a real
            // recognition of a long recording can legitimately take a while. It
            // should never fire; if it does, the chain records the reason and
            // stops instead of waiting for a callback that is not coming.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.callbackTimeout) {
                if resumed.claim() {
                    AppleSpeechRecovery.trace?("timed out after \(Self.callbackTimeout)s "
                        + "with no result and no error")
                    continuation.resume(throwing: TranscriptionFailure.providerUnavailable(
                        "recogniser never called back (\(Int(Self.callbackTimeout))s)"))
                }
            }
            // Accumulated per utterance, keyed by the start time of the utterance.
            //
            // This is the fix for the bug that made a 22-second paragraph transcribe
            // as one clause: `SFSpeechRecognizer` splits audio at pauses, emits one
            // settled result per utterance, and marks ONLY the last one `isFinal`.
            // The old code was `guard result.isFinal` — nineteen seconds discarded
            // to keep two. Measured on the offending file: one non-final callback
            // spanning 0.87–18.81s with 29 segments, then the final one with 6.
            let collected = Utterances()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if resumed.claim() {
                        continuation.resume(throwing: TranscriptionFailure.providerUnavailable("\(error)"))
                    }
                    return
                }
                guard let result else { return }

                let segments = result.bestTranscription.segments
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let start = segments.first?.timestamp ?? 0
                let end = segments.last.map { $0.timestamp + $0.duration } ?? 0
                // A zero span means untimed partial text that cannot be attributed
                // to an utterance. Recording it would double-count the utterance
                // the settled callback reports properly.
                let settled = end > 0
                AppleSpeechRecovery.trace?(
                    "\(settled ? "utterance" : "partial") isFinal=\(result.isFinal) "
                    + "segments=\(segments.count) "
                    + "span=\(String(format: "%.2f", start))–\(String(format: "%.2f", end))s "
                    + "chars=\(text.count)"
                    // Only settled utterances carry their text: partials are
                    // cumulative re-reports of the same words.
                    + (settled ? " | \(text)" : ""))
                if !text.isEmpty, settled { collected.record(start: start, text: text) }

                guard result.isFinal else { return }
                if resumed.claim() {
                    let joined = collected.joined()
                    AppleSpeechRecovery.trace?(
                        "final: \(collected.count) utterance(s), \(joined.count) chars")
                    if joined.isEmpty {
                        continuation.resume(throwing: TranscriptionFailure.noSpeechDetected)
                    } else {
                        continuation.resume(returning: TranscriptionResult(
                            text: joined, finality: .recoveryForcedFinal, provider: name))
                    }
                }
            }
        }
    }

    /// Utterance texts in spoken order, deduplicated by start time.
    ///
    /// A dictionary rather than an array because callbacks for one utterance arrive
    /// repeatedly as the recogniser refines it; the newest text for a given start
    /// time supersedes the older one instead of being appended twice. Internal, not
    /// private, so the accumulation rules are unit-testable without SFSpeech.
    final class Utterances: @unchecked Sendable {
        private var byStart: [Double: String] = [:]
        private let lock = NSLock()

        func record(start: Double, text: String) {
            lock.lock(); defer { lock.unlock() }
            // Rounded so floating-point jitter in a re-reported timestamp cannot
            // register the same utterance twice under two nearly-equal keys.
            byStart[(start * 100).rounded() / 100] = text
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return byStart.count }

        func joined() -> String {
            lock.lock(); defer { lock.unlock() }
            return byStart.keys.sorted()
                .compactMap { byStart[$0] }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Guards the continuation: the recognition callback can fire more than once,
    /// and resuming twice traps.
    private final class Resumed: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

// MARK: - OpenAI (file-based recovery)

public struct OpenAIRecovery: RecoveryTranscriptionProvider {
    public let name = "openai"
    public var model: String

    /// A7: the shared lexicon, biased in via the transcription API's `prompt`
    /// field — the same vocabulary the Apple floor gets as `contextualStrings`.
    /// This provider is the PRIMARY transcription path today, so without this the
    /// lexicon never reached the transcripts that matter most.
    public var lexicon: [String]

    public init(model: String = "whisper-1", lexicon: [String] = []) {
        self.model = model
        self.lexicon = lexicon
    }

    public var isConfigured: Bool { Secrets.has(.openAIAPIKey) }

    /// Whisper treats the prompt as preceding context and biases vocabulary and
    /// spelling toward it, but only reads the FINAL ~224 tokens — anything beyond
    /// that silently falls off the front. So the budget is enforced here, well
    /// under the limit, rather than trusting the model to truncate kindly.
    static let promptTokenBudget = 180

    /// Conservative overestimate (~3 bytes/token instead of the usual ~4), so a
    /// term-list that passes this check can never blow the real tokenizer's cap.
    static func estimatedTokens(_ text: String) -> Int {
        max(1, (text.utf8.count + 2) / 3)
    }

    private static let promptScaffold = "The recording may mention: "

    /// Compose the `prompt` field from the lexicon: a natural-ish comma-joined
    /// term list. The lexicon is already priority-ordered — seeds first
    /// (callsigns, project labels, live session names: the words the user says
    /// back at the app), then harvested terms by recency-weighted score — so
    /// truncating from the tail drops the least valuable terms.
    static func lexiconPrompt(
        _ terms: [String], tokenBudget: Int = promptTokenBudget
    ) -> String? {
        var included: [String] = []
        var spent = estimatedTokens(promptScaffold)
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            let cost = estimatedTokens(term) + 1  // + ", " separator
            guard spent + cost <= tokenBudget else { break }
            included.append(term)
            spent += cost
        }
        guard !included.isEmpty else { return nil }
        return promptScaffold + included.joined(separator: ", ") + "."
    }

    public func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
        guard let key = Secrets.read(.openAIAPIKey) else { throw TranscriptionFailure.notConfigured }
        guard let audio = try? Data(contentsOf: url) else { throw TranscriptionFailure.fileUnreadable }

        let boundary = "vd-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        if let prompt = Self.lexiconPrompt(lexicon) { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionFailure.providerUnavailable("no response")
        }
        if http.statusCode == 401 { throw TranscriptionFailure.authenticationFailed }
        guard http.statusCode == 200 else {
            throw TranscriptionFailure.providerUnavailable("http \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { throw TranscriptionFailure.noSpeechDetected }

        return TranscriptionResult(text: text, finality: .recoveryForcedFinal, provider: name)
    }
}
