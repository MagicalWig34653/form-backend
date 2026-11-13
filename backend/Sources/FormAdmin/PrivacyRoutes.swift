// SPDX-License-Identifier: AGPL-3.0-only
import FormStorage
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Deletion, hold, retention and ciphertext export of submissions (ADR 0012). The server never sees plaintext: an export
/// hands out the sealed packages, the browser decrypts them; deletion is physical and leaves a `deletion_records` row.
enum PrivacyRoutes {
    static let maxRetentionDays = 3650
    static let maxBatch = 100

    struct RetentionBody: Encodable { let days: Int? }
    struct HoldBody: Encodable { let id: String; let held: Bool }
    struct DeleteBody: Encodable { let deleted: [String]; let held: [String]; let missing: [String]; let pending: [String] }
    struct ExportItem: Encodable {
        let id: String, receivedAt: String?, keyId: String, generationId: String?, package: String, attachments: Int
    }
    struct ExportPage: Encodable { let format = "KUBUS-AEAD:2"; let items: [ExportItem]; let nextCursor: String? }

    static func scopeKey(_ form: UUID) -> String { "form:\(form.uuidString.lowercased())" }

    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func formExists(_ tenant: UUID, _ form: UUID) async throws -> Bool {
            try await sql.raw("SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.id = \(bind: DB.bin(form)) AND f.customer_id = \(bind: DB.bin(tenant)) AND c.state = 'active'")
                .first(decoding: FormAdmin.CountRow.self)?.c == 1
        }
        func noStore(_ res: Response) -> Response { res.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return res }

