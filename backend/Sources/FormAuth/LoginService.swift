// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormCore
import FormPersistence
import Foundation
import SQLKit

/// Listener policy: UV passkey alone, or passkey (`factor_pending`) plus password (`authenticated`).
/// Verification failures leave this type only as `PasskeyError`/`SecondFactorError`-translated `AuthenticationFailed`;
/// throttle hits are `RateLimited`; anything else (database) propagates as a server error.
public struct LoginService: Sendable {
    public static let challengeLifetime: TimeInterval = 120
    let db: Database
    var sql: SQLDatabase { db as! SQLDatabase }
    let sessions: SessionService
    let throttles: ThrottleService
    let passwords: any PasswordVerifier
    let secondFactorRequired: Bool
    let relyingParty: RelyingParty
    let now: @Sendable () -> Date

    public init(db: Database, sessions: SessionService, throttles: ThrottleService, passwords: any PasswordVerifier,
                relyingParty: RelyingParty, secondFactorRequired: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.sessions = sessions; self.throttles = throttles; self.passwords = passwords
        self.secondFactorRequired = secondFactorRequired
        self.relyingParty = relyingParty; self.now = now
    }

    // MARK: passkey

    public struct IssuedChallenge: Sendable { public let id: UUID; public let challenge: Data; public let expiresAt: Date }

