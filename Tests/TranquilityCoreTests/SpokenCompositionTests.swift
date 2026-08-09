import XCTest
@testable import TranquilityCore

/// A2/A4 Core halves: the hail text and the ⌃⌃ depth-1 composition. Both are
/// dormant — nothing in `announceNext` calls them — so these tests are the only
/// executable spec of their contract until the app layer wires them.
final class SpokenCompositionTests: XCTestCase {

    private func waitingSession(callsign: String?) -> WaitingSession {
        WaitingSession(
            sessionId: "sess-1", latestId: 1, createdAtMs: 0, cwd: "/tmp/promotions",
            tty: nil, promptId: nil, transcriptPath: nil, lastAssistantMessage: nil,
            notificationMatcher: nil, summaryText: nil, hookEvent: .stop,
            callsign: callsign)
    }

    private func announcement(
        callsign: String?, brief: SessionBrief
    ) -> Coordinator.Announcement {
        Coordinator.Announcement(
            event: waitingSession(callsign: callsign), brief: brief,
            spoken: SpokenTextSanitizer().sanitize("x"), via: "test", degraded: nil)
    }

    // MARK: - A2: hail

    func testHailTextIsJustTheCallsign() {
        let brief = SessionBrief(topic: "export", happened: "done")
        XCTAssertEqual(
            announcement(callsign: "promotions copy", brief: brief).hailText,
            "promotions copy",
            "the hail speaks the callsign and nothing else — content waits for the pull")
    }

    func testHailTextFallsBackToTheDirectoryWordBeforeMinting() {
        let brief = SessionBrief(topic: "export", happened: "done")
        XCTAssertEqual(announcement(callsign: nil, brief: brief).hailText, "promotions")
    }

    // MARK: - A4: depth-1 composition

    func testDepthOnePrefersTheModelWrittenRationale() {
        let brief = SessionBrief(
            topic: "export", goal: "ship the promotions poller", happened: "done",
            question: "Proceed?",
            risk: "the filter may drop real alerts",
            rationale: "We propose the filter because two thirds of alert volume is "
                + "noise the team ignores. We need to be careful about over-filtering.")
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertTrue(out.text.hasPrefix("We propose the filter"),
                      "the written briefing wins over the card fields: \(out.text)")
        XCTAssertFalse(out.text.contains("promotions copy"),
                       "no callsign on depth-1: the same agent just spoke (ruled 05 Aug)")
        XCTAssertFalse(out.text.contains("Proceed?"),
                       "card fields stay on the card when a rationale exists")
    }

    func testDepthOneFallbackSpeaksPlainClausesWithoutLabelGlue() {
        // Pre-rationale briefs (old rows) still speak — but as content, not as
        // "The goal is …" scaffolding, which read aloud was the original bug.
        let brief = SessionBrief(
            topic: "export", goal: "ship the promotions poller", happened: "done",
            question: "Proceed?",
            risk: "the filter may drop real alerts")
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertEqual(
            out.text,
            "ship the promotions poller. the filter may drop real alerts. Proceed?")
    }

    func testDepthOneSpeaksTheWholeRationale() {
        let long = "We propose running the full migration now because staging "
            + "verified every row count and the legacy table blocks the new queue "
            + "schema from serving reads. We need to be careful because the drop is "
            + "in the same transaction and the only rollback is the nightly backup. "
            + "The session also refreshed twelve fixtures and updated the runbook "
            + "documentation pages afterward."
        let brief = SessionBrief(topic: "export", happened: "done", rationale: long)
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertTrue(out.text.contains("We propose"))
        // The trailing sentence used to be dropped by a 40-word clamp while the
        // card kept showing it. ⌃⌃ means "tell me more"; answering it with a
        // tighter budget than the announcement was backwards (ruled 08 Aug).
        XCTAssertTrue(out.text.contains("runbook"),
                      "the rationale is spoken in full, however long it runs")
        XCTAssertEqual(out.displayIndex(forSpoken: out.text.count), out.displayText.count)
    }

