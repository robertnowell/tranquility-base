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

    /// Hold playback without ending it. `speak` stays suspended, so an announcement
    /// paused half-way is still in progress and still unread.
    func pause()
    func resume()
    var isPaused: Bool { get }
}

extension SpeechProvider {
    public func pause() {}
    public func resume() {}
    public var isPaused: Bool { false }
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

/// The slice of `AVSpeechSynthesizer` the provider actually touches, as a seam.
///
/// Exists so the completion tests can install a continuation without owning the
/// speakers: with the engine hard-coded, the only way to exercise `speak`'s
/// bookkeeping was to start real system speech, which made every `swift test`
/// audibly announce its test phrases and made the stop-before-start test a 20ms
/// race against engine startup. The bugs those tests pin live in the
/// continuation logic, not in the acoustics, so a silent spy is the honest
/// fidelity. (Compare TruncationTests, where playback TIMING is the property
/// under test and a real-but-silent WAV is the right level instead.)
protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}

/// `AVSpeechSynthesizer`. Free, offline, and the fastest to first audio — the
/// guaranteed floor, used whenever the network provider is unconfigured or fails.
/// It is not the default: see `SpeechChain` for why that changed after listening.
public final class SystemSpeechProvider: NSObject, SpeechProvider, @unchecked Sendable {
    public let name = "system"
    public let isConfigured = true

    private let synthesizer: SpeechSynthesizing

    /// The continuation is keyed to the utterance it is waiting on.
    ///
    /// It used to be a bare slot, and that is what made `speak` return before its
    /// own audio: `speak` calls `stop()` first, so the OUTGOING utterance's
    /// `didCancel` arrives *after* the incoming continuation has been installed, and
    /// resumed whichever one happened to be stored — the successor's. The caller
    /// then believed the announcement was over about 300ms in.
    ///
    /// Measured on 08 Aug: 4 of 4 ⌃⌃ pulls that interrupted live speech returned
    /// early and painted the grid four seconds into an eighteen-second rung, which
    /// kept talking for fourteen seconds after the card had gone. 0 of 50 pulls
    /// issued while nothing was speaking did.
    ///
    /// Identity comes from the delegate itself — every callback carries its
    /// utterance — so a stale one now resolves nothing rather than the wrong thing.
    private var pending: (utterance: AVSpeechUtterance, cont: CheckedContinuation<Void, Error>)?
    private var wordCallback: (@Sendable (Range<Int>) -> Void)?
    private let lock = NSLock()

    /// Measured with `say`: 25 words ≈ 9.9s at the default rate. A little above
    /// default keeps a 35-word summary near twelve seconds without sounding rushed.
    public var rate: Float
    public var voiceIdentifier: String?

    public convenience init(rate: Float = 0.52, voiceIdentifier: String? = nil) {
        self.init(rate: rate, voiceIdentifier: voiceIdentifier, synthesizer: AVSpeechSynthesizer())
    }

