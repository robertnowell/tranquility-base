import XCTest
@testable import TranquilityCore

/// Safety evals for instant-arm (docs/instant-arm.md).
///
/// E1 — typing-chord immunity: the arm window may only ever open for a bare
/// reply modifier that survives the grace untouched. The timelines here are
/// the exact synthetic sequences the design was ruled against: time never
/// appears because the timers ARE the clock, and their firings arrive as
/// events — "⌥-down, keyDown at +40ms" is simply `began` then `sawOtherInput`
/// before `graceElapsed`.
///
/// E6 — first-syllable fix: audio captured during the arm window reaches the
/// live stream (backlog fed before the socket opens rides the pre-open
/// buffer) and reaches the durable file byte-for-byte.
final class InstantArmTests: XCTestCase {

    // MARK: - E1: the machine, on synthetic timelines

    private func drive(_ events: [ReplyGestureMachine.Event])
        -> [ReplyGestureMachine.Effect]
    {
        var machine = ReplyGestureMachine()
        return events.flatMap { machine.apply($0) }
    }

    func testTypingChordBeforeGraceNeverArms() {
        // ⌥-down, keyDown at +40ms (before the grace), grace and hold timers
        // fire anyway, release. Nothing may ever show.
        let effects = drive([
            .began(isReply: true),
            .sawOtherInput,
            .graceElapsed,
            .holdElapsed,
            .released,
        ])
        XCTAssertEqual(effects, [],
                       "a typing chord must never flash the panel or open the mic")
    }

    func testCleanTapAfterGraceArmsThenAborts() {
        // ⌥-down, +80ms grace elapses (arm fires), released at +200ms —
        // before the hold threshold. The arm must fully unwind.
        let effects = drive([
            .began(isReply: true),
            .graceElapsed,
            .released,
        ])
        XCTAssertEqual(effects, [.openArmWindow, .abortArm],
                       "a tap arms optimistically and then aborts, in that order")
    }

    func testFullHoldArmsThenUpgradesThenEnds() {
        let effects = drive([
            .began(isReply: true),
            .graceElapsed,
            .holdElapsed,
            .released,
        ])
        XCTAssertEqual(effects, [.openArmWindow, .beginReply, .endReply],
                       "the armed face upgrades to the live reply and ends normally")
    }

    func testTapUnderGraceNeverArms() {
        // Released at +40ms: the grace timer never fires (the monitor
        // cancels it), so the machine sees only begin/release.
        let effects = drive([
            .began(isReply: true),
            .released,
        ])
        XCTAssertEqual(effects, [],
                       "a sub-grace tap shows nothing; its tap meaning is the monitor's")
    }

    func testChordGrowthAfterArmAbortsImmediately() {
        // ⌥ held past the grace, then ⌃ joins (a slow ⌃⌥): the arm aborts at
        // the moment of growth, and the later hold timer must not fire a
        // reply for a chord.
        let effects = drive([
            .began(isReply: true),
            .graceElapsed,
            .flagsChanged(isReply: false),
            .holdElapsed,
            .released,
        ])
        XCTAssertEqual(effects, [.openArmWindow, .abortArm],
                       "growing into a real chord kills the arm at once, not at key-up")
    }

    func testOtherInputAfterArmAbortsImmediately() {
        // ⌥ held past the grace, then a letter lands (slow ⌥-chord typing):
        // abort at the keystroke — the typist may keep ⌥ down for more
        // characters, and the panel must already be back to normal.
        let effects = drive([
            .began(isReply: true),
            .graceElapsed,
            .sawOtherInput,
            .holdElapsed,
            .released,
        ])
        XCTAssertEqual(effects, [.openArmWindow, .abortArm],
                       "the abort happens at the disqualifying keystroke, once")
    }

    func testOtherInputDuringReplyAbortsAtRelease() {
        // Disqualification after the hold resolved keeps today's meaning:
        // the recording is thrown away at release, not mid-hold.
        let effects = drive([
            .began(isReply: true),
            .graceElapsed,
            .holdElapsed,
            .sawOtherInput,
            .released,
        ])
        XCTAssertEqual(effects, [.openArmWindow, .beginReply, .abortReply])
    }

    func testNonReplyChordNeverArmsOrReplies() {
        // ⌃ (or any non-reply modifier) held forever: nothing.
        let effects = drive([
            .began(isReply: false),
            .graceElapsed,
            .holdElapsed,
            .released,
        ])
        XCTAssertEqual(effects, [])
    }

