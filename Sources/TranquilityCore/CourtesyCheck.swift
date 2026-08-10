import AVFoundation
import Foundation
import Speech

/// Listening for a moment before speaking, so the app does not talk over a human.
///
/// Ruled 08 Aug 2026 (docs/ruling-an-arrival-does-not-move-the-panel.md, ruling 3):
/// before an unprompted hail, check whether anyone is talking; if they are, hold.
/// "It's a courtesy thing. It's just listening before you talk."
///
/// ## Two properties this type exists to guarantee
///
/// **It cannot return words.** `WordCounter` yields an `Int?`, not a string, and
/// nothing in this file can produce text at an API boundary. That is deliberate:
/// the privacy question here does not get answered by a promise to discard the
/// transcript, it gets answered by there being no transcript to discard. Knowing
/// that someone is speaking never required knowing what they said.
///
/// This is a sharper rule than the app applies to dictation, on purpose.
/// `Transcription.trace` logs your words and the README says so — that is content
/// you asked the app to capture. Room audio taken to decide whether to say a
/// callsign is not, and does not get the same treatment.
///
/// **It never opens the microphone.** `assess` takes samples and returns a
/// verdict. Opening the device, timing the window and closing it is a thin shell
/// somewhere else. That is what makes the interesting behaviour a pure function
/// of a buffer, and therefore testable against fixtures instead of against
/// somebody standing in a room saying "seems right".
public struct CourtesyCheck: Sendable {

    /// What a few seconds of room audio amounted to. Carries no audio and no text.
    public struct Assessment: Sendable, Equatable {
        /// The verdict: someone is talking, hold the hail.
        public let speechDetected: Bool
        /// Raw RMS of the window, 0...1. Logged; never a verdict on its own.
        ///
        /// Deliberately NOT `Recorder.rms`'s scale. That one multiplies by 8 and
        /// clamps for a level meter, where saturating early is a feature — a bar
        /// that pins at loud reads fine. Here the number's only job is to let the
        /// log-only pass choose a threshold, and the first run of `tbase courtesy`
        /// showed why the meter scale cannot do that: noise at 0.3 amplitude, a
        /// pure tone at 0.4 and real speech all reported 1.0000, so a day of
        /// observations would have produced one value and no information.
        public let level: Float
        /// How many words came back. Never WHICH — see the type doc.
        /// Zero when the recogniser ran and heard none; nil when it did not run.
        public let wordCount: Int?
        /// Why, in the gate log's voice.
        public let reason: String
    }

    /// Counts words in a window without ever surfacing them.
    ///
    /// Injectable for the same reason `InterruptGate.Signals` is: a test that
    /// consults the machine is not testing the thing it claims to. With a stub
    /// counter the whole ladder below is deterministic; the real recogniser gets
    /// its own integration test that skips when unauthorised.
    ///
    /// Returns nil when the count could not be taken at all — no on-device model,
    /// no authorisation, recogniser unavailable. Nil is "I could not look", which
    /// the ladder treats differently from zero, "I looked and heard nobody".
    public struct WordCounter: Sendable {
        public var count: @Sendable (_ samples: [Int16], _ sampleRate: Double) async -> Int?

        public init(count: @escaping @Sendable (_ samples: [Int16], _ sampleRate: Double) async -> Int?) {
            self.count = count
        }

        /// Heard nobody. For tests about the ladder rather than about recognition.
        public static let silent = WordCounter { _, _ in 0 }
        /// Could not look. Exercises the degrade-to-speaking path.
        public static let unavailable = WordCounter { _, _ in nil }
        /// Heard someone.
        public static func hearing(_ words: Int) -> WordCounter { WordCounter { _, _ in words } }
    }

