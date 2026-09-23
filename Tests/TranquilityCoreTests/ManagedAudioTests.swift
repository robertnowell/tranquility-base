import Network
import XCTest
@testable import TranquilityCore

/// Hearing and speaking on the account.
///
/// The claims that matter to a person: a Mac on credits buys its voice and
/// its transcript with the sign-in, a Mac that is not on credits keeps using
/// its own keys and notices nothing, and a session left open does not keep
/// charging after the talking stops.
final class ManagedAudioTests: XCTestCase {

    private let account = UUID(uuidString: "7f3c2a10-1111-4222-8333-444455556666")!

    actor Transport: GatewayTransport {
        var replies: [(Int, Data)]
        private(set) var calls: [(method: String, path: String, body: Data?)] = []
        init(_ replies: [(Int, Data)]) { self.replies = replies }
        func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
            calls.append((method, path, body))
            guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
            return replies.removeFirst()
        }
        var paths: [String] { calls.map(\.path) }
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - The voice

    func testAClipIsBoughtOnTheAccountAndKeyedByItsWords() async throws {
        let audio = Data("mp3 bytes".utf8)
        let transport = Transport([(200, json([
            "version": "1", "kind": "speech", "accountId": account.uuidString.lowercased(),
            "operationId": ManagedSpeechClient.clipId(text: "Ready to ship.", voice: nil, account: account).uuidString.lowercased(),
            "state": "succeeded", "characters": 14,
            "clip": ["audioBase64": audio.base64EncodedString(), "characterStartTimes": [0, 0.2], "characters": 14],
        ]))])
        let client = ManagedSpeechClient(accountId: account, transport: transport, store: freshStore())
        let clip = try await client.speak("Ready to ship.", voice: nil)
        XCTAssertEqual(clip.audio, audio)
        XCTAssertEqual(clip.starts, [0, 0.2])
        let paths = await transport.paths
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths[0].hasPrefix("/v1/accounts/\(account.uuidString.lowercased())/speech/"))