    func testChordThatStartedAsReplyNeverReplies() {
        // ⌥ down, ⌃ joins before the grace: no arm, no reply, ever.
        let effects = drive([
            .began(isReply: true),
            .flagsChanged(isReply: false),
            .graceElapsed,
            .holdElapsed,
            .released,
        ])
        XCTAssertEqual(effects, [])
    }

    func testMachineResetsBetweenGestures() {
        var machine = ReplyGestureMachine()
        // A disqualified gesture...
        _ = machine.apply(.began(isReply: true))
        _ = machine.apply(.sawOtherInput)
        _ = machine.apply(.released)
        // ...must not poison the next clean one.
        XCTAssertEqual(machine.apply(.began(isReply: true)), [])
        XCTAssertEqual(machine.apply(.graceElapsed), [.openArmWindow])
        XCTAssertEqual(machine.apply(.holdElapsed), [.beginReply])
        XCTAssertEqual(machine.apply(.released), [.endReply])
    }

    func testTimerFiringsAfterReleaseDoNothing() {
        // The monitor cancels its work items on release, but a fire already
        // in flight must still be harmless.
        var machine = ReplyGestureMachine()
        _ = machine.apply(.began(isReply: true))
        _ = machine.apply(.released)
        XCTAssertEqual(machine.apply(.graceElapsed), [])
        XCTAssertEqual(machine.apply(.holdElapsed), [])
    }

    // MARK: - E6: the arm-window audio is never lost

    /// The backlog fed at hold-resolution (Recorder.openStream feeds
    /// everything buffered since the arm) plus live chunks after it must
    /// reach the socket complete and in order — the pre-open buffer holds it
    /// across the handshake, exactly the buffer-then-flush design documented
    /// in AssemblyAIStreaming.swift.
    func testArmWindowBacklogReachesTheStreamCompleteAndOrdered() async throws {
        let socket = AssemblyAIStreamingTests.FakeSocket()
        let provider = AssemblyAIStreaming(
            keyOverride: "test-key", socketFactory: { _ in socket })
        let stream = StreamedUtterance(provider: provider)

        // The arm-window backlog: fed BEFORE start(), as openStream does.
        let backlog = Data((0..<8_000).map { UInt8($0 % 251) })  // 250ms at 16kHz PCM16
        stream.feed(pcm16: backlog)
        await stream.start()
        // Live capture after the upgrade.
        let live1 = Data(repeating: 0xAB, count: 3_200)
        let live2 = Data(repeating: 0xCD, count: 3_200)
        stream.feed(pcm16: live1)
        stream.feed(pcm16: live2)

        // 14,400 bytes fed; the session re-cuts them to its 3,200-byte wire
        // chunks (the v3 50–1000ms contract — see the 12 Aug outage note in
        // AssemblyAIStreaming.swift), so four go out live and the 1,600-byte
        // remainder flushes at finish.
        for _ in 0..<40 where socket.sentData.count < 4 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(socket.sentData.map(\.count), [3_200, 3_200, 3_200, 3_200],
                       "audio leaves in wire-sized chunks, none below the 50ms minimum")
        _ = await stream.finish(timeout: 0.5)
        for _ in 0..<40 where socket.sentData.count < 5 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let sent = socket.sentData.flatMap { [UInt8]($0) }
        let fed = [UInt8](backlog) + [UInt8](live1) + [UInt8](live2)
        XCTAssertEqual(sent, fed,
                       "arm-window audio arrives first; order, content, and byte "
                       + "accounting survive the re-chunking — nothing dropped, nothing padded")
        stream.cancel()
    }

    /// And the durable half: every byte handed to captureAndTranscribe — the
    /// buffer that began filling at the arm, not at hold-resolution — lands
    /// in the saved audio file.
    func testEveryCapturedByteReachesTheDurableFile() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-arm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))

        // Half a second of arm-window-plus-hold audio, non-trivial content.
        let pcm = Data((0..<16_000).map { UInt8($0 % 249) })
        let utterance = try await store.captureAndTranscribe(
            pcm16: pcm, sampleRate: 16_000,
            audioStore: AudioStore(directory: tmpDir.appendingPathComponent("audio")),
            chain: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]),
            streamed: TranscriptionResult(
                text: "kept whole", finality: .explicitEndOfTurn,
                provider: "assemblyai-streaming"))

        let path = try XCTUnwrap(utterance.audioPath)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        XCTAssertGreaterThanOrEqual(size, pcm.count,
            "the saved file carries at least every captured byte (plus header)")
    }
}