    /// Why the recogniser said no, when it says no.
    ///
    /// Added 10 Aug, because the failure that mattered was invisible by design:
    /// every recogniser error maps to nil ("could not look") and nil degrades to
    /// speaking, so a permanently broken recogniser and a permanently quiet room
    /// produce the same behaviour and nearly the same log line. `Transcription`
    /// carries the same hook for the same reason.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// How long the microphone stays open for one check.
    ///
    /// Long enough to span a pause between sentences, short enough that the hail
    /// still feels attached to the arrival that caused it. Every millisecond is a
    /// millisecond the recording indicator is lit with no user action behind it,
    /// which is the real budget being spent.
    ///
    /// Kept at 4s against a request for 2s, and the 09 Aug eval weakened rather
    /// than broke the argument: speech across 1.2–1.4s gaps WAS detected, so the
    /// pause failure is milder than predicted — but a shorter window still has
    /// strictly fewer chances to catch a word, and the errors are not symmetric.
    /// Also load-bearing against the intake tick, which is 5s: a window at or
    /// past it would let overlapping arrivals skip the check entirely, because
    /// `sampleRoom` returns nil while one is already running and nil degrades to
    /// speaking.
    public static let listenSeconds: TimeInterval = 4

    /// How long to wait for the recogniser before giving up on it.
    ///
    /// Generous relative to the work — recognising a four-second window
    /// on-device takes well under a second in every measurement so far — because
    /// this is a deadlock guard, not a latency target. It should never fire.
    static let recognitionTimeout: TimeInterval = 10

    /// RMS below which nothing audible arrived at all.
    ///
    /// A "did the device give us anything" guard, NOT a discriminator. It was the
    /// second one until 09 Aug, when the acoustic eval showed that job cost more
    /// than it bought:
    ///
    ///   speech far (vol 20)      level 0.0049  — discarded by the old 0.005 floor
    ///   speech very far (vol 10) level 0.0039  — discarded by the old 0.005 floor
    ///   quiet room               level 0.0030
    ///
    /// A talker across the room and an empty room were less than a factor of two
    /// apart and the threshold sat between them, so the filter was throwing away
    /// exactly the audio this feature exists to catch. The room floor moved too —
    /// 0.0010 on one run, 0.0030 on another — which makes any fixed absolute
    /// value fragile across rooms and hours.
    ///
    /// Its only justification was cost: do not wake the recogniser for an empty
    /// room. The same eval retired that from the other side. The recogniser
    /// rejected a pure tone at 0.2474 and broadband noise at 0.0238 — both far
    /// louder than speech it correctly caught at 0.0126 — so it does not
    /// false-positive on loudness, and there is nothing left for a pre-filter to
    /// protect against. Letting it arbitrate anything audible makes the code
    /// simpler and the detection better at once.
    ///
    /// So: low enough that a distant voice always reaches the recogniser, high
    /// enough that a dead-quiet room does not pay for recognition. The check runs
    /// once per arrival, not continuously — a second of CPU is not a budget worth
    /// losing a detection over.
    public var quietFloor: Float

    public var words: WordCounter

    public init(quietFloor: Float = 0.0005, words: WordCounter = .apple) {
        self.quietFloor = quietFloor
        self.words = words
    }

