// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import _CryptoExtras
import Foundation

/// Minimal strict CBOR (RFC 8949) reader for WebAuthn: definite lengths only, no tags/floats/simple values, bounded depth
/// and size. Only what attestation objects and COSE keys use.
enum CBOR: Equatable {
    case uint(UInt64), negint(Int64), bytes(Data), text(String), array([CBOR]), map([(CBOR, CBOR)])

    static func == (a: CBOR, b: CBOR) -> Bool {
        switch (a, b) {
        case (.uint(let x), .uint(let y)): return x == y
        case (.negint(let x), .negint(let y)): return x == y
        case (.bytes(let x), .bytes(let y)): return x == y
        case (.text(let x), .text(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.map(let x), .map(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    struct Failure: Error { let reason: String }

    /// Decodes one item from the start of `data`; returns it and the number of bytes consumed.
    static func decode(_ data: Data, maxDepth: Int = 8) throws -> (CBOR, Int) {
        var r = Reader(bytes: [UInt8](data))
        let v = try r.item(depth: 0, maxDepth: maxDepth)
        return (v, r.pos)
    }

    var int: Int64? {
        switch self { case .uint(let u): return u <= UInt64(Int64.max) ? Int64(u) : nil; case .negint(let n): return n; default: return nil }
    }
    func value(forInt key: Int64) -> CBOR? { if case .map(let m) = self { return m.first { $0.0.int == key && !isText($0.0) }?.1 }; return nil }
    func value(forText key: String) -> CBOR? { if case .map(let m) = self { return m.first { if case .text(let t) = $0.0 { return t == key }; return false }?.1 }; return nil }
    private func isText(_ c: CBOR) -> Bool { if case .text = c { return true }; return false }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0
        static let maxItems = 4096

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= bytes.count else { throw Failure(reason: "truncated") }
            defer { pos += n }
            return bytes[pos..<pos + n]
        }

        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0...23: return UInt64(info)
            case 24: return UInt64(try take(1).first!)
            case 25: return try take(2).reduce(0) { $0 << 8 | UInt64($1) }
            case 26: return try take(4).reduce(0) { $0 << 8 | UInt64($1) }
            case 27: return try take(8).reduce(0) { $0 << 8 | UInt64($1) }
            default: throw Failure(reason: "indefinite or reserved length")
            }
        }

        mutating func item(depth: Int, maxDepth: Int) throws -> CBOR {
            guard depth <= maxDepth else { throw Failure(reason: "too deep") }
            let initial = try take(1).first!
            let major = initial >> 5, info = initial & 0x1F
            let arg = try argument(info)
            switch major {
            case 0: return .uint(arg)
            case 1:
                guard arg <= UInt64(Int64.max) else { throw Failure(reason: "integer range") }
                return .negint(-1 - Int64(arg))
            case 2:
                guard arg <= 65_536 else { throw Failure(reason: "byte string too long") }
                return .bytes(Data(try take(Int(arg))))
            case 3:
                guard arg <= 4096, let s = String(data: Data(try take(Int(arg))), encoding: .utf8) else { throw Failure(reason: "text") }
                return .text(s)
            case 4:
                guard arg <= UInt64(Reader.maxItems) else { throw Failure(reason: "array too long") }
                return .array(try (0..<Int(arg)).map { _ in try item(depth: depth + 1, maxDepth: maxDepth) })
            case 5:
                guard arg <= UInt64(Reader.maxItems) else { throw Failure(reason: "map too long") }
                var out: [(CBOR, CBOR)] = []
                for _ in 0..<Int(arg) {
                    let k = try item(depth: depth + 1, maxDepth: maxDepth), v = try item(depth: depth + 1, maxDepth: maxDepth)
                    guard !out.contains(where: { $0.0 == k }) else { throw Failure(reason: "duplicate map key") }
                    out.append((k, v))
                }
                return .map(out)
            default: throw Failure(reason: "unsupported major type")
            }
        }
    }
}

/// Why a registration was refused. Internal only (audit log); the response is one uniform `registration_failed`.
public enum RegistrationError: Error, Equatable, Sendable {
    case clientDataInvalid, wrongType, challengeMismatch, originMismatch, attestationInvalid, rpIdHashMismatch
    case userNotPresent, userNotVerified, noCredentialData, credentialIdInvalid, keyInvalid, algorithmNotAllowed
    case challengeInvalid, duplicateCredential, enrollmentInvalid, labelInvalid, accountInactive
}

public struct VerifiedRegistration: Sendable, Equatable {
    public let credentialID: Data
    public let publicKeyPEM: String
    public let coseAlgorithm: Int
    public let signCount: UInt32
    public let userVerified: Bool
    public let backupEligible: Bool
}

/// WebAuthn registration (W3C WebAuthn L2 §7.1) for the `none` trust model: the attestation statement is NOT verified
/// (no attestation CA policy); what is verified is challenge, origin, RP ID hash, user presence/verification and that
/// the credential key is one of ES256 / RS256 (>= 2048 bit) / EdDSA, which is stored as SPKI PEM like the legacy data.
public struct RegistrationVerifier: Sendable {
    public let relyingParty: RelyingParty
    public init(relyingParty: RelyingParty) { self.relyingParty = relyingParty }

