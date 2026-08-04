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
    public init() {}

    /// Per-callback visibility into the recogniser. Worth having permanently: a
    /// transcript that is quietly a fraction of what was said is indistinguishable
    /// from a transcript that is simply wrong, unless you can see how many results
    /// arrived and what time span each covered.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    public var isConfigured: Bool {
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.isAvailable ?? false
    }

    public func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionFailure.fileUnreadable
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else { throw TranscriptionFailure.providerUnavailable("speech recognizer unavailable") }

        let request = SFSpeechURLRecognitionRequest(url: url)
        // Partials off, but that was never what caused the truncation.
        //
        // `SFSpeechRecognizer` splits audio at pauses and emits one settled result per
        // utterance, each carrying real segment timestamps — and marks ONLY the last
        // one `isFinal`. With partials off, this file produces exactly two callbacks:
        // 0.87–18.81s (isFinal=false) and 20.43–22.53s (isFinal=true). Every settled
        // utterance is therefore already here; the bug was discarding all but the last.
        //
        // Partials add nothing usable: they report `span=0.00–0.00s` with no timestamps,
        // so they cannot be attributed to an utterance, and they duplicate text the
        // settled callback delivers anyway.
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            // Accumulated per utterance, keyed by the start time of the utterance.
            //
            // This is the fix for the bug that made a 22-second paragraph transcribe
            // as one clause: the old code took `bestTranscription` from the single
            // `isFinal` result, which covered only 20.43–22.53s of a 22.6s recording.
            // Measured on that file: one non-final callback spanning 0.87–18.81s with
            // 29 segments, then the final callback with 6. Keying by start time means
            // a later, better version of the SAME utterance replaces the earlier one,
            // while a genuinely new utterance is appended.
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
                AppleSpeechRecovery.trace?(
                    "callback isFinal=\(result.isFinal) segments=\(segments.count) "
                    + "span=\(String(format: "%.2f", start))–\(String(format: "%.2f", end))s "
                    + "chars=\(text.count)")
                // A zero span means untimed partial text that cannot be attributed to
                // an utterance. Recording it would double-count the utterance the
                // settled callback reports properly, which is how a first attempt at
                // this fix produced "…actually connected To the metric they're working
                // to improve To the metric they're working to improve".
                if !text.isEmpty, end > 0 { collected.record(start: start, text: text) }

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
    /// repeatedly as the recogniser refines it; the newest text for a given start time
    /// supersedes the older one instead of being appended twice.
    private final class Utterances: @unchecked Sendable {
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

    public init(model: String = "whisper-1") { self.model = model }

    public var isConfigured: Bool { Secrets.has(.openAIAPIKey) }

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
