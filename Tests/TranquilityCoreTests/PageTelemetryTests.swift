import XCTest
@testable import TranquilityCore

final class PageTelemetryTests: XCTestCase {
    private let a = "489b4804-8d64-4a91-a63c-5e493141c772"
    private let b = "11111111-2222-3333-4444-555555555555"

    private func root() throws -> URL {
        let r = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tb-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: RulesStore.seenDirectory(in: r), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: r) }
        return r
    }

    private func append(_ r: URL, _ text: String) throws {
        let url = PageTelemetry.logURL(r)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8))
    }

    private func line(session: String, path: String, rules: String = "3f6d1085bd5e") -> String {
        #"{"at_ms":1792800000000,"session":"\#(session)","path":"\#(path)","harness":"claude","type":"audit","brand":"U Vape","rules":"\#(rules)","words":700,"claims":5,"semicolons":2,"long_sentences":3,"headline_has_verb":false,"ste_flags":6}"# + "\n"
    }

    private func drain(_ r: URL) -> [(String, [String: TrackValue])] {
        var out: [(String, [String: TrackValue])] = []
        PageTelemetry.drain(root: r) { out.append(($0, $1)) }
        return out
    }

    func testAPageIsCountedOnceAndAWriteAfterThatIsARepublish() throws {
        let r = try root()
        try append(r, line(session: a, path: "/x/agents/\(a)/report.html"))
        let first = drain(r).filter { $0.0 == "page_published" }
        XCTAssertEqual(first.count, 1)
        let p = first[0].1
        XCTAssertEqual(p["rules_version"], .token("3f6d1085bd5e"))
        XCTAssertEqual(p["harness"], .token("claude"))
        XCTAssertEqual(p["page_type"], .token("audit"))
        XCTAssertEqual(p["semicolons"], .int(2))
        XCTAssertEqual(p["long_sentences"], .int(3))
        XCTAssertEqual(p["headline_has_verb"], .bool(false))
        XCTAssertEqual(p["ste_flags"], .int(6))
        XCTAssertEqual(p["version"], .int(1))
        XCTAssertEqual(p["republished"], .bool(false))
        if case .hash = p["agent_id"] {} else { XCTFail("agent_id must be a hash") }
        if case .hash = p["brand"] {} else { XCTFail("brand must be a hash, never the name") }
        XCTAssertTrue(p.values.allSatisfy { $0.isAdmissible }, "every value passes Track's door")

        XCTAssertTrue(drain(r).filter { $0.0 == "page_published" }.isEmpty, "a second drain reports nothing new")

        try append(r, line(session: a, path: "/x/agents/\(a)/report.html"))
        let again = drain(r).filter { $0.0 == "page_published" }
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].1["version"], .int(2))
        XCTAssertEqual(again[0].1["republished"], .bool(true))
    }

    func testAPageWrittenWithoutARulesRecordSaysNone() throws {
        let r = try root()
        try append(r, line(session: a, path: "/x/p.html", rules: "none"))
        XCTAssertEqual(drain(r).first { $0.0 == "page_published" }?.1["rules_version"], .token("none"))
    }

    func testAHalfWrittenLineWaitsForTheNextDrain() throws {
        let r = try root()
        let whole = line(session: a, path: "/x/half.html")
        try append(r, String(whole.dropLast(20)))
        XCTAssertTrue(drain(r).filter { $0.0 == "page_published" }.isEmpty)
        try append(r, String(whole.suffix(20)))
        XCTAssertEqual(drain(r).filter { $0.0 == "page_published" }.count, 1)
    }

    func testATurnIsCountedAndItsSessionIsSeenOnce() throws {
        let r = try root()
        try "3f6d1085bd5e\n".write(to: RulesStore.seenDirectory(in: r).appendingPathComponent(a), atomically: true, encoding: .utf8)
        var out: [(String, [String: TrackValue])] = []
        PageTelemetry.turnsCompleted([(a, "codex"), (b, "claude")], root: r) { out.append(($0, $1)) }
        let turns = out.filter { $0.0 == "turn_completed" }
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].1["harness"], .token("codex"))
        XCTAssertEqual(turns[0].1["rules_version"], .token("3f6d1085bd5e"))
        XCTAssertEqual(turns[1].1["rules_version"], .token("none"), "no record: none, never left out")
        let seen = out.filter { $0.0 == "session_seen" }
        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(seen.allSatisfy { $0.1["first"] == .bool(true) })
        XCTAssertTrue(out.allSatisfy { $0.1.values.allSatisfy(\.isAdmissible) })

        out = []
        PageTelemetry.turnsCompleted([(a, "codex")], root: r) { out.append(($0, $1)) }
        XCTAssertEqual(out.map(\.0), ["turn_completed"], "a second turn: no second session_seen")
    }

    func testASeenSessionIsSeenAgainOnlyWhenItsRulesChange() throws {
        let r = try root()
        let seen = RulesStore.seenDirectory(in: r)
        try "3f6d1085bd5e".write(to: seen.appendingPathComponent(a), atomically: true, encoding: .utf8)
        try "3f6d1085bd5e".write(to: seen.appendingPathComponent(b), atomically: true, encoding: .utf8)
        PageTelemetry.turnsCompleted([(a, "claude")], root: r) { _, _ in }
        XCTAssertTrue(drain(r).filter { $0.0 == "session_seen" }.isEmpty,
                      "unchanged; and b has no turn yet, so its harness is unknown and it waits")
        try "d8053510e223".write(to: seen.appendingPathComponent(a), atomically: true, encoding: .utf8)
        let changed = drain(r).filter { $0.0 == "session_seen" }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].1["rules_version"], .token("d8053510e223"))
        XCTAssertEqual(changed[0].1["harness"], .token("claude"))
        XCTAssertEqual(changed[0].1["first"], .bool(false))
        XCTAssertTrue(drain(r).filter { $0.0 == "session_seen" }.isEmpty)
    }

    func testCurrentIsTrueWhenTheSessionHoldsWhatThisInstallShips() throws {
        let r = try root()
        let cur = RulesStore.current(in: r)
        try FileManager.default.createDirectory(at: cur.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cur.appendingPathComponent("skills/share-as-page/references"), withIntermediateDirectories: true)
        try "hook\n".write(to: cur.appendingPathComponent("hooks/visual-output-hook.sh"), atomically: true, encoding: .utf8)
        try "shape\n".write(to: cur.appendingPathComponent("skills/share-as-page/references/shape-context.txt"), atomically: true, encoding: .utf8)
        // `printf 'hook\nshape\n' | shasum -a 256 | cut -c1-12`, as the hook computes it.
        let v = try XCTUnwrap(PageTelemetry.currentSessionVersion(root: r))
        XCTAssertEqual(v, "7cb5cd885e6d", "the same hash visual-output-hook.sh prints")
        try v.write(to: RulesStore.seenDirectory(in: r).appendingPathComponent(a), atomically: true, encoding: .utf8)
        var out: [(String, [String: TrackValue])] = []
        PageTelemetry.turnsCompleted([(a, "claude")], root: r) { out.append(($0, $1)) }
        XCTAssertEqual(out.first { $0.0 == "session_seen" }?.1["current"], .bool(true))
    }
}
