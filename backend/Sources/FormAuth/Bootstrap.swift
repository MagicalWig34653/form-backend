// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormPersistence
import Foundation
import SQLKit

/// Operator commands that need no session: the very first administrator and replacement enrollment links.
public enum Bootstrap {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case accountsExist, usernameInvalid, passwordTooShort, unknownAccount
        public var description: String {
            switch self {
            case .accountsExist: return "accounts already exist; use enroll-passkey for an existing account"
            case .usernameInvalid: return "username must match ^[a-z0-9][a-z0-9._@-]{2,119}$"
            case .passwordTooShort: return "password must have at least 12 characters"
            case .unknownAccount: return "no such active account"
            }
        }
    }

    static func validUsername(_ s: String) -> Bool { s.range(of: "^[a-z0-9][a-z0-9._@-]{2,119}$", options: .regularExpression) != nil }

    /// Creates the first account (Argon2id password, all catalog permissions with system scope) and a first-passkey token.
    /// Refuses when any account exists, so it cannot be used to add a privileged account to a running system.
    public static func createFirstAdmin(db: Database, username: String, password: String = "", now: Date = Date()) async throws -> (account: UUID, token: String) {
        guard validUsername(username) else { throw Failure.usernameInvalid }
        guard password.isEmpty || (12...256).contains(password.count) else { throw Failure.passwordTooShort }
        let hash = password.isEmpty ? "" : try Argon2id.hash(password)
        let id = UUID(), t = DB.time(now)
        // One pinned connection holds the named lock around check + insert, so parallel bootstrap runs (several Swarm tasks)
        // create at most one account; the lock is released on every path.
        struct C: Decodable { let c: Int }
        struct L: Decodable { let l: Int? }
        try await (db as! SQLDatabase).withSession { session in
            guard try await session.raw("SELECT GET_LOCK('form_bootstrap_admin', 10) AS l").first(decoding: L.self)?.l == 1 else { throw Failure.accountsExist }
            do {
                guard try await session.raw("SELECT COUNT(*) AS c FROM accounts").first(decoding: C.self)?.c == 0 else { throw Failure.accountsExist }
                try await session.raw("START TRANSACTION").run()
                try await session.raw("""
                    INSERT INTO accounts (id, username, password_hash, template_name, active, mcp_allowed, rights_version, created_at)
                    VALUES (\(bind: DB.bin(id)), \(bind: username), \(bind: hash), 'Administrator', 1, 0, 1, \(bind: t))
                    """).run()
                for p in PermissionCatalog.all.sorted() {
                    try await session.raw("""
                        INSERT INTO permission_assignments (id, account_id, permission, scope_kind, revision, granted_by, granted_at)
                        VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(id)), \(bind: p), 'system', 1, \(bind: DB.bin(id)), \(bind: t))
                        """).run()
                }
                try await session.raw("""
                    INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
                    VALUES (\(bind: DB.bin(UUID())), NULL, NULL, NULL, 'service', 'auth', 'account.bootstrap', \(bind: DB.bin(id)), \(bind: t), '{}')
                    """).run()
                try await session.raw("COMMIT").run()
            } catch {
                _ = try? await session.raw("ROLLBACK").run()
                _ = try? await session.raw("SELECT RELEASE_LOCK('form_bootstrap_admin')").run()
                throw error
            }
            _ = try? await session.raw("SELECT RELEASE_LOCK('form_bootstrap_admin')").run()
        }
        let token = try await EnrollmentService(db: db, now: { now }).issue(account: id, purpose: .firstPasskey)
        return (id, token)
    }

    /// New enrollment link for an existing active account (lost device, additional key). Operator action; audited.
    public static func issueEnrollment(db: Database, username: String, now: Date = Date()) async throws -> String {
        struct R: Decodable { let id: Blob }
        guard let r = try await (db as! SQLDatabase).raw("SELECT id FROM accounts WHERE username = \(bind: username) AND active = 1").first(decoding: R.self), let id = DB.uuid(r.id.data) else { throw Failure.unknownAccount }
        let token = try await EnrollmentService(db: db, now: { now }).issue(account: id, purpose: .recoveryPasskey)
        try await (db as! SQLDatabase).raw("""
            INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
            VALUES (\(bind: DB.bin(UUID())), NULL, NULL, NULL, 'service', 'auth', 'account.enrollment.issue', \(bind: DB.bin(id)), \(bind: DB.time(now)), '{}')
            """).run()
        return token
    }
}