    /// Issues a login challenge bound to the anonymous session (older open ones are revoked). 32 random bytes.
    public func beginPasskey(session: SessionRecord) async throws -> IssuedChallenge {
        guard session.state == .anonymous else { throw AuthenticationFailed.translate(SecondFactorError.wrongState) }
        let challenge = Data.random(32)
        let t = now()
        let ts = DB.time(t)
        let id = UUID()
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            try await tx.raw("UPDATE auth_challenges SET revoked_at = \(bind: ts) WHERE session_id = \(bind: DB.bin(session.id)) AND purpose = 'passkey-login' AND consumed_at IS NULL AND revoked_at IS NULL").run()
            try await tx.raw("""
                INSERT INTO auth_challenges (id, session_id, account_id, purpose, challenge_hash, factor_method, created_at, expires_at)
                VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(session.id)), NULL, 'passkey-login', \(bind: Blob(Data(SHA256.hash(data: challenge)))), 'passkey',
                  \(bind: ts), \(bind: DB.time(t.addingTimeInterval(Self.challengeLifetime))))
                """).run()
        }
        return IssuedChallenge(id: id, challenge: challenge, expiresAt: t.addingTimeInterval(Self.challengeLifetime))
    }

    /// Verifies the assertion and rotates the anonymous session into `factor_pending`.
    public func finishPasskey(session: SessionRecord, challengeID: UUID? = nil, input: AssertionInput, clientIP: String) async throws -> (token: String, session: SessionRecord) {
        try await throttles.ensureNotLocked(.ip, clientIP)
        do {
            guard session.state == .anonymous else { throw PasskeyError.challengeInvalid }
            // 1. consume first, in its own committed transaction: a later failure never revives the challenge
            let challengeHash = try await consumeChallenge(session: session, challengeID: challengeID)
            // 2. lookup; unknown credentials run the same verification on a fixed dummy key
            guard let stored = try await loadPasskey(credentialID: input.credentialID) else {
                _ = try? AssertionVerifier(relyingParty: relyingParty).verify(input, stored: Self.dummyPasskey, expectedChallengeSHA256: challengeHash ?? Data())
                throw PasskeyError.unknownCredential
            }
            guard let challengeHash else {
                _ = try? AssertionVerifier(relyingParty: relyingParty).verify(input, stored: stored.passkey, expectedChallengeSHA256: Data())
                throw PasskeyError.challengeInvalid
            }
            let result = try AssertionVerifier(relyingParty: relyingParty).verify(input, stored: stored.passkey, expectedChallengeSHA256: challengeHash)
            guard try await advanceCounter(credentialID: input.credentialID, to: result.newSignCount) else { throw PasskeyError.counterRegression }
            guard let rights = try await activeRightsVersion(stored.accountID) else { throw SecondFactorError.accountInactive }
            let next = try await sessions.rotate(from: session, to: secondFactorRequired ? .factorPending : .authenticated, accountID: stored.accountID, method: "passkey", rightsVersion: rights)
            if !secondFactorRequired {
                try await sql.raw("UPDATE accounts SET last_login_at = \(bind: DB.time(now())) WHERE id = \(bind: DB.bin(stored.accountID))").run()
            }
            return next
        } catch let e as PasskeyError {
            try? await throttles.recordFailure(.ip, clientIP, policy: .passwordPerIP)
            throw AuthenticationFailed.translate(e)
        } catch let e as SecondFactorError {
            try? await throttles.recordFailure(.ip, clientIP, policy: .passwordPerIP)
            throw AuthenticationFailed.translate(e)
        }
    }

    // MARK: step-up (fresh authentication of an existing session)

    /// Step-up options: a `fresh-auth` challenge bound to this authenticated session and its account, plus the account's own
    /// credential ids (allowCredentials). Refused under a listener policy that demands a second factor: a passkey alone must not
    /// renew what was established with passkey + password (the client then falls back to the full login).
    public func beginReauth(session: SessionRecord) async throws -> (challenge: IssuedChallenge, credentialIDs: [Data]) {
        guard !secondFactorRequired else { throw StepUpUnavailable() }
        guard session.state == .authenticated, let account = session.accountID else { throw AuthenticationFailed.translate(SecondFactorError.wrongState) }
        let challenge = Data.random(32)
        let t = now()
        let ts = DB.time(t)
        let id = UUID()
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            try await tx.raw("UPDATE auth_challenges SET revoked_at = \(bind: ts) WHERE session_id = \(bind: DB.bin(session.id)) AND purpose = 'fresh-auth' AND consumed_at IS NULL AND revoked_at IS NULL").run()
            try await tx.raw("""
                INSERT INTO auth_challenges (id, session_id, account_id, purpose, challenge_hash, factor_method, created_at, expires_at)
                VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(session.id)), \(bind: DB.bin(account)), 'fresh-auth', \(bind: Blob(Data(SHA256.hash(data: challenge)))), 'passkey',
                  \(bind: ts), \(bind: DB.time(t.addingTimeInterval(Self.challengeLifetime))))
                """).run()
        }
        struct R: Decodable { let credential_id: Blob }
        let ids = try await sql.raw("SELECT credential_id FROM passkeys WHERE account_id = \(bind: DB.bin(account)) ORDER BY created_at LIMIT 100").all(decoding: R.self).map(\.credential_id.data)
        return (IssuedChallenge(id: id, challenge: challenge, expiresAt: t.addingTimeInterval(Self.challengeLifetime)), ids)
    }

    /// Verifies a step-up assertion and sets `authenticated_at` of THIS session to now. Token, CSRF secret, state, method and
    /// rights version stay unchanged (no privilege change, no rotation). The passkey must belong to the session's account;
    /// a foreign, unknown or replayed credential gets the same neutral `authentication_failed` as any other failure.
    /// Returns the new `authenticated_at`.
    public func finishReauth(session: SessionRecord, challengeID: UUID, input: AssertionInput, clientIP: String) async throws -> Date {
        guard !secondFactorRequired else { throw StepUpUnavailable() }
        guard session.state == .authenticated, let account = session.accountID else { throw AuthenticationFailed.translate(SecondFactorError.wrongState) }
        let accountKey = "reauth|\(account.uuidString.lowercased())|\(clientIP)"
        try await throttles.ensureNotLocked(.ip, clientIP)
        try await throttles.ensureNotLocked(.account, accountKey)
        do {
            // 1. consume first, in its own committed transaction (session + purpose + account bound): never revived by a later failure
            let challengeHash = try await consumeChallenge(session: session, challengeID: challengeID, purpose: "fresh-auth", account: account)
            // 2. the credential must exist AND belong to this account; otherwise the same work on a fixed dummy key
            guard let stored = try await loadPasskey(credentialID: input.credentialID), stored.accountID == account else {
                _ = try? AssertionVerifier(relyingParty: relyingParty).verify(input, stored: Self.dummyPasskey, expectedChallengeSHA256: challengeHash ?? Data())
                throw PasskeyError.unknownCredential
            }
            guard let challengeHash else {
                _ = try? AssertionVerifier(relyingParty: relyingParty).verify(input, stored: stored.passkey, expectedChallengeSHA256: Data())
                throw PasskeyError.challengeInvalid
            }
            let result = try AssertionVerifier(relyingParty: relyingParty).verify(input, stored: stored.passkey, expectedChallengeSHA256: challengeHash)
            guard try await advanceCounter(credentialID: input.credentialID, to: result.newSignCount) else { throw PasskeyError.counterRegression }
            let t = now()
            let ts = DB.time(t)
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                struct Active: Decodable { let active: Int }
                guard try await tx.raw("SELECT active FROM accounts WHERE id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: Active.self)?.active == 1 else { throw SecondFactorError.accountInactive }
                // Only this session, only while it is still the same live authenticated session of this account (row locked, so a
                // concurrent logout/revocation either wins before this check or waits for the commit).
                struct Live: Decodable { let id: Blob }
                guard try await tx.raw("""
                    SELECT id FROM sessions
                    WHERE id = \(bind: DB.bin(session.id)) AND account_id = \(bind: DB.bin(account)) AND state = 'authenticated' AND revoked_at IS NULL
                      AND idle_expires_at > \(bind: ts) AND absolute_expires_at > \(bind: ts)
                    FOR UPDATE
                    """).first(decoding: Live.self) != nil else { throw SecondFactorError.noSession }
                try await tx.raw("UPDATE sessions SET authenticated_at = \(bind: ts) WHERE id = \(bind: DB.bin(session.id))").run()
                try await tx.raw("""
                    INSERT INTO audit_events (id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
                    VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), 'human', 'auth', 'auth.reauth', \(bind: DB.bin(session.id)), \(bind: ts), '{"method":"passkey"}')
                    """).run()
            }
            try? await throttles.clear(.account, accountKey)
            return t
        } catch let e as PasskeyError {
            try? await throttles.recordFailure(.ip, clientIP, policy: .passwordPerIP)
            try? await throttles.recordFailure(.account, accountKey, policy: .secondFactor)
            throw AuthenticationFailed.translate(e)
        } catch let e as SecondFactorError {
            try? await throttles.recordFailure(.ip, clientIP, policy: .passwordPerIP)
            try? await throttles.recordFailure(.account, accountKey, policy: .secondFactor)
            throw AuthenticationFailed.translate(e)
        }
    }

    // MARK: second factor

    /// Password as second factor of a `factor_pending` session. Success rotates into `authenticated`.
    public func verifySecondFactorPassword(session: SessionRecord, password: String, clientIP: String) async throws -> (token: String, session: SessionRecord) {
        guard session.state == .factorPending, let account = session.accountID else {
            throw AuthenticationFailed.translate(SecondFactorError.wrongState)
        }
        let key = "\(account.uuidString.lowercased())|\(clientIP)"
        try await throttles.ensureNotLocked(.totp, key)
        struct Row: Decodable { let password_hash: String; let active: Int; let rights_version: UInt64 }
        let row = try await sql.raw("SELECT password_hash, active, rights_version FROM accounts WHERE id = \(bind: DB.bin(account))").first(decoding: Row.self)
        let hash = (row?.active == 1 && row?.password_hash.isEmpty == false) ? row?.password_hash : nil
        let ok = await passwords.verify(password: password, hash: hash)
        guard ok, let row else {
            try? await throttles.recordFailure(.totp, key, policy: .secondFactor)
            throw AuthenticationFailed.translate(row == nil ? SecondFactorError.unknownAccount : (hash == nil ? SecondFactorError.noPasswordHash : SecondFactorError.passwordMismatch))
        }
        try await throttles.clear(.totp, key)
        let result = try await sessions.rotate(from: session, to: .authenticated, accountID: account, method: "passkey+password", rightsVersion: row.rights_version)
        try await sql.raw("UPDATE accounts SET last_login_at = \(bind: DB.time(now())) WHERE id = \(bind: DB.bin(account))").run()
        return result
    }

    // MARK: DB access

    private struct StoredRow { let accountID: UUID; let passkey: StoredPasskey }

    /// Marks the newest unrevoked login challenge of the session consumed (FOR UPDATE, committed on its own).
    /// Returns its hash only while it is unexpired; an expired one is consumed and yields nil.
    /// `purpose` is a fixed literal of this type, never client input. With `account`, the challenge must be bound to that account.
    private func consumeChallenge(session: SessionRecord, challengeID: UUID?, purpose: String = "passkey-login", account: UUID? = nil) async throws -> Data? {
        struct R: Decodable { let id: Blob; let challenge_hash: Blob; let expires_at: Date }
        precondition(purpose == "passkey-login" || purpose == "fresh-auth")
        let t = now()
        return try await db.transaction { conn -> Data? in
            let tx = conn as! SQLDatabase
            guard let r = try await tx.raw("""
                SELECT id, challenge_hash, expires_at FROM auth_challenges
                WHERE session_id = \(bind: DB.bin(session.id)) AND purpose = \(bind: purpose) AND consumed_at IS NULL AND revoked_at IS NULL
                  AND (\(bind: challengeID.map(DB.bin)) IS NULL OR id = \(bind: challengeID.map(DB.bin)))
                  AND (\(bind: account.map(DB.bin)) IS NULL OR account_id = \(bind: account.map(DB.bin)))
                ORDER BY created_at DESC LIMIT 1 FOR UPDATE
                """).first(decoding: R.self) else { return nil }
            try await tx.raw("UPDATE auth_challenges SET consumed_at = \(bind: DB.time(t)) WHERE id = \(bind: r.id)").run()
            return r.expires_at > t ? r.challenge_hash.data : nil
        }
    }

    private func loadPasskey(credentialID: Data) async throws -> StoredRow? {
        struct R: Decodable { let account_id: Blob; let user_handle: Blob; let public_key_bytes: Blob; let sign_count: UInt64 }
        guard let r = try await sql.raw("""
            SELECT account_id, user_handle, public_key_bytes, sign_count FROM passkeys WHERE credential_id = \(bind: Blob(credentialID))
            """).first(decoding: R.self), let account = DB.uuid(r.account_id.data),
              let pem = String(data: r.public_key_bytes.data, encoding: .utf8), r.sign_count <= UInt64(UInt32.max) else { return nil }
        return StoredRow(accountID: account, passkey: StoredPasskey(credentialID: credentialID, userHandle: r.user_handle.data, publicKeyPEM: pem, signCount: UInt32(r.sign_count)))
    }

    /// Conditional counter update (clone/replay protection): `new > old` or both 0.
    private func advanceCounter(credentialID: Data, to newCount: UInt32) async throws -> Bool {
        struct R: Decodable { let sign_count: UInt64 }
        let t = now()
        return try await db.transaction { conn -> Bool in
            let tx = conn as! SQLDatabase
            guard let r = try await tx.raw("SELECT sign_count FROM passkeys WHERE credential_id = \(bind: Blob(credentialID)) FOR UPDATE").first(decoding: R.self),
                  r.sign_count <= UInt64(UInt32.max), AssertionVerifier.counterPlausible(old: UInt32(r.sign_count), new: newCount) else { return false }
            try await tx.raw("UPDATE passkeys SET sign_count = \(bind: Int(newCount)), last_used_at = \(bind: DB.time(t)) WHERE credential_id = \(bind: Blob(credentialID))").run()
            return true
        }
    }

    private func activeRightsVersion(_ account: UUID) async throws -> UInt64? {
        struct R: Decodable { let active: Int; let rights_version: UInt64 }
        guard let r = try await sql.raw("SELECT active, rights_version FROM accounts WHERE id = \(bind: DB.bin(account))").first(decoding: R.self), r.active == 1 else { return nil }
        return r.rights_version
    }

    /// Fixed synthetic key for the dummy verification path (a valid ES256 SPKI, never matches a real signature).
    private static let dummyPasskey = StoredPasskey(
        credentialID: Data([0]), userHandle: Data(repeating: 0x30, count: 36),
        publicKeyPEM: """
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEQNAm2fom7wxuIcu/HMnCACNpe4rL
            Kyac4tDf9NqIXXZSu8DyVaan+oDXb8nRFxKmGzxFgqkSYXrSwFI57h7rEQ==
            -----END PUBLIC KEY-----
            """, signCount: 0)
}
