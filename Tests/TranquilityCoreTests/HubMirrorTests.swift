import XCTest
@testable import TranquilityCore

/// The mirror is a diff, never a repeat: the same page twice is one send, a
/// page's images leave it for the bucket before it goes, and a turn carries
/// the grid's name. Every test speaks to a fake hub; none opens a socket.
final class HubMirrorTests: XCTestCase {

    /// 14 Sep: the name came from `ProcessInfo.hostName`, which resolves
    /// through DNS and hung a fresh Mac's setup window on the main thread.
    /// The local host name is a config read; it answers at once, and it is
    /// the same spelling minus the `.local` the old call had to strip.
    func testDeviceNameIsTheLocalHostNameAndAnswersAtOnce() {
        let started = Date()
        let name = HubMirror.deviceName()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        XCTAssertFalse(name.isEmpty)
        XCTAssertFalse(name.hasSuffix(".local"))
        XCTAssertFalse(name.contains("."), "the hub keys one row per Mac on the bare name: \(name)")
    }

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

    /// A page the tree does not hold, recorded by the hook (the website's
    /// own index.html on 24 Sep), reaches the hub as a link-only row whose
    /// published address is the page's own. Sent once; a page that declares
    /// no address is not sent at all.
    func testAPageOutsideTheTreeIsSentAsALinkOnlyRow() async throws {
        let hub = FakeHub()
        // Not under the temp directory: the artifact record refuses /var/folders
        // and /tmp by design, and a fixture there passes vacuously (see
        // ArtifactStore.excluded). Somewhere the record accepts, cleaned up here.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/tb-tests/mirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let site = home.appendingPathComponent("Projects/tranquilitybase-site/index.html")
        let plain = home.appendingPathComponent("Projects/other/plain.html")
        for f in [site, plain] {
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try "<html><head><title>Tranquility Base: talk to your agents</title><link rel=\"canonical\" href=\"https://tranquilitybase.dev/\"></head><body>site</body></html>"
            .write(to: site, atomically: true, encoding: .utf8)
        try "<html><head><title>nothing</title></head></html>".write(to: plain, atomically: true, encoding: .utf8)
        let artifacts = tmp.appendingPathComponent("support").path
        XCTAssertTrue(ArtifactStore.record(site.path, session: session, root: artifacts))
        XCTAssertTrue(ArtifactStore.record(plain.path, session: session, root: artifacts))

        let m = HubMirror(transport: hub, agentsRoot: tmp.appendingPathComponent("agents").path,
                          stateURL: tmp.appendingPathComponent("state.json"), device: "test-mac",
                          store: nil, artifactRoot: artifacts)
        m.liveSessions = { [:] }
        let first = await m.run(docs: true, turns: false)
        XCTAssertEqual(first.documents, 1)
        let sent = hub.last("api/ingest")!
        XCTAssertEqual(sent["session_id"] as? String, session)
        XCTAssertEqual(sent["slug"] as? String, "tranquilitybase-site-index")
        XCTAssertEqual(sent["title"] as? String, "Tranquility Base: talk to your agents")
        XCTAssertEqual(sent["published_url"] as? String, "https://tranquilitybase.dev/")
        let html = (sent["html"] as? String) ?? ""
        XCTAssertTrue(html.contains("href=\"https://tranquilitybase.dev/\""), html)
        XCTAssertFalse(html.contains("<body>site</body>"), "the page's body is the project's, not the hub's")
        // Again: the record has not moved, nothing goes.
        let second = await m.run(docs: true, turns: false)
        XCTAssertEqual(second.documents, 0)
        XCTAssertEqual(hub.count("api/ingest"), 1)
    }

    func testTheLinkedSlugNamesTheProjectAndThePage() {
        XCTAssertEqual(HubMirror.linkedSlug(for: "/Users/x/Projects/tranquilitybase-site/index.html"), "tranquilitybase-site-index")
        XCTAssertEqual(HubMirror.linkedSlug(for: "/Users/x/Projects/Contract Proof/brief-coframe.html"), "contract-proof-brief-coframe")
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

    /// The turn itself rides with the summary of it, copied not written.
    ///
    /// The hub had the brief and nothing else, and for about a quarter of
    /// turns the brief is one sentence. Robert, 15 Sep: "it used to have
    /// verbatim turn text of both the user message and the agent reply... it
    /// should be a deterministic copy." Both halves go, and an empty half is
    /// absent rather than blank, because the hub coalesces on these.
    func testATurnCarriesWhatWasSaidOnBothSides() {
        let b = brief(rowid: 7, atMs: 1_700_000_000_000)
        let said = TurnText.Turn(prompt: "make the send button work",
                                 prose: "Both rulings are built and deploying to Dev.")
        let json = HubMirror.turnPayload(b, session: nil, live: nil, said: said)
        XCTAssertEqual(json["prompt"] as? String, "make the send button work")
        XCTAssertEqual(json["prose"] as? String, "Both rulings are built and deploying to Dev.")
        XCTAssertNil(HubMirror.turnPayload(b, session: nil, live: nil, said: nil)["prose"])
        let onlyProse = TurnText.Turn(prompt: "", prose: "carried on from before")
        let one = HubMirror.turnPayload(b, session: nil, live: nil, said: onlyProse)
        XCTAssertNil(one["prompt"], "a turn nobody prompted has no prompt, not an empty one")
        XCTAssertEqual(one["prose"] as? String, "carried on from before")
    }

    /// A brief covers the transcript turn that OPENED at or before it, and no
    /// two briefs may be handed the same words.
    ///
    /// The join is on two timestamps rather than on position, because the
    /// transcript is read as a tail and the tail does not know how many turns
    /// came before it. The claim is kept for the whole run, not per batch: a
    /// session's briefs routinely span two batches of a hundred, and a
    /// per-batch join would hand the same words out twice without failing.
    func testEachBriefClaimsItsOwnTranscriptTurnAtMostOnce() {
        let t0 = Date().addingTimeInterval(-300)
        var pool: [String: [TurnText.Turn]] = [session: [
            TurnText.Turn(prompt: "first", prose: "one", at: t0),
            TurnText.Turn(prompt: "second", prose: "two", at: t0.addingTimeInterval(60)),
        ]]
        let earlier = brief(rowid: 1, atMs: Int64(t0.addingTimeInterval(30).timeIntervalSince1970 * 1000))
        let later = brief(rowid: 2, atMs: Int64(t0.addingTimeInterval(90).timeIntervalSince1970 * 1000))
        XCTAssertEqual(HubMirror.claimWords(&pool, for: earlier)?.prompt, "first")
        XCTAssertEqual(HubMirror.claimWords(&pool, for: later)?.prompt, "second")
        XCTAssertNil(HubMirror.claimWords(&pool, for: later), "the pool is empty; nothing repeats")

        // A brief older than every turn in the tail claims nothing at all.
        var pool2: [String: [TurnText.Turn]] = [session: [
            TurnText.Turn(prompt: "later", prose: "words", at: t0),
        ]]
        XCTAssertNil(HubMirror.claimWords(&pool2, for: brief(
            rowid: 3, atMs: Int64(t0.addingTimeInterval(-600).timeIntervalSince1970 * 1000))))
    }

    private func brief(rowid: Int64, atMs: Int64) -> StoredBrief {
        StoredBrief(eventRowid: rowid, sessionId: session, atMs: atMs,
                    topic: "Deploy running; waiting for self-tests.",
                    goal: nil, happened: "Deploy running; waiting for self-tests.",
                    nextStep: nil, question: nil, risk: nil,
                    rationale: nil, findings: nil, solution: nil, recap: nil, proposal: nil,
                    headline: nil, deck: nil, pullRequests: nil, branch: nil,
                    callsign: nil, provider: "test")
    }

    // MARK: - Robots

    /// A transcript whose first line declares how it was started. `sdk-cli` is
    /// `claude -p`: a cron, a fleet voter, our own harness.
    private func transcript(entrypoint: String) -> String {
        let url = tmp.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        let line = #"{"type":"summary","entrypoint":"\#(entrypoint)"}"# + "\n"
        try! line.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func waiting(_ id: String, transcript: String?) -> WaitingSession {
        WaitingSession(sessionId: id, latestId: 1, createdAtMs: 0, cwd: "/Users/x/Projects/syndit",
                       tty: nil, promptId: nil, transcriptPath: transcript, lastAssistantMessage: nil,
                       notificationMatcher: nil, summaryText: nil, hookEvent: .stop, callsign: "voter")
    }

    func testAHeadlessRunIsNotAnAgentInTheHub() {
        XCTAssertTrue(HubMirror.isRobot(waiting(session, transcript: transcript(entrypoint: "sdk-cli"))))
        XCTAssertFalse(HubMirror.isRobot(waiting(session, transcript: transcript(entrypoint: "cli"))))
    }

    /// The asymmetry the grid settled on, kept here: excluding on an ABSENCE
    /// is how real conversations get hidden, so anything unclassifiable is
    /// yours.
    func testAnUnclassifiableSessionIsTreatedAsYours() {
        XCTAssertFalse(HubMirror.isRobot(nil), "no store row")
        XCTAssertFalse(HubMirror.isRobot(waiting(session, transcript: nil)), "no transcript")
        XCTAssertFalse(HubMirror.isRobot(waiting(session, transcript: tmp.appendingPathComponent("gone.jsonl").path)))
        XCTAssertFalse(HubMirror.isRobot(waiting(session, transcript: transcript(entrypoint: "something-new"))),
                       "an entrypoint Claude Code invents later is not evidence of a robot")
    }

    func testARobotsNameIsNotSentEither() {
        let robot = waiting("11111111-1111-1111-1111-111111111111", transcript: transcript(entrypoint: "sdk-cli"))
        let mine = waiting(session, transcript: transcript(entrypoint: "cli"))
        let changed = HubMirror.changedNames(sessions: [robot, mine], live: [:], previous: [:])
        XCTAssertEqual(changed.map(\.0), [session], "the robot never reaches the names call")
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

    // MARK: - Stopping, and being refused

    /// A refused Mac says so.
    ///
    /// The heartbeat used to throw its status away, so the one request that
    /// runs on every sweep could not report the one thing it is in a position
    /// to know. A revoked token wrote "ok: 0 documents, 0 turns" onto the
    /// Setup row on every pass, and the row stayed green over a mirror the hub
    /// had been rejecting for a week.
    func testA401IsReportedNotSwallowed() async {
        final class Refusing: HubMirror.Transport, @unchecked Sendable {
            func post(_ path: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
                path == "api/heartbeat" ? (401, Data("{}".utf8))
                                        : (200, Data(#"{"known":[]}"#.utf8))
            }
        }
        let m = HubMirror(transport: Refusing(), agentsRoot: tmp.appendingPathComponent("agents").path,
                          stateURL: tmp.appendingPathComponent("state.json"), device: "test-mac",
                          store: nil, artifactRoot: nil)
        m.liveSessions = { [:] }
        let report = await m.run(docs: false, turns: false)
        XCTAssertTrue(report.unauthorized)
        XCTAssertTrue(report.note.contains("revoked"), report.note)
        XCTAssertEqual(m.lastHeartbeat?.note, HubMirror.refusal(401),
                       "the row reads this, so it cannot say ok")
    }

    // MARK: - The first report

    /// The one report allowed to take the screen, and only the one.
    ///
    /// A person who has just connected a Mac does not know reports exist, so
    /// the first has to be seen. The second must not be: a thing that steals
    /// focus twice is a thing people learn to resent.
    func testTheFirstPageEverMirroredComesForwardOnceOnly() async {
        let store = UserDefaults(suiteName: "first-report-\(UUID().uuidString)")!
        FirstReport.defaults = store
        defer { FirstReport.defaults = .standard }

        final class Shown: @unchecked Sendable {
            private let lock = NSLock(); private var urls: [URL] = []
            func add(_ u: URL) { lock.withLock { urls.append(u) } }
            var all: [URL] { lock.withLock { urls } }
        }
        let shown = Shown()
        HubMirror.revealFirstReport = { [weak shown] in shown?.add($0) }
        defer { HubMirror.revealFirstReport = nil }

        let hub = FakeHub()
        _ = write("first.html", "<html><head><title>The first one</title></head><body>a</body></html>")
        let m = mirror(hub)
        // Named here, not read from the machine: a test that asks this Mac
        // where its hub is passes on a connected Mac and fails on every
        // other, which is exactly how CI caught it.
        m.hubBase = URL(string: "https://hub.example.test")
        _ = await m.run(docs: true, turns: false)
        XCTAssertEqual(shown.all.count, 1, "the first page did not come forward")
        XCTAssertEqual(shown.all.first?.path, "/open")
        XCTAssertTrue(shown.all.first?.query?.contains("slug=first") ?? false,
                      shown.all.first?.absoluteString ?? "no url")
        XCTAssertFalse(FirstReport.pending, "it must not be able to fire twice")

        _ = write("second.html", "<html><head><title>The second</title></head><body>b</body></html>")
        _ = await m.run(docs: true, turns: false)
        XCTAssertEqual(shown.all.count, 1, "a later report took the screen")
    }

    /// A timer nobody cancels is a leak with opinions: a reconnect used to
    /// leave the previous sweep running against the previous token.
    func testStopEndsTheTimer() async throws {
        let hub = FakeHub()
        let m = mirror(hub)
        m.start(every: 0.05, docsEvery: 0.05)
        var waited = 0.0
        while hub.count("api/heartbeat") == 0, waited < 6 {
            try await Task.sleep(nanoseconds: 50_000_000); waited += 0.05
        }
        XCTAssertGreaterThan(hub.count("api/heartbeat"), 0, "it never started")
        m.stop()
        // Whatever pass was in flight may still land; nothing after that.
        try await Task.sleep(nanoseconds: 300_000_000)
        let settled = hub.count("api/heartbeat")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(hub.count("api/heartbeat"), settled, "the sweep kept going after stop()")
    }
}
