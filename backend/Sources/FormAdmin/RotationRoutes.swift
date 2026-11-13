// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormCore
import FormCrypto
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Opaque key envelopes only. Customer lock serializes generation changes, ingress, hold and rewrap.
enum RotationRoutes {
    struct Generation: Decodable { let kid: String; let public_key: Blob; let state: String; let generation_no: Int }
    struct Access: Decodable { let accountId: UUID; let enc: String; let sealed: String; let expectedPublicKey: String? }
    struct Recovery: Decodable { let salt: String; let iterations: Int; let iv: String; let wrap: String }
    struct Begin: Decodable { let publicKey: String; let access: [Access]; let recovery: Recovery; let automatic: Bool? }
    struct Replacement: Decodable { let expectedRevision: UInt64; let expectedSha256: String; let package: String }
    struct Object: Decodable {
        let id: Blob; let form_id: Blob; let kid: String; let revision: UInt64; let ciphertext_sha256: Blob
        let payload_sha256: Blob; let ciphertext: Blob?; let backend: String; let wrap_kind: String; let held: Int?
    }
    static func audit(_ tx: SQLDatabase, tenant: UUID, form: UUID?, actor: UUID, action: String, subject: UUID, at: String, source: String, target: String) async throws {
        let details = String(decoding: try JSONSerialization.data(withJSONObject: ["sourceKid": source, "targetKid": target]), as: UTF8.self)
        try await tx.raw("""
            INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: form.map(DB.bin)), \(bind: DB.bin(actor)), 'human', 'key', \(bind: action), \(bind: DB.bin(subject)), \(bind: at), \(bind: details))
            """).run()
    }
    static func generations(_ tx: SQLDatabase, _ tenant: UUID) async throws -> [Generation] {
        try await tx.raw("SELECT kid, public_key, state, generation_no FROM customer_key_generations WHERE customer_id = \(bind: DB.bin(tenant)) FOR UPDATE").all(decoding: Generation.self)
    }
    static func requireAccess(_ tx: SQLDatabase, tenant: UUID, account: UUID, kid: String) async throws {
        guard try await tx.raw("SELECT COUNT(*) AS c FROM data_key_access WHERE customer_id = \(bind: DB.bin(tenant)) AND account_id = \(bind: DB.bin(account)) AND kid = \(bind: kid)").first(decoding: FormAdmin.CountRow.self)?.c == 1 else { throw Abort(.forbidden) }
    }
    static func isHeld(_ tx: SQLDatabase, tenant: UUID, id: Blob) async throws -> Bool {
        // Walk parents as well: recursive metadata may have no submission_id of its own.
        try await tx.raw("""
            WITH RECURSIVE parents AS (
              SELECT id, submission_id FROM stored_objects WHERE customer_id = \(bind: DB.bin(tenant)) AND id = \(bind: id)
              UNION DISTINCT
              SELECT o.id, o.submission_id FROM stored_objects o JOIN parents p ON o.metadata_object_id = p.id
                WHERE o.customer_id = \(bind: DB.bin(tenant))
            ) SELECT COUNT(*) AS c FROM parents p JOIN submissions s ON s.id = p.submission_id
              WHERE s.customer_id = \(bind: DB.bin(tenant)) AND s.removable = 0
            """).first(decoding: FormAdmin.CountRow.self)?.c ?? 0 > 0
    }
    static func bytes(_ s: String, _ count: Int) throws -> Data {
        guard let d = Data(base64URLString: s), d.count == count else { throw ValidationFailed(detail: "Ungültige Schlüsselhülle") }; return d
    }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func replacement(_ row: Object, _ b: Replacement, target: String, hold: Bool = false) throws -> PackageV2 {
        guard row.revision == b.expectedRevision, hex(row.ciphertext_sha256.data) == b.expectedSha256 else { throw Abort(.conflict, reason: "Objekt wurde geändert") }
        guard row.backend == "db", let wire = row.ciphertext, let text = String(data: wire.data, encoding: .utf8) else { throw Abort(.conflict, reason: "Externer Speicher benötigt bestätigten Rewrap") }
        guard let old = try? PackageV2(text), let new = try? PackageV2(b.package), new.kid == target,
              old.kid == row.kid, old.wrap == row.wrap_kind,
              old.iv == new.iv, old.ciphertext == new.ciphertext, old.tag == new.tag,
              Data(SHA256.hash(data: old.iv + old.ciphertext + old.tag)) == row.payload_sha256.data,
              Data(SHA256.hash(data: wire.data)) == row.ciphertext_sha256.data,
              !(old.wrap == "sym" && new.wrap != "sym"), !hold || new.wrap == "sym"
        else { throw ValidationFailed(detail: "Rewrap darf nur die Schlüsselhülle ändern") }
        return new
    }
    static func store(_ tx: SQLDatabase, tenant: UUID, row: Object, package: PackageV2) async throws {
        let wire = Data(package.wire.utf8)
        try await tx.raw("""
            UPDATE stored_objects SET ciphertext = \(bind: Blob(wire)), kid = \(bind: package.kid), wrap_kind = \(bind: package.wrap),
              ciphertext_sha256 = \(bind: Blob(Data(SHA256.hash(data: wire)))), byte_count = \(bind: wire.count), revision = revision + 1
            WHERE customer_id = \(bind: DB.bin(tenant)) AND id = \(bind: row.id) AND revision = \(bind: row.revision) AND ciphertext_sha256 = \(bind: row.ciphertext_sha256)
            """).run()
        // Row is held FOR UPDATE; revision/digest predicates also enforce the CAS at the write boundary.
    }
    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        tenants.get("key-rotation") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId")
            try await perms.authorize(account: s.accountID!, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            let rows = try await sql.raw("SELECT kid, public_key, state, generation_no FROM customer_key_generations WHERE customer_id = \(bind: DB.bin(tenant))").all(decoding: Generation.self)
            func item(_ state: String) -> Any { rows.first { $0.state == state }.map { ["kid": $0.kid, "publicKey": $0.public_key.data.base64URLString] } as Any? ?? NSNull() }
            let requested = try await sql.raw("SELECT COUNT(*) AS c FROM key_rotation_requests WHERE customer_id = \(bind: DB.bin(tenant))").first(decoding: FormAdmin.CountRow.self)?.c == 1
            let res = try MailRoutes.anyJSON(["active": item("active"), "retiring": item("retiring"), "requested": requested]); res.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return res
        }
        tenants.post("key-rotation") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), account = s.accountID!
            try await perms.authorize(account: account, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let b: Begin = try FormAdmin.decodeStrict(req, allowed: ["publicKey", "access", "recovery", "automatic"])
            let pk = try bytes(b.publicKey, 32), kid = try keyID(pk)
            guard KeyRoutes.usableForKeyAgreement(pk), !b.access.isEmpty, b.access.count <= 2000,
                  Set(b.access.map(\.accountId)).count == b.access.count, b.access.contains(where: { $0.accountId == account }), b.recovery.iterations == 600000 else { throw ValidationFailed(detail: "Ungültige Rotationsvorbereitung") }
            let salt = try bytes(b.recovery.salt, 32), iv = try bytes(b.recovery.iv, 12), wrap = try bytes(b.recovery.wrap, 48)
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard try await KeyRoutes.customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                try await PermissionService(sql: tx).authorize(account: account, "key.manage", on: .customer(tenant))
                let gs = try await generations(tx, tenant)
                guard gs.count == 1, let old = gs.first, old.state == "active", old.kid != kid else { throw Abort(.conflict) }
                try await requireAccess(tx, tenant: tenant, account: account, kid: old.kid)
                // Migration is global in the current schema: fail closed while any unresolved import exists.
                guard try await tx.raw("SELECT COUNT(*) AS c FROM migration_runs WHERE state <> 'activated'").first(decoding: FormAdmin.CountRow.self)?.c == 0,
                      try await tx.raw("SELECT COUNT(*) AS c FROM migration_issues WHERE state <> 'resolved'").first(decoding: FormAdmin.CountRow.self)?.c == 0 else { throw Abort(.conflict, reason: "Migration ist nicht abgeschlossen") }
                if b.automatic == true {
                    struct Recipient: Decodable { let account_id: Blob }
                    let rows = try await tx.raw("SELECT d.account_id FROM data_key_access d JOIN accounts a ON a.id = d.account_id WHERE d.customer_id = \(bind: DB.bin(tenant)) AND d.kid = \(bind: old.kid) AND a.active = 1").all(decoding: Recipient.self)
                    var required = Set<UUID>()
                    for r in rows {
                        if let id = DB.uuid(r.account_id.data), try await PermissionService(sql: tx).grants(account: id).contains(where: { $0.scope.covers(.customer(tenant)) }) { required.insert(id) }
                    }
                    guard Set(b.access.map(\.accountId)) == required, b.access.allSatisfy({ $0.expectedPublicKey != nil }) else { throw Abort(.conflict) }
                }
                for a in b.access {
                    if let expected = a.expectedPublicKey {
                        struct K: Decodable { let public_key: Blob }
                        let key = try await tx.raw("SELECT public_key FROM account_keys WHERE account_id = \(bind: DB.bin(a.accountId)) FOR UPDATE").first(decoding: K.self)
                        guard key?.public_key.data.base64URLString == expected else { throw Abort(.conflict) }
                    }
                    guard try await PermissionService(sql: tx).grants(account: a.accountId).contains(where: { $0.scope.covers(.customer(tenant)) }) else { throw Abort(.conflict) }
                    guard try await tx.raw("SELECT COUNT(*) AS c FROM account_keys k JOIN accounts a ON a.id = k.account_id WHERE a.id = \(bind: DB.bin(a.accountId)) AND a.active = 1 FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c == 1 else { throw ValidationFailed(detail: "Zielkonto ohne aktiven Kontoschlüssel") }
                    if a.accountId != account { try await requireAccess(tx, tenant: tenant, account: a.accountId, kid: old.kid) }
                    _ = try bytes(a.enc, 32); _ = try bytes(a.sealed, 48)
                }
                try await tx.raw("DELETE FROM key_rotation_requests WHERE customer_id = \(bind: DB.bin(tenant))").run()
                let t = DB.time(now())
                try await tx.raw("UPDATE customer_key_generations SET state = 'retiring' WHERE customer_id = \(bind: DB.bin(tenant)) AND kid = \(bind: old.kid)").run()
                try await tx.raw("INSERT INTO customer_key_generations (generation_id, customer_id, kid, generation_no, public_key, state, created_by, created_at) VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: kid), \(bind: old.generation_no + 1), \(bind: Blob(pk)), 'active', \(bind: DB.bin(account)), \(bind: t))").run()
                for a in b.access {
                    try await tx.raw("INSERT INTO data_key_access (customer_id,kid,account_id,enc,sealed_key,granted_by,granted_at) VALUES (\(bind: DB.bin(tenant)), \(bind: kid), \(bind: DB.bin(a.accountId)), \(bind: Blob(try bytes(a.enc, 32))), \(bind: Blob(try bytes(a.sealed, 48))), \(bind: DB.bin(account)), \(bind: t))").run()
                }
                try await tx.raw("INSERT INTO data_key_recovery (customer_id,kid,kdf_name,salt,iterations,iv,wrapped_key,created_at) VALUES (\(bind: DB.bin(tenant)), \(bind: kid), 'pbkdf2-hmac-sha256', \(bind: Blob(salt)), 600000, \(bind: Blob(iv)), \(bind: Blob(wrap)), \(bind: t))").run()
                try await audit(tx, tenant: tenant, form: nil, actor: account, action: "key.rotation.begin", subject: tenant, at: t, source: old.kid, target: kid)
            }
            return Response(status: .created)
        }
        tenants.get("key-rotation", "objects") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), account = s.accountID!
            try await perms.authorize(account: account, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            guard let kid = req.query[String.self, at: "kid"], kid.count == 16 else { throw Abort(.badRequest) }
            try await requireAccess(sql, tenant: tenant, account: account, kid: kid)
            let limit = min(max(req.query[Int.self, at: "limit"] ?? 50, 1), 100)
            let after: UUID?
            if let raw = req.query[String.self, at: "after"] { guard let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }; after = id } else { after = nil }
            let cursor: SQLQueryString = after.map { "AND id > \(bind: DB.bin($0))" } ?? ""
            let rows = try await sql.raw("SELECT id, form_id, kid, revision, ciphertext_sha256, payload_sha256, ciphertext, backend, wrap_kind, (SELECT COUNT(*) FROM submissions s WHERE s.customer_id = stored_objects.customer_id AND s.form_id = stored_objects.form_id AND s.id = stored_objects.submission_id AND s.removable = 0) AS held FROM stored_objects WHERE customer_id = \(bind: DB.bin(tenant)) AND kid = \(bind: kid) \(cursor) ORDER BY id LIMIT \(literal: limit + 1)").all(decoding: Object.self)
            var items: [[String: Any]] = []
            for r in rows.prefix(limit) {
                guard let form = DB.uuid(r.form_id.data) else { throw Abort(.conflict) }
                try await perms.authorize(account: account, "content.decrypt", on: .form(customer: tenant, form: form))
                items.append(["id": DB.uuid(r.id.data)!.uuidString.lowercased(), "formId": form.uuidString.lowercased(), "kid": r.kid, "revision": r.revision, "ciphertext_sha256": hex(r.ciphertext_sha256.data), "package": r.ciphertext.map { String(decoding: $0.data, as: UTF8.self) } as Any? ?? NSNull(), "wrapKind": r.wrap_kind, "held": try await isHeld(sql, tenant: tenant, id: r.id)])
            }
            let res = try MailRoutes.anyJSON(["items": items, "next": rows.count > limit ? DB.uuid(rows[limit - 1].id.data)!.uuidString.lowercased() as Any : NSNull()]); res.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return res
        }
        // 32 MiB ingress packages plus Base64/JSON and the complete Hold proof list.
        tenants.on(.PUT, "key-rotation", "objects", ":objectId", body: .collect(maxSize: "64mb")) { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), id = try FormAdmin.uuidParam(req, "objectId"), account = s.accountID!
            try await perms.authorize(account: account, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let b: Replacement = try FormAdmin.decodeStrict(req, allowed: ["expectedRevision", "expectedSha256", "package"])
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard try await KeyRoutes.customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                let p = PermissionService(sql: tx)
                try await p.authorize(account: account, "key.manage", on: .customer(tenant))
                let gs = try await generations(tx, tenant)
                guard let old = gs.first(where: { $0.state == "retiring" }), let active = gs.first(where: { $0.state == "active" }) else { throw Abort(.conflict) }
                for g in gs { try await requireAccess(tx, tenant: tenant, account: account, kid: g.kid) }
                guard let r = try await tx.raw("SELECT id, form_id, kid, revision, ciphertext_sha256, payload_sha256, ciphertext, backend, wrap_kind, (SELECT COUNT(*) FROM submissions s WHERE s.customer_id = stored_objects.customer_id AND s.form_id = stored_objects.form_id AND s.id = stored_objects.submission_id AND s.removable = 0) AS held FROM stored_objects WHERE customer_id = \(bind: DB.bin(tenant)) AND id = \(bind: DB.bin(id)) FOR UPDATE").first(decoding: Object.self), let form = DB.uuid(r.form_id.data) else { throw Abort(.notFound) }
                guard r.kid == old.kid else { throw Abort(.conflict) }
                try await p.authorize(account: account, "content.decrypt", on: .form(customer: tenant, form: form))
                let held = try await isHeld(tx, tenant: tenant, id: r.id)
                if held { try await p.authorize(account: account, "content.hold", on: .form(customer: tenant, form: form)) }
                try await store(tx, tenant: tenant, row: r, package: replacement(r, b, target: active.kid, hold: held))
                try await audit(tx, tenant: tenant, form: form, actor: account, action: "key.rotation.rewrap", subject: id, at: DB.time(now()), source: old.kid, target: active.kid)
            }
            return Response(status: .noContent)
        }
        tenants.post("key-rotation", "finish") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), account = s.accountID!
            try await perms.authorize(account: account, "key.manage", on: .customer(tenant), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            struct Finish: Decodable { let kid: String }
            let b: Finish = try FormAdmin.decodeStrict(req, allowed: ["kid"])
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard try await KeyRoutes.customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                try await PermissionService(sql: tx).authorize(account: account, "key.manage", on: .customer(tenant))
                let gs = try await generations(tx, tenant)
                guard gs.contains(where: { $0.kid == b.kid && $0.state == "retiring" }), gs.count == 2 else { throw Abort(.conflict) }
                for g in gs { try await requireAccess(tx, tenant: tenant, account: account, kid: g.kid) }
                // No role, state, backend or expiry filter: every surviving reference blocks destruction.
                guard try await tx.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE customer_id = \(bind: DB.bin(tenant)) AND kid = \(bind: b.kid) FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c == 0 else { throw Abort(.conflict, reason: "Altreferenzen verbleiben") }
                for table in ["data_key_access", "data_key_recovery", "customer_key_generations"] {
                    try await tx.raw("DELETE FROM \(unsafeRaw: table) WHERE customer_id = \(bind: DB.bin(tenant)) AND kid = \(bind: b.kid)").run()
                }
                try await audit(tx, tenant: tenant, form: nil, actor: account, action: "key.rotation.finish", subject: tenant, at: DB.time(now()), source: b.kid, target: gs.first(where: { $0.state == "active" })!.kid)
            }
            return Response(status: .noContent)
        }
    }
}
