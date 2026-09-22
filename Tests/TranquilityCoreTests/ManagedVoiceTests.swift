import Foundation
import XCTest
@testable import TranquilityCore

/// The Gateway's voice routes, answered from a script: the client's job is to
/// address them correctly and to refuse a reply that is not this session's.
final class ManagedVoiceTests: XCTestCase {
    private static let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let session = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    actor Script: GatewayTransport {
        private var seen: [(method: String, path: String, body: String)] = []
        private let reply: @Sendable (String, String) -> (Int, String)
        init(reply: @escaping @Sendable (String, String) -> (Int, String)) { self.reply = reply }
        func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
            seen.append((method, path, body.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
            let (status, text) = reply(method, path)
            return (status, Data(text.utf8))
        }
        func calls() -> [(method: String, path: String, body: String)] { seen }
    }

    /// A running session as the Gateway shapes it; `extra` adds the socket a
    /// start carries.
    static func running(_ extra: String = "") -> String {
        "{\"version\":\"1\",\"accountId\":\"\(account.uuidString.lowercased())\","
        + "\"sessionId\":\"\(session.uuidString.lowercased())\",\"state\":\"running\","
        + "\"startedAt\":\"2026-09-22T04:00:00.000Z\",\"blocks\":1,"
        + "\"renewBy\":\"2026-09-22T04:30:00.000Z\",\"pricebookVersion\":\"placeholder-2026-09-21\""
        + extra + "}"
    }

    func testStartAsksTheRightRouteAndReadsTheSocket() async throws {
        let socket = ",\"wsUrl\":\"wss://us-west.api.pipecat.daily.co/ws/x\",\"token\":\"t-1\""
        let script = Script { _, _ in (200, Self.running(socket)) }
        let client = ManagedVoiceClient(accountId: Self.account, transport: script)
        let started = try await client.start(id: Self.session, keyterms: ["Planning", "projects-3d"])
        XCTAssertEqual(started.wsUrl, "wss://us-west.api.pipecat.daily.co/ws/x")
        XCTAssertEqual(started.token, "t-1")
        XCTAssertEqual(started.renewByDate, ISO8601DateFormatter().date(from: "2026-09-22T04:30:00Z"))
        let calls = await script.calls()
        XCTAssertEqual(calls.first?.method, "PUT")
        XCTAssertEqual(calls.first?.path,
                       "/v1/accounts/\(Self.account.uuidString.lowercased())/voice/sessions/\(Self.session.uuidString.lowercased())")
        XCTAssertTrue(calls.first?.body.contains("Planning") == true, calls.first?.body ?? "")
    }

    func testRenewAndEndAddressTheirVerbs() async throws {
        let script = Script { _, _ in (200, Self.running()) }
        let client = ManagedVoiceClient(accountId: Self.account, transport: script)
        _ = try await client.renew(id: Self.session)
        _ = try await client.end(id: Self.session)
        let calls = await script.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].method, "POST")
        XCTAssertEqual(calls[1].method, "POST")
        XCTAssertTrue(calls[0].path.hasSuffix("/renew"), calls[0].path)
        XCTAssertTrue(calls[1].path.hasSuffix("/end"), calls[1].path)
        XCTAssertEqual(calls[0].body, "", "a renewal carries no body")
    }

    func testAStartWithoutASocketIsNotASession() async throws {
        let script = Script { _, _ in (200, Self.running()) }
        let client = ManagedVoiceClient(accountId: Self.account, transport: script)
        do { _ = try await client.start(id: Self.session); XCTFail("should refuse") }
        catch { XCTAssertEqual(error as? ManagedSummaryFailure, .invalidResponse) }
    }

    func testAnotherSessionsReplyIsRefused() async throws {
        let other = UUID().uuidString.lowercased()
        let body = "{\"version\":\"1\",\"accountId\":\"\(Self.account.uuidString.lowercased())\","
            + "\"sessionId\":\"\(other)\",\"state\":\"running\","
            + "\"startedAt\":\"2026-09-22T04:00:00.000Z\",\"blocks\":1,\"pricebookVersion\":\"p\"}"
        let script = Script { _, _ in (200, body) }
        let client = ManagedVoiceClient(accountId: Self.account, transport: script)
        do { _ = try await client.get(id: Self.session); XCTFail("should refuse") }
        catch { XCTAssertEqual(error as? ManagedSummaryFailure, .invalidResponse) }
    }

    /// 402 is the credit standing the panel already shows; 503 is "hands-free
    /// unavailable". Both arrive as a named refusal, never as a sign-out.
    func testRefusalsKeepTheirNames() async throws {
        for (status, code) in [(402, "insufficient_credit"), (503, "service_unavailable")] {
            let script = Script { _, _ in (status, "{\"error\":{\"code\":\"\(code)\"}}") }
            let client = ManagedVoiceClient(accountId: Self.account, transport: script)
            do { _ = try await client.start(id: Self.session); XCTFail("should refuse") }
            catch { XCTAssertEqual(error as? ManagedSummaryFailure, .refused(code: code, operationId: nil)) }
        }
    }
}
