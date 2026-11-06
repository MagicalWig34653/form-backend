// Copied from backend/poc-passkey/Sources/PasskeyPoC/PasskeyKey.swift (P3-C, ADR 0008 F9). Keep in sync via PasskeyParityTests.
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto
import _CryptoExtras

/// Failure reasons of assertion verification. Names are stable and used by test vectors.
public enum PasskeyError: Error, Equatable, Sendable {
    case clientDataInvalid
    case wrongType
    case challengeMismatch
    case originMismatch
    case rpIdHashMismatch
    case userNotPresent
    case userNotVerified
    case signatureInvalid
    case authenticatorDataInvalid
    case counterRegression
    case unsupportedKey
    case userHandleMismatch
    case unknownCredential
    case challengeInvalid
    case authenticationFailed

    /// What may leave the process (ADR 0006 / auth contract): one uniform category for every login
    /// verification failure, so responses are no oracle for credential existence, user-handle binding or
    /// which check failed. The specific case stays internal (audit log, tests). Only a key the server
    /// itself cannot use (`unsupportedKey` during registration) is reported as such by the caller.
    public var external: PasskeyError { .authenticationFailed }
    public static let externalCode = "authentication_failed"
}

/// Public key as stored by the legacy system: PEM text, SubjectPublicKeyInfo
/// (written by lbuchs/webauthn getPublicKeyPem() for COSE EC2/P-256, RSA, OKP/Ed25519).
public enum PasskeyPublicKey: Sendable {
    case es256(P256.Signing.PublicKey)      // COSE -7
    case rs256(_RSA.Signing.PublicKey)      // COSE -257 (PKCS#1 v1.5, SHA-256)
    case eddsa(Curve25519.Signing.PublicKey) // COSE -8 (Ed25519)

    public static let minimumRSABits = 2048
    private static let oidEcPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let oidPrime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let oidRsa: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let oidEd25519: [UInt8] = [0x2B, 0x65, 0x70]

    public init(pem: String) throws {
        let lines = pem.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "-----BEGIN PUBLIC KEY-----",
              lines.last?.trimmingCharacters(in: .whitespaces) == "-----END PUBLIC KEY-----"
        else { throw PasskeyError.unsupportedKey }
        let body = lines.dropFirst().dropLast().joined()
        guard let der = Data(base64Encoded: body) else { throw PasskeyError.unsupportedKey }
        try self.init(spkiDER: der)
    }

    public init(spkiDER der: Data) throws {
        var reader = DERReader(Array(der))
        guard let spki = reader.readTLV(tag: 0x30), reader.isAtEnd else { throw PasskeyError.unsupportedKey }
        var inner = DERReader(spki)
        guard let algId = inner.readTLV(tag: 0x30), let bitString = inner.readTLV(tag: 0x03), inner.isAtEnd
        else { throw PasskeyError.unsupportedKey }
        var alg = DERReader(algId)
        guard let oid = alg.readTLV(tag: 0x06) else { throw PasskeyError.unsupportedKey }
        do {
            switch oid {
            case Self.oidEcPublicKey:
                guard let curve = alg.readTLV(tag: 0x06), curve == Self.oidPrime256v1, alg.isAtEnd
                else { throw PasskeyError.unsupportedKey }
                self = .es256(try P256.Signing.PublicKey(derRepresentation: der))
            case Self.oidRsa:
                let rsa = try _RSA.Signing.PublicKey(derRepresentation: der)
                // ADR 0006 Nr. 12: minimum modulus length 2048 bits.
                // Measured from the DER itself: `keySizeInBits` rounds up to whole bytes in some swift-crypto versions
                // (3.15.1 reports 2048 for a 2047-bit modulus).
                guard Self.rsaModulusBits(bitString: bitString) >= Self.minimumRSABits else { throw PasskeyError.unsupportedKey }
                guard rsa.keySizeInBits >= Self.minimumRSABits else { throw PasskeyError.unsupportedKey }
                self = .rs256(rsa)
            case Self.oidEd25519:
                guard alg.isAtEnd, bitString.count == 33, bitString[0] == 0
                else { throw PasskeyError.unsupportedKey }
                self = .eddsa(try Curve25519.Signing.PublicKey(rawRepresentation: Data(bitString.dropFirst())))
            default:
                throw PasskeyError.unsupportedKey
            }
        } catch let e as PasskeyError {
            throw e
        } catch {
            throw PasskeyError.unsupportedKey
        }
    }

    /// Exact bit length of the modulus n in RSAPublicKey ::= SEQUENCE { n INTEGER, e INTEGER } inside a BIT STRING (0 if malformed).
    static func rsaModulusBits(bitString: [UInt8]) -> Int {
        guard bitString.first == 0 else { return 0 }
        var outer = DERReader(Array(bitString.dropFirst()))
        guard let seq = outer.readTLV(tag: 0x30), outer.isAtEnd else { return 0 }
        var inner = DERReader(seq)
        guard var n = inner.readTLV(tag: 0x02) else { return 0 }
        while n.first == 0 { n.removeFirst() }
        guard let first = n.first else { return 0 }
        return (n.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    /// Verifies `signature` over `data` (WebAuthn: authenticatorData || SHA-256(clientDataJSON)).
    public func isValidSignature(_ signature: Data, for data: Data) -> Bool {
        switch self {
        case .es256(let key):
            guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return key.isValidSignature(sig, for: data)
        case .rs256(let key):
            let sig = _RSA.Signing.RSASignature(rawRepresentation: signature)
            return key.isValidSignature(sig, for: data, padding: .insecurePKCS1v1_5)
        case .eddsa(let key):
            return key.isValidSignature(signature, for: data)
        }
    }
}

/// Minimal strict DER TLV reader (definite lengths up to 4 bytes, no indefinite form).
struct DERReader {
    private let bytes: [UInt8]
    private var pos = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var isAtEnd: Bool { pos == bytes.count }

    mutating func readTLV(tag: UInt8) -> [UInt8]? {
        guard pos < bytes.count, bytes[pos] == tag else { return nil }
        pos += 1
        guard pos < bytes.count else { return nil }
        var length = Int(bytes[pos]); pos += 1
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n >= 1, n <= 4, pos + n <= bytes.count else { return nil }
            length = 0
            for _ in 0..<n { length = (length << 8) | Int(bytes[pos]); pos += 1 }
        }
        guard length >= 0, pos + length <= bytes.count else { return nil }
        defer { pos += length }
        return Array(bytes[pos..<(pos + length)])
    }
}
