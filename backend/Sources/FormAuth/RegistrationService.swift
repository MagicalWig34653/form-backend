// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormCore
import FormPersistence
import Foundation
import SQLKit

/// One uniform answer for every refused registration/enrollment (no oracle on token validity, duplicates or key problems).
public struct RegistrationFailed: PublicProblemError {
    public let auditReason: String?
    public var statusCode: UInt { 422 }
    public var code: String { "registration_failed" }
    public var message: String { "Die Registrierung ist fehlgeschlagen." }
    public static func translate(_ error: Error) -> RegistrationFailed {
        switch error {
        case let e as RegistrationError: return RegistrationFailed(auditReason: "registration.\(e)")
        default: return RegistrationFailed(auditReason: "internal.\(type(of: error))")
        }
    }
}

/// One-time enrollment tokens (`account_enrollments`): 256-bit random, only the SHA-256 is stored.
public struct EnrollmentService: Sendable {
    public enum Purpose: String, Sendable { case firstPasskey = "first-passkey", recoveryPasskey = "recovery-passkey" }
    let db: Database
    var sql: SQLDatabase { db as! SQLDatabase }
    let now: @Sendable () -> Date
    public init(db: Database, now: @escaping @Sendable () -> Date = { Date() }) { self.db = db; self.now = now }

    /// Returns the token (shown once). `lifetime` is capped at 7 days by the schema.
    public func issue(account: UUID, purpose: Purpose, createdBy: UUID? = nil, lifetime: TimeInterval = 86_400) async throws -> String {
        let raw = Data.random(32)
        let t = now()
        try await sql.raw("""
            INSERT INTO account_enrollments (id, account_id, token_hash, purpose, created_by, created_at, expires_at)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), \(bind: Blob(Data(SHA256.hash(data: raw)))), \(bind: purpose.rawValue),
              \(bind: createdBy.map(DB.bin)), \(bind: DB.time(t)), \(bind: DB.time(t.addingTimeInterval(min(lifetime, 7 * 86_400)))))
            """).run()
        return raw.base64URL
    }

    struct Row: Decodable { let id: Blob; let account_id: Blob }

    /// Account of a valid (existing, unconsumed, unexpired) token whose account is active; nil otherwise. Does not consume.
    func lookup(_ token: String, _ sql: SQLDatabase? = nil) async throws -> (id: UUID, account: UUID)? {
        guard let raw = Data(base64URLToken: token), raw.count == 32 else { return nil }
        let q = sql ?? self.sql
        guard let r = try await q.raw("""
            SELECT e.id AS id, e.account_id AS account_id FROM account_enrollments e JOIN accounts a ON a.id = e.account_id
            WHERE e.token_hash = \(bind: Blob(Data(SHA256.hash(data: raw)))) AND e.consumed_at IS NULL AND e.expires_at > \(bind: DB.time(now())) AND a.active = 1
            """).first(decoding: Row.self), let id = DB.uuid(r.id.data), let acc = DB.uuid(r.account_id.data) else { return nil }
        return (id, acc)
    }
}

/// Registers new passkeys. Challenges live in `auth_challenges` (purpose `passkey-register`, bound to the session and the
/// account, 120 s, single use, consumed even when the verification fails). Used from two doors: the one-time enrollment
/// token (anonymous session) and an authenticated, fresh session adding another passkey to its own account.
public struct RegistrationService: Sendable {
    public static let maxPasskeysPerAccount = 20
    let db: Database
    var sql: SQLDatabase { db as! SQLDatabase }
    let relyingParty: RelyingParty
    let enrollments: EnrollmentService
    let now: @Sendable () -> Date

    public init(db: Database, relyingParty: RelyingParty, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.relyingParty = relyingParty; self.now = now
        enrollments = EnrollmentService(db: db, now: now)
    }

    public struct Options: Sendable {
        public let challengeID: UUID, challenge: Data, expiresAt: Date, userHandle: Data, userName: String, excludeIDs: [Data]
    }

    private struct AccountRow: Decodable { let username: String; let active: Int }
    private struct IdRow: Decodable { let credential_id: Blob }

