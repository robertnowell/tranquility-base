import XCTest
@testable import TranquilityCore

/// Read is not answered.
///
/// The store has always had two cursors — `heardThrough` and `dismissedThrough`
/// — and `waitingSessions` collapses them with max(), which is the right
/// predicate for the announce queue (nothing is read twice) and was the wrong
/// one for the grid: the act of listening extinguished the lamp, so a session
/// that had just asked a question went visually idle the moment you heard it
/// ask, and the menu-bar badge dropped to 0 with the answer still owed
/// (app.log 12 Aug: "announce: spoke via elevenlabs" → "menubar: count=0
/// (quiet)" seconds apart). `needsAttention` is the second predicate: gated on
/// `dismissedThrough` alone, it keeps a heard session on the user until a
/// reply is delivered, the lamp is clicked, or the session dies.
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

    private func latestId(_ session: String = "sess-1") throws -> Int64 {
        try XCTUnwrap(store.waitingSessionsIncludingHeard()
            .first { $0.sessionId == session }).latestId
    }

    /// A fresh Stop is in both lists: unheard AND on you.
    func testFreshStopIsInBothQueues() throws {
        try append()
        XCTAssertEqual(try store.waitingSessions().count, 1)
        XCTAssertEqual(try store.needsAttention().count, 1)
    }

    /// THE regression (Robert, 12 Aug): hearing the announcement removes the
    /// session from the announce queue and from nothing else. It asked a
    /// question; listening to the question is not answering it.
    func testHeardLeavesTheAnnounceQueueAndStaysOnYou() throws {
        try append()
        try store.advanceCursor(sessionId: "sess-1", heardThrough: latestId())
        XCTAssertEqual(try store.waitingSessions().count, 0,
                       "heard: must not be announced again")
        XCTAssertEqual(try store.needsAttention().count, 1,
                       "heard: still owed an answer — the lamp must stay lit")
        XCTAssertEqual(try store.attentionCount(), 1,
                       "the badge follows the lamp, not the announce queue")
    }

    /// Dismissal is a decision about attention and clears both queues — the
    /// announce predicate takes the max of the cursors, so a clicked lamp is
    /// also never announced.
    func testDismissClearsBothQueues() throws {
        try append()
        try store.advanceCursor(sessionId: "sess-1", dismissedThrough: latestId())
        XCTAssertEqual(try store.waitingSessions().count, 0)
        XCTAssertEqual(try store.needsAttention().count, 0)
    }

    /// A delivered reply advances both cursors (the dispatch arms write both),
    /// which is the same state dismissal reaches: answered.
    func testDeliveredReplyReadsAsAnswered() throws {
        try append()
        let id = try latestId()
        try store.advanceCursor(sessionId: "sess-1",
                                heardThrough: id, dismissedThrough: id)
        XCTAssertEqual(try store.waitingSessions().count, 0)
        XCTAssertEqual(try store.needsAttention().count, 0)
    }

    /// The next turn re-arms everything: a new Stop outranks both cursors, so
    /// an answered session that stops again is announced again and lit again.
    func testNewStopAfterAnswerRearmsBothQueues() throws {
        try append()
        let first = try latestId()
        try store.advanceCursor(sessionId: "sess-1",
                                heardThrough: first, dismissedThrough: first)
        try append(message: "Migration done. Ship it?")
        XCTAssertEqual(try store.waitingSessions().count, 1)
        XCTAssertEqual(try store.needsAttention().count, 1)
    }

    /// Heard-then-dismissed and dismissed-then-heard converge: cursor order
    /// must not matter, only the questions each cursor answers.
    func testCursorOrderDoesNotMatter() throws {
        try append()
        let id = try latestId()
        try store.advanceCursor(sessionId: "sess-1", heardThrough: id)
        try store.advanceCursor(sessionId: "sess-1", dismissedThrough: id)
        XCTAssertEqual(try store.needsAttention().count, 0)

        try append(session: "sess-2")
        let id2 = try XCTUnwrap(try store.waitingSessionsIncludingHeard()
            .first { $0.sessionId == "sess-2" }).latestId
        try store.advanceCursor(sessionId: "sess-2", dismissedThrough: id2)
        try store.advanceCursor(sessionId: "sess-2", heardThrough: id2)
        XCTAssertEqual(try store.needsAttention().count, 0)
        XCTAssertEqual(try store.waitingSessions().count, 0)
    }
}
