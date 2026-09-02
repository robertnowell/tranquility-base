import XCTest
@testable import TranquilityCore

/// A page's footer carries the 8-character slug when the page was claimed by its
/// path, and `latestStop` is an exact lookup on the full session id. So the
/// Discuss button on 107 already-written pages resolved to nothing and reported
/// that a running agent was gone. Those pages cannot be re-stamped, so the
/// lookup has to meet them where they are.
final class SessionPrefixTests: XCTestCase {

    var store: QueueStore!
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-prefix-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func record(_ session: String) {
        _ = try? store.insert(event: QueuedEvent(
            createdAtMs: 1_000, hookEvent: .stop, sessionId: session,
            promptId: "p", cwd: "/tmp", lastAssistantMessage: "done", tty: "ttys1"))
    }

    func testASlugFindsItsSession() throws {
        record("0d04e845-65ff-488f-983c-58f371d661ed")
        XCTAssertEqual(try store.sessionId(matching: "0d04e845"),
                       "0d04e845-65ff-488f-983c-58f371d661ed")
    }

    func testAFullIdStillMatchesItself() throws {
        let id = "0d04e845-65ff-488f-983c-58f371d661ed"
        record(id)
        XCTAssertEqual(try store.sessionId(matching: id), id)
    }

    /// Two sessions sharing a prefix is rare, and opening the wrong
    /// conversation is worse than the invitation the caller falls back to.
    func testAnAmbiguousPrefixRefuses() throws {
        record("abcd1234-0000-0000-0000-000000000001")
        record("abcd1234-0000-0000-0000-000000000002")
        XCTAssertNil(try store.sessionId(matching: "abcd1234"))
    }

    func testAnUnknownPrefixIsNil() throws {
        record("0d04e845-65ff-488f-983c-58f371d661ed")
        XCTAssertNil(try store.sessionId(matching: "ffffffff"))
    }

    /// A page can put any string in a URL, and this one reaches SQL.
    func testJunkIsRefusedBeforeItReachesTheQuery() throws {
        record("0d04e845-65ff-488f-983c-58f371d661ed")
        XCTAssertNil(try store.sessionId(matching: ""))
        XCTAssertNil(try store.sessionId(matching: "%"))
        XCTAssertNil(try store.sessionId(matching: "0d04%"))
        XCTAssertNil(try store.sessionId(matching: "'; DROP TABLE events;--"))
    }
}
