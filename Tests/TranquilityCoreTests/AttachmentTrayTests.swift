import XCTest
@testable import TranquilityCore

/// The drop tray's whole contract, as synthetic timelines (the MicMachine
/// discipline: the value type is the unit under test; the holder only locks).
final class AttachmentTrayTests: XCTestCase {

    // MARK: - Staging

    /// The typed line rides the dictation as a text chip staged after the
    /// files (ruled 15 Sep): the message the agent receives is the
    /// attachments, then what was typed, then what was said.
    func testATypedLineRidesAfterTheAttachmentsAndBeforeTheWords() {
        var tray = AttachmentTray()
        XCTAssertTrue(tray.stage("'/tmp/shot.png'", session: "A"))
        XCTAssertTrue(tray.stage("see the red box", session: "A"))
        let riding = tray.snapshot(session: "A", utteranceId: "u1")
        XCTAssertEqual(AttachmentTray.compose(transcript: "fix that", fragments: riding),
                       "'/tmp/shot.png'\n\nsee the red box\n\nfix that")
        XCTAssertTrue(tray.staged(for: "A").isEmpty, "the line left with the send")
    }

    func testStagingIsPerSessionAndOrdered() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "A")
        tray.stage("/a/two.pdf", session: "A")
        tray.stage("/b/other.png", session: "B")
        XCTAssertEqual(tray.staged(for: "A"), ["/a/one.png", "/a/two.pdf"])
        XCTAssertEqual(tray.staged(for: "B"), ["/b/other.png"])
        XCTAssertEqual(tray.staged(for: "C"), [])
    }

    /// A screenshot dropped on the greeting card before the agent has an id
    /// stages under the launch's own key and belongs to the session the
    /// launch becomes — the 6 Sep ruling that the card takes drops the moment
    /// it opens.
    func testALaunchsChipsFollowItToTheSessionItBecame() {
        var tray = AttachmentTray()
        tray.stage("/shots/one.png", session: "launch:abc")
        tray.stage("/shots/two.png", session: "launch:abc")
        tray.adopt(stagingKey: "launch:abc", asSession: "S")
        XCTAssertEqual(tray.staged(for: "S"), ["/shots/one.png", "/shots/two.png"])
        // This used to assert the opposite — "the provisional key is spent;
        // nothing can stage against it again" — and that assertion WAS the
        // bug. Spent meant addressable-but-empty: the panel's drop target
        // goes on naming the key for as long as it takes the next ambient
        // tick to re-derive one, so a screenshot dropped a second after
        // registration landed in a hole and was never sent, never shown and
        // never logged. Adoption is a rename now, so the old name still
        // reaches the agent (14 Sep).
        XCTAssertEqual(tray.staged(for: "launch:abc"),
                       ["/shots/one.png", "/shots/two.png"],
                       "the retired key and the session are one tray")
    }

    func testAdoptionAppendsAndDeduplicatesLikeAReDrop() {
        var tray = AttachmentTray()
        tray.stage("/shots/one.png", session: "S")
        tray.stage("/shots/one.png", session: "launch:abc")
        tray.stage("/shots/two.png", session: "launch:abc")
        tray.adopt(stagingKey: "launch:abc", asSession: "S")
        XCTAssertEqual(tray.staged(for: "S"), ["/shots/one.png", "/shots/two.png"])
    }

    func testAdoptingAKeyNothingWasDroppedOnStagesNothingButIsStillRecorded() {
        var tray = AttachmentTray()
        tray.stage("/a/one.png", session: "S")
        tray.adopt(stagingKey: "launch:never", asSession: "S")
        // No chips move: there were none. But the alias IS recorded, and that
        // is the narrow half of the same defect — drop nothing while the
        // agent comes up, drop one a second after it registers, and without
        // the alias that drop has nowhere to go. `adopt` used to return early
        // on an empty key and record nothing at all.
        XCTAssertEqual(tray.staged(for: "S"), ["/a/one.png"])
        XCTAssertTrue(tray.stage("/a/late.png", session: "launch:never"))
        XCTAssertEqual(tray.staged(for: "S"), ["/a/one.png", "/a/late.png"])
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

    func testComposePrependsFragmentsInStagingOrder() {
        let text = AttachmentTray.compose(
            transcript: "here is the repro",
            fragments: ["handoff context", "\"/Users/rob/Screen Shot 2026-08-15.png\""])
        XCTAssertEqual(text,
            "handoff context\n\n\"/Users/rob/Screen Shot 2026-08-15.png\"\n\nhere is the repro")
    }

    func testComposeWithoutFragmentsIsTheTranscriptVerbatim() {
        XCTAssertEqual(AttachmentTray.compose(transcript: "go ahead", fragments: []),
                       "go ahead")
    }

    func testComposeWithoutTranscriptIsTheFragmentsVerbatim() {
        XCTAssertEqual(AttachmentTray.compose(transcript: "", fragments: ["one", "two"]),
                       "one\n\ntwo")
    }

    func testQuotingEscapesEmbeddedQuotes() {
        XCTAssertEqual(AttachmentTray.quoted("/a/say \"hi\".png"),
                       "\"/a/say \\\"hi\\\".png\"")
    }

    func testComposedTextSurvivesFlatten() {
        // The transport deliberately collapses the visual paragraph boundaries
        // before typing into a TUI whose Return key submits.
        let text = AttachmentTray.compose(transcript: "see attached",
                                          fragments: [AttachmentTray.quoted("/a/one two.png")])
        XCTAssertEqual(DispatchText.flatten(text), "\"/a/one two.png\" see attached")
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

// MARK: - Adoption is a rename, not a deletion (14 Sep)

/// The case neither suite made, and the one that lost a screenshot.
///
/// `selftest cardPaste` and `tray-teardown-churn` both pass twenty-odd
/// assertions on every deploy, and neither crosses an adoption: they stage
/// against a fixed key and never run a registration underneath a live drop
/// target. The tray's own tests covered `adopt`; none covered STAGING AFTER
/// one. Measured in Robert's log: a screenshot dropped 0.9 s after
/// registration staged under `launch:b`, a key `adopt` had already emptied
/// and would never visit again. Two staged, one delivered.
final class AttachmentTrayAdoptionTests: XCTestCase {

    func testAFragmentStagedAfterAdoptionStillReachesTheAgent() {
        var tray = AttachmentTray()
        tray.stage("\"/tmp/one.png\"", session: "launch:abc")
        tray.adopt(stagingKey: "launch:abc", asSession: "sess-1")
        // The drop that used to vanish: same key, one second too late.
        XCTAssertTrue(tray.stage("\"/tmp/two.png\"", session: "launch:abc"))
        XCTAssertEqual(tray.staged(for: "sess-1"),
                       ["\"/tmp/one.png\"", "\"/tmp/two.png\""],
                       "both screenshots must ride, whichever key they arrived on")
    }

    func testAdoptionIsRecordedEvenWhenNothingWasStagedYet() {
        // The narrower miss: you drop NOTHING while the agent comes up, and
        // one a second after it registers. `adopt` used to return early on an
        // empty key, so no alias existed and that drop had nowhere to go.
        var tray = AttachmentTray()
        tray.adopt(stagingKey: "launch:abc", asSession: "sess-1")
        XCTAssertTrue(tray.stage("\"/tmp/late.png\"", session: "launch:abc"))
        XCTAssertEqual(tray.staged(for: "sess-1"), ["\"/tmp/late.png\""])
    }

    func testTheRetiredKeyAndTheSessionAreOneTray() {
        var tray = AttachmentTray()
        tray.stage("\"/tmp/one.png\"", session: "launch:abc")
        tray.adopt(stagingKey: "launch:abc", asSession: "sess-1")
        // Reading, de-duplicating and un-staging all follow the alias, so the
        // card cannot show one tray while a send reads another.
        XCTAssertEqual(tray.staged(for: "launch:abc"), tray.staged(for: "sess-1"))
        XCTAssertFalse(tray.stage("\"/tmp/one.png\"", session: "launch:abc"),
                       "a re-drop through the old key is still one chip")
        tray.unstage("\"/tmp/one.png\"", session: "launch:abc")
        XCTAssertTrue(tray.staged(for: "sess-1").isEmpty)
    }

    func testASnapshotThroughTheRetiredKeyRidesUnderTheRealSession() {
        var tray = AttachmentTray()
        tray.stage("\"/tmp/one.png\"", session: "launch:abc")
        tray.adopt(stagingKey: "launch:abc", asSession: "sess-1")
        XCTAssertEqual(tray.snapshot(session: "launch:abc", utteranceId: "u1"),
                       ["\"/tmp/one.png\""])
        // And a failed send returns them to the SESSION, not to the dead key.
        tray.resolve(utteranceId: "u1", landed: false)
        XCTAssertEqual(tray.staged(for: "sess-1"), ["\"/tmp/one.png\""])
    }

    func testTwoLaunchesNeverShareATray() {
        // The leak the per-session tray exists to prevent, re-checked now
        // that keys can alias: one client's screenshot must never follow the
        // other's alias into the wrong transcript.
        var tray = AttachmentTray()
        tray.stage("\"/tmp/a.png\"", session: "launch:aaa")
        tray.stage("\"/tmp/b.png\"", session: "launch:bbb")
        tray.adopt(stagingKey: "launch:aaa", asSession: "sess-a")
        tray.adopt(stagingKey: "launch:bbb", asSession: "sess-b")
        XCTAssertEqual(tray.staged(for: "sess-a"), ["\"/tmp/a.png\""])
        XCTAssertEqual(tray.staged(for: "sess-b"), ["\"/tmp/b.png\""])
    }

    func testEndingASessionRetiresItsAliasesToo() {
        var tray = AttachmentTray()
        tray.adopt(stagingKey: "launch:abc", asSession: "sess-1")
        tray.stage("\"/tmp/one.png\"", session: "launch:abc")
        tray.sessionEnded("sess-1")
        XCTAssertTrue(tray.staged(for: "sess-1").isEmpty)
        // The retired key must not go on collecting fragments for an agent
        // nobody can reach; it is its own tray again, not a pipe to a corpse.
        tray.stage("\"/tmp/two.png\"", session: "launch:abc")
        XCTAssertTrue(tray.staged(for: "sess-1").isEmpty)
    }

    // MARK: - The developer's tray (hands-free, ruled 22 Sep)

    func testAManagerSendTakesEverythingStagedWhicheverAgentItWasFor() {
        var tray = AttachmentTray()
        XCTAssertTrue(tray.stage("'/tmp/a.png'", session: "sess-a"))
        XCTAssertTrue(tray.stage("'/tmp/b.png'", session: "sess-b"))
        let riding = tray.snapshotAll(into: "sess-b", utteranceId: "u1")
        XCTAssertEqual(Set(riding), ["'/tmp/a.png'", "'/tmp/b.png'"])
        XCTAssertTrue(tray.staged(for: "sess-a").isEmpty)
        XCTAssertTrue(tray.staged(for: "sess-b").isEmpty)
        XCTAssertFalse(tray.hasAnythingStaged)
        XCTAssertEqual(tray.snapshotAll(into: "sess-b", utteranceId: "u1"), riding, "idempotent per utterance")
    }

    func testAFailedManagerSendPutsTheChipsBackOnItsTarget() {
        var tray = AttachmentTray()
        XCTAssertTrue(tray.stage("'/tmp/a.png'", session: "sess-a"))
        _ = tray.snapshotAll(into: "sess-b", utteranceId: "u1")
        tray.resolve(utteranceId: "u1", landed: false)
        XCTAssertEqual(tray.staged(for: "sess-b"), ["'/tmp/a.png'"])
    }

    func testThePanelsOwnSendStaysPerSession() {
        var tray = AttachmentTray()
        XCTAssertTrue(tray.stage("'/tmp/a.png'", session: "sess-a"))
        XCTAssertTrue(tray.snapshot(session: "sess-b", utteranceId: "u2").isEmpty)
        XCTAssertEqual(tray.staged(for: "sess-a"), ["'/tmp/a.png'"])
    }
}
