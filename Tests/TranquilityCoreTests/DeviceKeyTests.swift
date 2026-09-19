import CryptoKit
import XCTest
@testable import TranquilityCore

/// The key this Mac proves itself with.
///
/// Almost everything here is about agreeing with two other languages about
/// bytes. A proof that is correct in Swift and canonicalized differently from
/// the hub's is refused with a valid signature and a valid key, which is the
/// least diagnosable failure in the whole design, so the fingerprint and the
/// encoding are pinned to a shared vector rather than to this code's opinion.
final class DeviceKeyTests: XCTestCase {

    private func vector() throws -> [String: Any] {
        // The contract lives beside the sources, and the test reads the real
        // file rather than a copy: a vector duplicated into a test is a vector
        // that can drift from the one the other languages read.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("contracts/gateway/v1/dpop-vectors.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// RFC 7638, against a fingerprint computed by a different implementation.
    func testThumbprintAgreesWithTheSharedVector() throws {
        let v = try vector()
        let jwkFields = try XCTUnwrap(v["publicJWK"] as? [String: String])
        let key = DeviceKey.JWK(x: jwkFields["x"]!, y: jwkFields["y"]!)

        XCTAssertEqual(key.canonical, v["canonical"] as? String,
                       "canonical form must be lexicographic, unspaced, and exactly this")
        XCTAssertEqual(key.thumbprint, v["thumbprint"] as? String,
                       "a different fingerprint here means every request is refused")
    }

    /// The public half a real key produces has to be the shape the hub accepts:
    /// two 32-byte coordinates, base64url, unpadded.
    func testAGeneratedKeyProducesCoordinatesTheHubWouldAccept() {
        let signer = DeviceKey.SoftwareSigner()
        let jwk = signer.publicJWK
        XCTAssertEqual(jwk.kty, "EC")
        XCTAssertEqual(jwk.crv, "P-256")
        for coordinate in [jwk.x, jwk.y] {
            XCTAssertEqual(coordinate.count, 43, "32 bytes, base64url, unpadded")
            XCTAssertFalse(coordinate.contains("="), "padding is not base64url")
            XCTAssertFalse(coordinate.contains("+") || coordinate.contains("/"),
                           "base64url uses - and _")
        }
        XCTAssertEqual(jwk.thumbprint.count, 43)
    }

    /// A proof is three base64url segments, and its claims are the five the
    /// Gateway checks.
    func testProofCarriesExactlyWhatTheGatewayChecks() throws {
        let signer = DeviceKey.SoftwareSigner()
        let token = "an.access.token"
        let proof = try DeviceKey.proof(
            signer: signer, method: "POST",
            url: "https://gateway.example/v1/account", accessToken: token,
            now: Date(timeIntervalSince1970: 1_700_000_000), jti: "0123456789abcdef0123")

        let parts = proof.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        let header = try decode(parts[0])
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["typ"] as? String, "dpop+jwt")
        // The public key travels in the header; the verifier checks the
        // signature against it and then against the token's cnf.jkt.
        XCTAssertNotNil(header["jwk"])
        let jwk = try XCTUnwrap(header["jwk"] as? [String: Any])
        XCTAssertNil(jwk["d"], "a proof must never carry the private half")

        let claims = try decode(parts[1])
        XCTAssertEqual(claims["htm"] as? String, "POST")
        XCTAssertEqual(claims["htu"] as? String, "https://gateway.example/v1/account")
        XCTAssertEqual(claims["iat"] as? Int, 1_700_000_000)
        XCTAssertEqual(claims["jti"] as? String, "0123456789abcdef0123")
        // ath is over the ASCII of the token, which is what the Gateway hashes.
        let expected = Data(SHA256.hash(data: Data(token.utf8))).base64URLEncoded
        XCTAssertEqual(claims["ath"] as? String, expected)

        // 64 bytes: r ‖ s, as JWS ES256 requires. A DER-encoded signature here
        // would be a valid ECDSA signature that no JWS verifier accepts.
        let signature = try XCTUnwrap(Data(base64URLEncoded: parts[2]))
        XCTAssertEqual(signature.count, 64)
    }

    /// The signature has to verify against the key in the header, or the
    /// binding proves nothing.
    func testTheProofVerifiesAgainstItsOwnKey() throws {
        let key = P256.Signing.PrivateKey()
        let signer = DeviceKey.SoftwareSigner(key: key)
        let proof = try DeviceKey.proof(
            signer: signer, method: "GET", url: "https://gateway.example/v1/x", accessToken: nil)
        let parts = proof.split(separator: ".").map(String.init)
        let signingInput = Data((parts[0] + "." + parts[1]).utf8)
        let raw = try XCTUnwrap(Data(base64URLEncoded: parts[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    /// A proof with no token omits `ath` rather than sending an empty one: the
    /// only request without an access token is the one asking for a token.
    func testAProofWithNoTokenOmitsTheTokenHash() throws {
        let proof = try DeviceKey.proof(
            signer: DeviceKey.SoftwareSigner(), method: "POST",
            url: "https://hq.example/api/gateway/token", accessToken: nil)
        let claims = try decode(proof.split(separator: ".").map(String.init)[1])
        XCTAssertNil(claims["ath"])
    }

    /// Two proofs for the same request are different proofs. A reused jti is
    /// the one thing a replay detector keys on.
    func testEveryProofIsFresh() throws {
        let signer = DeviceKey.SoftwareSigner()
        let make = { try DeviceKey.proof(signer: signer, method: "POST",
                                         url: "https://gateway.example/v1/account",
                                         accessToken: "t") }
        XCTAssertNotEqual(try make(), try make())
    }

    private func decode(_ segment: String) throws -> [String: Any] {
        let data = try XCTUnwrap(Data(base64URLEncoded: segment))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
