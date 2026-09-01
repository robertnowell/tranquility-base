import XCTest
@testable import TranquilityCore

/// The drop tray's whole contract, as synthetic timelines (the MicMachine
/// discipline: the value type is the unit under test; the holder only locks).
final class AttachmentTrayTests: XCTestCase {

    // MARK: - Staging

    func testStagingIsPerSessionAndOrdered() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        tray.stage("/a/two.pdf", session: "A")
        tray.stage("/b/other.png", session: "B")
        XCTAssertEqual(tray.staged(for: "A"), ["/a/one.png", "/a/two.pdf"])
        XCTAssertEqual(tray.staged(for: "B"), ["/b/other.png"])
        XCTAssertEqual(tray.staged(for: "C"), [])
    }

    func testReDropOfTheSamePathIsOneChip() {
        var tray = AttachmentTray()
        XCTAssertTrue(tray.stage("/a/one.png", session: "A"))
        XCTAssertFalse(tray.stage("/a/one.png", session: "A"))
        XCTAssertEqual(tray.staged(for: "A"), ["/a/one.png"])
    }

    func testClearStagedIsTheChipCross() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        tray.stage("/b/other.png", session: "B")
        tray.clearStaged(session: "A")
        XCTAssertEqual(tray.staged(for: "A"), [])
        XCTAssertEqual(tray.staged(for: "B"), ["/b/other.png"], "✕ is per session")
    }

    // MARK: - The wrong-session rider (the SEV 1)

    func testAReplyToAnotherSessionCannotSeeTheFiles() {
        var tray = AttachmentTray()
        tray.stage("/a/dashboard.png", session: "A")
        // A reply to B snapshots nothing of A's.
        XCTAssertEqual(tray.snapshot(session: "B", utteranceId: "u1"), [])
        XCTAssertEqual(tray.staged(for: "A"), ["/a/dashboard.png"],
                       "A's chips are untouched by B's send")
    }

    // MARK: - Snapshot and resolve (the lifecycle)

    func testSnapshotMovesStagedToRiding() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        let riding = tray.snapshot(session: "A", utteranceId: "u1")
        XCTAssertEqual(riding, ["/a/one.png"])
        XCTAssertEqual(tray.staged(for: "A"), [], "chips left the tray")
        XCTAssertEqual(tray.riding(utteranceId: "u1"), ["/a/one.png"])
    }

    func testSnapshotIsIdempotentPerUtterance() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        _ = tray.snapshot(session: "A", utteranceId: "u1")
        tray.stage("/a/late.png", session: "A")  // dropped after capture close
        XCTAssertEqual(tray.snapshot(session: "A", utteranceId: "u1"), ["/a/one.png"],
                       "a recompose returns what is riding, never late drops")
        XCTAssertEqual(tray.staged(for: "A"), ["/a/late.png"])
    }

    func testDropDuringUndoWindowJoinsThePendingUtterance() {
        var tray = AttachmentTray()
        tray.stage("/a/first.png", session: "A")
        _ = tray.snapshot(session: "A", utteranceId: "u1")
        tray.stage("/a/late.png", session: "A")

        XCTAssertEqual(tray.absorbStaged(session: "A", utteranceId: "u1"),
                       ["/a/first.png", "/a/late.png"])
        XCTAssertEqual(tray.staged(for: "A"), [])
        XCTAssertEqual(tray.riding(utteranceId: "u1"),
                       ["/a/first.png", "/a/late.png"])
    }

    func testLateDropCannotCrossIntoAnotherSessionsPendingUtterance() {
        var tray = AttachmentTray()
        tray.stage("/a/first.png", session: "A")
        _ = tray.snapshot(session: "A", utteranceId: "u1")
        tray.stage("/b/private.png", session: "B")

        XCTAssertEqual(tray.absorbStaged(session: "B", utteranceId: "u1"),
                       ["/a/first.png"])
        XCTAssertEqual(tray.staged(for: "B"), ["/b/private.png"])
    }

    func testLandedClearsAndNotLandedRestores() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        _ = tray.snapshot(session: "A", utteranceId: "u1")
        tray.resolve(utteranceId: "u1", landed: true)
        XCTAssertEqual(tray.staged(for: "A"), [], "landed: cleared for good")
        XCTAssertEqual(tray.riding(utteranceId: "u1"), [])

        tray.stage("/a/two.png", session: "A")
        _ = tray.snapshot(session: "A", utteranceId: "u2")
        tray.resolve(utteranceId: "u2", landed: false)
        XCTAssertEqual(tray.staged(for: "A"), ["/a/two.png"],
                       "not landed: back to the chips, untouched")
    }

    func testRestoreLandsAheadOfLaterDropsWithoutDuplicating() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        _ = tray.snapshot(session: "A", utteranceId: "u1")
        tray.stage("/a/late.png", session: "A")
        tray.resolve(utteranceId: "u1", landed: false)
        XCTAssertEqual(tray.staged(for: "A"), ["/a/one.png", "/a/late.png"])
    }

    func testLateOutcomeForUnknownUtteranceIsRefusedByConstruction() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        tray.resolve(utteranceId: "never-snapshotted", landed: false)
        XCTAssertEqual(tray.staged(for: "A"), ["/a/one.png"], "nothing moved")
    }

    func testSessionEndKillsChipsButNotRidingEntries() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        _ = tray.snapshot(session: "A", utteranceId: "u1")
        tray.stage("/a/two.png", session: "A")
        tray.sessionEnded("A")
        XCTAssertEqual(tray.staged(for: "A"), [], "chips die with the session")
        XCTAssertEqual(tray.riding(utteranceId: "u1"), ["/a/one.png"],
                       "an in-flight send still resolves normally")
    }

    // MARK: - Message assembly

    func testComposeAppendsQuotedPathsAfterTranscript() {
        let text = AttachmentTray.compose(
            transcript: "here is the repro",
            paths: ["/Users/rob/Screen Shot 2026-08-15.png", "/tmp/log.txt"])
        XCTAssertEqual(text,
            "here is the repro \"/Users/rob/Screen Shot 2026-08-15.png\" \"/tmp/log.txt\"")
    }

    func testComposeWithoutPathsIsTheTranscriptVerbatim() {
        XCTAssertEqual(AttachmentTray.compose(transcript: "go ahead", paths: []),
                       "go ahead")
    }

    func testQuotingEscapesEmbeddedQuotes() {
        XCTAssertEqual(AttachmentTray.quoted("/a/say \"hi\".png"),
                       "\"/a/say \\\"hi\\\".png\"")
    }

    func testComposedTextSurvivesFlatten() {
        // The transport collapses newlines; quoted paths must not smuggle any.
        let text = AttachmentTray.compose(transcript: "see attached",
                                          paths: ["/a/one two.png"])
        XCTAssertEqual(DispatchText.flatten(text), text,
                       "assembly produces a single line already")
    }

    // MARK: - The holder

    func testStoreRoundTrip() {
        let store = AttachmentStore()
        store.stage("/a/one.png", session: "A")
        XCTAssertEqual(store.staged(for: "A"), ["/a/one.png"])
        XCTAssertEqual(store.snapshot(session: "A", utteranceId: "u1"), ["/a/one.png"])
        store.resolve(utteranceId: "u1", landed: false)
        XCTAssertEqual(store.staged(for: "A"), ["/a/one.png"])
        store.clearStaged(session: "A")
        XCTAssertEqual(store.staged(for: "A"), [])
    }
}
