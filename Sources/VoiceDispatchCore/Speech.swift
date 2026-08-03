import AVFoundation
import Foundation

/// Text-to-speech. Takes only `SanitizedSpokenText`, so raw model output cannot
/// reach a synthesizer by any route.
public protocol SpeechProvider: Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    /// Returns when the audio finishes, or throws. Must be interruptible.
    ///
    /// `onWord` reports the character range currently being spoken, so a UI can
    /// follow along. Without it the text can only be shown before or after, and
    /// "after" is useless — by then you have already heard it.
    func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws
    func stop()
    var isSpeaking: Bool { get }
}

extension SpeechProvider {
    public func speak(_ text: SanitizedSpokenText) async throws {
        try await speak(text, onWord: nil)
    }
}

public enum SpeechError: Error, Sendable {
    case notConfigured
    case synthesisFailed(String)
    /// `stop()` was called. Somebody asked for this.
    case interrupted
    /// The audio stopped short and nobody asked. A dropped connection, a decode
    /// failure, a device change. Distinguishable from `interrupted` because
    /// interruption is caused, not inferred: `stop()` bumps a counter, so if the
    /// counter is unchanged when the audio ends early, no one requested it.
    case truncated(playedSeconds: Double, ofSeconds: Double)
}

// MARK: - System (default)

/// `AVSpeechSynthesizer`. Free, offline, and the fastest to first audio — the
/// guaranteed floor, used whenever the network provider is unconfigured or fails.
/// It is not the default: see `SpeechChain` for why that changed after listening.
public final class SystemSpeechProvider: NSObject, SpeechProvider, @unchecked Sendable {
    public let name = "system"
    public let isConfigured = true

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?
    private var wordCallback: (@Sendable (Range<Int>) -> Void)?
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

    public func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
        stop()
        let utterance = AVSpeechUtterance(string: text.text)
        utterance.rate = rate
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = cont
            wordCallback = onWord
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
    /// Fires once per word as it is spoken — this is what drives the highlight.
    public func speechSynthesizer(
        _ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        lock.lock(); let callback = wordCallback; lock.unlock()
        callback?(characterRange.location..<(characterRange.location + characterRange.length))
    }

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

    /// Bumped by `stop()`. Any speak call whose generation is stale drops its audio
    /// on arrival rather than playing it. Without this, tapping to stop during the
    /// network round trip stopped nothing — the response landed a second later and
    /// played on top of whatever had started since.
    private var generation = 0
    private let generationQueue = DispatchQueue(label: "elevenlabs.generation")

    private func currentGeneration() -> Int { generationQueue.sync { generation } }
    private func bumpGeneration() { generationQueue.sync { generation += 1 } }

    /// Set by the app so highlight failures are visible instead of silent.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

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

    public func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
        guard let key = Secrets.read(.elevenLabsAPIKey) else { throw SpeechError.notConfigured }
        let mine = currentGeneration()

