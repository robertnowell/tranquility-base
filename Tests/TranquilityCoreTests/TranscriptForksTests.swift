import XCTest
@testable import TranquilityCore

/// The classifier, pinned against the shapes that actually occur.
///
/// The leaf rule here is a MEASUREMENT of Claude Code's undocumented behaviour
/// (see `TranscriptForks`' doc comment for the three probes). These tests keep
/// the implementation faithful to what was measured; they cannot detect the
/// measured rule itself changing in a future release.
final class TranscriptForksTests: XCTestCase {

    private func rec(_ uuid: String, _ parent: String?, sidechain: Bool = false,
                     type: String = "user") -> String {
        var o = "{\"uuid\":\"\(uuid)\",\"type\":\"\(type)\""
        o += parent.map { ",\"parentUuid\":\"\($0)\"" } ?? ",\"parentUuid\":null"
        o += ",\"isSidechain\":\(sidechain)}"
        return o
    }

    /// A healthy transcript: one chain, one leaf, nothing stranded.
    func testUnforkedTranscriptReportsNoLoss() {
        let text = [rec("a", nil), rec("b", "a"), rec("c", "b")].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertEqual(s.leaves, 1)
        XCTAssertFalse(s.isForked)
        XCTAssertEqual(s.unreachable, 0)
    }

    /// THE MEASURED RULE. The last non-sidechain record in FILE ORDER is the
    /// tip — so the branch written last survives even when it is the shorter
    /// one. Written to fail if someone "fixes" this to longest-chain.
    func testTipIsLastInFileNotLongestChain() {
        let text = [
            rec("a", nil), rec("b", "a"),
            // long branch, written FIRST
            rec("L1", "b"), rec("L2", "L1"), rec("L3", "L2"), rec("L4", "L3"),
            // short branch, written LAST
            rec("S1", "b"), rec("S2", "S1"),
        ].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertEqual(s.leaves, 2, "L4 and S2 are both dead ends")
        // Reachable = a,b,S1,S2 — the SHORT branch, because it is last in file.
        XCTAssertEqual(s.reachable, 4)
        XCTAssertEqual(s.unreachable, 4, "the four long-branch records are stranded")
    }

    /// Timestamps must not influence the walk; only file order does. The long
    /// branch here would win on every other candidate rule.
    func testOlderLastBranchStillWins() {
        let text = [
            rec("a", nil), rec("b", "a"),
            rec("N1", "b"), rec("N2", "N1"), rec("N3", "N2"),
            rec("O1", "b"),
        ].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertEqual(s.reachable, 3, "a, b, O1 — the last-written branch")
        XCTAssertEqual(s.unreachable, 3)
    }

    /// A sidechain record at the end must not be mistaken for the tip.
    func testSidechainTailIsNotTheTip() {
        let text = [
            rec("a", nil), rec("b", "a"),
            rec("side", "b", sidechain: true),
        ].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        // Tip is b; the sidechain record hangs off it and is still linked.
        XCTAssertEqual(s.reachable, 2)
    }

    /// Bookkeeping rows link to nothing. Counting them as unreachable reports
    /// loss where there is none — an early version of this analysis did.
    func testUnlinkedBookkeepingRowsAreNotCountedAsLoss() {
        let text = [
            rec("a", nil), rec("b", "a"),
            "{\"uuid\":\"meta1\",\"type\":\"mode\",\"parentUuid\":null}",
            "{\"uuid\":\"meta2\",\"type\":\"cost-state\",\"parentUuid\":null}",
        ].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertEqual(s.linked, 2, "only a and b are wired into the chain")
        XCTAssertEqual(s.unreachable, 0)
    }

    /// A live process may be mid-append. Half a record is not a record.
    func testTrailingPartialLineIsIgnored() {
        let text = [rec("a", nil), rec("b", "a")].joined(separator: "\n")
            + "\n{\"uuid\":\"c\",\"parentUu"
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertEqual(s.linked, 2)
        XCTAssertEqual(s.unreachable, 0)
    }

    func testGarbageLinesAreSkippedRatherThanFailingTheSurvey() {
        let text = [rec("a", nil), "not json at all", rec("b", "a")].joined(separator: "\n")
        XCTAssertEqual(TranscriptForks.survey(text: text, sessionId: "s")!.linked, 2)
    }

    func testEmptyTranscriptSurveysToNil() {
        XCTAssertNil(TranscriptForks.survey(text: "", sessionId: "s"))
        XCTAssertNil(TranscriptForks.survey(text: "\n\n", sessionId: "s"))
    }

    /// A cycle must not hang the walk.
    func testCycleTerminates() {
        let text = [rec("a", "b"), rec("b", "a")].joined(separator: "\n")
        XCTAssertNotNil(TranscriptForks.survey(text: text, sessionId: "s"))
    }

    /// The threshold exists so routine parallel-agent branching does not turn
    /// the gate permanently red. Measured gap: 60 stranded records at the top
    /// of the benign population, 1,256 at the bottom of the real one.
    func testThresholdSitsInTheMeasuredGap() {
        XCTAssertGreaterThan(TranscriptForks.significantUnreachable, 60)
        XCTAssertLessThan(TranscriptForks.significantUnreachable, 1256)
    }
}

/// The scoping decisions that keep this out of the deploy gate's way.
extension TranscriptForksTests {

    /// A full sweep parses every line of every transcript. The deploy path runs
    /// `tbase doctor`, so the mtime prefilter is not an optimization, it is what
    /// makes the check affordable there at all.
    func testModifiedWithinSkipsOldTranscripts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forks-\(UUID().uuidString)")
        let project = dir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let body = """
        {"uuid":"a","parentUuid":null,"isSidechain":false}
        {"uuid":"b","parentUuid":"a","isSidechain":false}
        """
        let old = project.appendingPathComponent("old-session.jsonl")
        let fresh = project.appendingPathComponent("new-session.jsonl")
        try body.write(to: old, atomically: true, encoding: .utf8)
        try body.write(to: fresh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)],
            ofItemAtPath: old.path)

        XCTAssertEqual(TranscriptForks.surveyAll(projects: dir).count, 2,
                       "no filter surveys the whole archive")
        let recent = TranscriptForks.surveyAll(projects: dir, modifiedWithin: 7 * 24 * 3600)
        XCTAssertEqual(recent.map(\.sessionId), ["new-session"],
                       "a month-old transcript must not be re-parsed on every deploy")
    }

    /// Routine parallel-agent branching must not be reported as a failure.
    /// Measured: 36 such transcripts held 293 stranded records between them,
    /// while the seven real ones held 1,256 apiece and up.
    func testMinorForksAreBelowTheReportingThreshold() {
        var lines = ["{\"uuid\":\"a\",\"parentUuid\":null,\"isSidechain\":false}"]
        // one main chain, plus a few stray tool-result siblings off the root
        for i in 1...5 { lines.append("{\"uuid\":\"m\(i)\",\"parentUuid\":\"a\",\"isSidechain\":false}") }
        let s = TranscriptForks.survey(text: lines.joined(separator: "\n"), sessionId: "s")!
        XCTAssertTrue(s.isForked, "five children of one node is a fork by definition")
        XCTAssertLessThan(s.unreachable, TranscriptForks.significantUnreachable,
                          "but far too small to be reported as lost conversation")
    }
}
