// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto

/// Mirrors auth_challenges (purpose 'passkey-login'): hash only, session bound, 120 s, single use.
public protocol ChallengeStore: Sendable {
    func issue(sessionID: UUID, challenge: Data, now: Date) async
    /// Atomically claims the open challenge of this session and marks it consumed.
    /// Returns the SHA-256 of the challenge, or nil if none/expired/already consumed.
    /// Consumption is permanent, also when the later verification fails.
    func consume(sessionID: UUID, now: Date) async -> Data?
}

public protocol PasskeyRepository: Sendable {
    func find(credentialID: Data) async -> StoredPasskey?
    /// Conditional update equivalent to
    /// UPDATE ... SET sign_count=:new WHERE credential_id=:id AND (sign_count < :new OR (sign_count = 0 AND :new = 0)).
    /// Returns false if no row was affected (concurrent clone/replay).
    func advanceCounter(credentialID: Data, to newCount: UInt32) async -> Bool
}

public actor InMemoryChallengeStore: ChallengeStore {
    public static let lifetime: TimeInterval = 120
    private struct Entry { var hash: Data; var issuedAt: Date; var consumed: Bool }
    private var entries: [UUID: Entry] = [:]
    public init() {}

    public func issue(sessionID: UUID, challenge: Data, now: Date) {
        entries[sessionID] = Entry(hash: Data(SHA256.hash(data: challenge)), issuedAt: now, consumed: false)
    }

    public func consume(sessionID: UUID, now: Date) -> Data? {
        guard var e = entries[sessionID], !e.consumed else { return nil }
        e.consumed = true
        entries[sessionID] = e
        guard now >= e.issuedAt, now.timeIntervalSince(e.issuedAt) <= Self.lifetime else { return nil }
        return e.hash
    }
}

public actor InMemoryPasskeyRepository: PasskeyRepository {
    private var rows: [Data: StoredPasskey] = [:]
    public init(_ passkeys: [StoredPasskey] = []) { for p in passkeys { rows[p.credentialID] = p } }

    public func find(credentialID: Data) -> StoredPasskey? { rows[credentialID] }

    public func advanceCounter(credentialID: Data, to newCount: UInt32) -> Bool {
        guard let r = rows[credentialID] else { return false }
        guard r.signCount < newCount || (r.signCount == 0 && newCount == 0) else { return false }
        rows[credentialID] = StoredPasskey(credentialID: r.credentialID, userHandle: r.userHandle,
                                           publicKeyPEM: r.publicKeyPEM, signCount: newCount)
        return true
    }
}

public struct PasskeyLoginService: Sendable {
    let verifier: AssertionVerifier
    let challenges: any ChallengeStore
    let passkeys: any PasskeyRepository

    public init(verifier: AssertionVerifier, challenges: any ChallengeStore, passkeys: any PasskeyRepository) {
        self.verifier = verifier; self.challenges = challenges; self.passkeys = passkeys
    }

    /// Returns 32 random bytes to hand to the browser (base64url) as the WebAuthn challenge.
    public func begin(sessionID: UUID, now: Date) async -> Data {
        let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await challenges.issue(sessionID: sessionID, challenge: challenge, now: now)
        return challenge
    }

    /// Verifies a login assertion; returns the stored passkey (and thus the account binding) on success.
    /// Order: claim challenge first (consumed even if anything below fails), then lookup, verify,
    /// then the atomic counter update.
    public func finish(sessionID: UUID, input: AssertionInput, now: Date) async throws -> StoredPasskey {
        guard let challengeHash = await challenges.consume(sessionID: sessionID, now: now) else {
            throw PasskeyError.challengeInvalid
        }
        guard let stored = await passkeys.find(credentialID: input.credentialID) else {
            throw PasskeyError.unknownCredential
        }
        let result = try verifier.verify(input, stored: stored, expectedChallengeSHA256: challengeHash)
        guard await passkeys.advanceCounter(credentialID: stored.credentialID, to: result.newSignCount) else {
            throw PasskeyError.counterRegression
        }
        return stored
    }
}
