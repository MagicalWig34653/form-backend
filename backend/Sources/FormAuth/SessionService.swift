// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormPersistence
import Foundation
import Vapor
import Fluent
import SQLKit

public enum SessionState: String, Sendable { case anonymous, factorPending = "factor_pending", authenticated, revoked, expired }

public struct SessionRecord: Sendable, Equatable {
    public let id: UUID
    public let state: SessionState
    public let accountID: UUID?
    public let authMethod: String?
    public let rightsVersion: UInt64?
    /// Earliest of idle and absolute expiry (what the client may rely on).
    public let expiresAt: Date
}

/// Lifetimes (anmeldung.md): anonymous/factor-pending absolute 5 min without extension; authenticated idle 30 min,
/// absolute 12 h.
public struct SessionPolicy: Sendable {
    public var intermediateLifetime: TimeInterval = 5 * 60
    public var idle: TimeInterval = 30 * 60
    public var absolute: TimeInterval = 12 * 3600
    public init() {}
}

/// DB sessions with an opaque 256-bit token (only SHA-256 stored), rotation on every privilege change and a
/// synchronizer CSRF token per session (secret stored AEAD-protected under the server key).
public struct SessionService: Sendable {
    public static let cookieName = "__Host-admin_session"
    let audience: String
    let db: Database
    var sql: SQLDatabase { db as! SQLDatabase }
    let keys: any ServerKeyProvider
    let policy: SessionPolicy
    let now: @Sendable () -> Date

    public init(db: Database, keys: any ServerKeyProvider, policy: SessionPolicy = SessionPolicy(), audience: String = "internal", now: @escaping @Sendable () -> Date = { Date() }) {
        self.audience = audience
        self.db = db; self.keys = keys; self.policy = policy; self.now = now
    }

    // Domain separation binds every state (including challenges) to its listener without a schema change.
    private func tokenHash(_ raw: Data) -> Data {
        Data(SHA256.hash(data: Data(("form-session-v2|" + audience + "|").utf8) + raw))
    }

    private struct Row: Decodable {
        let id: Blob; let state: String; let account_id: Blob?; let auth_method: String?; let rights_version: UInt64?; let idle_expires_at: Date
    }

    /// Creates an anonymous session. Returns the cookie token and the session record.
    public func createAnonymous() async throws -> (token: String, session: SessionRecord) {
        let t = now()
        return try await insert(state: .anonymous, accountID: nil, method: nil, rightsVersion: nil, at: t,
                                idle: t.addingTimeInterval(policy.intermediateLifetime), absolute: t.addingTimeInterval(policy.intermediateLifetime),
                                primaryAt: nil, secondAt: nil)
    }

    /// Resolves a cookie token. nil for unknown/revoked/expired. Authenticated sessions slide the idle window
    /// (never beyond the absolute limit); intermediate sessions are never extended.
    public func resolve(token: String) async throws -> SessionRecord? {
        guard let raw = Data(base64URLToken: token), raw.count == 32 else { return nil }
        let hash = Blob(tokenHash(raw))
        let ts = DB.time(now())
        guard let row = try await sql.raw("""
            SELECT id, state, account_id, auth_method, rights_version, idle_expires_at FROM sessions
            WHERE token_hash = \(bind: hash) AND revoked_at IS NULL AND state IN ('anonymous','factor_pending','authenticated')
              AND idle_expires_at > \(bind: ts) AND absolute_expires_at > \(bind: ts)
            """).first(decoding: Row.self), let id = DB.uuid(row.id.data), let state = SessionState(rawValue: row.state) else { return nil }
        if let account = row.account_id {
            struct A: Decodable { let active: Int }
            guard try await sql.raw("SELECT active FROM accounts WHERE id = \(bind: account)").first(decoding: A.self)?.active == 1 else { return nil }
        }
        let idleWindow = state == .authenticated ? await idleLifetime() : policy.idle
        if state == .authenticated {
            try await sql.raw("""
                UPDATE sessions SET last_seen_at = \(bind: ts),
                  idle_expires_at = LEAST(absolute_expires_at, \(bind: DB.time(now().addingTimeInterval(idleWindow))))
                WHERE id = \(bind: DB.bin(id))
                """).run()
        }
        let expires = state == .authenticated ? min(row.idle_expires_at, now().addingTimeInterval(idleWindow)) : row.idle_expires_at
        return SessionRecord(id: id, state: state, accountID: row.account_id.flatMap { DB.uuid($0.data) },
                             authMethod: row.auth_method, rightsVersion: row.rights_version, expiresAt: expires)
    }

