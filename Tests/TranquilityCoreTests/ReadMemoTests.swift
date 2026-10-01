import XCTest
import GRDB
@testable import TranquilityCore

/// The hot reads are answered again only when the database changes, and they
/// must never miss a change, from this connection or any other.
///
/// The other-connection case is the one that would fail quietly: the tbase CLI
/// and a second store in this process write through their own connections,
/// and `data_version` is the only thing that tells this one.
final class ReadMemoTests: XCTestCase {
    var dir: URL!
    var url: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("read-memo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("queue.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func stop(_ store: QueueStore, _ session: String) throws {
        _ = try store.insert(event: QueuedEvent(
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000), hookEvent: .stop,
            sessionId: session, promptId: UUID().uuidString, cwd: "/tmp/p",
            lastAssistantMessage: "Done?", tty: "ttys001"))
    }

    func testTheTokenHoldsStillWhileNothingIsWritten() throws {
        let store = try QueueStore(url: url)
        try stop(store, "a")
        let first = try store.dbQueue.read { try QueueStore.changeToken($0) }
        _ = try store.waitingSessions()
        _ = try store.allKnownSessions()
        let second = try store.dbQueue.read { try QueueStore.changeToken($0) }
        XCTAssertEqual(first, second, "a read must not move the key, or the memo never hits")
    }

    func testThisConnectionsOwnWriteIsSeen() throws {
        let store = try QueueStore(url: url)
        try stop(store, "a")
        XCTAssertEqual(try store.waitingSessions().map(\.sessionId), ["a"])
        try stop(store, "b")
        XCTAssertEqual(Set(try store.waitingSessions().map(\.sessionId)), ["a", "b"])
        XCTAssertEqual(try store.sessionsWithARecordedTurn(), ["a", "b"])
    }

    func testAnotherConnectionsWriteIsSeen() throws {
        let reader = try QueueStore(url: url)
        let writer = try QueueStore(url: url)
        try stop(writer, "a")
        XCTAssertEqual(try reader.waitingSessions().map(\.sessionId), ["a"])
        XCTAssertEqual(try reader.allKnownSessions().count, 1)

        try stop(writer, "b")
        XCTAssertEqual(Set(try reader.waitingSessions().map(\.sessionId)), ["a", "b"],
                       "a commit on another connection must invalidate the memo")
        XCTAssertEqual(try reader.allKnownSessions().count, 2)
        XCTAssertEqual(try reader.latestTurnBoundaries().count, 2)
    }
}
