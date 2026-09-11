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
        // 09 Sep: real silent captures passed a clean empty live assessment to
        // the generative file fallback, which returned news/outro boilerplate.
        // Saved-file recovery now asks the primary provider first as well.
        // A valid empty assessment stops the chain; actual service failures
        // retain independent cloud and on-device recovery. Lexicon context
        // still reaches the providers that support it.
        self.providers = providers
            ?? [AssemblyAIFileRecovery(), OpenAIRecovery(lexicon: lexicon),
                AppleSpeechRecovery(lexicon: lexicon)]
        self.maxAttemptsPerProvider = maxAttemptsPerProvider
        self.backoff = backoff
        self.floorAfter = floorAfter
    }

    public struct Outcome: Sendable {
        public let result: TranscriptionResult?
        public let attempts: [String]
        public let lastFailure: TranscriptionFailure?
        public var diagnostics: [TranscriptionAttempt] = []
        // The winning assessment excludes cancellation of the losing race lane.
        var assessment: TranscriptionDisposition? = nil
        public var disposition: TranscriptionDisposition {
            assessment ?? TranscriptionAttempt.disposition(of: diagnostics)
        }
        var concluded: Bool { succeeded || disposition == .noSpeechDetected }
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
                if !outcome.concluded { ladderSpent.spend() }
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
            // A usable transcript or the ordered lane's no-speech assessment
            // cancels the other lane; the group still drains it,
            // which is why every rung must unwind promptly under cancellation
            // (URLSession throws, the poll loops check, the recogniser's task
            // is cancelled by recognizePass's cancellation handler).
            var finished: [Lane] = []
            var winner: Outcome?
            while let lane = await group.next() {
                finished.append(lane)
                // An empty floor does not veto an ordered provider still working.
                if winner == nil, let outcome = lane.outcome,
                   outcome.succeeded || (!lane.isFloor && outcome.concluded) {
                    winner = outcome
                    group.cancelAll()
                }
            }
            let attempts = finished.compactMap(\.outcome).flatMap(\.attempts)
            let diagnostics = finished.compactMap(\.outcome).flatMap(\.diagnostics)
            if Task.isCancelled {
                return Outcome(result: nil, attempts: attempts, lastFailure: nil,
                               diagnostics: diagnostics, assessment: .cancelled)
            }
            if let winner = winner ?? finished.compactMap(\.outcome).first(where: { $0.concluded }) {
                return Outcome(result: winner.result, attempts: attempts, lastFailure: winner.lastFailure,
                               diagnostics: diagnostics, assessment: winner.disposition)
            }
            // Both lanes failed: the ordered lane's failure is the one that
            // names the better provider's reason, so it leads.
            let failure = finished.first { !$0.isFloor }?.outcome?.lastFailure
                ?? finished.compactMap { $0.outcome?.lastFailure }.first
            return Outcome(result: nil, attempts: attempts, lastFailure: failure, diagnostics: diagnostics)
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
        var diagnostics: [TranscriptionAttempt] = []
        func record(_ provider: String, configured: Bool = true, outcome: String,
                    code: String? = nil, began: Date = Date(), ordinal: Int = 0) {
            let item = TranscriptionAttempt(provider: provider, configured: configured,
                outcome: outcome, errorCode: code,
                durationMs: max(0, Int(Date().timeIntervalSince(began) * 1000)), ordinal: ordinal)
            diagnostics.append(item)
            item.record()
        }

        for provider in providers {
            // A cancelled lane lost the race; burning through its remaining
            // rungs would be network work whose answer is already discarded.
            if Task.isCancelled {
                attempts.append("cancelled before \(provider.name)")
                record(provider.name, outcome: "cancelled", code: "cancelled")
                break
            }
            guard provider.isConfigured else {
                attempts.append("\(provider.name): not configured")
                record(provider.name, configured: false, outcome: "skipped", code: "not_configured")
                continue
            }
            for attempt in 0..<maxAttemptsPerProvider {
                let began = Date()
                do {
                    let result = try await provider.transcribe(fileAt: url)
                    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TranscriptionFailure.noSpeechDetected
                    }
                    record(provider.name, outcome: "completed", began: began, ordinal: attempt + 1)
                    attempts.append("\(provider.name): ok")
                    return Outcome(result: result, attempts: attempts, lastFailure: nil, diagnostics: diagnostics)
                } catch let failure as TranscriptionFailure {
                    attempts.append("\(provider.name): \(failure)")
                    lastFailure = failure
                    record(provider.name, outcome: Task.isCancelled ? "cancelled"
                               : failure == .noSpeechDetected ? "no_speech_detected" : "failed",
                           code: Task.isCancelled ? "cancelled" : failure.diagnosticCode,
                           began: began, ordinal: attempt + 1)
                    if failure == .noSpeechDetected, !Task.isCancelled {
                        // A completed empty assessment is a result. Asking another
                        // recognizer to invent text created the observed silent-capture
                        // artifacts on 09 Sep. Keep the file for explicit user retry.
                        return Outcome(result: nil, attempts: attempts, lastFailure: failure,
                                       diagnostics: diagnostics, assessment: .noSpeechDetected)
                    }
                    // Retrying a bad key, an empty recording, or a machine
                    // with no network route accomplishes nothing.
                    switch failure {
                    case .providerHTTP(let status, _) where (400..<500).contains(status) && status != 429:
                        break
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
                    record(provider.name, outcome: Task.isCancelled ? "cancelled" : "failed",
                           code: Task.isCancelled ? "cancelled" : "provider_unavailable",
                           began: began, ordinal: attempt + 1)
                    break
                }
            }
        }
        return Outcome(result: nil, attempts: attempts, lastFailure: lastFailure, diagnostics: diagnostics)
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
        streamHadRecognizedText: Bool = false,
        streamNoSpeechProvider: String? = nil,
        preWritten: URL? = nil,
        utteranceId: String? = nil
    ) async throws -> Utterance {
        var utterance = Utterance(id: utteranceId ?? UUID().uuidString,
                                  eventId: eventId, status: .recorded)

        utterance.captureId = Track.captureID
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
            utterance.transcriptionOutcome = TranscriptionDisposition.completed.rawValue
            try update(utterance: utterance)
            Track.record("transcription", [
                "outcome": "completed", "streamed": true,
                "provider": Track.token(from: streamed.provider),
                "finality": Track.token(from: "\(streamed.finality)"),
                "audio_ms": .int(Int(stored.durationMs)),
                "speech_evidence": "provider_text", "latency_scope": "see_stream_attempt",
                "chars": .int(streamed.text.count), "words": .int(Track.wordCount(streamed.text)),
            ])
            return utterance
        }

        let hadText = streamHadRecognizedText
            || !(streamed?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        if let provider = streamNoSpeechProvider, !hadText, !Task.isCancelled {
            utterance.status = .transcriptionFailed  // existing durable, manually retryable row
            utterance.transcriptionOutcome = TranscriptionDisposition.noSpeechDetected.rawValue
            utterance.transcriptProvider = provider
            try update(utterance: utterance)
            Track.record("transcription", [
                "outcome": "no_speech_detected", "streamed": true,
                "provider": Track.token(from: provider), "audio_ms": .int(Int(stored.durationMs)),
                "speech_evidence": "provider_no_speech", "latency_scope": "see_stream_attempt",
                "attempts": 0,
            ])
            return utterance
        }

        utterance.status = .transcribing
        try update(utterance: utterance)

        let began = Date()
        let outcome = await chain.transcribe(fileAt: stored.url)
        // Conflicting recognizer evidence cannot quietly dismiss a capture.
        let disposition: TranscriptionDisposition = outcome.disposition == .noSpeechDetected && hadText
            ? .unresolved : outcome.disposition
        var transcription: [String: TrackValue] = [
            "streamed": .bool(streamed != nil),
            "latency_ms": .int(Int(Date().timeIntervalSince(began) * 1000)),
            "audio_ms": .int(Int(stored.durationMs)),
            "attempts": .int(outcome.attempts.count),
        ]
        if let result = outcome.result {
            transcription["outcome"] = "completed"
            transcription["provider"] = Track.token(from: result.provider)
            transcription["finality"] = Track.token(from: "\(result.finality)")
            transcription["chars"] = .int(result.text.count)
            transcription["words"] = .int(Track.wordCount(result.text))
        } else {
            transcription["outcome"] = .token(disposition.rawValue)
            // The attempts are "<provider>: <error>" lines (an HTTP status, an
            // auth failure, a dropped connection), never the transcript, which
            // exists only on the success branch above. On failure this is the
            // one thing that says WHICH provider failed and why, instead of a
            // bare disposition. Scrubbed and bounded by `.prose`.
            if !outcome.attempts.isEmpty {
                transcription["attempts_detail"] = .prose(outcome.attempts.joined(separator: "; "))
            }
        }
        transcription["speech_evidence"] = outcome.result != nil || hadText ? "provider_text" : "unknown"
        transcription["latency_scope"] = "recovery"
        utterance.transcriptionOutcome = disposition.rawValue
        Track.record("transcription", transcription)

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

    private func transcribeSavedUtterance(
        _ utterance: Utterance, at path: String, chain: RecoveryChain, trigger: String
    ) async -> RecoveryChain.Outcome {
        await Track.$captureID.withValue(utterance.captureId) {
            await Track.$attemptID.withValue(UUID().uuidString) {
                let began = Date()
                let outcome = await chain.transcribe(fileAt: URL(fileURLWithPath: path))
                Track.record("transcription", [
                    "outcome": .token(outcome.disposition.rawValue), "trigger": .token(trigger),
                    "streamed": false, "latency_scope": "recovery",
                    "latency_ms": .int(Int(Date().timeIntervalSince(began) * 1000)),
                    "speech_evidence": outcome.result == nil ? "unknown" : "provider_text",
                    "attempts": .int(outcome.attempts.count),
                ])
                return outcome
            }
        }
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
    /// and the latest diagnostic outcome change. Nothing is dispatched here.
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

        let outcome = await transcribeSavedUtterance(utterance, at: path, chain: chain, trigger: "manual_retry")
        utterance.transcriptionOutcome = outcome.disposition.rawValue
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
            let outcome = await transcribeSavedUtterance(utterance, at: path, chain: chain, trigger: "retry_failed")
            utterance.transcriptionOutcome = outcome.disposition.rawValue
            guard let result = outcome.result else {
                utterance.lastError = outcome.attempts.joined(separator: "; ")
                try update(utterance: utterance)
                continue
            }
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
