// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Server side of the browser key management (contracts/crypto/schluessel.md, VORGESCHLAGEN): the server stores and hands out ONLY
/// public keys and wrapped/sealed blobs; it can neither open an account wrap nor a data access nor a recovery wrap.
/// - `GET /me/key-bundle`, `PUT /me/account-key`, `POST /me/account-key/wraps`
/// - `PUT /tenants/{t}/key-access/{account}` (grant the customer data key to another account), `GET /tenants/{t}/key-recovery`
enum KeyManagementRoutes {
    struct WrapIn: Decodable { let credentialId: String; let prfSalt: String; let iv: String; let wrap: String }
    private struct Raw { let credential: Data; let salt: Data; let iv: Data; let wrap: Data }

    private static func raw(_ w: WrapIn) throws -> Raw {
        guard let c = Data(base64URLString: w.credentialId), (1...255).contains(c.count), let s = Data(base64URLString: w.prfSalt), s.count == 32,
              let i = Data(base64URLString: w.iv), i.count == 12, let k = Data(base64URLString: w.wrap), k.count == 48
        else { throw ValidationFailed(detail: "wrap: credentialId (1-255 Byte), prfSalt 32, iv 12, wrap 48 Byte, base64url") }
        return Raw(credential: c, salt: s, iv: i, wrap: k)
    }

    static func register(root: RoutesBuilder, tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        let rpID = guardian.config.relyingParty.rpID
        AccountRecoveryRoutes.register(root, guardian: guardian, db: db, now: now)

        root.get("me", "key-bundle") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let account = s.accountID!
            struct K: Decodable { let public_key: Blob }
            struct W: Decodable { let credential_id: Blob; let prf_salt: Blob; let iv: Blob; let wrapped_key: Blob }
            struct A: Decodable { let customer_id: Blob; let kid: String; let enc: Blob; let sealed_key: Blob }
            let key = try await sql.raw("SELECT public_key FROM account_keys WHERE account_id = \(bind: DB.bin(account))").first(decoding: K.self)
            let wraps = try await sql.raw("SELECT credential_id, prf_salt, iv, wrapped_key FROM account_key_wraps WHERE account_id = \(bind: DB.bin(account)) ORDER BY created_at, credential_id").all(decoding: W.self)
            // access rows only while the account still holds a right in that customer (live check, like everything else)
            let grants = try await perms.grants(account: account)
            let rows = try await sql.raw("SELECT customer_id, kid, enc, sealed_key FROM data_key_access WHERE account_id = \(bind: DB.bin(account))").all(decoding: A.self)
            let access: [[String: Any]] = rows.compactMap { r in
                guard let c = DB.uuid(r.customer_id.data), grants.contains(where: { $0.scope.covers(.customer(c)) }) else { return nil }
                return ["tenantId": c.uuidString.lowercased(), "kid": r.kid, "enc": r.enc.data.base64URLString, "sealed": r.sealed_key.data.base64URLString]
            }
            let res = try MailRoutes.anyJSON([
                "rpId": rpID,
                "accountPublicKey": key.map { $0.public_key.data.base64URLString } as Any? ?? NSNull(),
                "wraps": wraps.map { ["credentialId": $0.credential_id.data.base64URLString, "prfSalt": $0.prf_salt.data.base64URLString, "iv": $0.iv.data.base64URLString, "wrap": $0.wrapped_key.data.base64URLString] },
                "access": access,
                "recovery": try await AccountRecoveryRoutes.read(sql, account: account) as Any? ?? NSNull(),
            ] as [String: Any])
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }

