import CryptoKit
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
    /// How long the ordered rungs may hold the chain before the LAST provider —
    /// the on-device floor — starts alongside them; the first success wins and
    /// the loser is cancelled. Nil disables the race.
    ///
    /// Earned 19 Aug: a 2m46s reply sat on a silently stalled OpenAI upload
    /// while an on-device recognizer that answers such a file in well under a
    /// minute waited its turn — a turn that, at 180s timeout × 2 attempts plus
    /// backoff, was up to ~6 minutes away. The user gave up at 68s. The rung
    /// order still encodes quality (cloud answers win any race they can); the
    /// budget only bounds how long quality is allowed to cost availability.
    public let floorAfter: TimeInterval?

    public init(
        providers: [any RecoveryTranscriptionProvider]? = nil,
        maxAttemptsPerProvider: Int = 2,
        backoff: [TimeInterval] = [2, 8, 20],
        lexicon: [String] = [],
        floorAfter: TimeInterval? = 30
    ) {
        // Cloud first for quality, on-device last because it can never be
        // unavailable — and a second, independent cloud vendor between them,
        // because on 12 Aug the two-rung chain's rungs failed for unrelated
        // reasons on the same recording and the floor's mistake became the
        // transcript. A7: the shared lexicon reaches the Whisper `prompt` and
        // the Apple floor's contextualStrings; the AssemblyAI rung takes none
        // (its file API's vocabulary params are unverified — see its header).
        // All ignored when explicit providers are passed, which own their own
        // config.
        self.providers = providers
            ?? [OpenAIRecovery(lexicon: lexicon), AssemblyAIFileRecovery(),
                AppleSpeechRecovery(lexicon: lexicon)]
        self.maxAttemptsPerProvider = maxAttemptsPerProvider
        self.backoff = backoff
        self.floorAfter = floorAfter
    }

    public struct Outcome: Sendable {
        public let result: TranscriptionResult?
        public let attempts: [String]
        public let lastFailure: TranscriptionFailure?
        public var succeeded: Bool { result != nil }
    }

    public func transcribe(fileAt url: URL) async -> Outcome {
        // The race exists only when there is a floor to race: a chain pinned
        // to a single provider (tbase's --*-only probes) keeps the exact
        // sequential behaviour, as does an unconfigured floor and floorAfter
        // nil. The floor is BY POSITION the last provider — the same contract
        // the init comment states (on-device last because it can never be
        // unavailable) — not by name, so a test chain of fakes races too.
        guard let floorAfter, providers.count > 1,
              let floor = providers.last, floor.isConfigured
        else { return await run(providers, fileAt: url) }

        let ordered = Array(providers.dropLast())
        struct Lane: Sendable {
            let isFloor: Bool
            let outcome: Outcome?  // nil: the floor was cancelled before it began
        }
        // Spent when the ordered ladder finishes empty-handed: the floor's
        // wait exists to give quality a head start, and a ladder with nothing
        // left to say has no start worth protecting — the floor goes now, not
        // at the budget.
        let ladderSpent = SpentFlag()
        return await withTaskGroup(of: Lane.self) { group in
            group.addTask {
                let outcome = await run(ordered, fileAt: url)
                if !outcome.succeeded { ladderSpent.spend() }
                return Lane(isFloor: false, outcome: outcome)
            }
            group.addTask {
                let deadline = Date().addingTimeInterval(floorAfter)
                while Date() < deadline, !ladderSpent.isSpent {
                    do { try await Task.sleep(nanoseconds: 20_000_000) }
                    catch { return Lane(isFloor: true, outcome: nil) }  // ordered lane won
                }
                if Task.isCancelled { return Lane(isFloor: true, outcome: nil) }
                return Lane(isFloor: true, outcome: await run([floor], fileAt: url))
            }
            // First success cancels the other lane; the group still drains it,
            // which is why every rung must unwind promptly under cancellation
            // (URLSession throws, the poll loops check, the recogniser's task
            // is cancelled by recognizePass's cancellation handler).
            var finished: [Lane] = []
            while let lane = await group.next() {
                finished.append(lane)
                if lane.outcome?.succeeded == true { group.cancelAll() }
            }
            let attempts = finished.compactMap(\.outcome).flatMap(\.attempts)
            if let winner = finished.first(where: { $0.outcome?.succeeded == true })?.outcome {
                return Outcome(result: winner.result, attempts: attempts, lastFailure: nil)
            }
            // Both lanes failed: the ordered lane's failure is the one that
            // names the better provider's reason, so it leads.
            let failure = finished.first { !$0.isFloor }?.outcome?.lastFailure
                ?? finished.compactMap { $0.outcome?.lastFailure }.first
            return Outcome(result: nil, attempts: attempts, lastFailure: failure)
        }
    }

    /// One bit, set once, read across the race's lanes.
    private final class SpentFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var spent = false
        var isSpent: Bool { lock.lock(); defer { lock.unlock() }; return spent }
        func spend() { lock.lock(); spent = true; lock.unlock() }
    }

    /// The sequential ladder, exactly as it always ran — one lane of the race.
    private func run(
        _ providers: [any RecoveryTranscriptionProvider], fileAt url: URL
    ) async -> Outcome {
        var attempts: [String] = []
        var lastFailure: TranscriptionFailure?

        for provider in providers {
            // A cancelled lane lost the race; burning through its remaining
            // rungs would be network work whose answer is already discarded.
            if Task.isCancelled {
                attempts.append("cancelled before \(provider.name)")
                break
            }
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
                    // Retrying a bad key, an empty recording, or a machine
                    // with no network route accomplishes nothing.
                    switch failure {
                    case .authenticationFailed, .notConfigured, .fileUnreadable,
                         .noSpeechDetected, .offline:
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
    ///
    /// `streamed` is a live-transcription result obtained WHILE the audio was
    /// being recorded (see `StreamedUtterance`). It is accepted only when it
    /// carries an explicit end-of-turn — anything less trustworthy, or nil, and
    /// this function behaves exactly as it did before streaming existed. Either
    /// way the audio is saved first: streaming only ever adds speed.
    /// Move an already-written capture under the utterance's own id. Nil when
    /// there is nothing to adopt or the move fails, which sends the caller down
    /// the ordinary write path.
    private func adopt(
        _ preWritten: URL?, as utteranceId: String, audioStore: AudioStore
    ) -> AudioStore.Stored? {
        guard let preWritten, FileManager.default.fileExists(atPath: preWritten.path)
        else { return nil }
        let target = audioStore.url(for: utteranceId)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: preWritten, to: target)
            PrivateStorage.protect(target)
            let size = ((try? FileManager.default
                .attributesOfItem(atPath: target.path))?[.size] as? Int) ?? 0
            let data = (try? Data(contentsOf: target)) ?? Data()
            return AudioStore.Stored(
                url: target,
                byteCount: Int64(size),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                durationMs: Int64((Double(max(0, size - 44)) / 2.0 / 16000) * 1000))
        } catch {
            return nil
        }
    }

    /// `utteranceId` pre-mints the row's id (default: random). It exists for the
    /// panel's transcription retry: the caller must know which row an attempt
    /// owns BEFORE the attempt resolves, or a superseded attempt's row can
    /// neither be found nor retired.
    @discardableResult
    public func captureAndTranscribe(
        pcm16: Data,
        sampleRate: Double,
        audioStore: AudioStore = AudioStore(),
        chain: RecoveryChain = RecoveryChain(),
        eventId: String? = nil,
        streamed: TranscriptionResult? = nil,
        preWritten: URL? = nil,
        utteranceId: String? = nil
    ) async throws -> Utterance {
        var utterance = Utterance(id: utteranceId ?? UUID().uuidString,
                                  eventId: eventId, status: .recorded)

        // ── durability floor ──────────────────────────────────────────────
        // `preWritten` is a capture that was written to disk AS IT WAS SPOKEN
        // (LiveAudioCapture, via Recorder). The bytes are already there under a
        // capture id, so the floor is a rename rather than a write — measured at
        // 0.33ms against 4.47ms for a two-minute utterance, so this is both the
        // simpler path and the faster one.
        //
        // The fallback is deliberate and total: if adoption fails for any reason
        // the buffer is written exactly as it always was. The write-ahead copy is
        // an addition to this path, never a dependency of it.
        let stored = try adopt(preWritten, as: utterance.id, audioStore: audioStore)
            ?? audioStore.write(
                pcm16Data: pcm16, sampleRate: sampleRate, utteranceId: utterance.id)
        utterance.audioPath = stored.url.path
        utterance.audioBytes = stored.byteCount
        utterance.audioSha256 = stored.sha256
        utterance.audioDurationMs = stored.durationMs
        try update(utterance: utterance)
        // ── from here on, nothing can lose the recording ──────────────────

        // A trustworthy streamed final skips the recovery pass — that is the
        // entire speed win. The provider tag ("assemblyai-streaming" vs
        // "openai"/"apple-speech") records which path produced the transcript.
        if let streamed, streamed.finality == .explicitEndOfTurn,
           !streamed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            utterance.transcriptText = streamed.text
            utterance.transcriptProvider = streamed.provider
            utterance.transcriptFinality = streamed.finality
            utterance.status = .transcribed
            try update(utterance: utterance)
            return utterance
        }

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

    /// Re-run the chain over ONE utterance's saved audio, whatever its
    /// current status — the manual retry behind the recent-audio pane, and
    /// deliberately nothing more. Ruled 13 Aug: the machine does not retry
    /// transcriptions unasked, so this runs exactly when a human taps ↻.
    ///
    /// On success the transcript fields are rewritten in place and a row that
    /// had no transcript (`recorded`, `transcriptionFailed`) becomes
    /// `transcribed`; a row that already moved past transcription (confirmed,
    /// discarded, mid-dispatch) keeps its status — the retry improves the
    /// record, it must never rewind a lifecycle. On failure only `lastError`
    /// is touched. Nothing is ever dispatched from here.
    ///
    /// Nil when the utterance does not exist or its audio file is gone —
    /// "nothing to retry", which the caller surfaces as such.
    public func retryTranscription(
        utteranceId: String, chain: RecoveryChain = RecoveryChain()
    ) async throws -> Utterance? {
        guard var utterance = try utterances(limit: 10_000)
            .first(where: { $0.id == utteranceId }),
            let path = utterance.audioPath,
            FileManager.default.fileExists(atPath: path)
        else { return nil }

        let outcome = await chain.transcribe(fileAt: URL(fileURLWithPath: path))
        if let result = outcome.result {
            utterance.transcriptText = result.text
            utterance.transcriptProvider = result.provider
            utterance.transcriptFinality = result.finality
            utterance.lastError = nil
            if utterance.status == .recorded || utterance.status == .transcriptionFailed {
                utterance.status = .transcribed
            }
        } else {
            utterance.lastError = outcome.attempts.joined(separator: "; ")
        }
        try update(utterance: utterance)
        return utterance
    }

    /// Retire one utterance from every future sweep and pane, keeping the row
    /// as the record of what happened. The panel's transcription retry uses
    /// this on the attempt it superseded — without it every retry left a
    /// transcriptless twin of the same recording in the recent-audio list.
    public func discardUtterance(id: String, because reason: String) throws {
        guard var utterance = try utterances(limit: 10_000).first(where: { $0.id == id })
        else { return }
        utterance.status = .discarded
        utterance.discardedReason = reason
        try update(utterance: utterance)
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
