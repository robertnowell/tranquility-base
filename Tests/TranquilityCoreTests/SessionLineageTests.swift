import XCTest
@testable import TranquilityCore

/// One conversation, one hub. The link lives only at the tail of the OLD
/// transcript, as Claude Code wrote it on 10 Sep at 03:34Z:
/// `{"type":"continued-in","sessionId":"0d04…","continuedInSessionId":"54ac…"}`.
final class SessionLineageTests: XCTestCase {

    private let a = "0d04e845-65ff-488f-983c-58f371d661ed"
    private let b = "54acd236-0133-4866-bfee-905a9dc00e2c"
    private let c = "9f9f9f9f-0000-4000-8000-000000000001"

    private func projects(_ files: [(project: String, session: String, lines: [String])]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage-\(UUID().uuidString)", isDirectory: true)
        for f in files {
            let dir = root.appendingPathComponent(f.project, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (f.lines.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent("\(f.session).jsonl"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func record(_ from: String, _ to: String) -> String {
        #"{"type":"continued-in","timestamp":"2026-09-10T03:34:37.403Z","sessionId":"\#(from)","continuedInSessionId":"\#(to)"}"#
    }

    // MARK: - Reading the tail

    func testTheLinkIsReadOffTheTailOfTheOldTranscript() throws {
        let root = try projects([
            (project: "-Users-robertnowell-Projects", session: a,
             lines: [#"{"type":"user","message":{"content":"hello"}}"#] + Array(repeating: #"{"type":"assistant","message":{"content":"…padding…"}}"#, count: 40) + [record(a, b)]),
            (project: "-Users-robertnowell-Projects-tranquility-base", session: b,
             lines: [#"{"type":"ai-title","aiTitle":"Hub design and organization"}"#]),
        ])
        let map = SessionLineage.scan(projects: root)
        XCTAssertEqual(map, [b: a])
    }

    func testATranscriptThatEndsSomeOtherWayHasNoLink() throws {
        let root = try projects([
            (project: "p", session: a, lines: [#"{"type":"user","message":{"content":"x"}}"#, #"{"type":"assistant","message":{"content":"y"}}"#]),
        ])
        XCTAssertEqual(SessionLineage.scan(projects: root), [:])
    }

    /// A line that merely mentions the words is not the record.
    func testMentioningTheRecordTypeIsNotTheRecord() throws {
        let root = try projects([
            (project: "p", session: a, lines: [#"{"type":"assistant","message":{"content":"the file said continued-in and continuedInSessionId"}}"#]),
        ])
        XCTAssertEqual(SessionLineage.scan(projects: root), [:])
    }

    // MARK: - Origin and family

    func testTheContinuationsOriginIsTheSessionItCameFrom() {
        let map = [b: a]
        XCTAssertEqual(SessionLineage.origin(of: b, in: map), a)
        XCTAssertEqual(SessionLineage.origin(of: a, in: map), a)
        XCTAssertEqual(SessionLineage.origin(of: c, in: map), c)
    }

    func testAChainFollowsBackToTheFirstSession() {
        let map = [b: a, c: b]
        XCTAssertEqual(SessionLineage.origin(of: c, in: map), a)
        XCTAssertEqual(SessionLineage.family(of: c, in: map), [a, b, c])
        XCTAssertEqual(SessionLineage.family(of: a, in: map), [a, b, c])
        XCTAssertEqual(SessionLineage.family(of: b, in: map), [a, b, c])
    }

    func testASessionNobodyContinuedIsAFamilyOfOne() {
        XCTAssertEqual(SessionLineage.family(of: c, in: [b: a]), [c])
    }

    /// The harness should never write a loop. If it does, stop rather than spin.
    func testALoopStopsAtTheFirstRepeat() {
        let map = [b: a, a: b]
        _ = SessionLineage.origin(of: a, in: map)
        let family = SessionLineage.family(of: a, in: map)
        XCTAssertEqual(Set(family), Set([a, b]))
    }

    // MARK: - Which id carries the conversation

    private func transcript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The scratch job of 10 Sep after first use: its file opens with the
    /// copied history, stamped hours before the job started.
    func testAJobThatReceivedTheHistoryCarriesIt() throws {
        let started = ISO8601DateFormatter().date(from: "2026-09-10T14:39:44Z")!
        let url = try transcript([
            #"{"type":"ai-title","aiTitle":"probe"}"#,
            #"{"type":"user","timestamp":"2026-09-10T03:34:00.000Z","message":{"content":"Remember the word pineapple."}}"#,
            #"{"type":"assistant","timestamp":"2026-09-10T03:34:05.000Z","message":{"content":"OK"}}"#,
        ])
        XCTAssertTrue(SessionLineage.carriesHistory(transcript: url, before: started))
    }

    /// Robert's job of 10 Sep, killed before first use and restarted fresh:
    /// title only, then messages from after its own start. It carries
    /// nothing, and the origin must be resumed instead.
    func testAJobStoppedBeforeFirstUseCarriesNothing() throws {
        let started = ISO8601DateFormatter().date(from: "2026-09-10T03:34:38Z")!
        let url = try transcript([
            #"{"type":"ai-title","aiTitle":"Hub design and organization"}"#,
            #"{"type":"user","timestamp":"2026-09-10T13:17:22.995Z","message":{"content":"Done. Three rulings…"}}"#,
        ])
        XCTAssertFalse(SessionLineage.carriesHistory(transcript: url, before: started))
        let bare = try transcript([#"{"type":"ai-title","aiTitle":"x"}"#])
        XCTAssertFalse(SessionLineage.carriesHistory(transcript: bare, before: started))
        XCTAssertFalse(SessionLineage.carriesHistory(
            transcript: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl"), before: started))
    }
}
