import CryptoKit
import Foundation

/// The key this Mac proves itself with, and the proofs it signs.
///
/// The device token in the secrets file says WHICH Mac this is. It does not
/// say the Mac is here: a file can be read, and a copy of that token would let
/// somebody else ask the hub for a perfectly valid credential and spend the
/// balance. So every request that spends also carries a fresh signature from a
/// key that never leaves this machine, and the hub records that key's
/// fingerprint at pairing so a stolen token cannot register a new one.
///
/// The wire format is `contracts/gateway/v1/TOKEN.md`, and the Gateway
/// enforces every rule in it independently. Anything changed here without
/// changing that is a request the other side silently refuses.
///
/// P-256 is not a preference. It is the only curve the Secure Enclave will
/// generate, and the enclave is the whole point: a private key that cannot be
/// exported, by anyone, including someone who can read every file on the disk.
public enum DeviceKey {

    /// Where the private half lives.
    ///
    /// Two cases, and the second exists for exactly one machine. Every Mac
    /// that runs this app has a Secure Enclave except the 2019 iMac, which is
    /// the only model Sonoma supports without a T2. That is the entire
    /// fallback population, and it is written and tested rather than assumed,
    /// because a branch that only runs on hardware nobody here owns has never
    /// run.
    public enum Storage: Equatable, Sendable {
        case secureEnclave
        case softwareKey
    }

    /// Signing, abstracted so tests can have one.
    ///
    /// Creating a Secure Enclave key requires a signed application with
    /// entitlements, so an unsigned `swift test` binary cannot make one. That
    /// is not a reason to skip the tests; it is a reason for the signer to be
    /// injected, exactly as `HubPairing` injects its transport. A green test
    /// against a software key is evidence about this code and says nothing
    /// about the enclave, which is what the in-app drill is for.
    public protocol Signer: Sendable {
        /// The public half, as the JWK the hub stores a thumbprint of.
        var publicJWK: JWK { get }
        var storage: Storage { get }
        /// Raw ECDSA over SHA-256, as JWS ES256 requires: r ‖ s, 32 bytes each.
        func signature(over message: Data) throws -> Data
    }

    /// A public EC P-256 key, in the one shape both other languages agree on.
    ///
    /// The member order matters and is not cosmetic: RFC 7638 computes the
    /// thumbprint over a canonical JSON object with the required members in
    /// lexicographic order and no whitespace. Encoding this any other way
    /// yields a different fingerprint from the hub's and the Gateway's, and
    /// the failure would be a correct signature refused for no visible reason.
    public struct JWK: Equatable, Sendable, Codable {
        public let kty: String
        public let crv: String
        public let x: String
        public let y: String

        public init(x: String, y: String) {
            self.kty = "EC"; self.crv = "P-256"; self.x = x; self.y = y
        }

        /// The canonical form RFC 7638 hashes. Written by hand rather than
        /// through JSONEncoder, whose key order is not guaranteed to be the
        /// one the specification requires.
        public var canonical: String {
            #"{"crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#
        }

        /// What the hub stores and the token carries as `cnf.jkt`.
        public var thumbprint: String {
            Data(SHA256.hash(data: Data(canonical.utf8))).base64URLEncoded
        }
    }

    /// A P-256 key held in software. The fallback, and what tests use.
    public struct SoftwareSigner: Signer {
        private let key: P256.Signing.PrivateKey
        public let publicJWK: JWK
        public let storage: Storage = .softwareKey

        public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
            self.key = key
            // x963 representation is 0x04 ‖ X ‖ Y for an uncompressed point.
            let raw = key.publicKey.x963Representation.dropFirst()
            self.publicJWK = JWK(
                x: Data(raw.prefix(32)).base64URLEncoded,
                y: Data(raw.suffix(32)).base64URLEncoded)
        }

        public func signature(over message: Data) throws -> Data {
            try key.signature(for: message).rawRepresentation
        }
    }

    /// A P-256 key held in the Secure Enclave, where it cannot be exported.
    public struct EnclaveSigner: Signer {
        private let key: SecureEnclave.P256.Signing.PrivateKey
        public let publicJWK: JWK
        public let storage: Storage = .secureEnclave

        /// Nil on the one Mac that has no enclave, so the caller can fall back
        /// rather than this failing somewhere less obvious.
        public init?(representation: Data? = nil) {
            guard SecureEnclave.isAvailable else { return nil }
            guard let key = try? representation.map({
                try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: $0)
            }) ?? SecureEnclave.P256.Signing.PrivateKey() else { return nil }
            self.key = key
            let raw = key.publicKey.x963Representation.dropFirst()
            self.publicJWK = JWK(
                x: Data(raw.prefix(32)).base64URLEncoded,
                y: Data(raw.suffix(32)).base64URLEncoded)
        }

        /// The enclave's own wrapped blob. Useless without this machine's
        /// enclave, which is why it may be stored beside the device token.
        public var persistable: Data { key.dataRepresentation }

        public func signature(over message: Data) throws -> Data {
            try key.signature(for: message).rawRepresentation
        }
    }

    /// A DPoP proof for one request, and one request only.
    ///
    /// Bound to the method and the URL so it cannot be lifted onto another
    /// route, and to a hash of the access token so it cannot be lifted onto
    /// another token. There is no reuse and no cache: a proof is cheap, and a
    /// proof worth keeping would be a proof worth stealing.
    ///
    /// `url` must be the PUBLIC url, without query or fragment, exactly as the
    /// Gateway reconstructs it. The Gateway builds it from a configured origin
    /// rather than from a Host header for this reason.
    public static func proof(
        signer: Signer, method: String, url: String, accessToken: String?,
        now: Date = Date(), jti: String = UUID().uuidString
    ) throws -> String {
        let header = #"{"alg":"ES256","typ":"dpop+jwt","jwk":\#(signer.publicJWK.canonical)}"#
        var claims = [
            #""jti":"\#(jti)""#,
            #""htm":"\#(method)""#,
            #""htu":"\#(url)""#,
            #""iat":\#(Int(now.timeIntervalSince1970))"#,
        ]
        if let accessToken {
            // Over the ASCII of the token, which is what the Gateway hashes.
            let ath = Data(SHA256.hash(data: Data(accessToken.utf8))).base64URLEncoded
            claims.append(#""ath":"\#(ath)""#)
        }
        let payload = "{" + claims.joined(separator: ",") + "}"
        let signingInput = Data(header.utf8).base64URLEncoded
            + "." + Data(payload.utf8).base64URLEncoded
        let signature = try signer.signature(over: Data(signingInput.utf8))
        return signingInput + "." + signature.base64URLEncoded
    }
}

extension Data {
    /// base64url without padding, which is what every JWS field is.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