    func testDepthOneSanitizesIdentifiersAndPaths() {
        let brief = SessionBrief(
            topic: "export", goal: "harden the export step", happened: "done",
            risk: "buildLockedLayoutAssets may regress under /Users/x/app/lib")
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertFalse(out.text.contains("buildLockedLayoutAssets"))
        XCTAssertFalse(out.text.contains("/Users"))
        XCTAssertTrue(out.redactions.contains("symbol"))
    }

    func testDepthOneWithNoCardFieldsSaysSoInsteadOfGoingSilent() {
        let brief = SessionBrief(topic: "export", happened: "done")
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertEqual(out.text, "No further rationale recorded.")
    }

    func testDepthOneNeverPrependsAndStripsTheModelsCallsignEcho() {
        // The nastiest case: a field that itself opens with the callsign. The
        // mechanical pass strips it before the single prepend.
        let brief = SessionBrief(
            topic: "export", happened: "done", question: "promotions copy: proceed?")
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertEqual(out.text, "proceed?")
        XCTAssertEqual(out.text.components(separatedBy: "promotions copy").count - 1, 0,
                       "the echo is stripped and nothing is prepended")
    }

    func testDepthOneUnmintedSessionAlsoGetsNoPrefix() {
        let brief = SessionBrief(topic: "export", happened: "done", risk: "tests are flaky")
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: nil, brief: brief))
        XCTAssertEqual(out.text, "tests are flaky.")
    }

    // MARK: - The ⌃⌃ ladder (ruled order: findings → solution → why → message)

    func testLadderRungsFollowTheRuledOrder() {
        let brief = SessionBrief(
            topic: "export", happened: "done",
            rationale: "We propose shipping because staging verified clean.",
            findings: "Three misfiled pieces recovered; the scanner missed one class.",
            solution: "Seven fixes ranked; the top three: scope, snapshots, metrics.")
        let rungs = SpokenComposition.ladderRungs(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertEqual(rungs.count, 4)
        XCTAssertEqual(rungs.map(\.kind), [.findings, .solution, .why, .message],
                       "the ruled order, ending on the original message")
        XCTAssertTrue(rungs[0].spoken.text.contains("misfiled"), "findings first")
        XCTAssertTrue(rungs[1].spoken.text.contains("Seven fixes"), "solution second")
        XCTAssertTrue(rungs[2].spoken.text.contains("We propose shipping"), "why third")
        XCTAssertFalse(rungs.dropLast().contains { $0.spoken.text.contains("promotions copy") },
                       "no callsign anywhere on the explanation rungs")
    }

    func testLadderEndsOnTheOriginalMessageVerbatim() {
        // The rung after WHY is the announcement re-heard, exactly as spoken —
        // never re-sanitized or re-clamped.
        let brief = SessionBrief(topic: "export", happened: "done")
        let ann = announcement(callsign: "promotions copy", brief: brief)
        let rungs = SpokenComposition.ladderRungs(for: ann)
        XCTAssertEqual(rungs.last?.kind, .message)
        XCTAssertEqual(rungs.last?.spoken.text, ann.spoken.text)
    }

    func testLadderSkipsEmptyRungsAndAlwaysHasTheWhy() {
        // A trivial turn: no findings, nothing proposed, no rationale — the
        // ladder is the why (which says so instead of going silent) plus the
        // original message.
        let brief = SessionBrief(topic: "export", happened: "done")
        let rungs = SpokenComposition.ladderRungs(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertEqual(rungs.map(\.kind), [.why, .message])
        XCTAssertEqual(rungs[0].spoken.text, "No further rationale recorded.")
    }

    func testLadderRungsAreSanitizedAndSpokenInFull() {
        let brief = SessionBrief(
            topic: "export", happened: "done",
            findings: "The probe found that buildLockedLayoutAssets regressed. "
                + String(repeating: "A further sentence of trailing detail follows here. ", count: 8))
        let rungs = SpokenComposition.ladderRungs(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertFalse(rungs[0].spoken.text.contains("buildLockedLayoutAssets"),
                       "identifiers are still genericised for the ear")
        XCTAssertEqual(rungs[0].spoken.displayIndex(forSpoken: rungs[0].spoken.text.count),
                       rungs[0].spoken.displayText.count,
                       "a rung speaks all of what its card shows")
    }

}