    private struct ClientData: Decodable { let type: String; let challenge: String; let origin: String }

    public func verify(clientDataJSON: Data, attestationObject: Data, expectedChallengeSHA256: Data) throws -> VerifiedRegistration {
        guard let client = try? JSONDecoder().decode(ClientData.self, from: clientDataJSON) else { throw RegistrationError.clientDataInvalid }
        guard client.type == "webauthn.create" else { throw RegistrationError.wrongType }
        guard let challenge = Data(base64URLEncoded: client.challenge), Data(SHA256.hash(data: challenge)) == expectedChallengeSHA256 else { throw RegistrationError.challengeMismatch }
        guard client.origin == relyingParty.origin else { throw RegistrationError.originMismatch }

        guard let (obj, used) = try? CBOR.decode(attestationObject), used == attestationObject.count,
              case .text? = obj.value(forText: "fmt"), obj.value(forText: "attStmt") != nil, case .bytes(let authData)? = obj.value(forText: "authData")
        else { throw RegistrationError.attestationInvalid }
        let ad = [UInt8](authData)
        guard ad.count >= 37 else { throw RegistrationError.attestationInvalid }
        guard Data(ad[0..<32]) == Data(SHA256.hash(data: Data(relyingParty.rpID.utf8))) else { throw RegistrationError.rpIdHashMismatch }
        let flags = ad[32]
        guard flags & 0x01 != 0 else { throw RegistrationError.userNotPresent }
        guard flags & 0x04 != 0 else { throw RegistrationError.userNotVerified }
        guard flags & 0x40 != 0, ad.count >= 55 else { throw RegistrationError.noCredentialData }
        let signCount = ad[33..<37].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let idLength = Int(ad[53]) << 8 | Int(ad[54])
        guard (1...255).contains(idLength), ad.count >= 55 + idLength else { throw RegistrationError.credentialIdInvalid }
        let credentialID = Data(ad[55..<55 + idLength])
        let rest = Data(ad[(55 + idLength)...])
        guard let (cose, coseUsed) = try? CBOR.decode(rest) else { throw RegistrationError.keyInvalid }
        // Extension data (flag ED) may follow the key; anything else after it is malformed.
        if coseUsed != rest.count { guard flags & 0x80 != 0, (try? CBOR.decode(rest.dropFirst(coseUsed)).1) == rest.count - coseUsed else { throw RegistrationError.keyInvalid } }
        let (pem, alg) = try Self.pemFromCOSE(cose)
        return VerifiedRegistration(credentialID: credentialID, publicKeyPEM: pem, coseAlgorithm: alg, signCount: signCount, userVerified: true, backupEligible: flags & 0x08 != 0)
    }

    /// COSE_Key -> SubjectPublicKeyInfo PEM; also validated by the same parser the login path uses.
    static func pemFromCOSE(_ cose: CBOR) throws -> (String, Int) {
        guard let kty = cose.value(forInt: 1)?.int, let alg = cose.value(forInt: 3)?.int else { throw RegistrationError.keyInvalid }
        let der: Data
        switch (kty, alg) {
        case (2, -7):
            guard cose.value(forInt: -1)?.int == 1, case .bytes(let x)? = cose.value(forInt: -2), case .bytes(let y)? = cose.value(forInt: -3), x.count == 32, y.count == 32,
                  let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y) else { throw RegistrationError.keyInvalid }
            der = key.derRepresentation
        case (1, -8):
            guard cose.value(forInt: -1)?.int == 6, case .bytes(let x)? = cose.value(forInt: -2), x.count == 32, (try? Curve25519.Signing.PublicKey(rawRepresentation: x)) != nil else { throw RegistrationError.keyInvalid }
            der = Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00]) + x
        case (3, -257):
            guard case .bytes(let n)? = cose.value(forInt: -1), case .bytes(let e)? = cose.value(forInt: -2), !n.isEmpty, !e.isEmpty, n.count <= 1024, e.count <= 8,
                  let key = try? _RSA.Signing.PublicKey(n: n, e: e) else { throw RegistrationError.keyInvalid }
            der = key.derRepresentation
        default: throw RegistrationError.algorithmNotAllowed
        }
        // Same acceptance rules as at login (strict DER, curve check, RSA >= 2048 bits measured from the key).
        guard (try? PasskeyPublicKey(spkiDER: der)) != nil else { throw RegistrationError.keyInvalid }
        let b64 = der.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 64).map { i -> String in
            let a = b64.index(b64.startIndex, offsetBy: i), b = b64.index(a, offsetBy: min(64, b64.count - i)); return String(b64[a..<b])
        }
        return ("-----BEGIN PUBLIC KEY-----\n" + lines.joined(separator: "\n") + "\n-----END PUBLIC KEY-----\n", Int(alg))
    }
}