        root.put("me", "account-key") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            struct B: Decodable { let publicKey: String; let wrap: WrapIn }
            let b: B = try FormAdmin.decodeStrict(req, allowed: ["publicKey", "wrap"])
            guard let pk = Data(base64URLString: b.publicKey), KeyRoutes.usableForKeyAgreement(pk), pk.count == 32 else { throw ValidationFailed(detail: "publicKey: 32 Byte X25519, base64url") }
            let w = try raw(b.wrap)
            let account = s.accountID!
            try await guardian.requireFreshAuthentication(s, now: now())
            let t = DB.time(now())
            do {
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    // Replacement can remove accesses across customers. Lock customers in one order before
                    // any consistent read, matching rotation/revocation and avoiding an old RR snapshot.
                    _ = try await tx.raw("SELECT id FROM customers ORDER BY id FOR UPDATE").all(decoding: FormAdmin.CountRowID.self)
                    // the credential must be one of THIS account's passkeys
                    guard try await tx.raw("SELECT COUNT(*) AS c FROM passkeys WHERE account_id = \(bind: DB.bin(account)) AND credential_id = \(bind: Blob(w.credential))").first(decoding: FormAdmin.CountRow.self)?.c == 1
                    else { throw ValidationFailed(detail: "credentialId gehört nicht zu einem Passkey dieses Kontos") }
                    // Lost every passkey wrap (so the account key can never be opened again)? Then it is replaced; its data accesses were sealed to
                    // the old key and are useless now, so they go with it (the data key is recovered with the recovery code and re-granted).
                    if try await tx.raw("SELECT COUNT(*) AS c FROM account_keys WHERE account_id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c == 1 {
                        guard try await tx.raw("SELECT COUNT(*) AS c FROM account_key_wraps WHERE account_id = \(bind: DB.bin(account))").first(decoding: FormAdmin.CountRow.self)?.c == 0
                        else { throw Abort(.conflict) }
                        guard try await tx.raw("SELECT COUNT(*) AS c FROM account_key_recovery WHERE account_id = \(bind: DB.bin(account))").first(decoding: FormAdmin.CountRow.self)?.c == 0 else { throw Abort(.conflict) }
                        // Dropping this account's accesses must not remove the last capable identity of any customer.
                        struct T: Decodable { let customer_id: Blob }
                        for row in try await tx.raw("SELECT DISTINCT customer_id FROM data_key_access WHERE account_id = \(bind: DB.bin(account))").all(decoding: T.self) {
                            guard let c = DB.uuid(row.customer_id.data) else { continue }
                            let capable = try await capableIdentities(tx, tenant: c)
                            if capable.contains(account), capable.subtracting([account]).isEmpty { throw VersionConflict(kind: "der letzten handlungsfähigen Schlüsselidentität") }
                            try await tx.raw("INSERT IGNORE INTO key_rotation_requests (customer_id) VALUES (\(bind: DB.bin(c)))").run()
                        }
                        try await tx.raw("DELETE FROM data_key_access WHERE account_id = \(bind: DB.bin(account))").run()
                        try await tx.raw("UPDATE account_keys SET public_key = \(bind: Blob(pk)), created_at = \(bind: t) WHERE account_id = \(bind: DB.bin(account))").run()
                        try await MailRoutes.audit(tx, actor: account, action: "key.account.replace", subject: account, at: t)
                    } else {
                        try await tx.raw("INSERT INTO account_keys (account_id, public_key, created_at) VALUES (\(bind: DB.bin(account)), \(bind: Blob(pk)), \(bind: t))").run()
                        try await MailRoutes.audit(tx, actor: account, action: "key.account.create", subject: account, at: t)
                    }
                    try await insertWrap(tx, account: account, w, at: t)
                }
            } catch { if DB.isDuplicateKey(error) { throw Abort(.conflict) }; throw error }
            return try FormAdmin.json(.created, ["status": "created"])
        }

        root.post("me", "account-key", "wraps") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let b: WrapIn = try FormAdmin.decodeStrict(req, allowed: ["credentialId", "prfSalt", "iv", "wrap"])
            let w = try raw(b)
            let account = s.accountID!
            try await guardian.requireFreshAuthentication(s, now: now())
            let t = DB.time(now())
            do {
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    guard try await tx.raw("SELECT COUNT(*) AS c FROM account_keys WHERE account_id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c == 1
                    else { throw ValidationFailed(detail: "Es gibt noch keinen Kontoschlüssel") }
                    guard try await tx.raw("SELECT COUNT(*) AS c FROM passkeys WHERE account_id = \(bind: DB.bin(account)) AND credential_id = \(bind: Blob(w.credential))").first(decoding: FormAdmin.CountRow.self)?.c == 1
                    else { throw ValidationFailed(detail: "credentialId gehört nicht zu einem Passkey dieses Kontos") }
                    try await insertWrap(tx, account: account, w, at: t)
                    try await MailRoutes.audit(tx, actor: account, action: "key.account.wrap-add", subject: account, at: t)
                }
            } catch { if DB.isDuplicateKey(error) { throw Abort(.conflict) }; throw error }   // a credential is never overwritten
            return try FormAdmin.json(.created, ["status": "created"])
        }

        // Grant the customer data key (sealed in the browser to the target's account public key) to another account of this customer.
        tenants.put("key-access", ":accountId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), target = try FormAdmin.uuidParam(req, "accountId")
            struct B: Decodable { let kid: String; let enc: String; let sealed: String }
            let b: B = try FormAdmin.decodeStrict(req, allowed: ["kid", "enc", "sealed"])
            guard b.kid.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil, let enc = Data(base64URLString: b.enc), enc.count == 32,
                  let sealed = Data(base64URLString: b.sealed), sealed.count == 48 else { throw ValidationFailed(detail: "kid (16 Hex), enc 32 Byte, sealed 48 Byte, base64url") }
            let account = s.accountID!
            try await perms.authorize(account: account, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let t = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard try await KeyRoutes.customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                try await PermissionService(sql: tx).authorize(account: account, "key.manage", on: .customer(tenant))
                guard try await tx.raw("SELECT COUNT(*) AS c FROM customer_key_generations WHERE customer_id = \(bind: DB.bin(tenant)) AND kid = \(bind: b.kid) AND state IN ('active', 'retiring') FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c == 1
                else { throw ValidationFailed(detail: "kid ist keine aktive oder auslaufende Schlüsselgeneration des Kunden") }
                // Granting to someone else needs the granter's own access (key.manage alone does not confer it). Granting to oneself is the
                // recovery self-repair (schluessel.md): the key came from the recovery code, the own row may be replaced.
                let selfRepair = target == account
                if !selfRepair {
                    guard try await tx.raw("SELECT COUNT(*) AS c FROM data_key_access WHERE customer_id = \(bind: DB.bin(tenant)) AND kid = \(bind: b.kid) AND account_id = \(bind: DB.bin(account))").first(decoding: FormAdmin.CountRow.self)?.c == 1
                    else { throw Abort(.forbidden) }
                }
                // the target must be an active account with an account key and a right inside this customer
                guard try await tx.raw("SELECT COUNT(*) AS c FROM accounts a JOIN account_keys k ON k.account_id = a.id WHERE a.id = \(bind: DB.bin(target)) AND a.active = 1").first(decoding: FormAdmin.CountRow.self)?.c == 1
                else { throw ValidationFailed(detail: "Zielkonto ist nicht aktiv oder hat keinen Kontoschlüssel") }
                guard try await PermissionService(sql: tx).grants(account: target).contains(where: { $0.scope.covers(.customer(tenant)) }) else { throw ValidationFailed(detail: "Zielkonto hat keine Rechte in diesem Kunden") }
                let existing = try await tx.raw("SELECT COUNT(*) AS c FROM data_key_access WHERE customer_id = \(bind: DB.bin(tenant)) AND kid = \(bind: b.kid) AND account_id = \(bind: DB.bin(target)) FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c ?? 0
                if existing > 0 {
                    guard selfRepair else { throw Abort(.conflict) }   // foreign access is never silently replaced
                    try await tx.raw("DELETE FROM data_key_access WHERE customer_id = \(bind: DB.bin(tenant)) AND kid = \(bind: b.kid) AND account_id = \(bind: DB.bin(target))").run()
                }
                try await tx.raw("""
                    INSERT INTO data_key_access (customer_id, kid, account_id, enc, sealed_key, granted_by, granted_at)
                    VALUES (\(bind: DB.bin(tenant)), \(bind: b.kid), \(bind: DB.bin(target)), \(bind: Blob(enc)), \(bind: Blob(sealed)), \(bind: DB.bin(account)), \(bind: t))
                    """).run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: nil, actor: account, action: selfRepair ? "key.access.repair" : "key.access.grant", subject: target, at: t, category: "key").run()
            }
            return try FormAdmin.json(.created, ["status": "created"])
        }

        // Accounts of this customer that could be given access: they have an account key and a right inside the customer. Needs key.manage.
        tenants.get("key-candidates") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId")
            try await perms.authorize(account: s.accountID!, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            struct R: Decodable { let id: Blob; let username: String; let public_key: Blob; let has_access: Int }
            let rows = try await sql.raw("""
                SELECT a.id AS id, a.username AS username, k.public_key AS public_key,
                  EXISTS(SELECT 1 FROM data_key_access d JOIN customer_key_generations g ON g.customer_id = d.customer_id AND g.kid = d.kid AND g.state = 'active'
                         WHERE d.customer_id = \(bind: DB.bin(tenant)) AND d.account_id = a.id) AS has_access
                FROM accounts a JOIN account_keys k ON k.account_id = a.id WHERE a.active = 1 ORDER BY a.username LIMIT 2001
                """).all(decoding: R.self)
            guard rows.count <= 2000 else { throw Abort(.conflict, reason: "Empfängerliste ist zu groß") }
            var items: [[String: Any]] = []
            for r in rows {
                guard let id = DB.uuid(r.id.data), try await perms.grants(account: id).contains(where: { $0.scope.covers(.customer(tenant)) }) else { continue }
                items.append(["accountId": id.uuidString.lowercased(), "username": r.username, "publicKey": r.public_key.data.base64URLString, "hasAccess": r.has_access == 1, "isSelf": id == s.accountID!])
            }
            let res = try MailRoutes.anyJSON(["items": items])
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }

        // Withdraw an account's access. Keys already held cannot be recalled; rotating the data key is what makes a withdrawal final.
        tenants.delete("key-access", ":accountId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), target = try FormAdmin.uuidParam(req, "accountId")
            let account = s.accountID!
            try await perms.authorize(account: account, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let t = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard try await KeyRoutes.customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                try await PermissionService(sql: tx).authorize(account: account, "key.manage", on: .customer(tenant))
                guard try await tx.raw("SELECT COUNT(*) AS c FROM data_key_access WHERE customer_id = \(bind: DB.bin(tenant)) AND account_id = \(bind: DB.bin(target)) FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c ?? 0 > 0
                else { throw Abort(.notFound) }
                let capable = try await capableIdentities(tx, tenant: tenant)
                if capable.contains(target), capable.subtracting([target]).isEmpty { throw VersionConflict(kind: "der letzten handlungsfähigen Schlüsselidentität") }
                for g in try await RotationRoutes.generations(tx, tenant) {
                    try await RotationRoutes.requireAccess(tx, tenant: tenant, account: account, kid: g.kid)
                }
                try await tx.raw("DELETE FROM data_key_access WHERE customer_id = \(bind: DB.bin(tenant)) AND account_id = \(bind: DB.bin(target))").run()
                try await tx.raw("INSERT IGNORE INTO key_rotation_requests (customer_id) VALUES (\(bind: DB.bin(tenant)))").run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: nil, actor: account, action: "key.access.revoke", subject: target, at: t, category: "key").run()
            }
            return Response(status: .noContent)
        }

        // The recovery wrap of the requested live generation (defaults to active); fetching it is audited even if the local opening fails.
        tenants.get("key-recovery") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId")
            let account = s.accountID!
            try await perms.authorize(account: account, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let requestedKid = req.query[String.self, at: "kid"]
            if let requestedKid, requestedKid.range(of: "^[0-9a-f]{16}$", options: .regularExpression) == nil { throw ValidationFailed(detail: "kid muss 16 Hexzeichen enthalten") }
            struct R: Decodable { let kid: String; let salt: Blob; let iterations: UInt32; let iv: Blob; let wrapped_key: Blob }
            guard let r = try await sql.raw("""
                SELECT r.kid AS kid, r.salt AS salt, r.iterations AS iterations, r.iv AS iv, r.wrapped_key AS wrapped_key FROM data_key_recovery r
                JOIN customer_key_generations g ON g.customer_id = r.customer_id AND g.kid = r.kid AND g.state IN ('active', 'retiring')
                WHERE r.customer_id = \(bind: DB.bin(tenant)) AND ((\(bind: requestedKid) IS NULL AND g.state = 'active') OR g.kid = \(bind: requestedKid))
                """).first(decoding: R.self) else { throw Abort(.notFound) }
            try await ReleaseRoutes.audit(sql, tenant: tenant, form: nil, actor: account, action: "key.recovery.read", subject: tenant, at: DB.time(now()), category: "key").run()
            let res = try MailRoutes.anyJSON(["keyId": r.kid, "salt": r.salt.data.base64URLString, "iterations": Int(r.iterations), "iv": r.iv.data.base64URLString, "wrap": r.wrapped_key.data.base64URLString] as [String: Any])
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
    }

    /// Accounts that can still act on the customer's key: access rows for every active and retiring generation AND a live `key.manage` for the customer.
    /// The last one must never disappear (schluessel.md "letzte handlungsfaehige Identitaet").
    static func capableIdentities(_ tx: SQLDatabase, tenant: UUID) async throws -> Set<UUID> {
        struct R: Decodable { let account_id: Blob }
        let rows = try await tx.raw("""
            SELECT d.account_id AS account_id FROM data_key_access d
            JOIN customer_key_generations g ON g.customer_id = d.customer_id AND g.kid = d.kid
            WHERE d.customer_id = \(bind: DB.bin(tenant))
            GROUP BY d.account_id
            HAVING COUNT(DISTINCT d.kid) = (SELECT COUNT(*) FROM customer_key_generations WHERE customer_id = \(bind: DB.bin(tenant)))
            """).all(decoding: R.self)
        var out = Set<UUID>()
        let p = PermissionService(sql: tx)
        for r in rows {
            guard let id = DB.uuid(r.account_id.data) else { continue }
            if try await p.can(account: id, "key.manage", on: .customer(tenant)) { out.insert(id) }
        }
        return out
    }

    private static func insertWrap(_ tx: SQLDatabase, account: UUID, _ w: Raw, at t: String) async throws {
        try await tx.raw("""
            INSERT INTO account_key_wraps (credential_id, account_id, prf_salt, iv, wrapped_key, created_at)
            VALUES (\(bind: Blob(w.credential)), \(bind: DB.bin(account)), \(bind: Blob(w.salt)), \(bind: Blob(w.iv)), \(bind: Blob(w.wrap)), \(bind: t))
            """).run()
    }
}
