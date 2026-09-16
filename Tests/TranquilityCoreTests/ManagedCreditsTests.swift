import XCTest
@testable import TranquilityCore

/// The managed path assembled from what a Mac holds, and nothing else.
///
/// The claims worth testing are the ones a person would feel: a Mac that is
/// not connected keeps its old summariser, an account is asked for once, and
/// the Gateway's address comes from one place.
final class ManagedCreditsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-credits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheGatewayAddressIsBuiltInUnlessTheConfigSaysOtherwise() throws {
        let config = directory.appendingPathComponent("hq.json")
        XCTAssertEqual(ManagedCredits.gatewayURL(config: config), ManagedCredits.builtInGateway)
        try Data(#"{"app":{"base_url":"https://hub.example"},"gateway":{"base_url":"https://gw.example/"}}"#.utf8).write(to: config)
        XCTAssertEqual(ManagedCredits.gatewayURL(config: config).absoluteString, "https://gw.example")
        // Money does not go over plain http because a config file said so.
        try Data(#"{"gateway":{"base_url":"http://gw.example"}}"#.utf8).write(to: config)
        XCTAssertEqual(ManagedCredits.gatewayURL(config: config), ManagedCredits.builtInGateway)
    }

    func testTheOriginIsMadeOnceAndKept() throws {
        let file = directory.appendingPathComponent("origin-id")
        let first = try XCTUnwrap(ManagedCredits.originId(at: file))
        XCTAssertEqual(ManagedCredits.originId(at: file), first)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), first.uuidString.lowercased())
    }

    func testAnUnconnectedMacHasALiveSessionWithoutMakingAKeyOrCallingAService() async {
        let session = ManagedCredits.session(identity: { nil }, outboxURL: directory.appendingPathComponent("outbox.sqlite"))
        await session.refresh()
        XCTAssertEqual(CreditStanding.current, .notOnCredits(connectAgain: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outbox.sqlite").path))
        CreditStanding.reset()
    }

    func testTheAccountIsAskedForOnceAcrossConcurrentFirstSummaries() async throws {
        actor Counting: GatewayTransport {
            var posts = 0
            func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
                XCTAssertEqual(method, "POST"); XCTAssertEqual(path, "/v1/account")
                posts += 1
                try await Task.sleep(for: .milliseconds(20))
                let body = #"{"version":"1","accountId":"7f3c2a10-1111-4222-8333-444455556666","currency":"USD","balance":{"availableMicros":"10000000","reservedMicros":"0","ledgerSequence":"1"}}"#
                return (200, Data(body.utf8))
            }
        }
        let transport = Counting()
        let account = ManagedAccount(transport: transport)
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<10 { group.addTask { try await account.id() } }
            return try await group.reduce(into: [UUID]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(ids).count, 1)
        let posts = await transport.posts
        XCTAssertEqual(posts, 1, "ten first summaries are one account request")
        _ = try await account.id()
        let after = await transport.posts
        XCTAssertEqual(after, 1, "and a resolved account is never asked for again")
    }
}
