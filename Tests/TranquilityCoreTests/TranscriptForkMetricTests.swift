import XCTest
@testable import TranquilityCore

/// What the fork survey must NOT call loss.
///
/// Written 28 Aug after the survey reported 32,299 unreachable records across
/// 262 transcripts, and the true figure — conversation actually abandoned at a
/// branch point — was two orders of magnitude smaller. Two separate mistakes
/// produced that, and each one is pinned below, because both were plausible
/// enough to ship and neither showed up on the sessions I spot-checked first.
final class TranscriptForkMetricTests: XCTestCase {

    private func line(_ uuid: String, parent: String?, logical: String? = nil,
                      type: String = "user", subtype: String? = nil) -> String {
        var o = ["uuid": "\"\(uuid)\"", "type": "\"\(type)\""]
        o["parentUuid"] = parent.map { "\"\($0)\"" } ?? "null"
        if let logical { o["logicalParentUuid"] = "\"\(logical)\"" }
        if let subtype { o["subtype"] = "\"\(subtype)\"" }
        return "{" + o.map { "\"\($0.key.replacingOccurrences(of: "\"", with: ""))\":\($0.value)" }
            .joined(separator: ",") + "}"
    }

    /// COMPACTION IS NOT A FORK.
    ///
    /// A compacted conversation continues in a new segment whose first record
    /// has no parent. Measuring "reachable from the newest leaf" therefore
    /// counts every earlier segment as lost, and the count grows with the
    /// session's AGE rather than with anything going wrong — which is why the
    /// loudest sessions were simply the oldest ones.
    func testSequentialSegmentsAreNotLoss() {
        let text = [
            line("a", parent: nil), line("b", parent: "a"), line("c", parent: "b"),
            // A new segment. No parent, no divergence — the conversation just
            // carried on after a compaction.
            line("d", parent: nil, type: "system", subtype: "compact_boundary"),
            line("e", parent: "d"), line("f", parent: "e"),
        ].joined(separator: "\n")
        let survey = TranscriptForks.survey(text: text, sessionId: "seq")
        XCTAssertEqual(survey?.unreachable, 0,
                       "a second segment is a continuation, not an abandoned branch")
        XCTAssertFalse(survey?.isForked ?? true)
    }

    /// AND `logicalParentUuid` MUST NOT BE USED TO FIX THAT.
    ///
    /// It was the obvious repair and it invents a fork. A manual `/compact`
    /// writes its boundary BEFORE replaying the resume preamble, so the
    /// boundary's logical parent is a record that descends from that preamble:
    /// following the logical edge closes a loop, and a subtree walk around it
    /// hands both children of the branch point the SAME records. Measured on
    /// f30bb890 the file reported 2,490 abandoned records over a near-perfect
    /// 50/50 split of three days' work that never diverged at all; the true
    /// figure is 44.
    func testTheLogicalEdgeIsNotFollowedIntoACycle() {
        let text = [
            line("a", parent: nil), line("b", parent: "a"),
            // The boundary, written first, pointing BACK at a record that is
            // itself a descendant of the replayed preamble below it.
            line("boundary", parent: nil, logical: "preamble",
                 type: "system", subtype: "compact_boundary"),
            line("summary", parent: "boundary"),
            line("preamble", parent: "summary", type: "attachment"),
            line("next", parent: "preamble"), line("last", parent: "next"),
        ].joined(separator: "\n")
        let survey = TranscriptForks.survey(text: text, sessionId: "cycle")
        XCTAssertEqual(survey?.unreachable, 0,
                       "a compact back-pointer is not a branch point")
    }

    /// A real fork: one record, two children, one lineage continued.
    func testAnAbandonedBranchIsCounted() {
        let text = [
            line("a", parent: nil), line("fork", parent: "a"),
            // Abandoned: written first, then left behind.
            line("x1", parent: "fork"), line("x2", parent: "x1"),
            // Survivor: reaches furthest down the file, which is the branch a
            // resume follows.
            line("y1", parent: "fork"), line("y2", parent: "y1"), line("y3", parent: "y2"),
        ].joined(separator: "\n")
        let survey = TranscriptForks.survey(text: text, sessionId: "fork")
        XCTAssertEqual(survey?.unreachable, 2, "x1 and x2 were abandoned")
        XCTAssertTrue(survey?.isForked ?? false)
    }

    /// The survivor is decided PER BRANCH POINT, not by the file's newest leaf.
    ///
    /// "Is this child on the path to the last record" only answers correctly
    /// inside the final segment. In an earlier one no child is on that path, so
    /// the lineage that actually continued gets counted as abandoned too — 4,307
    /// records in a file whose real divergence was nil.
    func testAnEarlierSegmentsOwnBranchIsJudgedWithinThatSegment() {
        let text = [
            line("a", parent: nil), line("fork", parent: "a"),
            line("dead", parent: "fork"),
            line("kept1", parent: "fork"), line("kept2", parent: "kept1"),
            // A later segment entirely. Nothing here is downstream of `fork`.
            line("s2", parent: nil), line("s2b", parent: "s2"),
        ].joined(separator: "\n")
        let survey = TranscriptForks.survey(text: text, sessionId: "earlier")
        XCTAssertEqual(survey?.unreachable, 1, "only `dead` was abandoned")
    }

    /// Nested branch points must not count the same record twice. The first
    /// implementation summed a subtree per branch point and reported 89,380
    /// abandoned records in a 6,782-record file.
    func testANestedBranchIsCountedOnce() {
        let text = [
            line("a", parent: nil), line("fork", parent: "a"),
            line("d1", parent: "fork"), line("d2", parent: "d1"),
            line("d2b", parent: "d1"),
            line("k1", parent: "fork"), line("k2", parent: "k1"),
        ].joined(separator: "\n")
        let survey = TranscriptForks.survey(text: text, sessionId: "nested")
        XCTAssertEqual(survey?.unreachable, 3, "d1, d2, d2b — each once")
    }
}