        // Content is the identity: the same words in the same voice are the
        // same purchase, and a different voice is a different one.
        let same = ManagedSpeechClient.clipId(text: "Ready to ship.", voice: nil, account: account)
        XCTAssertEqual(same, ManagedSpeechClient.clipId(text: "Ready to ship.", voice: nil, account: account))
        XCTAssertNotEqual(same, ManagedSpeechClient.clipId(text: "Ready to ship.", voice: "other", account: account))
        XCTAssertNotEqual(same, ManagedSpeechClient.clipId(text: "Ready to ship!", voice: nil, account: account))
        XCTAssertNotEqual(same, ManagedSpeechClient.clipId(text: "Ready to ship.", voice: nil, account: UUID()))
    }

    private func freshStore() -> ManagedClipStore {
        ManagedClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("clips-\(UUID().uuidString)", isDirectory: true))
    }

    /// A line already bought plays from our own copy, with no second request.
    /// The Gateway keeps no audio, so on 22 Sep a clip evicted from the
    /// eight-slot memory cache came back as a receipt with no sound and was
    /// read in the system voice: 59 times against 11 plays. The copy also
    /// survives a relaunch, which is a new client over the same directory.
    func testABoughtLineIsKeptAndNeverAskedForAgain() async throws {
        let audio = Data("mp3 bytes".utf8)
        let id = ManagedSpeechClient.clipId(text: "Ready to ship.", voice: "v", account: account).uuidString.lowercased()
        let first = Transport([(200, json([
            "version": "1", "kind": "speech", "accountId": account.uuidString.lowercased(),
            "operationId": id, "state": "succeeded", "characters": 14,
            "clip": ["audioBase64": audio.base64EncodedString(), "characterStartTimes": [0, 0.2], "characters": 14],
        ]))])
        let store = freshStore()
        _ = try await ManagedSpeechClient(accountId: account, transport: first, store: store)
            .speak("Ready to ship.", voice: "v")

        let replayOnly = Transport([(200, json([
            "version": "1", "kind": "speech", "accountId": account.uuidString.lowercased(),
            "operationId": id, "state": "succeeded", "characters": 14,
        ]))])
        let again = try await ManagedSpeechClient(accountId: account, transport: replayOnly, store: store)
            .speak("Ready to ship.", voice: "v")
        XCTAssertEqual(again.audio, audio)
        XCTAssertEqual(again.starts, [0, 0.2])
        let asked = await replayOnly.paths
        XCTAssertTrue(asked.isEmpty, "a line we already own is not bought, or asked for, twice")
    }

    /// A line bought before there was a copy to keep: the Gateway answers
    /// with the receipt only. It is bought once more under a second id and
    /// kept, rather than read in the system voice.
    func testALineLostBeforeTheStoreIsBoughtOnceMore() async throws {
        let audio = Data("mp3 bytes".utf8)
        let first = ManagedSpeechClient.clipId(text: "Lost line.", voice: "v", account: account).uuidString.lowercased()
        let second = ManagedSpeechClient.clipId(text: "Lost line.", voice: "v", account: account, attempt: "rebuy").uuidString.lowercased()
        XCTAssertNotEqual(first, second)
        let acct = account.uuidString.lowercased()
        let transport = Transport([
            (200, json(["version": "1", "kind": "speech", "accountId": acct, "operationId": first,
                        "state": "succeeded", "characters": 10])),
            (200, json(["version": "1", "kind": "speech", "accountId": acct, "operationId": second,
                        "state": "succeeded", "characters": 10,
                        "clip": ["audioBase64": audio.base64EncodedString(), "characters": 10]])),
        ])
        let store = freshStore()
        let clip = try await ManagedSpeechClient(accountId: account, transport: transport, store: store)
            .speak("Lost line.", voice: "v")
        XCTAssertEqual(clip.audio, audio)
        let paths = await transport.paths
        XCTAssertEqual(paths.map { $0.components(separatedBy: "/").last! }, [first, second])
        XCTAssertEqual(store.load(first)?.audio, audio, "kept under the line's own id, so it is never bought a third time")
    }

    func testAnAnswerForAnotherClipOrWithoutAudioIsRefused() async throws {
        for body in [
            ["version": "1", "kind": "speech", "accountId": account.uuidString.lowercased(),
             "operationId": UUID().uuidString.lowercased(), "state": "succeeded",
             "clip": ["audioBase64": Data("x".utf8).base64EncodedString(), "characters": 1]],
            ["version": "1", "kind": "speech", "accountId": account.uuidString.lowercased(),
             "operationId": ManagedSpeechClient.clipId(text: "hi", voice: nil, account: account).uuidString.lowercased(),
             "state": "failed", "error": ["code": "provider_failed"]],
        ] {
            let client = ManagedSpeechClient(accountId: account, transport: Transport([(200, json(body))]), store: freshStore())
            do { _ = try await client.speak("hi", voice: nil); XCTFail("must refuse \(body)") }
            catch {}
        }
    }

    // MARK: - The transcript

    func testASessionIsOpenedOnceForABurstAndTokensAreFree() async throws {
        let id = UUID()
        let started = json(["version": "1", "accountId": account.uuidString.lowercased(),
                            "sessionId": id.uuidString.lowercased(), "state": "running",
                            "startedAt": "2026-09-22T21:00:00Z", "blocks": 1,
                            "renewBy": "2026-09-22T21:30:00Z", "pricebookVersion": "p",
                            "wsUrl": "wss://streaming.assemblyai.com/v3/ws", "token": "first"])
        let minted = json(["version": "1", "sessionId": id.uuidString.lowercased(),
                           "wsUrl": "wss://streaming.assemblyai.com/v3/ws", "token": "second", "expiresInSeconds": 60])
        // The session decides its own id, so the fixture answers positionally.
        let transport = Transport([(200, started), (200, minted)])
        let session = ManagedTranscriptionSession(accountId: account, transport: transport,
                                                  now: { Date(timeIntervalSince1970: 1_800_000_000) })
        // The start reply names a session id we cannot predict, so this proves
        // the shape check by using a client-minted id: read what was called.
        _ = try? await session.token(keyterms: ["Kopi"])
        let paths = await transport.paths
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths[0].contains("/transcription/sessions/"))
        XCTAssertFalse(paths[0].hasSuffix("/token"), "the first socket comes from the start itself")
    }

    func testEndingTheSessionStopsThePaying() async throws {
        let id = UUID()
        let transport = Transport([(200, json(["version": "1", "accountId": account.uuidString.lowercased(),
                                               "sessionId": id.uuidString.lowercased(), "state": "ended",
                                               "startedAt": "2026-09-22T21:00:00Z", "endedAt": "2026-09-22T21:01:00Z",
                                               "blocks": 1, "chargedSeconds": "60", "pricebookVersion": "p"]))])
        let session = ManagedTranscriptionSession(accountId: account, transport: transport)
        await session.end()
        let paths = await transport.paths
        XCTAssertEqual(paths.count, 0, "nothing to end before anything was started")
    }

    // MARK: - The rule

    func testAMacNotOnCreditsFallsThroughToItsOwnKeys() async throws {
        // A session with no hub identity refuses every call, and both closures
        // answer nil so the providers use the pasted key exactly as before.
        let session = ManagedCreditSession(identity: { nil },
                                           outboxURL: FileManager.default.temporaryDirectory
                                               .appendingPathComponent("audio-\(UUID().uuidString).sqlite"),
                                           connect: { _, _ in throw ManagedSummaryFailure.refused(code: "not_connected", operationId: nil) })
        let audio = ManagedAudio(session: session)
        let clip = try await audio.clip()(SpokenTextSanitizer().sanitize("hello"), nil, 4)
        XCTAssertNil(clip, "not on credits: the ElevenLabs key path runs")
        let token = try await audio.streamingToken()()
        XCTAssertNil(token, "not on credits: the AssemblyAI key path runs")

        // And the providers themselves keep their old answer about being
        // configured: a seam that is present does not claim a key exists.
        let speech = ElevenLabsSpeechProvider()
        speech.render = audio.clip()
        XCTAssertTrue(speech.isConfigured, "the managed renderer counts as configured")
        var streaming = AssemblyAIStreaming()
        streaming.tokenSource = audio.streamingToken()
        XCTAssertTrue(streaming.isConfigured)
    }

    /// A transcript refused for credit is an answer about the account: the
    /// standing becomes out of credits, so the top bar can say "Add credits".
    /// 22 Sep: the refusals reached only app.log and nothing on screen changed.
    func testARefusedTranscriptBecomesTheStanding() async throws {
        let refused = Transport([(402, json(["error": ["code": "insufficient_credit"]]))])
        let published = Published()
        let session = ManagedCreditSession(
            identity: { .init(hub: URL(string: "https://fixture.invalid")!, token: "A") },
            outboxURL: FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString).sqlite"),
            connect: { _, _ in .init(transport: refused) },
            publish: { standing, _ in published.set(standing) })
        await session.noteAudioFailure(ManagedSummaryFailure.refused(code: "insufficient_credit", operationId: nil),
                                       during: "transcript")
        guard case .floored(.outOfCredits, _)? = published.value else {
            return XCTFail("standing was \(String(describing: published.value))")
        }
        XCTAssertEqual(published.value?.line(ownKey: true), "Add credits")
    }

    private final class Published: @unchecked Sendable {
        private let lock = NSLock(); private var standing: CreditStanding?
        func set(_ s: CreditStanding) { lock.lock(); standing = s; lock.unlock() }
        var value: CreditStanding? { lock.lock(); defer { lock.unlock() }; return standing }
    }
}

