import XCTest
@testable import TranquilityCore

/// Read is not answered.
///
/// `waitingSessions` used to filter on `max(heardThrough, dismissedThrough)`,
/// collapsing two questions — "has this been told to me" and "have I dealt
/// with it" — into one predicate. Right for announcing, wrong for the lamp:
/// the act of listening extinguished the row and zeroed the badge with the
/// answer still owed (app.log 12 Aug: "announce: spoke via elevenlabs" →
/// "menubar: count=0 (quiet)" seconds apart).
///
/// The model is now ONE list — undismissed Stops — where each row carries its
/// `heard` bit, and the announce path is the only consumer that filters on it.
/// These tests pin the list and the bit at the store, with Robert's scenario
/// as the central case.
final class AttentionTests: XCTestCase {
    var tmpDir: URL!
    var store: QueueStore!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-attention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func append(session: String = "sess-1",
                        message: String = "Export finished. Proceed?") throws {
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000), hookEvent: .stop,
            sessionId: session, promptId: UUID().uuidString, cwd: "/tmp/promotions",
            lastAssistantMessage: message, tty: "ttys001"))
    }

    private func only(_ session: String = "sess-1") throws -> WaitingSession {
        try XCTUnwrap(store.waitingSessions().first { $0.sessionId == session })
    }

    /// A fresh Stop is on the list, unheard: lit AND announceable.
    func testFreshStopIsWaitingAndUnheard() throws {
        try append()
        let row = try only()
        XCTAssertFalse(row.heard, "a fresh Stop has not been told to anyone")
    }

    /// THE regression (Robert, 12 Aug): hearing flips the bit and removes the
    /// row from nothing. It asked a question; listening to the question is
    /// not answering it — the row stays waiting, the badge stays up.
    func testHeardStaysWaitingButNotAnnounceable() throws {
        try append()
        try store.advanceCursor(sessionId: "sess-1", heardThrough: only().latestId)
        let row = try only()
        XCTAssertTrue(row.heard, "the bit records the telling")
        XCTAssertEqual(try store.waitingSessions().count, 1,
                       "heard: still owed an answer — the lamp must stay lit")
        XCTAssertEqual(try store.pendingCount(), 1,
                       "the badge follows the list, not the heard bit")
    }

    /// Dismissal is the attention decision: the row leaves the list, so it is
    /// neither lit nor announceable — one predicate serves both, by design.
    func testDismissRemovesTheRow() throws {
        try append()
        try store.advanceCursor(sessionId: "sess-1", dismissedThrough: only().latestId)
        XCTAssertEqual(try store.waitingSessions().count, 0)
    }

    /// A delivered reply advances both cursors (the dispatch arms write both):
    /// answered, off the list.
    func testDeliveredReplyReadsAsAnswered() throws {
        try append()
        let id = try only().latestId
        try store.advanceCursor(sessionId: "sess-1",
                                heardThrough: id, dismissedThrough: id)
        XCTAssertEqual(try store.waitingSessions().count, 0)
    }

    /// The next turn re-arms everything: a new Stop outranks both cursors, so
    /// an answered session that stops again is lit again and unheard again.
    func testNewStopAfterAnswerRearms() throws {
        try append()
        let first = try only().latestId
        try store.advanceCursor(sessionId: "sess-1",
                                heardThrough: first, dismissedThrough: first)
        try append(message: "Migration done. Ship it?")
        let row = try only()
        XCTAssertFalse(row.heard, "a new Stop is a new question")
        XCTAssertEqual(try store.waitingSessions().count, 1)
    }

    /// The announce filter is `!heard` at the call site; pin it through the
    /// Coordinator's actual selector so the one consumer of the bit cannot
    /// drift from the list without a test noticing.
    func testNextToAnnounceSkipsHeardButKeepsItWaiting() throws {
        try append()
        try append(session: "sess-2", message: "Build green. Merge?")
        let heardId = try only("sess-2").latestId
        try store.advanceCursor(sessionId: "sess-2", heardThrough: heardId)

        let unheard = try store.waitingSessions().filter { !$0.heard }
        XCTAssertEqual(unheard.map(\.sessionId), ["sess-1"],
                       "only the untold session is announceable")
        XCTAssertEqual(try store.waitingSessions().count, 2,
                       "both are still waiting on the user")
    }
}
