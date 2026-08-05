import Foundation

/// Turns a saved utterance into a transcript, trying providers in order until one
/// works. Because it reads from disk rather than memory, it works after a crash,
/// after a network outage, and on a different vendor than the one that failed.
///
/// Two rules encode hard-won constraints:
///
/// - **Never vendor-hop mid-utterance.** Once the user has started speaking, a live
///   provider that dies is not replaced with another live provider — the utterance
///   is closed out and handed here, to run over the complete saved audio. Switching
///   mid-sentence loses context and makes the user repeat themselves.
/// - **Never silently accept a truncated transcript.** A live pass that ended without
///   an end-of-turn signal is marked `fallbackTimeout` and re-run here regardless of
///   whether it produced text, because no streaming vendor gives any way to know how
///   much was lost.
public struct RecoveryChain: Sendable {
    public let providers: [any RecoveryTranscriptionProvider]
    public let maxAttemptsPerProvider: Int
    /// Off the critical path — the user is not waiting — so backoff can be generous.
    public let backoff: [TimeInterval]

    public init(
        providers: [any RecoveryTranscriptionProvider]? = nil,
        maxAttemptsPerProvider: Int = 2,
        backoff: [TimeInterval] = [2, 8, 20],
        lexicon: [String] = []
    ) {
        // Cloud first for quality, on-device last because it can never be unavailable.
        // A7: the shared lexicon reaches the Apple floor as contextualStrings;
        // ignored when explicit providers are passed, which own their own config.
        self.providers = providers ?? [OpenAIRecovery(), AppleSpeechRecovery(lexicon: lexicon)]
        self.maxAttemptsPerProvider = maxAttemptsPerProvider
        self.backoff = backoff
    }

    public struct Outcome: Sendable {
        public let result: TranscriptionResult?
        public let attempts: [String]
        public let lastFailure: TranscriptionFailure?
        public var succeeded: Bool { result != nil }
    }

    public func transcribe(fileAt url: URL) async -> Outcome {
        var attempts: [String] = []
        var lastFailure: TranscriptionFailure?

        for provider in providers {
            guard provider.isConfigured else {
                attempts.append("\(provider.name): not configured")
                continue
            }
            for attempt in 0..<maxAttemptsPerProvider {
                do {
                    let result = try await provider.transcribe(fileAt: url)
                    attempts.append("\(provider.name): ok")
                    return Outcome(result: result, attempts: attempts, lastFailure: nil)
                } catch let failure as TranscriptionFailure {
                    attempts.append("\(provider.name): \(failure)")
                    lastFailure = failure
                    // Retrying a bad key or an empty recording accomplishes nothing.
                    switch failure {
                    case .authenticationFailed, .notConfigured, .fileUnreadable, .noSpeechDetected:
                        break
                    default:
                        if attempt + 1 < maxAttemptsPerProvider {
                            let delay = backoff[min(attempt, backoff.count - 1)]
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            continue
                        }
                    }
                    break
                } catch {
                    attempts.append("\(provider.name): \(error)")
                    lastFailure = .providerUnavailable("\(error)")
                    break
                }
            }
        }
        return Outcome(result: nil, attempts: attempts, lastFailure: lastFailure)
    }
}

// MARK: - Orchestration

extension QueueStore {
    /// Persist a recorded utterance, then transcribe it.
    ///
    /// Order is the invariant: the audio and its row are committed **first**, and
    /// only then does anything touch the network. If transcription fails at every
    /// provider the row lands in `transcriptionFailed` with its audio intact, ready
    /// for a manual or boot-sweep retry — never discarded.
    @discardableResult
    public func captureAndTranscribe(
        pcm16: Data,
        sampleRate: Double,
        audioStore: AudioStore = AudioStore(),
        chain: RecoveryChain = RecoveryChain(),
        eventId: String? = nil
    ) async throws -> Utterance {
        var utterance = Utterance(eventId: eventId, status: .recorded)

        // ── durability floor ──────────────────────────────────────────────
        let stored = try audioStore.write(
            pcm16Data: pcm16, sampleRate: sampleRate, utteranceId: utterance.id)
        utterance.audioPath = stored.url.path
        utterance.audioBytes = stored.byteCount
        utterance.audioSha256 = stored.sha256
        utterance.audioDurationMs = stored.durationMs
        try update(utterance: utterance)
        // ── from here on, nothing can lose the recording ──────────────────

        utterance.status = .transcribing
        try update(utterance: utterance)

        let outcome = await chain.transcribe(fileAt: stored.url)

        if let result = outcome.result {
            utterance.transcriptText = result.text
            utterance.transcriptProvider = result.provider
            utterance.transcriptFinality = result.finality
            utterance.status = .transcribed
        } else {
            utterance.status = .transcriptionFailed
            utterance.lastError = outcome.attempts.joined(separator: "; ")
        }
        try update(utterance: utterance)
        return utterance
    }

    /// Retry every utterance whose transcription failed, from disk.
    public func retryFailedTranscriptions(
        audioStore: AudioStore = AudioStore(),
        chain: RecoveryChain = RecoveryChain()
    ) async throws -> [Utterance] {
        var recovered: [Utterance] = []
        for var utterance in try utterances(status: .transcriptionFailed) {
            guard let path = utterance.audioPath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            let outcome = await chain.transcribe(fileAt: URL(fileURLWithPath: path))
            guard let result = outcome.result else { continue }
            utterance.transcriptText = result.text
            utterance.transcriptProvider = result.provider
            utterance.transcriptFinality = result.finality
            utterance.status = .transcribed
            utterance.lastError = nil
            try update(utterance: utterance)
            recovered.append(utterance)
        }
        return recovered
    }
}