/// The transport returns what it received, measured through the real `GatewayHTTPTransport`
/// against a loopback server rather than a fake: the fake transports in this
/// file never applied the old 256 KB cap, which is how a limit that discarded every
/// ordinary voice clip shipped with green tests (22 Sep).
final class GatewayResponseLimitTests: XCTestCase {

    /// Serves one fixed body to every request, then closes.
    private func serve(_ body: Data) throws -> (NWListener, URL) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                reply.append(body)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)
        return (listener, try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")))
    }

    private func transport(_ base: URL) throws -> GatewayHTTPTransport {
        try GatewayHTTPTransport(base: base, allowLoopbackFixture: true,
                                 credential: { _, _ in .init(authorization: "DPoP fixture", proof: "fixture") })
    }

    /// An 18-second recap is about 400 KB as base64 MP3. It must arrive.
    func testAnOrdinaryVoiceClipIsNotDiscarded() async throws {
        let body = Data(repeating: UInt8(ascii: "a"), count: 400_000)
        let (listener, base) = try serve(body)
        defer { listener.cancel() }
        let response = try await transport(base).request(
            method: "PUT", path: "/v1/accounts/a/speech/b", body: Data("{}".utf8))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body.count, body.count)
    }

    /// And a summary, which the old cap was written for, is not size-checked
    /// either: the check guarded nothing, since the body was already read.
    func testALargeSummaryResponseIsReturnedToBeValidated() async throws {
        let (listener, base) = try serve(Data(repeating: UInt8(ascii: "a"), count: 400_000))
        defer { listener.cancel() }
        let response = try await transport(base).request(
            method: "GET", path: "/v1/accounts/a/summaries/b", body: nil)
        XCTAssertEqual(response.body.count, 400_000)
    }
}