    /// Replaces `old` by a new session in one transaction (rotation): new token, new CSRF secret, the old row is
    /// revoked and linked, its open challenges are revoked. Nothing else is copied to the new session.
    public func rotate(from old: SessionRecord, to state: SessionState, accountID: UUID, method: String, rightsVersion: UInt64) async throws
        -> (token: String, session: SessionRecord)
    {
        precondition(state == .factorPending || state == .authenticated)
        let t = now()
        let intermediate = state == .factorPending
        let idleWindow = intermediate ? policy.intermediateLifetime : await idleLifetime()
        let idle = t.addingTimeInterval(idleWindow)
        let abs = t.addingTimeInterval(intermediate ? policy.intermediateLifetime : policy.absolute)
        let created = try await prepare(state: state, accountID: accountID, method: method, rightsVersion: rightsVersion,
                                        at: t, idle: idle, absolute: abs,
                                        primaryAt: t, secondAt: state == .authenticated && ["passkey+password", "passkey+totp", "password+totp"].contains(method) ? t : nil)
        let ts = DB.time(t)
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            struct Active: Decodable { let active: Int }
            guard try await tx.raw("SELECT active FROM accounts WHERE id = \(bind: DB.bin(accountID)) FOR UPDATE").first(decoding: Active.self)?.active == 1 else { throw Abort(.unauthorized) }
            if ["passkey+totp", "password+totp"].contains(method) {
                struct T: Decodable { let secret_ref: String? }
                guard try await tx.raw("SELECT secret_ref FROM account_totp WHERE account_id = \(bind: DB.bin(accountID)) FOR UPDATE").first(decoding: T.self)?.secret_ref != nil else { throw Abort(.unauthorized) }
                try await tx.raw("UPDATE accounts SET last_login_at = \(bind: ts) WHERE id = \(bind: DB.bin(accountID))").run()
            }
            try await created.insert(tx)
            try await tx.raw("""
                UPDATE sessions SET state = 'revoked', revoked_at = \(bind: ts), replaced_by = \(bind: DB.bin(created.session.id))
                WHERE id = \(bind: DB.bin(old.id)) AND revoked_at IS NULL AND state IN ('anonymous','factor_pending','authenticated')
                """).run()
            // Exactly one predecessor must have been consumed: a parallel rotation or a revocation that won the race rolls this one back (review M1).
            struct N: Decodable { let n: Int }
            guard try await tx.raw("SELECT ROW_COUNT() AS n").first(decoding: N.self)?.n == 1 else { throw Abort(.unauthorized) }
            try await tx.raw("""
                UPDATE auth_challenges SET revoked_at = \(bind: ts) WHERE session_id = \(bind: DB.bin(old.id)) AND consumed_at IS NULL AND revoked_at IS NULL
                """).run()
        }
        return (created.token, created.session)
    }

    /// Idle time after which a signed-in session ends: setting `auth.sessionIdleMinutes` (5...720, default 120, editable in the UI), never beyond
    /// the absolute limit of the session. Falls back to the policy value (30 min) if the setting cannot be read.
    func idleLifetime() async -> TimeInterval {
        guard let value = try? await SystemSettings.value("auth.sessionIdleMinutes", sql: sql), let minutes = Int(value), (5...720).contains(minutes) else { return policy.idle }
        return TimeInterval(minutes * 60)
    }

    /// How long a completed login counts as "fresh" for sensitive actions: setting `auth.freshLoginMinutes` (1...120, default 30, editable in the UI).
    /// Falls back to the former fixed 5 minutes if the setting cannot be read, never to something longer.
    public func freshWindow() async -> TimeInterval {
        guard let value = try? await SystemSettings.value("auth.freshLoginMinutes", sql: sql), let minutes = Int(value), (1...120).contains(minutes) else { return 300 }
        return TimeInterval(minutes * 60)
    }

    /// `authenticated_at` of the session (nil if unknown): when both factors were last completed.
    public func authenticatedAt(_ session: SessionRecord) async throws -> Date? {
        struct R: Decodable { let authenticated_at: Date? }
        return try await sql.raw("SELECT authenticated_at FROM sessions WHERE id = \(bind: DB.bin(session.id))").first(decoding: R.self)?.authenticated_at
    }

    public func revoke(_ session: SessionRecord) async throws {
        try await sql.raw("UPDATE sessions SET state = 'revoked', revoked_at = \(bind: DB.time(now())) WHERE id = \(bind: DB.bin(session.id)) AND revoked_at IS NULL").run()
    }

    // MARK: CSRF

    /// Token handed to the page: HMAC(csrf secret, session id). Stable for the session's lifetime.
    public func csrfToken(for session: SessionRecord) async throws -> String? {
        guard let secret = try await csrfSecret(session.id) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(session.id.uuidString.lowercased().utf8), using: SymmetricKey(data: secret))).base64URL
    }

    /// Constant-time check of a presented token (missing/invalid -> false).
    public func verifyCSRF(_ presented: String?, for session: SessionRecord) async throws -> Bool {
        guard let presented, let expected = try await csrfToken(for: session) else { return false }
        return constantTimeEqual(Data(presented.utf8), Data(expected.utf8))
    }

    // MARK: internals

    private struct Prepared {
        let token: String; let session: SessionRecord; let tokenHash: Blob; let sealed: Blob
        let ts: String; let idle: String; let absolute: String; let primary: String?; let second: String?; let level: String
        func insert(_ db: SQLDatabase) async throws {
            try await db.raw("""
                INSERT INTO sessions (id, token_hash, account_id, state, auth_level, auth_method, authenticated_at, rights_version,
                  primary_factor_at, second_factor_at, csrf_secret_ciphertext, created_at, last_seen_at, idle_expires_at, absolute_expires_at)
                VALUES (\(bind: DB.bin(session.id)), \(bind: tokenHash), \(bind: session.accountID.map(DB.bin)), \(bind: session.state.rawValue), \(bind: level),
                  \(bind: session.authMethod), \(bind: session.state == .authenticated ? ts : nil), \(bind: session.rightsVersion),
                  \(bind: primary), \(bind: second), \(bind: sealed), \(bind: ts), \(bind: ts), \(bind: idle), \(bind: absolute))
                """).run()
        }
    }

    private func prepare(state: SessionState, accountID: UUID?, method: String?, rightsVersion: UInt64?, at t: Date, idle: Date, absolute: Date,
                         primaryAt: Date?, secondAt: Date?) async throws -> Prepared {
        let id = UUID()
        let raw = Data.random(32)
        let secret = Data.random(32)
        let master = try await keys.serverKey()
        let box = try AES.GCM.seal(secret, using: KeyPurpose.csrf.derive(from: master), authenticating: Data(id.uuidString.lowercased().utf8))
        let level: String
        switch state { case .anonymous: level = "none"; case .factorPending: level = "primary"; default: level = "full" }
        return Prepared(token: raw.base64URL,
                        session: SessionRecord(id: id, state: state, accountID: accountID, authMethod: method, rightsVersion: rightsVersion, expiresAt: idle),
                        tokenHash: Blob(tokenHash(raw)), sealed: Blob(box.combined!),
                        ts: DB.time(t), idle: DB.time(idle), absolute: DB.time(absolute),
                        primary: primaryAt.map(DB.time), second: secondAt.map(DB.time), level: level)
    }

    private func insert(state: SessionState, accountID: UUID?, method: String?, rightsVersion: UInt64?, at t: Date, idle: Date, absolute: Date,
                        primaryAt: Date?, secondAt: Date?) async throws -> (token: String, session: SessionRecord) {
        let p = try await prepare(state: state, accountID: accountID, method: method, rightsVersion: rightsVersion, at: t, idle: idle,
                                  absolute: absolute, primaryAt: primaryAt, secondAt: secondAt)
        try await p.insert(sql)
        return (p.token, p.session)
    }

    private struct SecretRow: Decodable { let csrf_secret_ciphertext: Blob }

    private func csrfSecret(_ id: UUID) async throws -> Data? {
        guard let row = try await sql.raw("SELECT csrf_secret_ciphertext FROM sessions WHERE id = \(bind: DB.bin(id))").first(decoding: SecretRow.self) else { return nil }
        let master = try await keys.serverKey()
        guard let box = try? AES.GCM.SealedBox(combined: row.csrf_secret_ciphertext.data) else { return nil }
        return try? AES.GCM.open(box, using: KeyPurpose.csrf.derive(from: master), authenticating: Data(id.uuidString.lowercased().utf8))
    }
}

extension Data {
    /// Strict unpadded base64url (as produced by `base64URL`).
    init?(base64URLToken s: String) {
        guard !s.isEmpty, s.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }) else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}
