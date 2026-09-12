import XCTest
@testable import TranquilityCore

/// The mirror is a diff, never a repeat: the same page twice is one send, a
/// page's images leave it for the bucket before it goes, and a turn carries
/// the grid's name. Every test speaks to a fake hub; none opens a socket.
final class HubMirrorTests: XCTestCase {

    /// A hub that remembers what it was told and answers like the real one.
    final class FakeHub: HubMirror.Transport, @unchecked Sendable {
        var calls: [(path: String, json: [String: Any])] = []
        var known: Set<String> = []
        let lock = NSLock()
        func post(_ path: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
            lock.withLock { calls.append((path, json)) }
            switch path {
            case "api/ingest/known":
                let hashes = (json["hashes"] as? [String]) ?? []
                let hit = hashes.filter { known.contains($0) }
                return (200, try JSONSerialization.data(withJSONObject: ["known": hit]))
            case "api/ingest":
                return (201, try JSONSerialization.data(withJSONObject: ["id": "doc"]))
            case "api/ingest/assets":
                let sha = (json["sha256"] as? String) ?? "x"
                return (200, try JSONSerialization.data(withJSONObject: ["url": "https://media.example.test/media/\(sha.prefix(16)).png"]))
            case "api/ingest/turns":
                return (200, try JSONSerialization.data(withJSONObject: ["ok": true]))
            case "api/ingest/names":
                return (200, try JSONSerialization.data(withJSONObject: ["renamed": ((json["names"] as? [Any]) ?? []).count]))
            default:
                return (200, Data("{}".utf8))
            }
        }
        func count(_ path: String) -> Int { lock.withLock { calls.filter { $0.path == path }.count } }
        func last(_ path: String) -> [String: Any]? { lock.withLock { calls.last { $0.path == path }?.json } }
    }

    private var tmp: URL!
    private let session = "489b4804-8d64-4a91-a63c-5e493141c772"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hub-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("agents/\(session)/assets"),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func mirror(_ hub: FakeHub) -> HubMirror {
        let m = HubMirror(transport: hub, agentsRoot: tmp.appendingPathComponent("agents").path,
                          stateURL: tmp.appendingPathComponent("state.json"), device: "test-mac",
                          store: nil, artifactRoot: nil)
        m.liveSessions = { [:] }
        return m
    }