        // The /with-timestamps variant returns per-character start times alongside the
        // audio, which is the only way to follow along with a pre-rendered clip.
        var request = URLRequest(
            url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/with-timestamps")!)
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base64 = json["audio_base64"] as? String,
              let audioData = Data(base64Encoded: base64)
        else { throw SpeechError.synthesisFailed("unexpected response shape") }

        let starts = (json["alignment"] as? [String: Any])?["character_start_times_seconds"] as? [Double]
        ElevenLabsSpeechProvider.trace?("alignment starts=\(starts?.count ?? -1) chars=\(text.text.count) onWord=\(onWord != nil)")

        guard mine == currentGeneration() else { throw SpeechError.interrupted }

        let audio = try AVAudioPlayer(data: audioData)
        player = audio
        audio.prepareToPlay()
        guard audio.play() else { throw SpeechError.synthesisFailed("player refused to start") }

        // play() returns before isPlaying flips. Without this the polling loop below
        // exits on its first test and the audio is reported as having stopped at 0s.
        for _ in 0..<20 where !audio.isPlaying {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard audio.isPlaying || audio.currentTime > 0 else {
            throw SpeechError.synthesisFailed("playback never started")
        }

        // Only poll when there is a highlight to drive, and at a rate matched to
        // reading rather than to rendering — 40ms was needless CPU for a cosmetic
        // effect. ~8/second is well past what the eye resolves for word highlighting.
        guard let starts, let onWord else {
            while audio.isPlaying { try await Task.sleep(nanoseconds: 200_000_000) }
            try checkForTruncation(audio, generation: mine)
            return
        }

        var lastIndex = -1
        while audio.isPlaying {
            do {
                // Character index whose start time has just passed.
                let now = audio.currentTime
                var index = lastIndex
                while index + 1 < starts.count, starts[index + 1] <= now { index += 1 }
                if index != lastIndex, index >= 0 {
                    lastIndex = index
                    ElevenLabsSpeechProvider.trace?("onWord upTo=\(index + 1) t=\(now)")
                    onWord(0..<min(index + 1, text.text.count))
                }
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        try checkForTruncation(audio, generation: mine)
    }

    /// Playback that ends early with the generation unchanged was not stopped by
    /// anyone — that is a failure, and it should not be reported as your choice.
    private func checkForTruncation(_ audio: AVAudioPlayer, generation mine: Int) throws {
        guard mine == currentGeneration() else { throw SpeechError.interrupted }
        let remaining = audio.duration - audio.currentTime
        guard remaining > 0.25 else { return }
        throw SpeechError.truncated(playedSeconds: audio.currentTime, ofSeconds: audio.duration)
    }

    public func stop() {
        bumpGeneration()
        player?.stop()
        player = nil
    }
}

// MARK: - Chain

/// Speech is not on the never-lose-data path — a failed announcement is an
/// annoyance, not data loss. So it degrades quietly to the system voice rather than
/// blocking or retrying.
///
/// ElevenLabs is the default after listening to both back to back. The engineering
/// argument for the system voice was time-to-first-audio, and that argument loses:
/// for a twenty-five-second update the extra second before speech starts is
/// imperceptible, while the difference in listenability across that duration is not.
/// The system voice remains the fallback and needs no network or key.
public struct SpeechChain: Sendable {
    public let preferred: (any SpeechProvider)?
    public let fallback: any SpeechProvider

    public init(
        preferred: (any SpeechProvider)? = ElevenLabsSpeechProvider(),
        fallback: any SpeechProvider = SystemSpeechProvider()
    ) {
        self.preferred = preferred
        self.fallback = fallback
    }

    public var isSpeaking: Bool {
        (preferred?.isSpeaking ?? false) || fallback.isSpeaking
    }

    /// Cut speech off immediately. A tap while it is talking means "stop", and a
    /// voice you cannot interrupt is worse than one you have to summon.
    public func stop() {
        preferred?.stop()
        fallback.stop()
    }

    public struct Spoken: Sendable {
        public let provider: String
        /// False when the audio was cut off. An interrupted announcement was not
        /// heard, so it must not be treated as delivered.
        public let completed: Bool
        /// Set only when the audio stopped short without anyone asking. The item is
        /// still unread either way, but this is a fault to surface rather than a
        /// choice to respect quietly.
        public var failure: String?
        /// Set when the preferred voice failed and the system voice covered for it.
        /// The announcement WAS heard; this exists so a silent downgrade is visible.
        public var degraded: String?
    }

    @discardableResult
    public func speak(
        _ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)? = nil
    ) async -> Spoken {
        var degraded: String?
        if let preferred, preferred.isConfigured {
            do {
                ElevenLabsSpeechProvider.trace?("chain: trying \(preferred.name)")
                try await preferred.speak(text, onWord: onWord)
                return Spoken(provider: preferred.name, completed: true)
            } catch SpeechError.interrupted {
                return Spoken(provider: preferred.name, completed: false)
            } catch SpeechError.truncated(let played, let total) {
                // Cut off part-way. Re-reading the whole thing in the system voice is
                // better than leaving you with a fragment and a fault message.
                degraded = String(format: "cut off at %.0fs of %.0fs", played, total)
            } catch {
                degraded = "\(error)"
                ElevenLabsSpeechProvider.trace?("chain: \(preferred.name) failed: \(error)")
                // fall through to the system voice for this utterance only
            }
        } else {
            ElevenLabsSpeechProvider.trace?(
                "chain: preferred unavailable (configured=\(preferred?.isConfigured ?? false))")
        }
        ElevenLabsSpeechProvider.trace?("chain: falling back to \(fallback.name)")
        do {
            try await fallback.speak(text, onWord: onWord)
            // Heard, in the plainer voice. Not a failure — a degradation, reported
            // so an outage cannot hide behind a robotic voice you assume is normal.
            return Spoken(provider: fallback.name, completed: true, degraded: degraded)
        } catch SpeechError.interrupted {
            return Spoken(provider: fallback.name, completed: false)
        } catch {
            return Spoken(
                provider: fallback.name, completed: false, failure: "\(error)")
        }
    }
}
