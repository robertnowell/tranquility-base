import AVFoundation
import Foundation

/// Text-to-speech. Takes only `SanitizedSpokenText`, so raw model output cannot
/// reach a synthesizer by any route.
public protocol SpeechProvider: Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    /// Returns when the audio finishes, or throws. Must be interruptible.
    func speak(_ text: SanitizedSpokenText) async throws
    func stop()
    var isSpeaking: Bool { get }
}

public enum SpeechError: Error, Sendable {
    case notConfigured
    case synthesisFailed(String)
    case interrupted
}

// MARK: - System (default)

/// `AVSpeechSynthesizer`. Free, offline, and by far the fastest to first audio, so
/// it is the default rather than merely the fallback: for an ambient notification
/// nobody needs a premium voice, and a network round trip before speech is a worse
/// experience than a plainer voice that starts immediately.
public final class SystemSpeechProvider: NSObject, SpeechProvider, @unchecked Sendable {
    public let name = "system"
    public let isConfigured = true

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    /// Measured with `say`: 25 words ≈ 9.9s at the default rate. A little above
    /// default keeps a 35-word summary near twelve seconds without sounding rushed.
    public var rate: Float
    public var voiceIdentifier: String?

    public init(rate: Float = 0.52, voiceIdentifier: String? = nil) {
        self.rate = rate
        self.voiceIdentifier = voiceIdentifier
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func speak(_ text: SanitizedSpokenText) async throws {
        stop()
        let utterance = AVSpeechUtterance(string: text.text)
        utterance.rate = rate
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        resume(with: .failure(SpeechError.interrupted))
    }

    private func resume(with result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success: cont?.resume()
        case .failure(let error): cont?.resume(throwing: error)
        }
    }
}

extension SystemSpeechProvider: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume(with: .success(()))
    }

    public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume(with: .failure(SpeechError.interrupted))
    }
}

// MARK: - ElevenLabs (optional)

/// Nicer voice at the cost of a network round trip. Kept behind the same protocol so
/// it can be swapped in per preference; on any failure the caller falls back to the
/// system provider for that utterance only, never stickily.
public final class ElevenLabsSpeechProvider: NSObject, SpeechProvider, @unchecked Sendable {
    public let name = "elevenlabs"
    public var voiceId: String
    public var model: String
    /// Voice UX cares about sub-second starts, so this is far tighter than a normal
    /// network timeout — past this we are better off speaking in a plainer voice.
    public var timeout: TimeInterval

    private var player: AVAudioPlayer?

    public init(
        voiceId: String = "EXAVITQu4vr4xnSDxMaL",
        model: String = "eleven_flash_v2_5",
        timeout: TimeInterval = 3
    ) {
        self.voiceId = voiceId
        self.model = model
        self.timeout = timeout
    }

    public var isConfigured: Bool { Secrets.has(.elevenLabsAPIKey) }
    public var isSpeaking: Bool { player?.isPlaying ?? false }

    public func speak(_ text: SanitizedSpokenText) async throws {
        guard let key = Secrets.read(.elevenLabsAPIKey) else { throw SpeechError.notConfigured }

        var request = URLRequest(
            url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text.text,
            "model_id": model,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpeechError.synthesisFailed("http \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let audio = try AVAudioPlayer(data: data)
        player = audio
        audio.play()
        while audio.isPlaying {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    public func stop() {
        player?.stop()
        player = nil
    }
}

// MARK: - Chain

/// Speech is not on the never-lose-data path — a failed announcement is an
/// annoyance, not data loss. So it degrades quietly to the system voice rather than
/// blocking or retrying.
public struct SpeechChain: Sendable {
    public let preferred: (any SpeechProvider)?
    public let fallback: any SpeechProvider

    public init(preferred: (any SpeechProvider)? = nil, fallback: any SpeechProvider = SystemSpeechProvider()) {
        self.preferred = preferred
        self.fallback = fallback
    }

    @discardableResult
    public func speak(_ text: SanitizedSpokenText) async -> String {
        if let preferred, preferred.isConfigured {
            do {
                try await preferred.speak(text)
                return preferred.name
            } catch SpeechError.interrupted {
                return preferred.name
            } catch {
                // fall through to the system voice for this utterance only
            }
        }
        try? await fallback.speak(text)
        return fallback.name
    }
}