    private func write(_ name: String, _ html: String) -> String {
        let url = tmp.appendingPathComponent("agents/\(session)/\(name)")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! html.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testAPageIsSentOnceWithTheDrainersShape() async {
        let hub = FakeHub()
        _ = write("plan/the-build.html", "<html><head><title>The build plan</title><meta name=\"intranet:url\" content=\"https://pub.example.test/x\"></head><body>hi</body></html>")
        _ = write("index.html", "<html><title>hub</title></html>")   // the hub itself, never sent
        let m = mirror(hub)
        let first = await m.run(docs: true, turns: false)
        XCTAssertEqual(first.documents, 1)
        let sent = hub.last("api/ingest")!
        XCTAssertEqual(sent["session_id"] as? String, session)
        XCTAssertEqual(sent["slug"] as? String, "plan-the-build")
        XCTAssertEqual(sent["title"] as? String, "The build plan")
        XCTAssertEqual(sent["published_url"] as? String, "https://pub.example.test/x")
        XCTAssertEqual(sent["device"] as? String, "test-mac")
        XCTAssertNotNil(sent["produced_at"])
        // Again: the mark matches, the hash is in `sent`, nothing goes.
        let second = await m.run(docs: true, turns: false)
        XCTAssertEqual(second.documents, 0)
        XCTAssertEqual(hub.count("api/ingest"), 1)
        XCTAssertTrue(second.note.hasPrefix("ok"))
    }

    func testAHashTheHubAlreadyHoldsIsNotSentAgain() async {
        let hub = FakeHub()
        let html = "<html><title>Known</title></html>"
        _ = write("known.html", html)
        hub.known = [HubMirror.sha256(html)]
        let r = await mirror(hub).run(docs: true, turns: false)
        XCTAssertEqual(r.documents, 0)
        XCTAssertEqual(hub.count("api/ingest"), 0)
        XCTAssertEqual(hub.count("api/ingest/known"), 1)
    }

    func testImagesLeaveThePageForTheBucketBeforeItIsSent() async throws {
        let hub = FakeHub()
        let png = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 7, count: 64))
        try png.write(to: tmp.appendingPathComponent("agents/\(session)/assets/shot.png"))
        let inline = "data:image/png;base64," + Data([UInt8](repeating: 1, count: 60)).base64EncodedString()
        let path = write("report.html", "<html><title>R</title><body><img src=\"assets/shot.png\"><img src=\"\(inline)\"></body></html>")
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
        let r = await mirror(hub).run(docs: true, turns: false)
        XCTAssertEqual(r.images, 2)
        XCTAssertEqual(hub.count("api/ingest/assets"), 2)
        let after = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(after.contains("assets/shot.png"))
        XCTAssertFalse(after.contains("data:image"))
        XCTAssertEqual(after.components(separatedBy: "https://media.example.test/media/").count - 1, 2)
        // The page that went to the hub is the rewritten one.
        XCTAssertTrue(((hub.last("api/ingest")?["html"] as? String) ?? "").contains("https://media.example.test/media/"))
        // mtime is the archive's sort order; a rewrite must not make old news today's.
        let now = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
        XCTAssertEqual(now.timeIntervalSince1970, before.timeIntervalSince1970, accuracy: 1)
    }

    func testTheSlugIsThePathUnderTheAgentWithSlashesFolded() {
        XCTAssertEqual(HubMirror.slug(path: "/a/agents/S/2026-09-07-x/index.html", base: "/a/agents/S"), "2026-09-07-x-index")
        XCTAssertEqual(HubMirror.slug(path: "/a/agents/S/plan.html", base: "/a/agents/S"), "plan")
    }

    func testATurnCarriesTheGridsNameAndTheHubsKey() {
        var b = StoredBrief(eventRowid: 42, sessionId: session, atMs: 1_700_000_000_000, topic: "the poller",
                            goal: nil, happened: "Finished.", nextStep: "Land it.", question: "Go?", risk: nil,
                            rationale: nil, findings: nil, solution: nil, recap: nil, proposal: nil,
                            headline: "Done", deck: nil, pullRequests: nil, branch: "main",
                            callsign: "promotions rebuild", provider: "test")
        let json = HubMirror.turnPayload(b, session: nil, live: nil)
        XCTAssertEqual(json["source_key"] as? String, "\(session):42")
        XCTAssertEqual(json["agent_title"] as? String, "promotions rebuild", "no store row: the callsign")
        XCTAssertEqual(json["headline"] as? String, "Done")
        XCTAssertEqual(json["next_step"] as? String, "Land it.")
        XCTAssertNil(json["risk"])
        b.callsign = nil
        XCTAssertNil(HubMirror.turnPayload(b, session: nil, live: nil)["agent_title"])
    }

    func testOnlyChangedNamesAreSent() {
        let s = WaitingSession(sessionId: session, latestId: 1, createdAtMs: 0, cwd: "/Users/x/Projects/promotions",
                               tty: nil, promptId: nil, transcriptPath: nil, lastAssistantMessage: nil,
                               notificationMatcher: nil, summaryText: nil, hookEvent: .stop, callsign: "promotions rebuild")
        let fresh = HubMirror.changedNames(sessions: [s], live: [:], previous: [:])
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(fresh.first?.1, "promotions rebuild")
        let same = HubMirror.changedNames(sessions: [s], live: [:], previous: [session: "promotions rebuild"])
        XCTAssertTrue(same.isEmpty)
    }
}
