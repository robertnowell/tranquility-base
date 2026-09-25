import XCTest
@testable import TranquilityCore

/// A relay or only a reflector — the distinction the whole change is about.
///
/// Until 25 Sep the app had one hardcoded STUN server. STUN tells a client its
/// own public address and carries no audio, so a user behind a symmetric NAT or
/// a firewall that blocks UDP got a session that never connected, with nothing
/// to try. These hold the parse and the distinction, against the shape
/// Cloudflare's credential API actually answers with.
final class IceServersTests: XCTestCase {
    /// Verbatim from the documented response of
    /// POST /v1/turn/keys/$ID/credentials/generate-ice-servers.
    private let minted: [[String: Any]] = [
        ["urls": ["stun:stun.cloudflare.com:3478"]],
        ["urls": ["turn:turn.cloudflare.com:3478?transport=udp",
                  "turns:turn.cloudflare.com:443?transport=tcp"],
         "username": "u-123", "credential": "c-456"],
    ]

    func testAMintedAnswerParsesWithItsCredentials() {
        let servers = IceServers.parse(minted)
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[1].username, "u-123")
        XCTAssertEqual(servers[1].credential, "c-456")
    }

    func testOnlyTheRelayCountsAsOne() {
        let servers = IceServers.parse(minted)
        XCTAssertFalse(servers[0].relays, "stun reflects; it does not relay")
        XCTAssertTrue(servers[1].relays)
        XCTAssertEqual(IceServers.describe(servers), "2 ice server(s), 1 that can relay")
    }

    /// `turns:` on 443 over TCP is the entry that survives a network which
    /// blocks UDP outright, so it must not be dropped in parsing.
    func testTheEntryThatSurvivesAHostileNetworkIsKept() {
        let relay = IceServers.parse(minted)[1]
        XCTAssertTrue(relay.urls.contains("turns:turn.cloudflare.com:443?transport=tcp"))
    }

    /// A hand-written config is likelier to say `url`; a minted one says `urls`.
    func testBothSpellingsOfTheKey() {
        XCTAssertEqual(IceServers.parse([["url": "stun:example:3478"]]).first?.urls,
                       ["stun:example:3478"])
        XCTAssertEqual(IceServers.parse([["urls": "turn:example:3478"]]).first?.urls,
                       ["turn:example:3478"])
    }

    /// Nothing usable means "fall back", never "route nowhere".
    func testGarbageParsesToNothingRatherThanASilentDeadEnd() {
        XCTAssertTrue(IceServers.parse(nil).isEmpty)
        XCTAssertTrue(IceServers.parse("turn:example").isEmpty)
        XCTAssertTrue(IceServers.parse([["username": "u"]]).isEmpty, "no urls is not a server")
        XCTAssertFalse(IceServers.stunOnly.isEmpty)
        XCTAssertFalse(IceServers.stunOnly[0].relays, "the fallback cannot relay, and says so")
    }
}
