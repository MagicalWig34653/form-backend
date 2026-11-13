// SPDX-License-Identifier: AGPL-3.0-only
import CoreFoundation
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Accounts, customer rights and own passkeys (VORGESCHLAGEN):
/// - `POST /accounts` (system `identity.manage` (rechte.md: `account.manage` is only the self-service right of every account), fresh login): new account with password; returns a one-time passkey setup link.
/// - `GET /tenants/{t}/members`, `PUT /tenants/{t}/members/{a}/permissions` (customer `identity.manage`, fresh login): direct customer-wide
///   rights. Nobody can grant what they do not hold themselves, and nobody changes their own rights.
/// - `GET /me/passkeys`, `DELETE /me/passkeys/{credentialId}` (fresh login, never the last passkey).
enum AccountRoutes {
    static let assignable: Set<String> = PermissionCatalog.all.subtracting(["system.manage"])

    static func register(root: RoutesBuilder, tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        let origin = guardian.config.adminOrigin

        root.get("accounts") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            try await perms.authorize(account: s.accountID!, "identity.manage", on: .system)
            struct A: Decodable { let id: Blob; let username: String; let active: Int; let mcp_allowed: Int }
            let rows = try await sql.raw("SELECT id, username, active, mcp_allowed FROM accounts ORDER BY username LIMIT 2000").all(decoding: A.self)
            return try MailRoutes.anyJSON(["items": rows.map { ["id": DB.uuid($0.id.data)!.uuidString.lowercased(), "username": $0.username, "active": $0.active == 1, "mcpAllowed": $0.mcp_allowed == 1] as [String: Any] }])
        }
        root.put("accounts", ":accountId", "status") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            try await guardian.requireFreshAuthentication(s, now: now())
            let target = try FormAdmin.uuidParam(req, "accountId"), me = s.accountID!
            let obj = try MailRoutes.jsonObject(req, allowed: ["active", "mcpAllowed"])
            guard obj.count == 1, let raw = (obj["active"] ?? obj["mcpAllowed"]) as? NSNumber, CFGetTypeID(raw) == CFBooleanGetTypeID() else { throw Abort(.badRequest) }
            let value = raw.boolValue
            let changingActive = obj["active"] != nil
            let ts = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                // Serialize all account status changes, including competing last-admin removals.
                struct A: Decodable { let id: Blob }
                let accounts = try await tx.raw("SELECT id FROM accounts ORDER BY id FOR UPDATE").all(decoding: A.self)
                let p = PermissionService(sql: tx)
                try await p.authorize(account: me, "identity.manage", on: .system)
                guard accounts.contains(where: { DB.uuid($0.id.data) == target }) else { throw Abort(.notFound) }
                if changingActive && !value {
                    var admins = Set<UUID>()
                    for a in accounts {
                        if let id = DB.uuid(a.id.data), try await p.can(account: id, "system.manage", on: .system) {
                            if id == target { admins.insert(id) }
                            else if try await p.can(account: id, "identity.manage", on: .system),
                                    try await tx.raw("SELECT COUNT(*) AS c FROM passkeys WHERE account_id = \(bind: DB.bin(id))").first(decoding: FormAdmin.CountRow.self)?.c ?? 0 > 0 { admins.insert(id) }
                        }
                    }
                    if admins.contains(target), admins.subtracting([target]).isEmpty { throw VersionConflict(kind: "des letzten Administrators") }
                    struct C: Decodable { let id: Blob }
                    for c in try await tx.raw("SELECT id FROM customers ORDER BY id FOR UPDATE").all(decoding: C.self) {
                        if let id = DB.uuid(c.id.data) {
                            let capable = try await KeyManagementRoutes.capableIdentities(tx, tenant: id)
                            if capable.contains(target), capable.subtracting([target]).isEmpty { throw VersionConflict(kind: "der letzten handlungsfähigen Schlüsselidentität") }
                        }
                    }
                }
                if changingActive {
                    try await tx.raw("UPDATE accounts SET active = \(bind: value), rights_version = rights_version + 1 WHERE id = \(bind: DB.bin(target))").run()
                    if !value {
                        try await tx.raw("INSERT IGNORE INTO key_rotation_requests (customer_id) SELECT DISTINCT customer_id FROM data_key_access WHERE account_id = \(bind: DB.bin(target))").run()
                        try await tx.raw("UPDATE sessions SET state = 'revoked', revoked_at = \(bind: ts) WHERE account_id = \(bind: DB.bin(target)) AND revoked_at IS NULL").run() }
                } else {
                    try await tx.raw("UPDATE accounts SET mcp_allowed = \(bind: value), rights_version = rights_version + 1 WHERE id = \(bind: DB.bin(target))").run()
                }
                if !value {
                    try await tx.raw("UPDATE mcp_tokens SET revoked_at = \(bind: ts) WHERE account_id = \(bind: DB.bin(target)) AND revoked_at IS NULL").run()
                    try await tx.raw("UPDATE oauth_grants SET revoked_at = \(bind: ts) WHERE account_id = \(bind: DB.bin(target)) AND revoked_at IS NULL").run()
                }
                try await MailRoutes.audit(tx, actor: me, action: changingActive ? (value ? "account.unlock" : "account.lock") : (value ? "account.mcp.allow" : "account.mcp.deny"), subject: target, at: ts)
            }
            return Response(status: .noContent)
        }

        root.post("accounts") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let me = s.accountID!
            try await perms.authorize(account: me, "identity.manage", on: .system)
            try await guardian.requireFreshAuthentication(s, now: now())
            let obj = try MailRoutes.jsonObject(req, allowed: ["username", "password"])
            guard let username = obj["username"] as? String, username.range(of: "^[a-z0-9][a-z0-9._@-]{2,119}$", options: .regularExpression) != nil,
                  obj["password"] == nil || obj["password"] is String
            else { throw ValidationFailed(detail: "username (a-z0-9._@-, 3-120 Zeichen) und password (12-256 Zeichen)") }
            let password = obj["password"] as? String ?? ""
            guard password.isEmpty || (12...256).contains(password.count), !guardian.config.secondFactorRequired || !password.isEmpty else {
                throw ValidationFailed(detail: "Passwort erforderlich: 12–256 Zeichen")
            }
            let hash = password.isEmpty ? "" : try Argon2id.hash(password)
            let id = UUID(), ts = DB.time(now())
            do {
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    try await tx.raw("""
                        INSERT INTO accounts (id, username, password_hash, active, mcp_allowed, rights_version, created_at)
                        VALUES (\(bind: DB.bin(id)), \(bind: username), \(bind: hash), 1, 0, 1, \(bind: ts))
                        """).run()
                    try await MailRoutes.audit(tx, actor: me, action: "account.create", subject: id, at: ts)
                }
            } catch { if DB.isDuplicateKey(error) { throw Abort(.conflict) }; throw error }
            let token = try await EnrollmentService(db: db, now: now).issue(account: id, purpose: .firstPasskey, createdBy: me)
            let res = try FormAdmin.json(.created, ["id": id.uuidString.lowercased(), "username": username, "setupLink": "\(origin)/setup#\(token)"])
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }

        // Self-service password setup requires a fresh passkey login; changing it ends other sessions.
        root.put("me", "password") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            try await guardian.requireFreshAuthentication(s, now: now())
            let obj = try MailRoutes.jsonObject(req, allowed: ["password"])
            guard let password = obj["password"] as? String, (12...256).contains(password.count) else {
                throw ValidationFailed(detail: "Passwort: 12–256 Zeichen")
            }
            let hash = try Argon2id.hash(password)
            let ts = DB.time(now()), me = s.accountID!
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await tx.raw("UPDATE accounts SET password_hash = \(bind: hash) WHERE id = \(bind: DB.bin(me))").run()
                try await tx.raw("UPDATE sessions SET state = 'revoked', revoked_at = \(bind: ts) WHERE account_id = \(bind: DB.bin(me)) AND id <> \(bind: DB.bin(s.id)) AND revoked_at IS NULL").run()
                try await tx.raw("UPDATE mcp_tokens SET revoked_at = \(bind: ts) WHERE account_id = \(bind: DB.bin(me)) AND revoked_at IS NULL").run()
                try await tx.raw("UPDATE oauth_grants SET revoked_at = \(bind: ts) WHERE account_id = \(bind: DB.bin(me)) AND revoked_at IS NULL").run()
                try await MailRoutes.audit(tx, actor: me, action: "account.password", subject: me, at: ts)
            }
            return Response(status: .noContent)
        }

        tenants.get("members") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId")
            try await perms.authorize(account: s.accountID!, "identity.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            struct R: Decodable { let id: Blob; let username: String }
            let rows = try await sql.raw("SELECT id, username FROM accounts WHERE active = 1 ORDER BY username LIMIT 2000").all(decoding: R.self)
            var items: [[String: Any]] = []
            for r in rows {
                guard let id = DB.uuid(r.id.data) else { continue }
                let g = try await perms.grants(account: id)
                guard g.contains(where: { $0.scope.covers(.customer(tenant)) }) else { continue }
                let direct = g.filter { $0.scope == .customer(tenant) }.map(\.permission)
                let inherited = g.filter { $0.scope != .customer(tenant) && $0.scope.covers(.customer(tenant)) }.map(\.permission)
                items.append(["accountId": id.uuidString.lowercased(), "username": r.username, "permissions": Array(Set(direct)).sorted(), "inherited": Array(Set(inherited)).sorted()])
            }
            let res = try MailRoutes.anyJSON(["items": items, "assignable": assignable.sorted()])
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }

        tenants.put("members", ":accountId", "permissions") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), target = try FormAdmin.uuidParam(req, "accountId")
            let me = s.accountID!
            try await perms.authorize(account: me, "identity.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let obj = try MailRoutes.jsonObject(req, allowed: ["permissions"])
            guard let list = obj["permissions"] as? [String], list.count <= 64, Set(list).isSubset(of: assignable) else { throw ValidationFailed(detail: "permissions: Liste bekannter Rechte (ohne system.manage)") }
            let wanted = Set(list)
            if target == me { throw Abort(.forbidden) }   // nobody changes their own rights
            let ts = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard try await KeyRoutes.customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                let p = PermissionService(sql: tx)
                try await p.authorize(account: me, "identity.manage", on: .customer(tenant))
                guard try await tx.raw("SELECT COUNT(*) AS c FROM accounts WHERE id = \(bind: DB.bin(target)) AND active = 1 FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c == 1
                else { throw ValidationFailed(detail: "Konto unbekannt oder inaktiv") }
                // Taking a stranger into the customer is a system-level act (review M1); a customer administrator only edits existing members.
                let isMember = try await p.grants(account: target).contains { $0.scope.covers(.customer(tenant)) }
                if !isMember, !(try await p.can(account: me, "identity.manage", on: .system)) { throw Abort(.forbidden) }
                struct D: Decodable { let id: Blob; let permission: String }
                let current = try await tx.raw("""
                    SELECT id, permission FROM permission_assignments WHERE account_id = \(bind: DB.bin(target)) AND scope_kind = 'customer' AND customer_id = \(bind: DB.bin(tenant))
                      AND form_id IS NULL AND group_id IS NULL AND revoked_at IS NULL FOR UPDATE
                    """).all(decoding: D.self)
                let have = Set(current.map(\.permission))
                let changed = wanted.symmetricDifference(have)
                // only rights the actor holds for this customer may be added or removed
                let mine = Set(try await p.grants(account: me).filter { $0.scope.covers(.customer(tenant)) }.map(\.permission))
                guard changed.isSubset(of: mine) else { throw Abort(.forbidden) }
                if (have.contains("key.manage") && !wanted.contains("key.manage")) || (have.contains("content.decrypt") && !wanted.contains("content.decrypt")) {
                    let capable = try await KeyManagementRoutes.capableIdentities(tx, tenant: tenant)
                    if capable.contains(target), capable.subtracting([target]).isEmpty { throw VersionConflict(kind: "der letzten handlungsfähigen Schlüsselidentität") }
                }
                if have.contains("content.decrypt"), !wanted.contains("content.decrypt") {
                    try await tx.raw("DELETE FROM data_key_access WHERE customer_id = \(bind: DB.bin(tenant)) AND account_id = \(bind: DB.bin(target))").run()
                    try await tx.raw("INSERT IGNORE INTO key_rotation_requests (customer_id) VALUES (\(bind: DB.bin(tenant)))").run()
                }
                for c in current where !wanted.contains(c.permission) {
                    try await tx.raw("UPDATE permission_assignments SET revoked_at = \(bind: ts) WHERE id = \(bind: c.id)").run()
                }
                for perm in wanted.subtracting(have).sorted() {
                    try await tx.raw("""
                        INSERT INTO permission_assignments (id, account_id, permission, scope_kind, customer_id, revision, granted_by, granted_at)
                        VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(target)), \(bind: perm), 'customer', \(bind: DB.bin(tenant)), 1, \(bind: DB.bin(me)), \(bind: ts))
                        """).run()
                }
                if !changed.isEmpty {
                    try await tx.raw("UPDATE accounts SET rights_version = rights_version + 1 WHERE id = \(bind: DB.bin(target))").run()
                    try await ReleaseRoutes.audit(tx, tenant: tenant, form: nil, actor: me, action: "account.permissions.set", subject: target, at: ts, category: "account").run()
                }
            }
            return Response(status: .noContent)
        }

        root.get("me", "passkeys") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            struct R: Decodable { let credential_id: Blob; let label: String; let created_at: Date; let last_used_at: Date?; let wrapped: Int }
            let rows = try await sql.raw("""
                SELECT p.credential_id AS credential_id, p.label AS label, p.created_at AS created_at, p.last_used_at AS last_used_at,
                  EXISTS(SELECT 1 FROM account_key_wraps w WHERE w.credential_id = p.credential_id) AS wrapped
                FROM passkeys p WHERE p.account_id = \(bind: DB.bin(s.accountID!)) ORDER BY p.created_at, p.credential_id
                """).all(decoding: R.self)
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try MailRoutes.anyJSON(["items": rows.map { r -> [String: Any] in
                var o: [String: Any] = ["credentialId": r.credential_id.data.base64URLString, "label": r.label, "createdAt": iso.string(from: r.created_at), "unlocksKeys": r.wrapped == 1]
                if let l = r.last_used_at { o["lastUsedAt"] = iso.string(from: l) }
                return o
            }])
        }

        root.delete("me", "passkeys", ":credentialId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            guard let raw = req.parameters.get("credentialId"), let cred = Data(base64URLString: raw), (1...255).contains(cred.count) else { throw Abort(.badRequest) }
            let me = s.accountID!
            try await guardian.requireFreshAuthentication(s, now: now())
            let ts = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                struct C: Decodable { let credential_id: Blob }
                let mine = try await tx.raw("SELECT credential_id FROM passkeys WHERE account_id = \(bind: DB.bin(me)) FOR UPDATE").all(decoding: C.self)
                guard mine.contains(where: { $0.credential_id.data == cred }) else { throw Abort(.notFound) }
                guard mine.count > 1 else { throw ValidationFailed(detail: "Der letzte Passkey kann nicht entfernt werden") }
                // The last key-unlocking passkey of an account that holds data access stays (otherwise only the recovery code is left; review M2).
                struct W: Decodable { let credential_id: Blob }
                let wraps = try await tx.raw("SELECT credential_id FROM account_key_wraps WHERE account_id = \(bind: DB.bin(me)) FOR UPDATE").all(decoding: W.self)
                if wraps.count == 1, wraps[0].credential_id.data == cred,
                   try await tx.raw("SELECT COUNT(*) AS c FROM data_key_access WHERE account_id = \(bind: DB.bin(me))").first(decoding: FormAdmin.CountRow.self)?.c ?? 0 > 0 {
                    throw ValidationFailed(detail: "Der letzte Passkey, der Ihre Datenschlüssel entsperrt, kann nicht entfernt werden")
                }
                try await tx.raw("DELETE FROM account_key_wraps WHERE account_id = \(bind: DB.bin(me)) AND credential_id = \(bind: Blob(cred))").run()
                try await tx.raw("DELETE FROM passkeys WHERE account_id = \(bind: DB.bin(me)) AND credential_id = \(bind: Blob(cred))").run()
                // Sessions are not tied to a credential: every other session of the account ends (review M2); the current one continues.
                try await tx.raw("UPDATE sessions SET state = 'revoked', revoked_at = \(bind: ts) WHERE account_id = \(bind: DB.bin(me)) AND id <> \(bind: DB.bin(s.id)) AND revoked_at IS NULL").run()
                try await MailRoutes.audit(tx, actor: me, action: "passkey.remove", subject: me, at: ts)
            }
            return Response(status: .noContent)
        }
    }
}
