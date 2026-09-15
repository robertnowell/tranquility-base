import XCTest
@testable import TranquilityCore

final class ACPCatalogTests: XCTestCase {

    /// **An entry is a name and commands, and nothing else.** The moment a
    /// capability column appears here it is a copy of somebody else's fact
    /// that goes stale on their next release, which is precisely what the
    /// handshake exists to prevent. This test is the tripwire. `open` is the
    /// second command (the vendor's own interface on a session), argv like
    /// `command` and the same kind of fact: where a binary is and what to
    /// pass it, which no handshake can tell us.
    func testAnEntryDeclaresNoCapabilities() {
        let mirror = Mirror(reflecting: ACPCatalog.published[0])
        XCTAssertEqual(Set(mirror.children.compactMap(\.label)), ["id", "name", "command", "open"],
                       "a catalog entry grew a field; capabilities come from the handshake")
    }

    /// The door opens the same binary the protocol runs, on the session.
    func testTheOpenLineIsTheSameBinaryOnTheSession() {
        let entry = ACPCatalog.published.first { $0.id == "opencode" }!
        XCTAssertEqual(entry.openLine(session: "ses_1", binary: "/x/bin/opencode"),
                       "'/x/bin/opencode' '--session' 'ses_1'")
        let cursor = ACPCatalog.published.first { $0.id == "cursor" }!
        XCTAssertNil(cursor.openLine(session: "s", binary: "/x/cursor-agent"),
                     "a vendor with no known door offers none rather than a guess")
    }

    func testEveryPublishedEntryHasAUniqueIdAndANonEmptyCommand() {
        let ids = ACPCatalog.published.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "catalog ids collide")
        for entry in ACPCatalog.published {
            XCTAssertFalse(entry.command.isEmpty, "\(entry.id) has no command")
            XCTAssertFalse(entry.name.isEmpty, "\(entry.id) has no name")
        }
    }

    /// A GUI app inherits launchd's PATH, not the user's shell, so trusting
    /// `PATH` alone would report every one of these as missing. That defect is
    /// already on the record once, for Codex.
    func testAnAgentIsFoundOnTheSearchPathRatherThanThroughPATH() {
        let entry = ACPCatalog.Entry(id: "x", name: "X", command: ["thing", "acp"])
        let resolved = ACPCatalog.resolve(entry, paths: ["/nope", "/opt/homebrew/bin"],
                                          exists: { $0 == "/opt/homebrew/bin/thing" })
        XCTAssertEqual(resolved, ["/opt/homebrew/bin/thing", "acp"],
                       "the argv keeps its arguments and gains a resolved executable")
    }

    func testAnAgentThisMachineDoesNotHaveIsAbsentRatherThanBroken() {
        XCTAssertNil(ACPCatalog.resolve(ACPCatalog.published[0], paths: ["/nope"],
                                        exists: { _ in false }))
        XCTAssertTrue(ACPCatalog.installed(paths: ["/nope"], exists: { _ in false }).isEmpty)
    }

    /// An absolute path in the table is taken as given, which is what lets a
    /// hand-configured agent work without a second code path.
    func testAnAbsolutePathIsHonouredWithoutSearching() {
        let entry = ACPCatalog.Entry(id: "x", name: "X", command: ["/custom/agent", "acp"])
        XCTAssertEqual(ACPCatalog.resolve(entry, paths: [], exists: { $0 == "/custom/agent" }),
                       ["/custom/agent", "acp"])
        XCTAssertNil(ACPCatalog.resolve(entry, paths: [], exists: { _ in false }))
    }

    /// The catalog is a LIST, not a filter: an agent nobody has installed is
    /// still listed, because "which agents could I use" has to be answerable.
    func testTheCatalogListsAgentsThisMachineDoesNotHave() {
        XCTAssertTrue(ACPCatalog.published.count > ACPCatalog.installed().count
                        || ACPCatalog.installed().count == ACPCatalog.published.count,
                      "installed is a subset of published, never the other way round")
        XCTAssertTrue(ACPCatalog.published.contains { $0.id == "cursor" })
        XCTAssertTrue(ACPCatalog.published.contains { $0.id == "gemini" })
    }
}
