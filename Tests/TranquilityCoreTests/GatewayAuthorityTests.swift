import XCTest
@testable import TranquilityCore

/// Free-standing so the @Sendable exchange closures need not capture a test case.
private func minted(_ token: String, expiresIn: Int = 900) -> (Int, Data) {
    (200, Data(#"{"access_token":"\#(token)","token_type":"DPoP","expires_in":\#(expiresIn)}"#.utf8))
}

/// Authority to spend: fetched silently, cached, and never confused with
/// being signed in.
///
/// The cases that matter here are not the happy one. They are the four ways
/// this can go wrong in a way the person would feel: asking ten times when
/// once would do, holding a credential past a sign-out, sending someone back
/// to a browser because a service was down, and treating a Mac that predates
/// key binding as broken rather than as needing to connect again.
final class GatewayAuthorityTests: XCTestCase {

    private func authority(
        deviceToken: String? = "hq_device_token",
        clock: @escaping @Sendable () -> Date = { Date() },
        exchange: @escaping GatewayAuthority.Exchange
    ) -> GatewayAuthority {
        GatewayAuthority(
            signer: DeviceKey.SoftwareSigner(),
            hubBase: URL(string: "https://hub.example")!,
            deviceToken: { deviceToken },
            exchange: exchange,
            now: clock)
    }

    func testABearerIsFetchedOnceAndReused() async throws {
        let calls = Counter()
        let a = authority { _, _ in await calls.bump(); return minted("first") }
        let one = try await a.bearer()
        let two = try await a.bearer()
        XCTAssertEqual(one, "first")
        XCTAssertEqual(two, "first")
        let count = await calls.value
        XCTAssertEqual(count, 1, "a cached bearer must not be re-fetched")
    }

    /// Ten callers at once produce one request, not ten. The app asks for a
    /// bearer on every managed operation, so this is the difference between a
    /// silent refresh and a stampede against the hub.
    func testConcurrentCallersCoalesceIntoOneRequest() async throws {
        let calls = Counter()
        let a = authority { _, _ in
            await calls.bump()
            try? await Task.sleep(nanoseconds: 30_000_000)
            return minted("shared")
        }
        let results = await withTaskGroup(of: String?.self) { group -> [String?] in
            for _ in 0..<10 { group.addTask { try? await a.bearer() } }
            var all: [String?] = []
            for await r in group { all.append(r) }
            return all
        }
        XCTAssertEqual(Set(results.compactMap { $0 }), ["shared"])
        let count = await calls.value
        XCTAssertEqual(count, 1, "ten callers must produce one exchange")
    }

    /// A token about to expire is replaced before it is used, not after it
    /// fails. The margin exists so a request never begins with a credential
    /// that dies in flight.
    func testATokenNearExpiryIsRefreshedBeforeItIsHandedOut() async throws {
        let calls = Counter()
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let a = authority(clock: { clock.now }) { _, _ in
            await calls.bump()
            let n = await calls.value
            return minted(n == 1 ? "first" : "second", expiresIn: 900)
        }
        let first = try await a.bearer()
        XCTAssertEqual(first, "first")
        // 880 seconds later: 20 left, inside the 60-second margin.
        clock.advance(880)
        let second = try await a.bearer()
        XCTAssertEqual(second, "second")
    }

    /// Sign-out drops the grant AND cancels a refresh in flight. A refresh
    /// begun as one account must never install its result afterwards; that is
    /// how one person's credential comes to serve another.
    func testSignOutForgetsEverythingIncludingAnInFlightRefresh() async throws {
        let a = authority { _, _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return minted("late-arrival")
        }
        let pending = Task { try await a.bearer() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await a.clear()
        _ = try? await pending.value

        // Whatever happened to that request, nothing it returned is cached.
        let calls = Counter()
        let fresh = authority { _, _ in await calls.bump(); return minted("after") }
        let after = try await fresh.bearer()
        XCTAssertEqual(after, "after")
    }

    /// The four refusals, each of which the app must present differently.
    func testEachRefusalKeepsItsOwnMeaning() async throws {
        let unconnected = authority(deviceToken: nil) { _, _ in minted("never") }
        await assertFails(unconnected, with: .notConnected)

        let rejected = authority { _, _ in (401, Data(#"{"error":"auth_required"}"#.utf8)) }
        await assertFails(rejected, with: .connectionRejected)

        let unbound = authority { _, _ in (403, Data(#"{"error":"rebinding_required"}"#.utf8)) }
        await assertFails(unbound, with: .rebindingRequired)

        // 503 is the one that must NOT read as a sign-out. An outage leaves
        // the person signed in and managed work waiting.
        let down = authority { _, _ in (503, Data(#"{"error":"service_unavailable"}"#.utf8)) }
        await assertFails(down, with: .temporarilyUnavailable)

        // A 200 the app cannot parse is a service problem, not a credential one.
        let garbled = authority { _, _ in (200, Data("{".utf8)) }
        await assertFails(garbled, with: .temporarilyUnavailable)
    }

    /// The request carries both credentials, and the proof is for this URL.
    func testTheExchangeCarriesADeviceTokenAndAProofForThisRoute() async throws {
        let seen = Box()
        let a = authority { proof, token in
            await seen.set(proof: proof, token: token)
            return minted("ok")
        }
        _ = try await a.bearer()
        let (proof, token) = await seen.value
        XCTAssertEqual(token, "hq_device_token")
        let parts = try XCTUnwrap(proof).split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(Data(base64URLEncoded: parts[1]))) as? [String: Any])
        XCTAssertEqual(claims["htm"] as? String, "POST")
        XCTAssertEqual(claims["htu"] as? String, "https://hub.example/api/gateway/token")
        // No access token exists yet: this is the request that asks for one.
        XCTAssertNil(claims["ath"])
    }

    private func assertFails(_ a: GatewayAuthority, with expected: GatewayAuthority.Failure,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await a.bearer()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let failure as GatewayAuthority.Failure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

/// A key made once is the key used for ever: re-making it would orphan the
/// thumbprint the hub recorded, and every request would be refused with a
/// perfectly valid key.
final class DeviceKeyStoreTests: XCTestCase {

    func testAStoredKeyIsReusedRatherThanRemade() throws {
        var stored: String?
        let first = try DeviceKeyStore.resolve(
            load: { stored }, save: { stored = $0 },
            makeEnclave: { _ in nil })
        XCTAssertTrue(first.created)
        XCTAssertNotNil(stored)

        let second = try DeviceKeyStore.resolve(
            load: { stored }, save: { stored = $0 },
            makeEnclave: { _ in nil })
        XCTAssertFalse(second.created)
        XCTAssertEqual(first.signer.publicJWK, second.signer.publicJWK,
                       "a remade key would orphan the thumbprint the hub holds")
    }

    /// The 2019 iMac: no enclave, so a software key, and the code says which
    /// it got rather than letting a caller assume the stronger guarantee.
    func testWithoutAnEnclaveItFallsBackAndSaysSo() throws {
        var stored: String?
        let resolved = try DeviceKeyStore.resolve(
            load: { stored }, save: { stored = $0 }, makeEnclave: { _ in nil })
        XCTAssertEqual(resolved.signer.storage, .softwareKey)
    }
}

// MARK: - Small helpers

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

private actor Box {
    private var proof: String?
    private var token: String?
    func set(proof: String, token: String) { self.proof = proof; self.token = token }
    var value: (String?, String?) { (proof, token) }
}

private final class Clock: @unchecked Sendable {
    private(set) var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
