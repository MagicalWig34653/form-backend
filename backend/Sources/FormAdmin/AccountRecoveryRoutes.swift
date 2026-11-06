// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Account authentication is required; a recovery code only unlocks data in the browser.
enum AccountRecoveryRoutes {
    struct Envelope: Codable { let salt: String; let iterations: Int; let iv: String; let wrap: String }
    struct Row: Decodable { let revision: String; let salt: Blob; let iv: Blob; let wrapped_key: Blob }
    static func read(_ sql: SQLDatabase, account: UUID) async throws -> [String: Any]? {
        guard let r = try await sql.raw("SELECT revision, salt, iv, wrapped_key FROM account_key_recovery WHERE account_id = \(bind: DB.bin(account))").first(decoding: Row.self) else { return nil }
        return ["revision": r.revision, "salt": r.salt.data.base64URLString, "iterations": 600000, "iv": r.iv.data.base64URLString, "wrap": r.wrapped_key.data.base64URLString]
    }
    static func register(_ root: RoutesBuilder, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        root.put("me", "account-recovery") { req async throws -> Response in
            let session = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            try await guardian.requireFreshAuthentication(session, now: now())
            let account = session.accountID!
            struct Input: Decodable { let publicKey: String; let expectedRevision: String?; let recovery: Envelope }
            let b: Input = try FormAdmin.decodeStrict(req, allowed: ["publicKey", "expectedRevision", "recovery"])
            let pk = try RotationRoutes.bytes(b.publicKey, 32)
            guard KeyRoutes.usableForKeyAgreement(pk), b.recovery.iterations == 600000 else { throw ValidationFailed(detail: "Ungültige Wiederherstellung") }
            let salt = try RotationRoutes.bytes(b.recovery.salt, 32), iv = try RotationRoutes.bytes(b.recovery.iv, 12), wrap = try RotationRoutes.bytes(b.recovery.wrap, 48)
            let revision = UUID().uuidString.lowercased(), at = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                // Serialize creation and CAS even when the account has no data key yet.
                _ = try await tx.raw("SELECT id FROM accounts WHERE id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: FormAdmin.CountRowID.self)
                struct K: Decodable { let public_key: Blob }
                if let key = try await tx.raw("SELECT public_key FROM account_keys WHERE account_id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: K.self) {
                    guard key.public_key.data == pk else { throw Abort(.conflict) }
                } else {
                    guard b.expectedRevision == nil else { throw Abort(.conflict) }
                    try await tx.raw("INSERT INTO account_keys (account_id, public_key, created_at) VALUES (\(bind: DB.bin(account)), \(bind: Blob(pk)), \(bind: at))").run()
                }
                let old = try await tx.raw("SELECT revision, salt, iv, wrapped_key FROM account_key_recovery WHERE account_id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: Row.self)
                guard old?.revision == b.expectedRevision else { throw Abort(.conflict) }
                try await tx.raw("DELETE FROM account_key_recovery WHERE account_id = \(bind: DB.bin(account))").run()
                try await tx.raw("INSERT INTO account_key_recovery (account_id, revision, salt, iv, wrapped_key) VALUES (\(bind: DB.bin(account)), \(bind: revision), \(bind: Blob(salt)), \(bind: Blob(iv)), \(bind: Blob(wrap)))").run()
                try await MailRoutes.audit(tx, actor: account, action: "key.account.recovery.save", subject: account, at: at)
            }
            let res = try FormAdmin.json(.ok, ["revision": revision]); res.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return res
        }
    }
}
