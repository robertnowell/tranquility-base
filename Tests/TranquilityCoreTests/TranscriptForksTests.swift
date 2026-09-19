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
                     type: String = "user", retry: Bool = false) -> String {
        var o = "{\"uuid\":\"\(uuid)\",\"type\":\"\(type)\""
        if retry { o += ",\"retryAttempt\":1,\"retryInMs\":2000" }
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
        // Expectation changed 28 Aug with the metric, deliberately. `reachable`
        // used to mean "walked back from the tip", so the sidechain record was
        // outside it and this read 2. The survey now counts what was ABANDONED
        // at a branch point, and a sidechain hanging off `b` is not a branch —
        // nothing here diverged, so nothing is stranded.
        XCTAssertEqual(s.unreachable, 0, "a sidechain tail is not a fork")
        XCTAssertEqual(s.reachable, 3)
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

    func testUTF8RecordsAndCRLFPreserveForkClassification() {
        let records = [rec("根🌳", nil), rec("分岐", "根🌳"),
                       rec("ancien-é", "分岐"), rec("新🛰️", "分岐")]
        for separator in ["\n", "\r\n"] {
            let text = records.joined(separator: separator) + separator + separator
                + "{\"uuid\":\"partial"
            let survey = TranscriptForks.survey(text: text, sessionId: "unicode")
            XCTAssertEqual(survey?.linked, 4)
            XCTAssertEqual(survey?.reachable, 3)
            XCTAssertEqual(survey?.unreachable, 1)
        }
    }

    func testDuplicateRecordTypesPreserveFirstOccurrenceClassification() {
        for firstType in ["attachment", "assistant"] {
            let secondType = firstType == "attachment" ? "assistant" : "attachment"
            let text = [rec("root", nil), rec("duplicate", "root", type: firstType),
                        rec("duplicate", "root", type: secondType),
                        rec("retry", "root", type: "system", retry: true)]
                .joined(separator: "\n")
            let survey = TranscriptForks.survey(text: text, sessionId: "duplicate")
            XCTAssertEqual(survey?.linked, 4)
            XCTAssertEqual(survey?.unreachable, 1)
            XCTAssertEqual(survey?.retryOnly, firstType != "attachment",
                           "branch classification uses the first record with this UUID")
        }
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
    // MARK: - Attachments

    /// THE SHAPE CLAUDE CODE STARTED WRITING IN SEPTEMBER. An `attachment`
    /// record is parented on the assistant record that caused it and lands
    /// about 100 ms BEFORE the real tool_result, so it is a sibling that
    /// loses the branch point every single time. Sixteen of the twenty-nine
    /// transcripts over the threshold on 13 Sep were nothing else.
    func testAnAbandonedAttachmentIsNotLostConversation() {
        let text = [
            rec("a", nil), rec("asst", "a", type: "assistant"),
            rec("att", "asst", type: "attachment"),      // written first, loses
            rec("res", "asst", type: "user"),            // the real continuation
            rec("next", "res", type: "assistant"),
        ].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertEqual(s.unreachable, 0, "an attachment is metadata, not a turn")
        XCTAssertFalse(s.isForked)
    }

    /// And the other half of the rule: an attachment stays in the GRAPH, so
    /// real conversation hanging off one is still counted when it is
    /// abandoned. Dropping the node would strand its descendants and invent
    /// the loss it is meant to stop reporting.
    func testConversationBelowAnAttachmentStillCounts() {
        let text = [
            rec("a", nil), rec("asst", "a", type: "assistant"),
            rec("att", "asst", type: "attachment"),
            rec("said", "att", type: "assistant"),       // real work, abandoned with it
            rec("res", "asst", type: "user"),
            rec("next", "res", type: "assistant"),
        ].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertEqual(s.unreachable, 1, "the assistant record below the attachment")
        XCTAssertTrue(s.isForked)
    }

    /// A failed API request writes a `system` record carrying `retryAttempt`,
    /// parented on whatever was current when the REQUEST started and flushed
    /// at the END of the run — so it wins the branch point and the work done
    /// while the request was in flight becomes the abandoned side. The loss is
    /// real and stays reported; the CAUSE is one process, and saying "a second
    /// writer" was simply false for six of the eleven on this Mac.
    func testARetryRecordWinningIsNotASecondWriter() {
        let text = [
            rec("a", nil), rec("ask", "a", type: "user"),
            rec("said", "ask", type: "assistant"), rec("more", "said", type: "assistant"),
            rec("retry", "ask", type: "system", retry: true),   // back-dated, written last
            rec("after", "retry", type: "assistant"),
        ].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertEqual(s.unreachable, 2, "the two assistant records still count as loss")
        XCTAssertTrue(s.retryOnly)
    }

    /// And a real divergence is still called one, even in a file that also
    /// had a retry.
    func testOneRealDivergenceOutweighsTheRetries() {
        let text = [
            rec("a", nil), rec("ask", "a", type: "user"),
            rec("said", "ask", type: "assistant"),
            rec("retry", "ask", type: "system", retry: true),
            rec("b", "retry", type: "user"),
            rec("x1", "b", type: "assistant"), rec("x2", "x1", type: "assistant"),
            rec("y1", "b", type: "assistant"),          // written last, wins on its own merit
        ].joined(separator: "\n")
        let s = TranscriptForks.survey(text: text, sessionId: "sess")!
        XCTAssertFalse(s.retryOnly, "a conversation record won a branch point here")
    }

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