    /// The ladder, in order. Cheap first, and the verdict leans toward silence.
    ///
    /// The errors are not symmetric and the thresholds are set accordingly. A
    /// false positive — we think someone is talking, we hold — costs a delayed
    /// hail: the lamp is still green, the next tick tries again, nothing is lost.
    /// A false negative talks over somebody's sentence, which is the entire
    /// failure this exists to prevent. So a crude detector is adequate, and
    /// nobody should build a classifier here.
    public func assess(samples: [Int16], sampleRate: Double) async -> Assessment {
        let level = Self.rms(samples)

        // 1. Digital silence is a DEAD DEVICE, not a quiet room.
        //
        // No real microphone returns exactly zero over thousands of samples;
        // room tone, preamp hiss and the ADC's own noise floor guarantee some
        // energy. Exact zero means nothing arrived — a revoked permission (which
        // does not throw: AVAudioEngine starts happily and delivers zeros), or
        // the Bluetooth mic that opens and then sends silence, which this repo
        // has already met once and named in `StateLegend.noAudioMessage`.
        //
        // Found by the acoustic eval on 09 Aug: every stimulus, including
        // speech at full volume, reported level 0.0000 and "room is quiet".
        // The verdict was right by accident and the REASON was a lie, which is
        // the same defect as the kAFAssistantErrorDomain case below — and the
        // day anyone makes "could not look" mean hold, an unreadable device
        // would become permanent silence instead of degrading to speech.
        //
        // Same conclusion `Recorder.lastOpenSeconds` reaches from the other
        // side: a device that yields no samples cannot be told from a slip of
        // the thumb by looking at the buffer, so say which one you actually saw.
        if level == 0 {
            return Assessment(
                speechDetected: false, level: 0, wordCount: nil,
                reason: samples.isEmpty
                    ? "no samples — the device returned nothing"
                    : "digital silence over \(samples.count) samples — the microphone "
                        + "is dead or denied, not the room")
        }

        // 2. Nothing audible arrived. Skip the recogniser entirely.
        if level < quietFloor {
            return Assessment(
                speechDetected: false, level: level, wordCount: nil,
                reason: String(format: "silent room (level %.5f < floor %.5f)", level, quietFloor))
        }

        // 3. Loud enough that it might be a person. Ask whether it is.
        guard let heard = await words.count(samples, sampleRate) else {
            // Could not look. Degrade to today's behaviour rather than to
            // permanent silence: a user whose recogniser is unavailable still
            // wants to know their agent came back, and a check that can never
            // run must not turn into a hail that never fires.
            return Assessment(
                speechDetected: false, level: level, wordCount: nil,
                reason: String(format: "audible (level %.4f) but no recogniser — speaking anyway", level))
        }

        // 4. A person produces words; a fan does not. This is the discrimination
        //    the ruling asked for — "catch if we can get any words, or if it's
        //    just loud". A podcast produces words too and will hold the hail,
        //    which is the right degradation and needs no special case: talking
        //    over something you are listening to is the same discourtesy.
        if heard > 0 {
            return Assessment(
                speechDetected: true, level: level, wordCount: heard,
                reason: String(format: "speech detected (%d words, level %.4f)", heard, level))
        }
        return Assessment(
            speechDetected: false, level: level, wordCount: 0,
            reason: String(format: "audible but wordless (level %.4f) — noise, not a person", level))
    }

    /// Plain RMS over the window, 0...1, unscaled and unclamped.
    ///
    /// `Recorder.rms` is the same computation times 8 and clamped, because it
    /// drives a level meter. Do not copy that here: the multiplier saturates
    /// everything above ~0.125 to exactly 1.0, which is invisible in a meter and
    /// fatal to a threshold nobody has chosen yet.
    static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples {
            let v = Double(s) / 32768
            sum += v * v
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}

// MARK: - The real recogniser

extension CourtesyCheck.WordCounter {

    /// `SFSpeechRecognizer`, on-device, counting only.
    ///
    /// Costs no new permission: `AppleSpeechRecovery` already makes the
    /// recogniser the last provider in `RecoveryChain`, and
    /// `NSSpeechRecognitionUsageDescription` is already in the bundle
    /// (scripts/bundle.sh). The "three permissions reasoned better than four"
    /// question (bd9e71a / d0cf0ac) is not reopened by this.
    ///
    /// **The one line that must not be copied from `AppleSpeechRecovery`.**
    /// Transcription guards its on-device request as
    /// `if recognizer.supportsOnDeviceRecognition { requiresOnDeviceRecognition = true }`,
    /// so a machine without the local model silently uses the network. For
    /// dictation that is an accepted quality trade for words you chose to speak.
    /// Here it would mean shipping ambient room audio to Apple in order to decide
    /// whether to say a callsign, which inverts the entire point of the feature.
    /// So the guard is inverted: no on-device model means no recognition at all.
    public static let apple = CourtesyCheck.WordCounter { samples, sampleRate in
        // Authorisation, checked first and cheaply.
        //
        // Not because an unauthorised recogniser hangs — measured 10 Aug, it
        // does not; it errors like anything else. The guard is here because a
        // status check is free and an audio round-trip is not, and because it
        // gives the trace below something true to say instead of letting the
        // failure arrive as a generic error three seconds later.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            CourtesyCheck.trace?("speech recognition not authorised (status "
                + "\(SFSpeechRecognizer.authorizationStatus().rawValue)) — the check "
                + "cannot run, so the hail speaks")
            return nil
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            CourtesyCheck.trace?("no recogniser for en-US at all")
            return nil
        }
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            CourtesyCheck.trace?("recogniser unusable: available=\(recognizer.isAvailable) "
                + "onDevice=\(recognizer.supportsOnDeviceRecognition) "
                + "auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
            return nil
        }

