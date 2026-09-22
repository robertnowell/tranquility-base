import Foundation
import XCTest
@testable import TranquilityCore

/// A WAV as the microphone: 16 kHz mono PCM16, delivered in 20 ms frames at
/// real time, then silence so the bot's turn ends and it answers.
final class WAVAudioSource: ManagerAudioSource {
    private let pcm: Data
    private var task: Task<Void, Never>?
    init(wav: URL) throws {
        let data = try Data(contentsOf: wav)
        // A canonical 44-byte header; afconvert writes one.
        pcm = data.count > 44 ? data.subdata(in: 44..<data.count) : Data()
    }
    func start(onPCM16: @escaping @Sendable (Data) -> Void) throws {
        let pcm = self.pcm
        task = Task {
            let step = 640
            var i = 0
            while i < pcm.count, !Task.isCancelled {
                onPCM16(pcm.subdata(in: i..<min(i + step, pcm.count)))
                i += step
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let quiet = Data(count: step)
            for _ in 0..<600 where !Task.isCancelled {  // 12 s of silence
                onPCM16(quiet)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
    func stop() { task?.cancel() }
}

/// Counts what the socket plays instead of playing it.
final class CountingPlayer: PCMPlayer {
    var bytes = 0
    override func play(_ pcm16: Data) { bytes += pcm16.count }
    override func flush() {}
    override func stop() {}
}

final class ManagerSocketTests: XCTestCase {
    /// Against a running hosted bot (`TB_HOSTED=1 uv run bot.py -t websocket`),
    /// the socket must: deliver the event lines, answer a door request, and
    /// receive the manager's voice. Set TB_MANAGER_WS_URL and TB_MANAGER_WAV.
    func testSpokenQuestionRoundTrip() async throws {
        guard let url = ProcessInfo.processInfo.environment["TB_MANAGER_WS_URL"].flatMap(URL.init(string:)),
              let wav = ProcessInfo.processInfo.environment["TB_MANAGER_WAV"] else {
            throw XCTSkip("needs TB_MANAGER_WS_URL and TB_MANAGER_WAV")
        }
        let token = ProcessInfo.processInfo.environment["TB_MANAGER_TOKEN"]
        let player = CountingPlayer()
        let answered = AnsweredLog()
        let socket = ManagerSocket(
            session: ManagerSession(url: url, token: token),
            audio: try WAVAudioSource(wav: URL(fileURLWithPath: wav)),
            player: player
        ) { argv in
            answered.add(argv)
            if argv.count > 1, argv[1] == "targets" {
                return (0, "[{\"sessionId\":\"abc12345\",\"name\":\"Planning\",\"project\":\"p\",\"goal\":\"plan\"}]")
            }
            return (0, "{\"waiting\":[]}")
        }
        try socket.start()
        var events: [String] = []
        let deadline = Date().addingTimeInterval(40)
        for await line in socket.lines() {
            if let e = ManagerEvent.parse(line) { events.append(e.event.rawValue) }
            if events.contains("quiet") || Date() > deadline { break }
        }
        await socket.close()
        XCTAssertTrue(events.contains("ready"), "\(events)")
        XCTAssertTrue(events.contains("addressed"), "the name should open the gate: \(events)")
        XCTAssertTrue(events.contains("speaking"), "\(events)")
        XCTAssertFalse(answered.value.isEmpty, "the bot should have asked for a door")
        XCTAssertGreaterThan(player.bytes, 24_000 * 2, "its voice should have come down the wire")
    }
}

final class AnsweredLog: @unchecked Sendable {
    private var v: [[String]] = []
    private let lock = NSLock()
    var value: [[String]] { lock.lock(); defer { lock.unlock() }; return v }
    func add(_ argv: [String]) { lock.lock(); v.append(argv); lock.unlock() }
}

final class ManagerEventIdleTests: XCTestCase {
    /// The hosted bot's `idle` line parses with its seconds; the app reads
    /// it to stop rather than reconnect.
    func testIdleLineParses() {
        let line = Data(#"{"event":"idle","t":1790046000.0,"secs":1200}"#.utf8)
        let e = ManagerEvent.parse(line)
        XCTAssertEqual(e?.event, .idle)
        XCTAssertEqual(e?.secs, 1200)
    }
}

final class ManagerAvailabilityTests: XCTestCase {
    private func config(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hq-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// The three states HANDS-FREE can be in before it is pressed: a local
    /// command wins over hosted, hosted over the default checkout, and with
    /// none of them the placard reads SET UP HANDS-FREE.
    func testThreeStates() throws {
        let local = try config(#"{"manager":{"command":["/x/run.sh"],"hosted":{"start":"https://h/start","key":"pk"}}}"#)
        XCTAssertEqual(ManagerConfig.availability(config: local, fileExists: { _ in false }, signedIn: { true }), .local,
                       "a command in hq.json is the developer's own bot and wins over everything")
        let hosted = try config(#"{"manager":{"hosted":{"start":"https://h/start","key":"pk"}}}"#)
        XCTAssertEqual(ManagerConfig.availability(config: hosted, fileExists: { _ in true }, signedIn: { false }), .hosted)
        let none = try config(#"{"manager":{}}"#)
        XCTAssertEqual(ManagerConfig.availability(config: none, fileExists: { _ in true }, signedIn: { false }), .local, "the default checkout on disk is a local manager")
        XCTAssertEqual(ManagerConfig.availability(config: none, fileExists: { _ in false }, signedIn: { false }), .unset)
        let halfHosted = try config(#"{"manager":{"hosted":{"start":"https://h/start"}}}"#)
        XCTAssertEqual(ManagerConfig.availability(config: halfHosted, fileExists: { _ in false }, signedIn: { false }), .unset, "a hosted block without a key is not configured")
    }

    /// Signed in, the session is bought from the Gateway: that is the path
    /// every user has, and it beats the dev shim and the local checkout.
    func testSignedInBuysFromTheGateway() throws {
        let shim = try config(#"{"manager":{"hosted":{"start":"https://h/start","key":"pk"}}}"#)
        XCTAssertEqual(ManagerConfig.availability(config: shim, fileExists: { _ in true }, signedIn: { true }), .managed)
        let bare = try config(#"{"manager":{}}"#)
        XCTAssertEqual(ManagerConfig.availability(config: bare, fileExists: { _ in false }, signedIn: { true }), .managed)
    }
}

/// Voice processing is a preference with a fallback, and the fallback is the
/// whole safety story: a Mac that will not give us the unit must still have
/// hands-free, exactly as it did before.
final class VoiceProcessingTests: XCTestCase {
    private func config(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hq-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    func testOffUnlessAskedFor() throws {
        XCTAssertFalse(ManagerConfig.echoCancellation(config: try config(#"{"manager":{}}"#)))
        XCTAssertFalse(ManagerConfig.echoCancellation(config: try config(#"{}"#)))
        XCTAssertTrue(ManagerConfig.echoCancellation(config: try config(#"{"manager":{"echo_cancellation":true}}"#)))
    }

    /// The manager's voice has to be resampled from the wire's 24 kHz to
    /// whatever the unit runs at, or it plays at the wrong pitch and the
    /// canceller is subtracting a signal that does not match what was heard.
    func testResamplingKeepsTheLengthAndTheShape() {
        let tone = (0..<2400).map { sinf(2 * .pi * 200 * Float($0) / 24_000) }   // 100 ms at 24 kHz
        let up = VoiceProcessingAudio.resample(tone, from: 24_000, to: 48_000)
        XCTAssertEqual(up.count, 4800, "100 ms is 100 ms")
        XCTAssertEqual(Double(up.map { abs($0) }.max() ?? 0), 1.0, accuracy: 0.05, "and it is still a full-scale tone")
        let same = VoiceProcessingAudio.resample(tone, from: 24_000, to: 24_000)
        XCTAssertEqual(same, tone)
    }

    /// A line that is cut off has to stop now: flush drops what has not been
    /// rendered, which is what an interruption sounds like.
    func testFlushDropsTheRestOfTheLine() {
        let outgoing = VoiceProcessingAudio.Outgoing()
        outgoing.append([Float](repeating: 0.5, count: 1000))
        var buffer = [Float](repeating: 99, count: 10)
        buffer.withUnsafeMutableBufferPointer { out in
            outgoing.take(10, into: out.baseAddress!, stride: 1)
        }
        XCTAssertEqual(buffer.first, 0.5, "it was playing")
        outgoing.clear()
        buffer.withUnsafeMutableBufferPointer { out in
            outgoing.take(10, into: out.baseAddress!, stride: 1)
        }
        XCTAssertEqual(buffer, [Float](repeating: 0, count: 10), "and now it is silent, mid-line")
    }
}