    /// Internal: tests pass a silent synthesizer here. Production always gets
    /// the real one via the convenience initializer above.
    init(rate: Float, voiceIdentifier: String?, synthesizer: SpeechSynthesizing) {
        self.rate = rate
        self.voiceIdentifier = voiceIdentifier
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
        stop()
        let utterance = AVSpeechUtterance(string: text.text)
        utterance.rate = rate
        // Resolved per utterance, not frozen at construction.
        //
        // The chain holds one provider for the life of the app and `speech` is a
        // `let`, so a voice chosen at construction could never change: picking a new
        // one from the menu would store the preference and keep speaking in the old
        // voice. An explicit `voiceIdentifier` still wins — that is how the previewer
        // auditions a row without disturbing the narrator.
        let chosen = voiceIdentifier ?? SystemVoiceCatalog.preferredIdentifier()
        if let chosen, let voice = AVSpeechSynthesisVoice(identifier: chosen) {
            utterance.voice = voice
        }
        // WHICH voice, on the record. The fallback exists so that a degraded read
        // still says who is talking, and nothing anywhere recorded whether it
        // used the session's assigned voice or the machine default — so the one
        // claim this path makes was the one thing unobservable in it. `assigned`
        // vs `default` is the whole distinction, so the line names which.
        ElevenLabsSpeechProvider.trace?(
            "system: speaking as \(chosen ?? "the synthesiser's own default")"
                + " (\(voiceIdentifier == nil ? "default" : "assigned"))")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            pending = (utterance, cont)
            wordCallback = onWord
            lock.unlock()
            synthesizer.speak(utterance)
        }
    }

    /// Stops whatever is speaking and always settles the waiter.
    ///
    /// The `guard synthesizer.isSpeaking` that used to open this was two bugs in one
    /// line: a stop landing between `synthesizer.speak()` and audio actually starting
    /// stopped nothing AND left the continuation unresumed, so the caller hung on an
    /// utterance it had asked to cancel. `stopSpeaking` is already a no-op when idle,
    /// so the guard bought nothing and cost the exit.
    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        resumeAny(with: .failure(SpeechError.interrupted))
    }

    /// Resume only if this callback belongs to the utterance we are waiting on.
    private func resume(_ utterance: AVSpeechUtterance, with result: Result<Void, Error>) {
        lock.lock()
        guard let waiting = pending, waiting.utterance === utterance else {
            // A callback from an utterance we already abandoned. Dropping it is the
            // whole fix: resuming here would settle the NEXT announcement's await.
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        settle(waiting.cont, result)
    }

    /// Settle the waiter whatever it is waiting on — used by `stop()`, which is a
    /// deliberate teardown rather than a callback about one particular utterance.
    private func resumeAny(with result: Result<Void, Error>) {
        lock.lock()
        let waiting = pending
        pending = nil
        lock.unlock()
        guard let waiting else { return }
        settle(waiting.cont, result)
    }

    private func settle(_ cont: CheckedContinuation<Void, Error>, _ result: Result<Void, Error>) {
        switch result {
        case .success: cont.resume()
        case .failure(let error): cont.resume(throwing: error)
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
        resume(utterance, with: .success(()))
    }

    public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume(utterance, with: .failure(SpeechError.interrupted))
    }
}

// MARK: - Prefetched audio

/// A rendered utterance: the audio, and the per-character start times that drive
/// the read-along highlight. Split out from `speak` so the network half can run
/// BEFORE anyone presses anything — see `ClipCache`.
public struct SpokenClip: Sendable {
    public let audio: Data
    /// Nil when the vendor returned no alignment; playback then runs without a
    /// highlight rather than failing.
    public let starts: [Double]?
}

