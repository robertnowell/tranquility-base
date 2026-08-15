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
    /// The machine has no route to the provider at all — airplane mode, no
    /// DNS. Distinct from providerUnavailable because retrying is pure
    /// wait: on a plane (14 Aug) the two cloud rungs spent ~40 seconds
    /// backing off against "hostname could not be found" before the one
    /// rung that works offline got its turn on a 2-second clip.
    case offline

    /// Classify a thrown transport error: certainly-offline URLError codes
    /// map to `.offline` (fail the rung once, immediately); anything else
    /// stays a retryable providerUnavailable.
    static func fromTransport(_ error: Error) -> TranscriptionFailure {
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
            .internationalRoamingOff, .dataNotAllowed].contains(urlError.code) {
            return .offline
        }
        return .providerUnavailable("transport: \(error.localizedDescription)")
    }
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
        // Deliberately does NOT gate on authorisation.
        //
        // It did, briefly, on 10 Aug, on the premise that an unauthorised
        // recogniser hangs. Measured: it does not — it returns
        // kAFAssistantErrorDomain errors like any other failure, and the hang
        // that premise came from was never reproduced once the grant existed.
        // Gating here would have made the fallback refuse silently on a fresh
        // install rather than attempt and report, which is the opposite of what
        // a last-resort provider is for.
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.isAvailable ?? false
    }

    /// How much untranscribed tail still counts as full coverage. Speech ends
    /// before audio does — the key-up trails the last word — so a pass over a
    /// complete recording legitimately settles a second or two short.
    static let coverageSlack: TimeInterval = 2.0
    /// Runaway guard on the continuation loop. Every pass restarts at a
    /// settled-utterance boundary, so a recogniser that keeps stopping early
    /// still advances — but it must not get to do so unboundedly.
    static let maxPasses = 32
    static let sampleRate: Double = 16000

    /// PCM16 bytes from `from` seconds to the end, aligned to a whole sample.
    static func pcmSlice(of pcm: Data, from seconds: Double, sampleRate: Double) -> Data {
        let startByte = min(pcm.count, max(0, Int(seconds * sampleRate) * 2))
        return pcm.subdata(in: startByte..<pcm.count)
    }

    /// Transcribe the whole file, however long it is.
    ///
    /// One recognition pass is not trusted to mean one whole file: on 12 Aug a
    /// 1690.86s recording came back `isFinal` after settling 0.87–60.21s — the
    /// recogniser stopped early under in-app audio churn (the mic re-armed
    /// twice mid-recognition) and its final looked exactly like a real one.
    /// The same file recognised standalone covered all 27 minutes, so the stop
    /// is circumstance, not capability. The defence is to measure every pass
    /// against the audio's real duration and CONTINUE where it stopped: each
    /// pass restarts at the last settled utterance's end (a pause boundary),
    /// and the floor returns everything it heard. Once anything is
    /// transcribed, a later pass failure returns the partial rather than
    /// throwing — this is the last rung; something honest beats nothing.
    public func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionFailure.fileUnreadable
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else { throw TranscriptionFailure.providerUnavailable("speech recognizer unavailable") }

        guard let pcm = BuddyPCM16Converter.pcm16Data(contentsOf: url) else {
            throw TranscriptionFailure.fileUnreadable
        }
        let duration = Double(pcm.count) / 2.0 / Self.sampleRate
        AppleSpeechRecovery.trace?(String(format:
            "starting: %.2fs of audio, onDevice=%@",
            duration, recognizer.supportsOnDeviceRecognition ? "true" : "false"))
        let collected = Utterances()
        var cursor: Double = 0
        var passes = 0
        var retriedEmptyPass = false
        // Set when an empty pass earns its one retry: the retry must re-enter
        // the loop even for a clip too short to owe continuation coverage.
        var retryPassOwed = false

        // The first pass ALWAYS runs; the slack governs only whether a
        // CONTINUATION pass is owed. Folding both into one `remaining >
        // slack` test silently declared every recording shorter than the
        // slack "no speech" without ever recognizing it — which is exactly
        // what happened to four short dictations on a plane (14 Aug): the
        // cloud rungs were offline, the floor got a 1.9s clip, the loop
        // never entered, and the one rung that works offline threw the
        // recording out untried. Online the bug was invisible because
        // Whisper answered every short clip first.
        while passes < Self.maxPasses,
              passes == 0 || retryPassOwed || duration - cursor > Self.coverageSlack {
            retryPassOwed = false
            passes += 1
            // The first pass reads the original file; a continuation pass
            // slices the remainder to a temp WAV so the recogniser restarts
            // exactly at the boundary where the previous pass stopped.
            let passURL: URL
            var scratch: URL?
            if cursor == 0 {
                passURL = url
            } else {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("apple-pass-\(UUID().uuidString).wav")
                let slice = Self.pcmSlice(of: pcm, from: cursor, sampleRate: Self.sampleRate)
                do {
                    try BuddyWAVBuilder
                        .wavData(fromPCM16: slice, sampleRate: Self.sampleRate)
                        .write(to: tmp)
                } catch {
                    break  // keep what is already transcribed
                }
                passURL = tmp
                scratch = tmp
            }
            defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }

            let pass: Utterances
            do {
                pass = try await recognizePass(
                    recognizer: recognizer, fileAt: passURL,
                    timeout: max(Self.callbackTimeout, (duration - cursor) / 2))
            } catch {
                guard collected.count > 0 else { throw error }
                AppleSpeechRecovery.trace?(
                    "pass \(passes) failed (\(error)); returning what is transcribed")
                break
            }

            for entry in pass.entries() {
                collected.record(start: cursor + entry.start, text: entry.text)
            }
            AppleSpeechRecovery.trace?(String(
                format: "pass %d: %d utterance(s), settled through %.2fs of the %.2fs after %.2fs",
                passes, pass.count, pass.lastEnd, duration - cursor, cursor))
            guard pass.lastEnd > 0 else {
                // Nothing settled in this remainder. Usually that IS the
                // answer — trailing silence to the end of the file — but a
                // recogniser refusing under churn looks identical, so the
                // first empty pass per file gets one retry over the same
                // audio. The retry's cost is one redundant recognition of a
                // silent tail; its value is that "no speech" is only ever
                // declared twice.
                if !retriedEmptyPass {
                    retriedEmptyPass = true
                    retryPassOwed = true
                    AppleSpeechRecovery.trace?(
                        "pass \(passes) settled nothing; retrying that span once")
                    continue
                }
                break
            }
            cursor += pass.lastEnd
        }

        let joined = collected.joined()
        if joined.isEmpty { throw TranscriptionFailure.noSpeechDetected }
        if duration - cursor > Self.coverageSlack {
            AppleSpeechRecovery.trace?(String(
                format: "coverage gap: settled %.2f of %.2fs — returning what was heard",
                cursor, duration))
        }
        return TranscriptionResult(text: joined, finality: .recoveryForcedFinal, provider: name)
    }

    /// One recognition attempt over one file, returning every settled
    /// utterance (starts relative to that file). Extracted verbatim from the
    /// single-pass `transcribe` so the continuation loop above could exist.
    private func recognizePass(
        recognizer: SFSpeechRecognizer, fileAt url: URL, timeout: TimeInterval
    ) async throws -> Utterances {
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
            // recognition of a long recording can legitimately take a while —
            // the 12 Aug 27-minute file recognised in 119s, so the deadline
            // scales with the audio handed to this pass. It should never fire;
            // if it does, the caller records the reason and stops instead of
            // waiting for a callback that is not coming.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if resumed.claim() {
                    AppleSpeechRecovery.trace?("timed out after \(Int(timeout))s "
                        + "with no result and no error")
                    continuation.resume(throwing: TranscriptionFailure.providerUnavailable(
                        "recogniser never called back (\(Int(timeout))s)"))
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
                if !text.isEmpty, settled {
                    collected.record(start: start, end: end, text: text)
                }

                guard result.isFinal else { return }
                if resumed.claim() {
                    AppleSpeechRecovery.trace?(
                        "final: \(collected.count) utterance(s), \(collected.joined().count) chars")
                    continuation.resume(returning: collected)
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
        private var byStart: [Double: (end: Double, text: String)] = [:]
        private let lock = NSLock()

        func record(start: Double, text: String) {
            record(start: start, end: start, text: text)
        }

        /// `end` feeds the continuation loop: where the last settled utterance
        /// stopped is where the next recognition pass begins.
        func record(start: Double, end: Double, text: String) {
            lock.lock(); defer { lock.unlock() }
            // Rounded so floating-point jitter in a re-reported timestamp cannot
            // register the same utterance twice under two nearly-equal keys.
            byStart[(start * 100).rounded() / 100] = (end, text)
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return byStart.count }

        /// The furthest point any settled utterance reached, in this file's
        /// own timeline. Zero when nothing settled.
        var lastEnd: Double {
            lock.lock(); defer { lock.unlock() }
            return byStart.values.map(\.end).max() ?? 0
        }

        /// Settled utterances in spoken order.
        func entries() -> [(start: Double, end: Double, text: String)] {
            lock.lock(); defer { lock.unlock() }
            return byStart.keys.sorted().compactMap { start in
                byStart[start].map { (start, $0.end, $0.text) }
            }
        }

        func joined() -> String {
            lock.lock(); defer { lock.unlock() }
            return byStart.keys.sorted()
                .compactMap { byStart[$0]?.text }
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

    /// Whisper's DOCUMENTED upload cap is 25MB. The observed one is lower and
    /// enforced without a status code: measured 12 Aug against the incident's
    /// own 52MB WAV, a 9.6MB (5-minute) upload returned 200, while 15.4MB and
    /// 22MB uploads had the connection killed in under half a second — from
    /// curl exactly as from URLSession, so it is the server's edge, not this
    /// client. Slices therefore stay at 5 minutes, and anything over one
    /// slice's size is transcribed in slices cut at quiet points.
    /// PCM bytes per slice: 5 minutes at 16 kHz PCM16 mono.
    static let slicePCMBytes = 5 * 60 * 16000 * 2
    /// Files at or under one slice (plus WAV header slack) upload whole.
    static let maxUploadBytes = slicePCMBytes + 1024

    /// Where to cut a slice that must end near `target` (PCM byte offset):
    /// the start of the quietest 100ms in the 10 seconds before it, so the
    /// seam falls in a pause rather than mid-word. Falls back to `target`
    /// exactly when the search window is degenerate.
    static func sliceBoundary(
        pcm: Data, target: Int, sampleRate: Int = 16000
    ) -> Int {
        let window = 10 * sampleRate * 2
        let block = sampleRate * 2 / 10  // 100ms
        let searchStart = max(0, target - window)
        guard target <= pcm.count, target - searchStart >= block * 2 else {
            return min(target, pcm.count)
        }
        var quietest = target - block
        var quietestLoudness = Int.max
        var offset = searchStart
        while offset + block <= target {
            var loudness = 0
            pcm.subdata(in: offset..<(offset + block)).withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) {
                    loudness += Int(sample.magnitude)
                }
            }
            if loudness < quietestLoudness {
                quietestLoudness = loudness
                quietest = offset
            }
            offset += block
        }
        // Cut on a whole sample regardless of what the scan found.
        return quietest - (quietest % 2)
    }

    public func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
        guard let key = Secrets.read(.openAIAPIKey) else { throw TranscriptionFailure.notConfigured }
        guard let audio = try? Data(contentsOf: url) else { throw TranscriptionFailure.fileUnreadable }

        if audio.count <= Self.maxUploadBytes {
            let text = try await transcribeUpload(audio, key: key)
            return TranscriptionResult(text: text, finality: .recoveryForcedFinal, provider: name)
        }

        // Over the cap: decode to PCM and re-upload in slices under it. A
        // slice that fails throws, and the chain falls to the Apple floor —
        // better the floor's whole transcript than this rung's half of one.
        guard let pcm = BuddyPCM16Converter.pcm16Data(contentsOf: url) else {
            throw TranscriptionFailure.fileUnreadable
        }
        var texts: [String] = []
        var offset = 0
        while offset < pcm.count {
            let end = offset + Self.slicePCMBytes < pcm.count
                ? Self.sliceBoundary(pcm: pcm, target: offset + Self.slicePCMBytes)
                : pcm.count
            let wav = BuddyWAVBuilder.wavData(
                fromPCM16: pcm.subdata(in: offset..<end), sampleRate: 16000)
            texts.append(try await transcribeUpload(wav, key: key))
            offset = end
        }
        let text = texts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionFailure.noSpeechDetected }
        return TranscriptionResult(text: text, finality: .recoveryForcedFinal, provider: name)
    }

    /// One multipart upload of one complete audio file, returning its text.
    private func transcribeUpload(_ audio: Data, key: String) async throws -> String {
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
        // Long enough for a full slice: a 12-minute upload plus its
        // transcription comfortably outlives the old 60s.
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // upload(for:from:) rather than data(for:) with an httpBody — the
        // dedicated upload path for multi-megabyte bodies. And a thrown
        // transport error (a TLS abort mid-upload happened on the first
        // 22MB slice tried) becomes providerUnavailable rather than escaping
        // raw: the chain retries providerUnavailable with backoff, while an
        // unrecognised error type burns the rung in one attempt.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw TranscriptionFailure.fromTransport(error)
        }
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

        return text
    }
}