        guard let buffer = CourtesyCheck.pcmBuffer(from: samples, sampleRate: sampleRate) else {
            CourtesyCheck.trace?("could not build a PCM buffer from \(samples.count) samples "
                + "at \(sampleRate)Hz")
            return nil
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        // Never the network. Unconditional, unlike the dictation path.
        request.requiresOnDeviceRecognition = true
        // Nothing downstream reads text, so partials would only be more chances
        // to hold words we have no use for.
        request.shouldReportPartialResults = false
        // No `contextualStrings`. The lexicon biases the recogniser toward THIS
        // app's callsigns, which is right for dictation and pointless here —
        // we are asking whether a human is audible, not who they are.
        request.append(buffer)
        request.endAudio()

        CourtesyCheck.trace?("recogniser starting on \(samples.count) samples")
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let resumed = OneShot()

            // The only unbounded wait in the hail path, so it gets a bound.
            //
            // `recognitionTask` resumes this on a final result or on an error,
            // and `endAudio()` above should guarantee one of them. "Should" is
            // the problem: if neither ever arrives the continuation never
            // resumes, the hail is lost with no log line, and the symptom is
            // "the app quietly stopped announcing" — the hardest class of bug to
            // attribute in a feature whose correct behaviour is often silence.
            //
            // Timing out to nil degrades to speaking, which is the same thing
            // every other "could not look" does.
            DispatchQueue.global().asyncAfter(deadline: .now() + CourtesyCheck.recognitionTimeout) {
                if resumed.claim() {
                    // Traced, because an untraced timeout is exactly the hole
                    // that made the 10 Aug investigation take all day: a nil
                    // with no explanation reads as "could not look" and is
                    // indistinguishable from every other could-not-look.
                    CourtesyCheck.trace?("recogniser timed out after "
                        + "\(Int(CourtesyCheck.recognitionTimeout))s — no result, no error")
                    continuation.resume(returning: nil)
                }
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    // Two very different failures arrive down one channel, and
                    // the first run of `tbase courtesy` proved it: noise and a
                    // pure tone both reported "no recogniser — speaking anyway"
                    // on a machine whose recogniser was working perfectly, and
                    // had just counted nine words in the row below.
                    //
                    // `kAFAssistantErrorDomain` 1110 is "no speech detected" —
                    // the recogniser ran, listened, and heard nobody. That is a
                    // VERDICT (0 words), not an outage. Reporting it as an
                    // outage is harmless while nil means "speak", and becomes a
                    // silent lie the day anyone makes nil mean "hold".
                    let ns = error as NSError
                    let heardNobody = ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110
                    CourtesyCheck.trace?("recogniser error: domain=\(ns.domain) "
                        + "code=\(ns.code) heardNobody=\(heardNobody) — \(ns.localizedDescription)")
                    if resumed.claim() { continuation.resume(returning: heardNobody ? 0 : nil) }
                    return
                }
                guard let result, result.isFinal else { return }
                // The ONLY thing read off the result. The transcription itself is
                // never touched, logged, or returned.
                let count = result.bestTranscription.segments.count
                if resumed.claim() { continuation.resume(returning: count) }
            }
        }
    }
}

extension CourtesyCheck {
    /// PCM16 mono to the float buffer the recogniser wants. In memory only —
    /// the courtesy check never writes audio anywhere, which is why this does not
    /// reuse `AppleSpeechRecovery`'s file-based `SFSpeechURLRecognitionRequest`.
    static func pcmBuffer(from samples: [Int16], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        for (i, s) in samples.enumerated() { channel[i] = Float(s) / 32768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// One-shot latch for a continuation a callback may reach more than once.
/// `Transcription` has its own `Resumed` for the same reason; that one is private
/// to the file and this target has no shared home for a four-line primitive.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
