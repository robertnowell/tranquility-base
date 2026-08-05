import XCTest
@testable import VoiceDispatchCore

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
        XCTAssertTrue(out.text.hasPrefix("promotions copy: We propose the filter"),
                      "the written briefing wins over the card fields: \(out.text)")
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
            "promotions copy: ship the promotions poller. "
            + "the filter may drop real alerts. Proceed?")
    }

    func testDepthOneWordBudgetClampsTheRationaleAtASentenceBoundary() {
        let long = "We propose running the full migration now because staging "
            + "verified every row count and the legacy table blocks the new queue "
            + "schema from serving reads. We need to be careful because the drop is "
            + "in the same transaction and the only rollback is the nightly backup. "
            + "The session also refreshed twelve fixtures and updated the runbook "
            + "documentation pages afterward."
        let brief = SessionBrief(topic: "export", happened: "done", rationale: long)
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertTrue(out.text.contains("We propose"), "the why always survives the clamp")
        XCTAssertFalse(out.text.contains("runbook"),
                       "over budget, the trailing sentence goes whole — never mid-clause")
        // Budget bounds the composed body; the mechanical callsign prefix (2
        // words) rides on top of it.
        XCTAssertLessThanOrEqual(out.wordCount, SpokenComposition.depthOneMaxWords + 2)
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
        XCTAssertEqual(out.text, "promotions copy: No further rationale recorded.")
    }

    func testDepthOneCallsignPrefixAppearsExactlyOnce() {
        // The nastiest case: a field that itself opens with the callsign. The
        // mechanical pass strips it before the single prepend.
        let brief = SessionBrief(
            topic: "export", happened: "done", question: "promotions copy: proceed?")
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: "promotions copy", brief: brief))
        XCTAssertEqual(out.text, "promotions copy: proceed?")
        XCTAssertEqual(out.text.components(separatedBy: "promotions copy").count - 1, 1)
    }

    func testDepthOneUnmintedSessionUsesTheDirectoryWordPrefix() {
        let brief = SessionBrief(topic: "export", happened: "done", risk: "tests are flaky")
        let out = SpokenComposition.depthOneSpokenText(
            for: announcement(callsign: nil, brief: brief))
        XCTAssertEqual(out.text, "promotions: tests are flaky.")
    }
}