/// Clips rendered ahead of the press, keyed by exactly what produced them.
///
/// Keyed by the full text, the voice and the model — not by session, and not by
/// any path or id. A path-keyed cache shipped stale narration once already
/// (video pipeline, 06 Aug): the file name matched while the words behind it had
/// moved on. Content IS the identity, so content is the key, and a summary that
/// changes by one word simply misses rather than speaking yesterday's sentence.
///
/// Bounded because a long session announces indefinitely: eight clips is the
/// announcement plus a full ladder plus slack, and the oldest is evicted rather
/// than letting a day of audio accumulate in memory.
actor ClipCache {
    private var entries: [(key: String, clip: SpokenClip)] = []
    /// Renders already running, so two presses in the same second cannot pay for
    /// the same clip twice — the second awaits the first instead of duplicating it.
    private var inFlight: [String: Task<SpokenClip, Error>] = [:]
    private let limit: Int

    init(limit: Int = 8) { self.limit = limit }

    static func key(text: String, voice: String?, model: String) -> String {
        "\(voice ?? "default")|\(model)|\(text)"
    }

    func cached(_ key: String) -> SpokenClip? {
        entries.first(where: { $0.key == key })?.clip
    }

    func store(_ clip: SpokenClip, for key: String) {
        entries.removeAll { $0.key == key }
        entries.append((key, clip))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// The clip for `key`, rendering it only if nobody already is. Callers that
    /// arrive mid-render await the same task, so a prefetch that is still in
    /// flight when the user presses is waited on rather than raced.
    func clip(for key: String, render: @escaping @Sendable () async throws -> SpokenClip) async throws -> SpokenClip {
        if let hit = cached(key) { return hit }
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await render() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let clip = try await task.value
        store(clip, for: key)
        return clip
    }

    func hasClip(for key: String) -> Bool { cached(key) != nil }
}

// MARK: - ElevenLabs (optional)

/// Nicer voice at the cost of a network round trip. Kept behind the same protocol so
/// it can be swapped in per preference; on any failure the caller falls back to the
/// system provider for that utterance only, never stickily.
public final class ElevenLabsSpeechProvider: NSObject, SpeechProvider, @unchecked Sendable {
    public let name = "elevenlabs"
    public var voiceId: String
    /// Per-utterance voice, set by the chain just before speaking. Sessions keep
    /// a durable voice of their own (ruled 05 Aug: ambient identity — the same
    /// session always sounds the same, which disambiguates two sessions on the
    /// same subject faster than any name). Nil = the user's selected voice.
    public nonisolated(unsafe) var voiceOverride: String?
    public var model: String
    /// Voice UX cares about sub-second starts, so this is far tighter than a normal
    /// network timeout — past this we are better off speaking in a plainer voice.
    /// NOTE: this is URLSession's inactivity timeout and does NOT bound the call;
    /// `foregroundDeadline` is what actually does. Kept because it still cuts off
    /// a connection that stalls completely.
    public var timeout: TimeInterval
    /// Wall-clock budget when somebody is standing there waiting. Past this the
    /// system voice is strictly better than more silence: four seconds is the
    /// measured point where a wait stops reading as "loading" and starts reading
    /// as "broken", and the p90 render is one second, so this costs the good
    /// voice almost nothing.
    public var foregroundDeadline: TimeInterval
    /// Nobody is waiting on a prefetch, so it gets room to finish on a bad link
    /// rather than burning the request and re-paying for it at press time.
    public var prefetchDeadline: TimeInterval

    // private(set), not private: the truncation tests stage a GENUINE truncation
    // by stopping the transport mid-play without bumping the generation — which
    // is what a route change looks like, and the one direction a pure-function
    // test cannot cover. You cannot stage it with a lying WAV header; the player
    // recomputes `duration` from the bytes actually present (measured).
    private(set) var player: AVAudioPlayer?

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
        voiceId: String = VoiceCatalog.selectedVoiceId,
        model: String = "eleven_flash_v2_5",
        timeout: TimeInterval = 3,
        foregroundDeadline: TimeInterval = 4,
        prefetchDeadline: TimeInterval = 20
    ) {
        self.voiceId = voiceId
        self.model = model
        self.timeout = timeout
        self.foregroundDeadline = foregroundDeadline
        self.prefetchDeadline = prefetchDeadline
    }

    public var isConfigured: Bool {
        let key = Secrets.read(.elevenLabsAPIKey)
        if key == nil {
            ElevenLabsSpeechProvider.trace?("isConfigured=false: no key readable")
        }
        return key != nil
    }
    public var isSpeaking: Bool { player?.isPlaying ?? false }

    /// Render an utterance to audio WITHOUT playing it.
    ///
    /// Separated from `speak` so the whole network cost can be paid before the
    /// user asks. Nothing here touches the generation counter or the player: a
    /// prefetch has no claim on the speakers and must be invisible to whatever
    /// is currently talking.
    ///
    /// `deadline` is the real one. `timeoutInterval` is URLSession's INACTIVITY
    /// timeout, not a total budget — a connection trickling bytes resets it
    /// forever, which is exactly how the three-second fallback to the system
    /// voice became unreachable on the slow links it was written for (measured:
    /// an eleven-second ladder fetch that never once fell back). A wall-clock
    /// race is the only thing that bounds it.
    public func synthesize(
        _ text: SanitizedSpokenText, voice: String?, deadline: TimeInterval
    ) async throws -> SpokenClip {
        guard let key = Secrets.read(.elevenLabsAPIKey) else { throw SpeechError.notConfigured }
        let model = self.model

        // The /with-timestamps variant returns per-character start times alongside the
        // audio, which is the only way to follow along with a pre-rendered clip.
        var request = URLRequest(
            url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/"
                     + "\(voice ?? VoiceCatalog.selectedVoiceId)/with-timestamps")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text.text,
            "model_id": model,
        ])

        let started = Date()
        let sending = request
        let (data, response) = try await Self.withDeadline(deadline) {
            try await URLSession.shared.data(for: sending)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // ElevenLabs explains itself in the body: invalid_api_key, quota
            // exceeded, and detected_unusual_activity are all 401 and all mean
            // different things. Throwing away the body left "http 401" as the whole
            // diagnosis, which is why this took three rounds to get anywhere.
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ").prefix(300) ?? ""
            ElevenLabsSpeechProvider.trace?("http \(code) body=\(body)")
            throw SpeechError.synthesisFailed("http \(code): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base64 = json["audio_base64"] as? String,
              let audioData = Data(base64Encoded: base64)
        else { throw SpeechError.synthesisFailed("unexpected response shape") }

        let starts = (json["alignment"] as? [String: Any])?["character_start_times_seconds"] as? [Double]
        // Throughput, not just duration: this is the line that tells a slow link
        // apart from a slow vendor, which nothing in the log could do before.
        let elapsed = Date().timeIntervalSince(started)
        ElevenLabsSpeechProvider.trace?(String(
            format: "synth %.2fs %dkB (%.0f kB/s) starts=%d chars=%d",
            elapsed, audioData.count / 1024,
            Double(audioData.count) / 1024 / max(elapsed, 0.001),
            starts?.count ?? -1, text.text.count))
        return SpokenClip(audio: audioData, starts: starts)
    }

    /// Fail the whole attempt at a wall-clock bound, cancelling the request.
    /// `URLSession.data(for:)` honours task cancellation, so losing the race
    /// tears the connection down rather than leaving it to land unheard.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SpeechError.synthesisFailed(
                    String(format: "no audio after %.1fs", seconds))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw SpeechError.synthesisFailed("deadline race produced nothing")
            }
            return first
        }
    }

    public func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
        let clip = try await synthesize(
            text, voice: voiceOverride, deadline: foregroundDeadline)
        try await play(clip, text: text, onWord: onWord)
    }

    /// Play an already-rendered clip. This is the half a prefetch skips, and the
    /// only half that owns the speakers — so the generation check lives here.
    public func play(
        _ clip: SpokenClip, text: SanitizedSpokenText,
        onWord: (@Sendable (Range<Int>) -> Void)?
    ) async throws {
        let mine = currentGeneration()
        let audioData = clip.audio
        let starts = clip.starts
        guard mine == currentGeneration() else { throw SpeechError.interrupted }

        // Keep the last N spoken files on disk (Robert, 06 Aug: the first
        // syllable of hails sounds clipped, and with playback running straight
        // from memory there was nothing to listen to after the fact — no way
        // to tell generated-clipped from playback-clipped). Same 0700 boundary
        // as everything else; pruned, so it can never become model-calls.
        // Archived at PLAYBACK, not synthesis: the folder is a record of what
        // was heard, and a prefetched clip nobody listened to is not that.
        SpokenAudioArchive.keep(audioData, label: text.text)

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

        // One loop for both modes, and it MEASURES while it waits.
        //
        // Completion is measured while playing, never re-read after the fact —
        // the same rule as "interruption is caused, not inferred", applied to the
        // axis it was missing from. AVAudioPlayer's post-terminal state is
        // bit-identical to its pre-initial state: on natural completion
        // `currentTime` resets to 0 (measured 08 Aug: a 16.379s archived clip read
        // 0.000 after finishing), so a check that re-reads the player after the
        // loop calls every COMPLETED announcement truncated at 0s — under 2s, so
        // the chain restarted it from the top in the system voice. That is the
        // ElevenLabs-then-robot double-read, and it was this read, not the 0.25s
        // tolerance blamed for it on 02 Aug.
        //
        // So the loop keeps a high-water mark. `max` rather than last-sampled: a
        // resetting `currentTime` can only be ignored, never believed. Poll at
        // 125ms only when there is a highlight to drive; ~8/s is past what the eye
        // resolves, and 40ms was needless CPU for a cosmetic effect.
        let interval: UInt64 = (starts != nil && onWord != nil) ? 125_000_000 : 200_000_000
        var played = 0.0
        var lastIndex = -1
        while audio.isPlaying || isPaused {
            let now = audio.currentTime
            played = max(played, now)
            // The resume half of the pause latch: `resume()` only restarts the
            // player, and the latch drops HERE, once playback is observed
            // running again. See `resume()` for the window this closes.
            if isPaused, audio.isPlaying {
                generationQueue.sync { pausedByUser = false }
            }
            if let starts, let onWord {
                // Character index whose start time has just passed.
                var index = lastIndex
                while index + 1 < starts.count, starts[index + 1] <= now { index += 1 }
                if index != lastIndex, index >= 0 {
                    lastIndex = index
                    ElevenLabsSpeechProvider.trace?("onWord upTo=\(index + 1) t=\(now)")
                    onWord(0..<min(index + 1, text.text.count))
                }
            }
            try await Task.sleep(nanoseconds: interval)
        }
        played = max(played, audio.currentTime)
        try Self.checkForTruncation(
            played: played, duration: audio.duration,
            generation: mine, current: currentGeneration())
    }

    /// Playback that ends early with the generation unchanged was not stopped by
    /// anyone — that is a failure, and it should not be reported as your choice.
    ///
    /// A pure function of measured facts, deliberately: it takes seconds, not the
    /// player, so it CANNOT re-read state the player has already reset — and so a
    /// test can pin both directions without a speaker. `played` must be a
    /// high-water mark sampled while `isPlaying` was true.
    static func checkForTruncation(
        played: Double, duration: Double, generation mine: Int, current: Int
    ) throws {
        guard mine == current else { throw SpeechError.interrupted }
        // 0.75s: must exceed the largest poll interval (200ms, the no-highlight
        // branch — raising that poll past ~350ms silently erodes this margin),
        // plus Task.sleep overshoot and format rounding on `duration`. Measured
        // worst-case shortfall across ten completions, four of them real archived
        // ElevenLabs MP3s: 0.105s. Loose on purpose — a false truncation is the
        // double-read, a missed one loses under 0.75s of tail.
        let remaining = duration - played
        guard remaining > 0.75 else { return }
        throw SpeechError.truncated(playedSeconds: played, ofSeconds: duration)
    }

    /// Audio teardown, off the caller's thread.
    ///
    /// `AVAudioPlayer.stop()` is not the cheap local call it looks like: it reaches
    /// into AudioToolbox, which takes the audio queue's dispatch queue, which can
    /// be held by a `play()` that is itself blocked in an IPC to `coreaudiod`.
    /// Every `stop()` call site in the app is on the main actor, so when that
    /// happens the main thread stops forever.
    ///
    /// Measured 28 Aug, from a live `sample` of a wedged instance — not a crash,
    /// a deadlock, and the reason the microphone appeared dead (the push-to-talk
    /// handler could not run):
    ///
    ///     main thread  AppDelegate.handle -> SpeechChain.stop -> AVAudioPlayer.stop
    ///                  -> AudioQueueGetCurrentTime -> dispatch_sync -> kevent_id
    ///     AQServer     announceNext -> play -> AVAudioPlayer.play -> AudioQueueStart
    ///                  -> HAL_defaultDeviceOutputType -> mach_msg   (waiting on
    ///                     coreaudiod for the default output device)
    ///     AQClient     AudioPlayerAQOutputCallback -> psynch_mutexwait
    ///
    /// All three at 2547/2547 samples. `play()` held the queue while waiting on a
    /// default-device lookup, and `stop()` waited on the queue behind it.
    private static let teardownQueue = DispatchQueue(label: "elevenlabs.teardown")

    public func stop() {
        // The LOGICAL cancel stays synchronous and ordered: bumping the generation
        // is what actually abandons in-flight synthesis, and it must have happened
        // by the time this returns or a response landing a moment later would play
        // over whatever started next. It touches only our own queue and cannot
        // block on CoreAudio.
        bumpGeneration()
        let dying = player
        player = nil
        // A stop ends the pause too, or the next playback would start "paused" and
        // its loop would spin on a flag nobody set.
        generationQueue.sync { pausedByUser = false }
        // Only the AUDIO teardown moves off the caller. Serial, so stops stay
        // ordered among themselves. In the healthy case this costs microseconds
        // and nothing is audible; in the wedged case the app survives instead of
        // freezing, which is the whole trade.
        if let dying { Self.teardownQueue.async { dying.stop() } }
    }

    /// Recorded, not inferred.
    ///
    /// This used to be `player != nil && !player.isPlaying`, which cannot tell "the
    /// user paused it" from "it finished" — `player` is cleared only in `stop()`, so
    /// the moment playback ended naturally the flag latched true and stayed true.
    /// The playback loops below wait on `isPlaying || isPaused`, so they never exited:
    /// `speak` never returned, `Coordinator` never saw `completed`, and the heard
    /// cursor was never advanced. Invisible whenever ElevenLabs is unconfigured,
    /// because the system voice resumes its continuation from `didFinish` instead.
    ///
    /// Pausing is a user intent, so it is stored when the user expresses it rather
    /// than guessed from a player state that two different situations share.
    public var isPaused: Bool { generationQueue.sync { pausedByUser } }
    private var pausedByUser = false

    /// AVAudioPlayer keeps `currentTime` across a pause, so resuming continues from
    /// where it stopped rather than starting the summary over.
    public func pause() {
        guard player?.isPlaying == true else { return }
        generationQueue.sync { pausedByUser = true }
        player?.pause()
    }

    /// Restart the player, and leave the pause latch to the playback loop.
    ///
    /// Clearing `pausedByUser` here — which is what this did — opens a window
    /// the loop can wake inside: `play()` returns before `isPlaying` flips (the
    /// same lag `play(_:text:onWord:)` already waits out at the start), so for
    /// a few milliseconds the loop sees neither a playing player nor a paused
    /// one, exits, and calls a clip you are still listening to `truncated` at
    /// wherever you paused it. Under the read ruling that is a `failure`, so a
    /// pause-and-resume would leave the turn unread and paint "Playback
    /// failed" over an announcement that never stopped.
    ///
    /// Found by a test that had been flaky for days (issue 16) and only became
    /// diagnostic once it stopped racing on the wall clock: the payload was
    /// always exactly the pause point.
    ///
    /// So the latch stays TRUE across the whole transition and the loop clears
    /// it the moment it observes playback actually running — the same
    /// "measured, not assumed" rule the truncation check itself is built on.
    public func resume() {
        player?.play()
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
    /// Chain-wide stop counter.
    ///
    /// The ElevenLabs provider had one, so audio arriving after a stop was
    /// discarded. The system voice did not, so a stop during the network round trip
    /// silenced nothing and the fallback then read the whole thing aloud — a second
    /// voice, arriving late, over whatever had started since. Putting the counter on
    /// the chain covers both providers and every path between them.
    final class Generation: @unchecked Sendable {
        private let queue = DispatchQueue(label: "speechchain.generation")
        private var value = 0
        var current: Int { queue.sync { value } }
        func bump() { queue.sync { value += 1 } }
    }

    let generation = Generation()
    public let preferred: (any SpeechProvider)?
    public let fallback: any SpeechProvider
    /// Shared by every path that speaks, so a clip rendered by `prewarm` is the
    /// same object `speak` finds. Lives on the chain rather than the provider
    /// because the chain is what both the announcement and the ⌃⌃ ladder hold.
    let clips = ClipCache()

    public init(
        preferred: (any SpeechProvider)? = ElevenLabsSpeechProvider(),
        // Bare: the provider resolves the preferred voice per utterance, so a voice
        // chosen from the menu takes effect on the next announcement rather than the
        // next launch.
        fallback: any SpeechProvider = SystemSpeechProvider()
    ) {
        self.preferred = preferred
        self.fallback = fallback
    }

    /// Render an utterance now so a later `speak` of the SAME text in the SAME
    /// voice plays instantly. Best-effort by construction: it returns a Bool for
    /// logging and swallows everything else, because a failed prefetch must cost
    /// nothing but a re-render at press time.
    ///
    /// Silently a no-op unless the preferred provider is ElevenLabs — the system
    /// voice has no network half to pay in advance.
    @discardableResult
    public func prewarm(_ text: SanitizedSpokenText, voice: String? = nil) async -> Bool {
        guard let eleven = preferred as? ElevenLabsSpeechProvider, eleven.isConfigured else {
            return false
        }
        // Same guard as `speak`, and it belongs here independently: the 400 that
        // exposed this arrived from a PREWARM, not from a live announcement, so the
        // speculative path reaches ElevenLabs before any gesture does. Paying a
        // network round trip to render a voice this session will not use would be
        // wrong even if the id were valid.
        if voice.map(SystemVoiceCatalog.isSystemVoice) ?? false { return false }
        let key = ClipCache.key(
            text: text.text, voice: voice ?? VoiceCatalog.selectedVoiceId, model: eleven.model)
        if await clips.hasClip(for: key) { return true }
        do {
            _ = try await clips.clip(for: key) {
                try await eleven.synthesize(
                    text, voice: voice, deadline: eleven.prefetchDeadline)
            }
            ElevenLabsSpeechProvider.trace?("prewarm: ready (\(text.text.count) chars)")
            return true
        } catch {
            ElevenLabsSpeechProvider.trace?("prewarm: failed \(error)")
            return false
        }
    }

    public var isSpeaking: Bool {
        (preferred?.isSpeaking ?? false) || fallback.isSpeaking
    }

    public var isPaused: Bool { (preferred?.isPaused ?? false) || fallback.isPaused }

    /// Pause and resume, so stopping to think does not cost you the announcement.
    /// Toggling is one call because the caller has one button and one chord.
    public func togglePause() {
        if isPaused {
            preferred?.resume()
            fallback.resume()
        } else {
            preferred?.pause()
            fallback.pause()
        }
    }

    /// Cut speech off immediately. A tap while it is talking means "stop", and a
    /// voice you cannot interrupt is worse than one you have to summon.
    public func stop() {
        generation.bump()
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
        /// Whether any audio actually reached the speakers. Starting to talk counts
        /// as read — but an announcement that never made a sound was not read, and
        /// that distinction is what keeps a silent failure from being marked
        /// delivered and from handing the reply to an older session.
        public var heardAny: Bool = false
    }

    @discardableResult
    public func speak(
        _ text: SanitizedSpokenText, voice: String? = nil,
        systemVoice: String? = nil,
        onWord: (@Sendable (Range<Int>) -> Void)? = nil
    ) async -> Spoken {
        // Every session has TWO voices: the ElevenLabs voice it speaks in, and the
        // system voice it falls back to. ElevenLabs is used whenever it is
        // available; the system voice is a redundancy, not a preference, so this
        // is not a mode switch and there is no state to get wrong.
        //
        // The one hard rule is that a system identifier is never handed to
        // ElevenLabs as a voice id. That is what a single mixed roster did — the
        // settings pane listed both families and its toggle appended any checked
        // id to the one roster — and it cost an HTTP 400 `invalid_uid` on
        // `com.apple.ttsbundle.siri_Nicky_en-US_premium` every five seconds,
        // indefinitely, per prewarm.
        //
        // A system id arriving in `voice` is legacy data from that era. It is read
        // as the FALLBACK voice rather than discarded: the id is a real voice the
        // user checked, it just is not a cloud one.
        let cloudVoice = voice.flatMap { SystemVoiceCatalog.isSystemVoice($0) ? nil : $0 }
        let ownSystemVoice = systemVoice
            ?? voice.flatMap { SystemVoiceCatalog.isSystemVoice($0) ? $0 : nil }
        // Both set every call, never conditionally: staleness is impossible when
        // the override's whole lifetime is one utterance.
        (preferred as? ElevenLabsSpeechProvider)?.voiceOverride = cloudVoice
        // The session's OWN fallback voice, so a degraded read still says who is
        // talking. Before this the fallback used one machine-wide default, and
        // every session that fell back became the same person.
        (fallback as? SystemSpeechProvider)?.voiceIdentifier = ownSystemVoice
        // The narrow case where the cloud is skipped even though it is available:
        // this session has NO cloud voice but does have a system one. That is a
        // legacy row from the single-roster era, and reaching for ElevenLabs here
        // would render in the provider's default voice — a stranger, rather than
        // the agent you have been listening to. Identity beats fidelity.
        //
        // Not a preference and not sticky: once the migration re-mints the pair,
        // `cloudVoice` is present and the cloud is used like everywhere else.
        let sessionHasNoCloudVoice = cloudVoice == nil && ownSystemVoice != nil
        var degraded: String?
        var heardAny = false
        // Anything that happens after a stop belongs to an announcement the user
        // already dismissed. Checked before each provider, because the expensive
        // part is the gap between them.
        let mine = generation.current
        guard mine == generation.current else {
            return Spoken(provider: "none", completed: false)
        }
        if let preferred, preferred.isConfigured, !sessionHasNoCloudVoice {
            do {
                ElevenLabsSpeechProvider.trace?("chain: trying \(preferred.name)")
                if let eleven = preferred as? ElevenLabsSpeechProvider {
                    // Through the cache, so a prefetched clip plays with no
                    // network at all — and a press that lands DURING a prefetch
                    // awaits that same render instead of starting a second one.
                    let key = ClipCache.key(
                        text: text.text, voice: voice ?? VoiceCatalog.selectedVoiceId,
                        model: eleven.model)
                    let warm = await clips.hasClip(for: key)
                    ElevenLabsSpeechProvider.trace?("chain: clip \(warm ? "HIT" : "miss")")
                    let clip = try await clips.clip(for: key) {
                        try await eleven.synthesize(
                            text, voice: voice, deadline: eleven.foregroundDeadline)
                    }
                    try await eleven.play(clip, text: text, onWord: onWord)
                } else {
                    try await preferred.speak(text, onWord: onWord)
                }
                return Spoken(provider: preferred.name, completed: true, heardAny: true)
            } catch SpeechError.interrupted {
                // Stopped on purpose, part-way through. It was being spoken, so it
                // counts as read.
                return Spoken(provider: preferred.name, completed: false, heardAny: true)
            } catch SpeechError.truncated(let played, let total) {
                heardAny = played > 0
                // Only start over if you effectively heard nothing. Re-reading a
                // whole summary in the mechanical voice after you already sat
                // through most of it is worse than the truncation — that is the
                // "ElevenLabs, then immediately the robot voice" double-read.
                guard played < 2 else {
                    return Spoken(
                        provider: preferred.name, completed: false,
                        failure: String(format: "cut off at %.0fs of %.0fs", played, total),
                        heardAny: true)
                }
                degraded = String(format: "no audio (stopped at %.0fs of %.0fs)", played, total)
            } catch SpeechError.synthesisFailed(let reason) where reason.contains("401") {
                ElevenLabsSpeechProvider.trace?("chain: 401 from elevenlabs: \(reason)")
                degraded = "ElevenLabs returned 401"
            } catch is CancellationError {
                // Cancellation is not a voice failure. Treating it as one read a
                // cancelled announcement aloud in the system voice (app.log
                // 20 Aug 14:13:50); like the stop guard below, stay silent —
                // nothing was heard, so nothing is marked read.
                ElevenLabsSpeechProvider.trace?("chain: cancelled; staying silent")
                return Spoken(provider: "none", completed: false, heardAny: heardAny)
            } catch {
                degraded = "\(error)"
                ElevenLabsSpeechProvider.trace?("chain: \(preferred.name) failed: \(error)")
                // fall through to the system voice for this utterance only
            }
        } else {
            ElevenLabsSpeechProvider.trace?(
                "chain: preferred unavailable (configured=\(preferred?.isConfigured ?? false))")
        }
        guard mine == generation.current else {
            // Stopped while the preferred voice was still working. Falling back now
            // would speak an announcement that was cancelled several seconds ago.
            ElevenLabsSpeechProvider.trace?("chain: stopped before fallback; staying silent")
            return Spoken(provider: "none", completed: false, heardAny: heardAny)
        }
        ElevenLabsSpeechProvider.trace?("chain: falling back to \(fallback.name)")
        do {
            try await fallback.speak(text, onWord: onWord)
            // Heard, in the plainer voice. Not a failure — a degradation, reported
            // so an outage cannot hide behind a robotic voice you assume is normal.
            return Spoken(provider: fallback.name, completed: true,
                          degraded: degraded, heardAny: true)
        } catch SpeechError.interrupted {
            return Spoken(provider: fallback.name, completed: false, heardAny: true)
        } catch {
            return Spoken(provider: fallback.name, completed: false,
                          failure: "\(error)", heardAny: heardAny)
        }
    }
}
