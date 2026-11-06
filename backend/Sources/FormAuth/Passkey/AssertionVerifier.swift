// Copied from backend/poc-passkey/Sources/PasskeyPoC/AssertionVerifier.swift (P3-C, ADR 0008 F9). Keep in sync via PasskeyParityTests.
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto

public struct RelyingParty: Sendable {
    /// Unchanged legacy RP ID (bare host, lowercase). Never derived from Host/Forwarded headers.
    public let rpID: String
    /// Exact configured admin origin, e.g. https://admin.example.test (no trailing slash).
    public let origin: String
    public init(rpID: String, origin: String) { self.rpID = rpID; self.origin = origin }
}

public struct AssertionInput: Sendable {
    public let credentialID: Data
    public let clientDataJSON: Data
    public let authenticatorData: Data
    public let signature: Data
    public let userHandle: Data?
    public init(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?) {
        self.credentialID = credentialID; self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData; self.signature = signature; self.userHandle = userHandle
    }
}

public struct StoredPasskey: Sendable {
    public let credentialID: Data
    /// Legacy: UTF-8 bytes of the account UUID text (see handoff, contract note).
    public let userHandle: Data
    public let publicKeyPEM: String
    /// UInt32 range; DB column is BIGINT UNSIGNED with CHECK <= 4294967295.
    public let signCount: UInt32
    public init(credentialID: Data, userHandle: Data, publicKeyPEM: String, signCount: UInt32) {
        self.credentialID = credentialID; self.userHandle = userHandle
        self.publicKeyPEM = publicKeyPEM; self.signCount = signCount
    }
}

public struct VerifiedAssertion: Sendable, Equatable {
    public let newSignCount: UInt32
    public let userVerified: Bool
    public let backupEligible: Bool
    public let backupState: Bool
}

/// WebAuthn assertion verification (W3C WebAuthn L2 §7.2) with the legacy rules:
/// exact origin, UP and UV required, own counter rule (0/0 allowed), no attestation.
public struct AssertionVerifier: Sendable {
    public let relyingParty: RelyingParty
    public init(relyingParty: RelyingParty) { self.relyingParty = relyingParty }

    private struct ClientData: Decodable {
        let type: String
        let challenge: String
        let origin: String
    }

    /// Legacy rule (Passkey.php zaehlerPlausibel): (old == 0 && new == 0) || new > old.
    public static func counterPlausible(old: UInt32, new: UInt32) -> Bool {
        (old == 0 && new == 0) || new > old
    }

    /// - Parameter expectedChallengeSHA256: hash of the challenge consumed from the challenge store
    ///   (schema: auth_challenges.challenge_hash).
    public func verify(
        _ input: AssertionInput,
        stored: StoredPasskey,
        expectedChallengeSHA256: Data
    ) throws -> VerifiedAssertion {
        // Account binding (legacy: userHandle must equal the account of the credential id).
        if let handle = input.userHandle, !handle.isEmpty, handle != stored.userHandle {
            throw PasskeyError.userHandleMismatch
        }

        guard let client = try? JSONDecoder().decode(ClientData.self, from: input.clientDataJSON) else {
            throw PasskeyError.clientDataInvalid
        }
        guard client.type == "webauthn.get" else { throw PasskeyError.wrongType }
        guard let challenge = Data(base64URLEncoded: client.challenge),
              Data(SHA256.hash(data: challenge)) == expectedChallengeSHA256
        else { throw PasskeyError.challengeMismatch }
        // Exact string comparison (no suffix matching, no case/slash tolerance).
        guard client.origin == relyingParty.origin else { throw PasskeyError.originMismatch }

        // authenticatorData: rpIdHash[32] || flags[1] || signCount[4 BE] || optional extensions
        let ad = [UInt8](input.authenticatorData)
        guard ad.count >= 37 else { throw PasskeyError.authenticatorDataInvalid }
        guard Data(ad[0..<32]) == Data(SHA256.hash(data: Data(relyingParty.rpID.utf8))) else {
            throw PasskeyError.rpIdHashMismatch
        }
        let flags = ad[32]
        guard flags & 0x01 != 0 else { throw PasskeyError.userNotPresent }
        guard flags & 0x04 != 0 else { throw PasskeyError.userNotVerified }

        let key: PasskeyPublicKey
        do { key = try PasskeyPublicKey(pem: stored.publicKeyPEM) } catch { throw PasskeyError.unsupportedKey }
        var signed = input.authenticatorData
        signed.append(contentsOf: SHA256.hash(data: input.clientDataJSON))
        guard key.isValidSignature(input.signature, for: signed) else { throw PasskeyError.signatureInvalid }

        let newCount = ad[33..<37].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Self.counterPlausible(old: stored.signCount, new: newCount) else { throw PasskeyError.counterRegression }

        return VerifiedAssertion(
            newSignCount: newCount,
            userVerified: true,
            backupEligible: flags & 0x08 != 0,
            backupState: flags & 0x10 != 0
        )
    }
}

extension Data {
    /// Strict base64url without padding (as produced by browsers); rejects '+', '/', '=' and whitespace.
    init?(base64URLEncoded s: String) {
        guard !s.isEmpty, s.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F })
        else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}
