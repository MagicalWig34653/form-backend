// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import _CryptoExtras
import Foundation
@testable import FormAuth

/// Test-only CBOR encoder (just what the attestation object and COSE keys need).
enum CBOREnc {
    static func head(_ major: UInt8, _ n: UInt64) -> Data {
        let m = major << 5
        switch n {
        case 0..<24: return Data([m | UInt8(n)])
        case 24..<256: return Data([m | 24, UInt8(n)])
        case 256..<65_536: return Data([m | 25, UInt8(n >> 8), UInt8(n & 0xFF)])
        default: return Data([m | 26] + (0..<4).map { UInt8((n >> (8 * (3 - UInt64($0)))) & 0xFF) })
        }
    }
    static func int(_ v: Int) -> Data { v >= 0 ? head(0, UInt64(v)) : head(1, UInt64(-1 - v)) }
    static func bytes(_ d: Data) -> Data { head(2, UInt64(d.count)) + d }
    static func text(_ s: String) -> Data { head(3, UInt64(s.utf8.count)) + Data(s.utf8) }
    static func map(_ pairs: [(Data, Data)]) -> Data { head(5, UInt64(pairs.count)) + pairs.reduce(Data()) { $0 + $1.0 + $1.1 } }
}

/// A software WebAuthn authenticator for tests: creates real attestation objects and real assertions with a real key.
final class SyntheticAuthenticator {
    enum Kind { case es256, eddsa, rs256 }
    let kind: Kind, rpID: String, origin: String
    let credentialID: Data
    private let p256 = P256.Signing.PrivateKey()
    private let ed = Curve25519.Signing.PrivateKey()
    private let rsa = try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    var signCount: UInt32 = 0

    init(_ kind: Kind, rpID: String, origin: String) { self.kind = kind; self.rpID = rpID; self.origin = origin; credentialID = Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    func coseKey() -> Data {
        switch kind {
        case .es256:
            let x963 = p256.publicKey.x963Representation
            return CBOREnc.map([(CBOREnc.int(1), CBOREnc.int(2)), (CBOREnc.int(3), CBOREnc.int(-7)), (CBOREnc.int(-1), CBOREnc.int(1)),
                                (CBOREnc.int(-2), CBOREnc.bytes(x963[1..<33])), (CBOREnc.int(-3), CBOREnc.bytes(x963[33..<65]))])
        case .eddsa:
            return CBOREnc.map([(CBOREnc.int(1), CBOREnc.int(1)), (CBOREnc.int(3), CBOREnc.int(-8)), (CBOREnc.int(-1), CBOREnc.int(6)),
                                (CBOREnc.int(-2), CBOREnc.bytes(ed.publicKey.rawRepresentation))])
        case .rs256:
            let prim = try! rsa.publicKey.getKeyPrimitives()
            return CBOREnc.map([(CBOREnc.int(1), CBOREnc.int(3)), (CBOREnc.int(3), CBOREnc.int(-257)), (CBOREnc.int(-1), CBOREnc.bytes(prim.modulus)), (CBOREnc.int(-2), CBOREnc.bytes(prim.publicExponent))])
        }
    }

    func clientData(type: String, challenge: Data, origin: String? = nil) -> Data {
        Data("{\"type\":\"\(type)\",\"challenge\":\"\(challenge.base64URL)\",\"origin\":\"\(origin ?? self.origin)\",\"crossOrigin\":false}".utf8)
    }

    static func counterBytes(_ c: UInt32) -> Data { Data([UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]) }

    /// - Parameters override the corresponding field to build faulty responses.
    func registration(challenge: Data, type: String = "webauthn.create", origin: String? = nil, rpID rp: String? = nil, flags: UInt8 = 0x45,
                      cose: Data? = nil, trailing: Data = Data(), fmt: String = "none") -> (clientDataJSON: Data, attestationObject: Data) {
        var auth = Data(SHA256.hash(data: Data((rp ?? rpID).utf8))) + Data([flags]) + Self.counterBytes(signCount)
        if flags & 0x40 != 0 {
            auth += Data(count: 16) + Data([UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xFF)]) + credentialID + (cose ?? coseKey())
        }
        auth += trailing
        let obj = CBOREnc.map([(CBOREnc.text("fmt"), CBOREnc.text(fmt)), (CBOREnc.text("attStmt"), CBOREnc.map([])), (CBOREnc.text("authData"), CBOREnc.bytes(auth))])
        return (clientData(type: type, challenge: challenge, origin: origin), obj)
    }

    /// A login assertion signed with the credential's private key; the counter advances like a real authenticator.
    func assertion(challenge: Data) -> (authenticatorData: Data, clientDataJSON: Data, signature: Data) {
        signCount += 1
        let cd = clientData(type: "webauthn.get", challenge: challenge)
        let ad = Data(SHA256.hash(data: Data(rpID.utf8))) + Data([0x05]) + Self.counterBytes(signCount)
        let signed = ad + Data(SHA256.hash(data: cd))
        let sig: Data
        switch kind {
        case .es256: sig = try! p256.signature(for: signed).derRepresentation
        case .eddsa: sig = try! ed.signature(for: signed)
        case .rs256: sig = try! rsa.signature(for: signed, padding: .insecurePKCS1v1_5).rawRepresentation
        }
        return (ad, cd, sig)
    }
}