    /// Issues creation options for `account` (older open registration challenges of the session are revoked).
    public func begin(session: SessionRecord, account: UUID) async throws -> Options {
        guard let a = try await sql.raw("SELECT username, active FROM accounts WHERE id = \(bind: DB.bin(account))").first(decoding: AccountRow.self), a.active == 1 else { throw RegistrationError.accountInactive }
        let existing = try await sql.raw("SELECT credential_id FROM passkeys WHERE account_id = \(bind: DB.bin(account))").all(decoding: IdRow.self).map(\.credential_id.data)
        guard existing.count < Self.maxPasskeysPerAccount else { throw RegistrationError.duplicateCredential }
        let challenge = Data.random(32), id = UUID(), t = now(), ts = DB.time(t)
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            try await tx.raw("UPDATE auth_challenges SET revoked_at = \(bind: ts) WHERE session_id = \(bind: DB.bin(session.id)) AND purpose = 'passkey-register' AND consumed_at IS NULL AND revoked_at IS NULL").run()
            try await tx.raw("""
                INSERT INTO auth_challenges (id, session_id, account_id, purpose, challenge_hash, factor_method, created_at, expires_at)
                VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(session.id)), \(bind: DB.bin(account)), 'passkey-register', \(bind: Blob(Data(SHA256.hash(data: challenge)))), 'passkey',
                  \(bind: ts), \(bind: DB.time(t.addingTimeInterval(LoginService.challengeLifetime))))
                """).run()
        }
        return Options(challengeID: id, challenge: challenge, expiresAt: t.addingTimeInterval(LoginService.challengeLifetime),
                       userHandle: Data(account.uuidString.lowercased().utf8), userName: a.username, excludeIDs: existing)
    }

    /// Verifies the response and stores the passkey. With `enrollmentID` the token is consumed in the same transaction
    /// as the insert (a failed verification leaves it usable until it expires; the challenge is gone either way).
    public func finish(session: SessionRecord, account: UUID, challengeID: UUID, clientDataJSON: Data, attestationObject: Data,
                       label: String, enrollmentID: UUID? = nil) async throws {
        guard (1...120).contains(label.count), !label.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { throw RegistrationError.labelInvalid }
        // 1. consume the challenge first, in its own committed transaction
        struct C: Decodable { let id: Blob; let challenge_hash: Blob; let expires_at: Date; let account_id: Blob? }
        let t = now()
        let hash: Data? = try await db.transaction { conn -> Data? in
            let tx = conn as! SQLDatabase
            guard let c = try await tx.raw("""
                SELECT id, challenge_hash, expires_at, account_id FROM auth_challenges
                WHERE id = \(bind: DB.bin(challengeID)) AND session_id = \(bind: DB.bin(session.id)) AND purpose = 'passkey-register' AND consumed_at IS NULL AND revoked_at IS NULL FOR UPDATE
                """).first(decoding: C.self) else { return nil }
            try await tx.raw("UPDATE auth_challenges SET consumed_at = \(bind: DB.time(t)) WHERE id = \(bind: c.id)").run()
            return c.expires_at > t && c.account_id?.data == DB.bin(account).data ? c.challenge_hash.data : nil
        }
        guard let hash else { throw RegistrationError.challengeInvalid }
        let result = try RegistrationVerifier(relyingParty: relyingParty).verify(clientDataJSON: clientDataJSON, attestationObject: attestationObject, expectedChallengeSHA256: hash)
        // 2. store; token and passkey change together
        do {
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                if let enrollmentID {
                    // Consume atomically: only one of two parallel registrations with the same token can win.
                    try await tx.raw("UPDATE account_enrollments SET consumed_at = \(bind: DB.time(t)) WHERE id = \(bind: DB.bin(enrollmentID)) AND consumed_at IS NULL AND expires_at > \(bind: DB.time(t))").run()
                    struct N: Decodable { let n: Int }
                    guard try await tx.raw("SELECT ROW_COUNT() AS n").first(decoding: N.self)?.n == 1 else { throw RegistrationError.enrollmentInvalid }
                }
                guard try await tx.raw("SELECT active FROM accounts WHERE id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: AccountRow2.self)?.active == 1 else { throw RegistrationError.accountInactive }
                try await tx.raw("""
                    INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at)
                    VALUES (\(bind: Blob(result.credentialID)), \(bind: DB.bin(account)), \(bind: Blob(Data(account.uuidString.lowercased().utf8))), \(bind: Blob(Data(result.publicKeyPEM.utf8))),
                      'pem-spki', \(bind: result.coseAlgorithm), \(bind: Int(result.signCount)), \(bind: label), \(bind: relyingParty.rpID), \(bind: DB.time(t)))
                    """).run()
                try await tx.raw("""
                    INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
                    VALUES (\(bind: DB.bin(UUID())), NULL, NULL, \(bind: DB.bin(account)), 'human', 'auth', 'passkey.register', \(bind: DB.bin(account)), \(bind: DB.time(t)),
                      \(bind: "{\"alg\":\(result.coseAlgorithm),\"via\":\"\(enrollmentID == nil ? "session" : "enrollment")\"}"))
                    """).run()
            }
        } catch {
            if DB.isDuplicateKey(error) { throw RegistrationError.duplicateCredential }
            throw error
        }
    }
    private struct AccountRow2: Decodable { let active: Int }
}
