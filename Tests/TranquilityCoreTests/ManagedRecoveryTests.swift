import XCTest
@testable import TranquilityCore

/// Recovering a saved recording on the account.
///
/// The claims a person would care about: a Mac on credits recovers a lost
/// recording with its sign-in, the same recording is never bought twice, and
/// a Mac that is not on credits notices nothing at all.
final class ManagedRecoveryTests: XCTestCase {

    /// A box, because the seam is a `@Sendable` closure and a test needs to
    /// see whether it ran.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func note() { lock.lock(); value = true; lock.unlock() }
        var wasAsked: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let account = UUID(uuidString: "7f3c2a10-1111-4222-8333-444455556666")!

    /// Records what it was actually sent, including the parts that only the
    /// recovery route uses: the content type and the declared length.
    actor Transport: GatewayTransport {
        var replies: [(Int, Data)]
        private(set) var calls: [(method: String, path: String, bytes: Int, type: String?, headers: [String: String])] = []
        init(_ replies: [(Int, Data)]) { self.replies = replies }
        func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
            try await request(method: method, path: path, body: body, contentType: "application/json", headers: [:])
        }
        func request(method: String, path: String, body: Data?, contentType: String,
                     headers: [String: String]) async throws -> (status: Int, body: Data) {
            calls.append((method, path, body?.count ?? 0, contentType, headers))
            guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
            return replies.removeFirst()
        }
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func reply(_ id: UUID, _ state: String, text: String? = nil,
                       seconds: String? = nil, code: String? = nil) -> Data {
        var body: [String: Any] = ["version": "1", "kind": "recovery",
                                   "accountId": account.uuidString.lowercased(),
                                   "operationId": id.uuidString.lowercased(), "state": state]
        if let text { body["text"] = text }
        if let seconds { body["seconds"] = seconds }
        if let code { body["error"] = ["code": code] }
        return json(body)
    }

    func testTheCallerPollsTheRecordingToItsTranscript() async throws {
        let audio = Data("a saved recording".utf8)
        let id = ManagedRecoveryClient.recoveryId(audio: audio, account: account)
        let transport = Transport([
            (202, reply(id, "running")),
            (202, reply(id, "running")),
            (200, reply(id, "succeeded", text: "the dictation, recovered", seconds: "120")),
        ])
        let client = ManagedRecoveryClient(accountId: account, transport: transport)
        let text = try await client.transcribe(audio, seconds: 180, sleep: { _ in })
        XCTAssertEqual(text, "the dictation, recovered")

        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.method), ["PUT", "GET", "GET"], "put once, then poll")
        XCTAssertEqual(calls[0].type, "application/octet-stream", "the body is a recording, not a document")
        XCTAssertEqual(calls[0].headers["tb-audio-seconds"], "180", "the declared length is what gets reserved")
        XCTAssertEqual(calls[0].bytes, audio.count)
        XCTAssertEqual(calls[1].bytes, 0, "a poll re-sends nothing")
        XCTAssertTrue(calls.allSatisfy { $0.path.hasSuffix(id.uuidString.lowercased()) })
    }

    /// Content is the identity, so offering the same file twice cannot buy it
    /// twice -- and a Mac that restarts mid-recovery rejoins its own operation.
    func testTheIdIsTheRecordingItself() {
        let one = Data("first recording".utf8), two = Data("second recording".utf8)
        XCTAssertEqual(ManagedRecoveryClient.recoveryId(audio: one, account: account),
                       ManagedRecoveryClient.recoveryId(audio: one, account: account))
        XCTAssertNotEqual(ManagedRecoveryClient.recoveryId(audio: one, account: account),
                          ManagedRecoveryClient.recoveryId(audio: two, account: account))
        // And it is this account's operation, not another's.
        XCTAssertNotEqual(ManagedRecoveryClient.recoveryId(audio: one, account: account),
                          ManagedRecoveryClient.recoveryId(audio: one, account: UUID()))
    }

    func testAFailedRecoveryIsNamedRatherThanGuessedAt() async throws {
        let audio = Data("a recording".utf8)
        let id = ManagedRecoveryClient.recoveryId(audio: audio, account: account)
        let transport = Transport([(200, reply(id, "failed", code: "no_speech_detected"))])
        let client = ManagedRecoveryClient(accountId: account, transport: transport)
        do {
            _ = try await client.transcribe(audio, seconds: 30, sleep: { _ in })
            XCTFail("expected a refusal")
        } catch let failure as ManagedSummaryFailure {
            guard case let .refused(code, _) = failure else { return XCTFail("wrong failure: \(failure)") }
            XCTAssertEqual(code, "no_speech_detected")
        }
    }

    /// The whole point of the seam: a Mac with no credits behaves exactly as
    /// it did before, and its own key is what recovers the recording.
    func testTheRungFallsToTheKeyPathWhenTheManagedSeamDeclines() async throws {
        let asked = Asked()
        AssemblyAIFileRecovery.managed = { _, _ in asked.note(); return nil }
        defer { AssemblyAIFileRecovery.managed = nil }

        var rung = AssemblyAIFileRecovery(keyOverride: nil)   // no key of its own
        rung.compress = { _ in nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("decline-\(UUID()).wav")
        try BuddyWAVBuilder.wavData(fromPCM16: Data(count: 32_000), sampleRate: 16_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await rung.transcribe(fileAt: url)
            XCTFail("with no key and no credits this rung has nothing to offer")
        } catch {
            XCTAssertEqual(error as? TranscriptionFailure, .notConfigured)
        }
        XCTAssertTrue(asked.wasAsked, "the account is asked first, before any key")
    }

    /// And when it answers, no key is needed and nothing reaches the vendor.
    func testOnCreditsTheRecordingNeverTouchesAVendorKey() async throws {
        AssemblyAIFileRecovery.managed = { audio, seconds in
            XCTAssertGreaterThan(audio.count, 0)
            XCTAssertEqual(seconds, 1, "a one-second recording declares one second")
            return "recovered on the account"
        }
        defer { AssemblyAIFileRecovery.managed = nil }

        var rung = AssemblyAIFileRecovery(keyOverride: nil)
        rung.compress = { _ in nil }
        XCTAssertTrue(rung.isConfigured, "credits are enough; a key of your own is not required")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("credited-\(UUID()).wav")
        try BuddyWAVBuilder.wavData(fromPCM16: Data(count: 32_000), sampleRate: 16_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await rung.transcribe(fileAt: url)
        XCTAssertEqual(result.text, "recovered on the account")
        XCTAssertEqual(result.provider, "assemblyai-file")
        XCTAssertEqual(result.finality, .recoveryForcedFinal)
    }

    /// Audio under the vendor's floor is still refused before anything is
    /// asked of the account -- the guard sits in front of both paths.
    func testTheFloorIsCheckedBeforeTheAccountToo() async throws {
        let asked = Asked()
        AssemblyAIFileRecovery.managed = { _, _ in asked.note(); return "should not happen" }
        defer { AssemblyAIFileRecovery.managed = nil }

        var rung = AssemblyAIFileRecovery(keyOverride: "k")
        rung.compress = { _ in nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID()).wav")
        try BuddyWAVBuilder.wavData(fromPCM16: Data(count: 3_200), sampleRate: 16_000).write(to: url)  // 100 ms
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await rung.transcribe(fileAt: url)
            XCTFail("expected the floor to refuse it")
        } catch {
            XCTAssertEqual(error as? TranscriptionFailure, .noSpeechDetected)
        }
        XCTAssertFalse(asked.wasAsked, "nothing under the floor should cost an account call either")
    }
}
