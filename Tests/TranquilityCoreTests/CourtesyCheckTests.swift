import AVFoundation
import Speech
import XCTest
@testable import TranquilityCore

/// The courtesy check's ladder, and the gate order that keeps the microphone the
/// LAST question asked.
///
/// Everything here except the two integration tests at the bottom is deterministic
/// and hardware-free, which is the whole reason `assess` takes samples instead of
/// opening the device. See docs/courtesy-check-evidence-plan.md for the scenario
/// matrix these implement.
/// A flag a `@Sendable` counter closure may set. Swift 6 refuses a captured
/// `var` here, and threading the result out of the closure instead would stop
/// the test asserting the thing it is actually about: that the recogniser was
/// REACHED, not merely that the verdict came out right.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func raise() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class CourtesyCheckTests: XCTestCase {

    // MARK: - Signal fixtures, synthesised

    /// Digital silence.
    private func silence(seconds: Double = 1, rate: Double = 16000) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * rate))
    }

    /// Broadband noise at a given amplitude — a fan, traffic, a room.
    /// Seeded, so a failure is reproducible rather than a coin flip.
    private func noise(amplitude: Double, seconds: Double = 1, rate: Double = 16000) -> [Int16] {
        var state: UInt64 = 0x5DEECE66D
        return (0..<Int(seconds * rate)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53) * 2 - 1
            return Int16(max(-32767, min(32767, unit * amplitude * 32767)))
        }
    }

    /// A pure tone — loud, periodic, and unmistakably not a person.
    private func tone(hz: Double = 440, amplitude: Double = 0.4,
                      seconds: Double = 1, rate: Double = 16000) -> [Int16] {
        (0..<Int(seconds * rate)).map { i in
            let v = sin(2 * .pi * hz * Double(i) / rate) * amplitude
            return Int16(v * 32767)
        }
    }

    // MARK: - The level pre-filter

    func testSilenceIsQuietAndNeverWakesTheRecogniser() async {
        // A counter that fails the test if it is ever consulted: the empty room is
        // the common case, and paying for recognition on it would make the check
        // expensive exactly when it has nothing to find.
        let neverCalled = CourtesyCheck.WordCounter { _, _ in
            XCTFail("the recogniser must not run below the quiet floor")
            return 0
        }
        let check = CourtesyCheck(words: neverCalled)
        let assessment = await check.assess(samples: noise(amplitude: 0.0004), sampleRate: 16000)

        XCTAssertFalse(assessment.speechDetected)
        XCTAssertNil(assessment.wordCount, "nil is 'did not look', not 'heard nobody'")
        XCTAssertTrue(assessment.reason.contains("silent room"), assessment.reason)
    }

    /// A dead or denied microphone must not read as the quietest room in the
    /// world. Found by the acoustic eval, which reported level 0.0000 for speech
    /// at full volume and blamed the room.
    func testDigitalSilenceIsADeadDeviceNotAQuietRoom() async {
        let check = CourtesyCheck(words: .silent)
        let assessment = await check.assess(samples: silence(), sampleRate: 16000)

        XCTAssertFalse(assessment.speechDetected, "still degrades to speaking")
        XCTAssertNil(assessment.wordCount)
        XCTAssertTrue(assessment.reason.contains("dead or denied"), assessment.reason)
        XCTAssertFalse(assessment.reason.contains("silent room"),
                       "blaming the room for a dead device is the bug")
    }

    /// A real room floor — tiny but not zero — is a quiet ROOM, and must still
    /// take the cheap path without waking the recogniser.
    func testRoomToneIsAQuietRoomAndSkipsTheRecogniser() async {
        let neverCalled = CourtesyCheck.WordCounter { _, _ in
            XCTFail("the recogniser must not run below the quiet floor")
            return 0
        }
        let check = CourtesyCheck(words: neverCalled)
        let assessment = await check.assess(samples: noise(amplitude: 0.0004), sampleRate: 16000)

        XCTAssertGreaterThan(assessment.level, 0, "fixture must have a real floor")
        XCTAssertLessThan(assessment.level, check.quietFloor)
        XCTAssertTrue(assessment.reason.contains("silent room"), assessment.reason)
    }

    func testEmptyBufferIsQuietRatherThanACrash() async {
        let check = CourtesyCheck(words: .silent)
        let assessment = await check.assess(samples: [], sampleRate: 16000)
        XCTAssertFalse(assessment.speechDetected)
        XCTAssertEqual(assessment.level, 0)
    }

    /// Scenario 3, the one that justifies the feature's shape: a loud room with
    /// nobody in it is safe to speak into. If this ever flips, the check has
    /// become a mute switch that fires on air conditioning.
    func testLoudButWordlessSpeaks() async {
        let check = CourtesyCheck(words: .silent)
        let assessment = await check.assess(samples: noise(amplitude: 0.3), sampleRate: 16000)

        XCTAssertGreaterThan(assessment.level, check.quietFloor, "fixture must clear the floor")
        XCTAssertFalse(assessment.speechDetected)
        XCTAssertEqual(assessment.wordCount, 0, "the recogniser ran and heard nobody")
        XCTAssertTrue(assessment.reason.contains("noise, not a person"), assessment.reason)
    }

    func testToneIsAlsoNotAPerson() async {
        let check = CourtesyCheck(words: .silent)
        let assessment = await check.assess(samples: tone(), sampleRate: 16000)
        XCTAssertFalse(assessment.speechDetected)
    }

    /// The regression the 09 Aug acoustic eval bought: a distant voice must REACH
    /// the recogniser. Both far-speech rows measured 0.0039–0.0049 through air,
    /// and the old 0.005 floor discarded them unheard — which is precisely the
    /// failure this feature exists to prevent: a person across the room, and we
    /// talk over them.
    func testDistantSpeechLevelsReachTheRecogniser() async {
        let consulted = Flag()
        let counter = CourtesyCheck.WordCounter { _, _ in consulted.raise(); return 3 }
        let check = CourtesyCheck(words: counter)

        for measured in [Float(0.0039), Float(0.0049)] {
            consulted.reset()
            let amplitude = Double(measured) * 1.732  // rms of uniform noise = a/sqrt(3)
            let assessment = await check.assess(samples: noise(amplitude: amplitude),
                                                sampleRate: 16000)
            XCTAssertTrue(consulted.isRaised, "level \(measured) never reached the recogniser")
            XCTAssertTrue(assessment.speechDetected, assessment.reason)
        }
    }

    // MARK: - The verdict

    /// Scenario 2. One word is enough — the threshold is deliberately at the
    /// floor, because the asymmetry runs one way: a held hail costs a few
    /// seconds, talking over somebody costs the product.
    func testASingleWordHoldsTheHail() async {
        let check = CourtesyCheck(words: .hearing(1))
        let assessment = await check.assess(samples: noise(amplitude: 0.3), sampleRate: 16000)

        XCTAssertTrue(assessment.speechDetected)
        XCTAssertEqual(assessment.wordCount, 1)
        XCTAssertTrue(assessment.reason.contains("speech detected"), assessment.reason)
    }

    /// Scenario 8/13. The recogniser could not run — no on-device model, no
    /// authorisation. We speak, rather than falling permanently silent: a check
    /// that can never run must not become a hail that never fires.
    func testNoRecogniserDegradesToSpeaking() async {
        let check = CourtesyCheck(words: .unavailable)
        let assessment = await check.assess(samples: noise(amplitude: 0.3), sampleRate: 16000)

        XCTAssertFalse(assessment.speechDetected)
        XCTAssertNil(assessment.wordCount)
        XCTAssertTrue(assessment.reason.contains("no recogniser"), assessment.reason)
    }

    /// The type-level privacy guarantee, pinned so a later session cannot widen
    /// the API "just for logging". If this test needs changing, the change is the
    /// thing to argue about.
    func testAssessmentCarriesNoText() async {
        let check = CourtesyCheck(words: .hearing(4))
        let assessment = await check.assess(samples: noise(amplitude: 0.3), sampleRate: 16000)
        let mirror = Mirror(reflecting: assessment)
        for child in mirror.children where child.label != "reason" {
            XCTAssertFalse(child.value is String,
                           "\(child.label ?? "?") is a String — the assessment must not carry words")
        }
        XCTAssertEqual(assessment.wordCount, 4)
    }

    /// `AppleSpeechRecovery` refuses fast when the grant is missing, instead of
    /// entering the hang measured on 10 Aug — a provider that never returns keeps
    /// `RecoveryChain` from ever reaching its end, which is strictly worse than
    /// one that is unavailable.
    ///
    /// Skipped where the grant EXISTS, because there the provider is expected to
    /// work; the assertion is about the unauthorised machine, and pretending
    /// otherwise would make this a test that passes for the wrong reason.
    func testAppleRecoveryRefusesFastWithoutAuthorization() async throws {
        try XCTSkipIf(SFSpeechRecognizer.authorizationStatus() == .authorized,
                      "this asserts the UNauthorised path; the grant is present here")
        XCTAssertFalse(AppleSpeechRecovery().isConfigured,
                       "an unauthorised recogniser is not a configured provider")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-auth-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))

        let started = Date()
        do {
            _ = try await AppleSpeechRecovery().transcribe(fileAt: url)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                              "refusal must be immediate, not a timeout")
        }
    }

    // MARK: - RMS

    /// Raw and unsaturating — the property the meter scale does not have, and
    /// the reason the threshold can be tuned from the log at all.
    func testRMSIsRawAndDoesNotSaturate() {
        XCTAssertEqual(CourtesyCheck.rms([]), 0)
        XCTAssertEqual(CourtesyCheck.rms([0, 0, 0]), 0)
        // Full-scale square wave is the only thing that reaches 1.0.
        XCTAssertEqual(CourtesyCheck.rms([32767, -32767, 32767, -32767]), 1, accuracy: 0.001)
        // Meter scale would clamp both of these to exactly 1.0, which is what
        // made the first `tbase courtesy` run report one number for everything.
        let mid = CourtesyCheck.rms(noise(amplitude: 0.3))
        let loud = CourtesyCheck.rms(noise(amplitude: 0.6))
        XCTAssertLessThan(mid, 1)
        // Monotonic in amplitude, which is all any threshold needs of it.
        let quiet = CourtesyCheck.rms(noise(amplitude: 0.01))
        XCTAssertLessThan(quiet, mid)
        XCTAssertLessThan(mid, loud)
    }

    // MARK: - Gate order (scenario 5, 6, 9)

    private func gate(locked: Bool = false, front: String? = nil,
                      micInUse: Bool = false, idle: Double = 1000) -> InterruptGate {
        InterruptGate(minimumIdleSeconds: 8, signals: .init(
            idleSeconds: { idle }, frontmostApp: { front },
            screenLocked: { locked }, microphoneInUse: { micInUse }))
    }

    /// Scenario 5 — the case that ships broken today. Zoom is NOT frontmost, so
    /// `mutedApps` matches nothing; the device signal catches it anyway.
    func testBackgroundCallIsVetoedEvenThoughTheMutedListMissesIt() {
        let decision = gate(front: "Terminal", micInUse: true).evaluate()
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "microphone in use elsewhere")
        XCTAssertTrue(decision.heldForCourtesy, "this is the veto the panel explains")
    }

    /// Scenario 9 / the ordering rule: a locked screen is answered before the
    /// microphone is ever consulted. Asserted by making the mic signal fail the
    /// test if it is reached — the drill-in-a-unit-test for "the recording light
    /// must never come on over a lock screen".
    func testLockedScreenIsAnsweredBeforeTheMicrophoneIsConsulted() {
        let gate = InterruptGate(minimumIdleSeconds: 8, signals: .init(
            idleSeconds: { 1000 }, frontmostApp: { nil }, screenLocked: { true },
            microphoneInUse: {
                XCTFail("the microphone must not be consulted once a cheaper veto fired")
                return false
            }))
        XCTAssertFalse(gate.evaluate().allowed)
        XCTAssertEqual(gate.evaluate().reason, "screen is locked")
    }

    func testFrontmostMutedAppIsAnsweredBeforeTheMicrophone() {
        let gate = InterruptGate(minimumIdleSeconds: 8, signals: .init(
            idleSeconds: { 1000 }, frontmostApp: { "zoom.us" }, screenLocked: { false },
            microphoneInUse: {
                XCTFail("the microphone must not be consulted once a cheaper veto fired")
                return false
            }))
        XCTAssertEqual(gate.evaluate().reason, "muted app in front: zoom.us")
    }

    /// A call in progress outranks a recent keystroke: the mic veto is checked
    /// before idle time, so the reason a user reads is the true one.
    func testMicrophoneOutranksIdleTime() {
        let decision = gate(micInUse: true, idle: 0).evaluate()
        XCTAssertEqual(decision.reason, "microphone in use elsewhere")
    }

    func testQuiescentSignalsAllowSpeech() {
        let gate = InterruptGate(minimumIdleSeconds: 0, signals: .quiescent)
        let decision = gate.evaluate()
        XCTAssertTrue(decision.allowed)
        XCTAssertFalse(decision.heldForCourtesy)
    }

    /// Every other veto leaves `heldForCourtesy` false — only the microphone
    /// earns the explanation, because only it looks like "the agent never came
    /// back" from the outside.
    func testOnlyTheMicrophoneVetoIsExplainedToTheUser() {
        XCTAssertFalse(gate(locked: true).evaluate().heldForCourtesy)
        XCTAssertFalse(gate(front: "zoom.us").evaluate().heldForCourtesy)
        XCTAssertFalse(gate(idle: 0).evaluate().heldForCourtesy)
    }

    // MARK: - Integration: the real recogniser against real speech

    /// Speech synthesised by `say`, so the corpus is reproducible and committed as
    /// a command rather than as binary blobs, and so no real third party's voice
    /// is recorded into this repo.
    private func spokenSamples(_ text: String) throws -> [Int16] {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-courtesy-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--file-format=WAVE",
                         "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("`say` failed on this machine") }

        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { throw XCTSkip("could not allocate a read buffer") }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw XCTSkip("no channel data") }
        return (0..<Int(buffer.frameLength)).map { Int16(max(-1, min(1, channel[$0])) * 32767) }
    }

    private func requireRecogniser() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("speech recognition not authorised for the test binary")
        }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              r.isAvailable, r.supportsOnDeviceRecognition else {
            throw XCTSkip("no on-device recogniser on this machine")
        }
    }

    /// Scenario 2, end to end: a human-shaped waveform produces words.
    func testRealRecogniserHearsSpeech() async throws {
        try requireRecogniser()
        let samples = try spokenSamples("the quick brown fox jumps over the lazy dog")
        let assessment = await CourtesyCheck().assess(samples: samples, sampleRate: 16000)

        XCTAssertTrue(assessment.speechDetected, assessment.reason)
        XCTAssertGreaterThan(assessment.wordCount ?? 0, 0)
    }

    /// Scenario 3, end to end: the discrimination actually discriminates. This is
    /// the test that would catch a detector which simply fires on loudness.
    func testRealRecogniserDoesNotHearSpeechInNoise() async throws {
        try requireRecogniser()
        let assessment = await CourtesyCheck()
            .assess(samples: noise(amplitude: 0.3, seconds: 3), sampleRate: 16000)
        XCTAssertFalse(assessment.speechDetected, assessment.reason)
    }
}