        // --- retention policy of a form --------------------------------------------------------------------------------
        tenants.get("forms", ":formId", "retention") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            try await perms.authorize(account: s.accountID!, "content.read", on: .form(customer: tenant, form: form), exists: try await formExists(tenant, form))
            struct R: Decodable { let d: Int? }
            let d = try await sql.raw("SELECT CAST(JSON_VALUE(safe_value_json, '$') AS UNSIGNED) AS d FROM settings WHERE scope_key = \(bind: scopeKey(form)) AND setting_key = 'retention.days'").first(decoding: R.self)?.d
            // Every form has a period; without an entry the default applies (ingest and the upgrade fill it the same way).
            return noStore(try FormAdmin.json(.ok, RetentionBody(days: d ?? Retention.defaultDays)))
        }

        // days = null switches the automatic deletion off. Existing, not held submissions get their due date recomputed.
        tenants.put("forms", ":formId", "retention") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            let account = s.accountID!
            try await perms.authorize(account: account, "privacy.manage", on: .customer(tenant), exists: try await formExists(tenant, form))
            try await guardian.requireFreshAuthentication(s, now: now())
            let obj = try MailRoutes.jsonObject(req, allowed: ["days"])
            // The period is mandatory: missing, null and out-of-range values are rejected (no way to switch the deletion off).
            guard let days = obj["days"] as? Int, (Retention.minDays...Retention.maxDays).contains(days) else { throw RetentionProblem.required }
            let ts = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: account, "privacy.manage", on: .customer(tenant))
                // A resumable import compares target snapshots; rewriting the due dates of its rows would break the resume.
                guard !(try await SubmissionEraser.importMayResume(tx, form: form)) else { throw RetentionProblem.importRunning }
                try await tx.raw("""
                    INSERT INTO settings (scope_key, setting_key, safe_value_json, manageable, modified_at)
                    VALUES (\(bind: scopeKey(form)), \(bind: Retention.settingKey), \(bind: String(days)), 1, \(bind: ts))
                    ON DUPLICATE KEY UPDATE safe_value_json = VALUES(safe_value_json), modified_at = VALUES(modified_at)
                    """).run()
                try await tx.raw("""
                    UPDATE submissions SET retention_due_at = DATE_ADD(received_at, INTERVAL \(literal: days) DAY)
                    WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND received_at IS NOT NULL
                    """).run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: account, action: "privacy.retention.set", subject: form, at: ts, category: "privacy").run()
            }
            return noStore(try FormAdmin.json(.ok, RetentionBody(days: days)))
        }

        // --- hold ------------------------------------------------------------------------------------------------------
        // held = true: neither the retention job nor a deletion request may remove the submission.
        // 32 MiB ingress packages plus Base64/JSON and the complete Hold proof list.
        tenants.on(.PUT, "forms", ":formId", "entries", ":entryId", "hold", body: .collect(maxSize: "64mb")) { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), entry = try FormAdmin.uuidParam(req, "entryId")
            let account = s.accountID!
            let scope = PermissionTarget.form(customer: tenant, form: form)
            try await perms.authorize(account: account, "content.hold", on: scope, exists: try await formExists(tenant, form))
            try await guardian.requireFreshAuthentication(s, now: now())
            let b: HoldRewrapRoutes.Input = try FormAdmin.decodeStrict(req, allowed: ["held", "objects"])
            let held = b.held
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard try await KeyRoutes.customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                try await PermissionService(sql: tx).authorize(account: account, "content.hold", on: scope)
                guard try await FormAdmin.CountRow.count(tx, "SELECT COUNT(*) AS c FROM submissions WHERE id = \(bind: DB.bin(entry)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND state = 'accepted' FOR UPDATE") == 1 else { throw Abort(.notFound) }
                guard try await FormAdmin.CountRow.count(tx, "SELECT COUNT(*) AS c FROM stored_objects WHERE submission_id = \(bind: DB.bin(entry)) AND state = 'deleting'") == 0 else { throw Abort(.conflict) }
                try await HoldRewrapRoutes.apply(tx, tenant: tenant, form: form, entry: entry, account: account, input: b)
                try await tx.raw("UPDATE submissions SET removable = \(literal: held ? 0 : 1) WHERE id = \(bind: DB.bin(entry)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: account, action: held ? "content.hold.set" : "content.hold.clear", subject: entry, at: DB.time(now()), category: "privacy").run()
            }
            return noStore(try FormAdmin.json(.ok, HoldBody(id: entry.uuidString.lowercased(), held: held)))
        }

        // --- deletion ----------------------------------------------------------------------------------------------------
        func erase(_ req: Request, ids: [UUID], tenant: UUID, form: UUID, account: UUID, fresh: () async throws -> Void) async throws -> SubmissionEraser.Outcome {
            let scope = PermissionTarget.form(customer: tenant, form: form)
            try await perms.authorize(account: account, "content.delete", on: scope, exists: try await formExists(tenant, form))
            try await fresh()
            let at = now()
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: account, "content.delete", on: scope)
                try await SubmissionEraser.prepare(tx, tenant: tenant, form: form, ids: ids, now: at)
            }
            return try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: account, "content.delete", on: scope)
                let out = try await SubmissionEraser.erase(tx, tenant: tenant, form: form, ids: ids, reason: "request", actor: account, now: at, storage: req.application.storage[StorageServiceKey.self])
                if !out.deleted.isEmpty {
                    try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: account, action: "content.delete", subject: form, at: DB.time(at), category: "privacy").run()
                }
                return out
            }
        }

        tenants.post("forms", ":formId", "entries", "delete") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            let obj = try MailRoutes.jsonObject(req, allowed: ["ids"])
            guard let raw = obj["ids"] as? [String], (1...maxBatch).contains(raw.count) else { throw ValidationFailed(detail: "ids: 1–\(maxBatch) Einträge") }
            let ids = try raw.map { s -> UUID in guard let u = MailRoutes.lowerUUID(s) else { throw ValidationFailed(detail: "ids: ungültige ID") }; return u }
            let out = try await erase(req, ids: ids, tenant: tenant, form: form, account: s.accountID!, fresh: { try await guardian.requireFreshAuthentication(s, now: now()) })
            let f = { (a: [UUID]) in a.map { $0.uuidString.lowercased() } }
            return noStore(try FormAdmin.json(.ok, DeleteBody(deleted: f(out.deleted), held: f(out.held), missing: f(out.missing), pending: f(out.pending))))
        }

        tenants.delete("forms", ":formId", "entries", ":entryId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), entry = try FormAdmin.uuidParam(req, "entryId")
            let out = try await erase(req, ids: [entry], tenant: tenant, form: form, account: s.accountID!, fresh: { try await guardian.requireFreshAuthentication(s, now: now()) })
            if !out.held.isEmpty { throw Abort(.conflict, reason: "held") }
            if !out.pending.isEmpty { return Response(status: .accepted) }
            if out.deleted.isEmpty { throw Abort(.notFound) }
            return Response(status: .noContent)
        }

        // Local search gets live capabilities; no search text or decrypted values enter this API.
        struct AccessBody: Encodable { let canExport: Bool; let canDelete: Bool }
        tenants.get("forms", ":formId", "entries", "local-access") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            let scope = PermissionTarget.form(customer: tenant, form: form), account = s.accountID!
            try await perms.authorize(account: account, "content.read", on: scope, exists: try await formExists(tenant, form))
            try await perms.authorize(account: account, "content.decrypt", on: scope)
            try await guardian.requireFreshAuthentication(s, now: now())
            return noStore(try FormAdmin.json(.ok, AccessBody(canExport: try await perms.can(account: account, "content.export", on: scope), canDelete: try await perms.can(account: account, "content.delete", on: scope))))
        }

        // A download is released only after this explicit, CSRF-protected audit succeeds.
        // No filters, person identifiers, field values or entry IDs are accepted.
        tenants.post("forms", ":formId", "export", "audit") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            _ = try MailRoutes.jsonObject(req, allowed: [])
            try await guardian.requireFreshAuthentication(s, now: now())
            guard try await formExists(tenant, form) else { throw Abort(.notFound) }
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                let live = PermissionService(sql: tx), scope = PermissionTarget.form(customer: tenant, form: form)
                for right in ["content.read", "content.decrypt", "content.export"] {
                    try await live.authorize(account: s.accountID!, right, on: scope)
                }
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: s.accountID!, action: "content.export.local", subject: form, at: DB.time(now()), category: "content").run()
            }
            return noStore(Response(status: .noContent))
        }

        // --- ciphertext export -------------------------------------------------------------------------------------------
        // Pages of sealed data packages (newest first). Attachments are fetched one by one through the attachment route.
        tenants.get("forms", ":formId", "export") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            let account = s.accountID!
            let scope = PermissionTarget.form(customer: tenant, form: form)
            try await perms.authorize(account: account, "content.export", on: scope, exists: try await formExists(tenant, form))
            try await perms.authorize(account: account, "content.read", on: scope)
            try await guardian.requireFreshAuthentication(s, now: now())
            let limit = try FormAdmin.limitParam(req)
            let after = try FormAdmin.cursorParam(req)
            if let after, try await sql.raw("SELECT COUNT(*) AS c FROM submissions WHERE id = \(bind: Blob(after)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").first(decoding: FormAdmin.CountRow.self)?.c != 1 { throw Abort(.badRequest) }
            let cursorClause: SQLQueryString = after.map {
                "AND (COALESCE(s.received_at, '1000-01-01 00:00:00'), s.id) < (SELECT COALESCE(c.received_at, '1000-01-01 00:00:00'), c.id FROM submissions c WHERE c.id = \(bind: Blob($0)) AND c.customer_id = \(bind: DB.bin(tenant)) AND c.form_id = \(bind: DB.bin(form)))"
            } ?? ""
            struct Row: Decodable { let id: Blob; let received_at: Date?; let object_id: Blob; let ciphertext: Blob?; let ciphertext_sha256: Blob; let kid: String; let generation_id: Blob?; let attachments: Int }
            let rows = try await sql.raw("""
                SELECT s.id AS id, s.received_at AS received_at, o.id AS object_id, o.ciphertext_sha256, o.ciphertext AS ciphertext, o.kid AS kid, g.generation_id AS generation_id,
                  (SELECT COUNT(*) FROM stored_objects a WHERE a.customer_id = s.customer_id AND a.form_id = s.form_id AND a.submission_id = s.id AND a.object_role = 'attachment' AND a.state = 'ready') AS attachments
                FROM submissions s
                JOIN stored_objects o ON o.customer_id = s.customer_id AND o.form_id = s.form_id AND o.submission_id = s.id
                  AND o.object_role = 'data' AND o.ordinal_no = 0 AND o.state = 'ready'
                LEFT JOIN customer_key_generations g ON g.customer_id = o.customer_id AND g.kid = o.kid
                WHERE s.customer_id = \(bind: DB.bin(tenant)) AND s.form_id = \(bind: DB.bin(form)) AND s.state = 'accepted'
                  \(cursorClause)
                ORDER BY COALESCE(s.received_at, '1000-01-01 00:00:00') DESC, s.id DESC LIMIT \(literal: limit + 1)
                """).all(decoding: Row.self)
            let page = rows.prefix(limit)
            var items: [ExportItem] = []
            for r in page {
                guard let id = DB.uuid(r.id.data) else { throw Abort(.internalServerError) }
                let bytes = try await StoredContent.read(req, sql: sql, customer: tenant, form: form, object: r.object_id, fallback: r.ciphertext, hash: r.ciphertext_sha256)
                items.append(ExportItem(id: id.uuidString.lowercased(), receivedAt: r.received_at.map { iso.string(from: $0) }, keyId: r.kid,
                                  generationId: r.generation_id.flatMap { DB.uuid($0.data) }?.uuidString.lowercased(),
                                  package: String(decoding: bytes, as: UTF8.self), attachments: r.attachments))
            }
            try await ReleaseRoutes.audit(sql, tenant: tenant, form: form, actor: account, action: "content.export", subject: form, at: DB.time(now()), category: "content").run()
            return noStore(try FormAdmin.json(.ok, ExportPage(items: items, nextCursor: rows.count > limit ? page.last.map { FormAdmin.cursor($0.id) } : nil)))
        }
    }
}
