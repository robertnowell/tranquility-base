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
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if resumed.claim() {
                        continuation.resume(throwing: TranscriptionFailure.providerUnavailable("\(error)"))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                if resumed.claim() {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        continuation.resume(throwing: TranscriptionFailure.noSpeechDetected)
                    } else {
                        continuation.resume(returning: TranscriptionResult(
                            text: text, finality: .recoveryForcedFinal, provider: name))
                    }
                }
            }
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
