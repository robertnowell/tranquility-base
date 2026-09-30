import XCTest
import CryptoKit
@testable import TranquilityCore

/// One account (30 Sep, Robert): a connected Mac signs its own Hub window in.
final class HubWebSessionTests: XCTestCase {
    private let hub = URL(string: "https://hq.example.test")!
    private let signer = DeviceKey.SoftwareSigner()

    private func answer(_ status: Int, _ json: [String: Any]) -> HubWebSession.Post {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return { _ in (status, data) }
    }

    func testTheRequestCarriesTheTokenAProofForThisRouteAndTheLandingPath() async throws {
        let seen = Box<URLRequest>()
        let t = try await HubWebSession.ticket(hub: hub, next: "/d/abc", deviceToken: "hq_tok", signer: signer, post: { req in
            seen.value = req
            return (200, try JSONSerialization.data(withJSONObject: ["url": "https://hq.example.test/sign-in?__clerk_ticket=t", "user": "user_1"]))
        })
        XCTAssertEqual(t.user, "user_1")
        let req = try XCTUnwrap(seen.value)
        XCTAssertEqual(req.url?.absoluteString, "https://hq.example.test/api/devices/web-session")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer hq_tok")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: String]
        XCTAssertEqual(body?["next"], "/d/abc")
        // The proof is for exactly this method and address, with no access token.
        let proof = try XCTUnwrap(req.value(forHTTPHeaderField: "DPoP"))
        let payload = proof.split(separator: ".")[1]
        var b64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let claims = try JSONSerialization.jsonObject(with: Data(base64Encoded: b64)!) as? [String: Any]
        XCTAssertEqual(claims?["htm"] as? String, "POST")
        XCTAssertEqual(claims?["htu"] as? String, "https://hq.example.test/api/devices/web-session")
        XCTAssertNil(claims?["ath"])
    }

    func testANotConnectedMacAsksNothing() async {
        do { _ = try await HubWebSession.ticket(hub: hub, next: "/", deviceToken: "", signer: signer, post: { _ in XCTFail("asked"); return (500, Data()) }); XCTFail("no error") }
        catch { XCTAssertEqual(error as? HubWebSession.Failure, .notConnected) }
    }

    func testARefusalIsAnError() async {
        do { _ = try await HubWebSession.ticket(hub: hub, next: "/", deviceToken: "t", signer: signer, post: answer(401, ["error": "invalid_dpop_proof"])); XCTFail("no error") }
        catch { XCTAssertEqual(error as? HubWebSession.Failure, .refused(status: 401)) }
    }

    func testATicketOffTheHubIsNeverTrusted() async {
        do { _ = try await HubWebSession.ticket(hub: hub, next: "/", deviceToken: "t", signer: signer,
                                                post: answer(200, ["url": "https://evil.example/sign-in", "user": "u"])); XCTFail("no error") }
        catch { XCTAssertEqual(error as? HubWebSession.Failure, .unreadable) }
    }

    func testTheWindowLandsWhereItWasGoing() {
        func land(_ s: String?) -> String { HubWebSession.landing(from: s.flatMap(URL.init(string:))) }
        XCTAssertEqual(land(nil), "/")
        XCTAssertEqual(land("https://hq.example.test/d/abc"), "/d/abc")
        XCTAssertEqual(land("https://hq.example.test/a/s/x?tab=notes"), "/a/s/x?tab=notes")
        XCTAssertEqual(land("https://hq.example.test/sign-in?redirect_url=%2Fshipping"), "/shipping")
        XCTAssertEqual(land("https://hq.example.test/sign-in?redirect_url=%2F%2Fevil.example"), "/")
        XCTAssertEqual(land("https://hq.example.test/sign-in"), "/")
    }
}

private final class Box<T>: @unchecked Sendable { var value: T? }
