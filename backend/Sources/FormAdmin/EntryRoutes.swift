// SPDX-License-Identifier: AGPL-3.0-only
import FormStorage
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Reading submissions (VORGESCHLAGEN, contracts/auth listEntries/getCiphertext). The server only hands out metadata and the
/// still-sealed `KUBUS-AEAD:2` package; decryption happens in the browser with a key the server never sees.
enum EntryRoutes {
    struct EntryItem: Encodable { let id: String; let receivedAt: String?; let state: String; let releaseId: String?; let keyId: String?; let held: Bool; let captchaStatus: String; let malwareStatus: String; let environment: String }
    struct EntryList: Encodable { let items: [EntryItem]; let nextCursor: String? }
    struct CiphertextBody: Encodable {
        let id: String, tenantId: String, formId: String
        let generationId: String, keyId: String
        let format = "KUBUS-AEAD:2"
        let package: String
    }
    private struct Row: Decodable { let id: Blob; let received_at: Date?; let state: String; let release_id: Blob?; let kid: String?; let removable: Int; let captcha_status: String; let malware_scan_status: String; let environment: String }
    private struct PackageRow: Decodable { let id: Blob; let ciphertext: Blob?; let ciphertext_sha256: Blob; let kid: String; let generation_id: Blob? }

    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func formExists(_ tenant: UUID, _ form: UUID) async throws -> Bool {
            try await sql.raw("SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.id = \(bind: DB.bin(form)) AND f.customer_id = \(bind: DB.bin(tenant)) AND c.state = 'active'")
                .first(decoding: FormAdmin.CountRow.self)?.c == 1
        }

        // listEntries: metadata only, newest first, keyset pagination by (received_at, id)
        tenants.get("forms", ":formId", "entries") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            try await perms.authorize(account: s.accountID!, "content.read", on: .form(customer: tenant, form: form), exists: try await formExists(tenant, form))
            let limit = try FormAdmin.limitParam(req)
            let after = try FormAdmin.cursorParam(req)
            if let after, try await sql.raw("SELECT COUNT(*) AS c FROM submissions WHERE id = \(bind: Blob(after)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").first(decoding: FormAdmin.CountRow.self)?.c != 1 { throw Abort(.badRequest) }
            let cursorClause: SQLQueryString = after.map {
                "AND (COALESCE(s.received_at, '1000-01-01 00:00:00'), s.id) < (SELECT COALESCE(c.received_at, '1000-01-01 00:00:00'), c.id FROM submissions c WHERE c.id = \(bind: Blob($0)) AND c.customer_id = \(bind: DB.bin(tenant)) AND c.form_id = \(bind: DB.bin(form)))"
            } ?? ""
            let rows = try await sql.raw("""
                SELECT s.id AS id, s.received_at AS received_at, s.state AS state, s.release_id AS release_id, o.kid AS kid, s.removable AS removable, s.captcha_status, s.malware_scan_status, s.environment
                FROM submissions s
                JOIN stored_objects o ON o.customer_id = s.customer_id AND o.form_id = s.form_id AND o.submission_id = s.id
                  AND o.object_role = 'data' AND o.ordinal_no = 0 AND o.state = 'ready'
                WHERE s.customer_id = \(bind: DB.bin(tenant)) AND s.form_id = \(bind: DB.bin(form)) AND s.state = 'accepted'
                  \(cursorClause)
                ORDER BY COALESCE(s.received_at, '1000-01-01 00:00:00') DESC, s.id DESC LIMIT \(literal: limit + 1)
                """).all(decoding: Row.self)
            let page = rows.prefix(limit)
            let items = page.map { r in
                EntryItem(id: DB.uuid(r.id.data)?.uuidString.lowercased() ?? "", receivedAt: r.received_at.map { iso.string(from: $0) }, state: r.state,
                          releaseId: r.release_id.flatMap { DB.uuid($0.data) }?.uuidString.lowercased(), keyId: r.kid, held: r.removable != 1, captchaStatus: r.captcha_status, malwareStatus: r.malware_scan_status, environment: r.environment)
            }
            let res = try FormAdmin.json(.ok, EntryList(items: items, nextCursor: rows.count > limit ? page.last.map { FormAdmin.cursor($0.id) } : nil))
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }

        // attachment n of a submission: the sealed package of that file (same rights, freshness and audit as the data package)
        tenants.get("forms", ":formId", "entries", ":entryId", "attachments", ":ordinal") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), entry = try FormAdmin.uuidParam(req, "entryId")
            guard let n = req.parameters.get("ordinal").flatMap({ Int($0) }), (0..<16).contains(n) else { throw Abort(.badRequest) }
            let account = s.accountID!
            let scope = PermissionTarget.form(customer: tenant, form: form)
            try await perms.authorize(account: account, "content.read", on: scope, exists: try await formExists(tenant, form))
            try await perms.authorize(account: account, "content.decrypt", on: scope)
            try await guardian.requireFreshAuthentication(s, now: now())
            guard let row = try await sql.raw("""
                SELECT o.id, o.ciphertext_sha256, o.ciphertext AS ciphertext, o.kid AS kid, g.generation_id AS generation_id
                FROM stored_objects o
                JOIN submissions s ON s.customer_id = o.customer_id AND s.form_id = o.form_id AND s.id = o.submission_id
                LEFT JOIN customer_key_generations g ON g.customer_id = o.customer_id AND g.kid = o.kid
                WHERE o.customer_id = \(bind: DB.bin(tenant)) AND o.form_id = \(bind: DB.bin(form)) AND o.submission_id = \(bind: DB.bin(entry))
                  AND o.object_role = 'attachment' AND o.ordinal_no = \(bind: n) AND o.state = 'ready' AND s.state = 'accepted'
                """).first(decoding: PackageRow.self), let gen = row.generation_id.flatMap({ DB.uuid($0.data) }) else { throw Abort(.notFound) }
            let bytes = try await StoredContent.read(req, sql: sql, customer: tenant, form: form, object: row.id, fallback: row.ciphertext, hash: row.ciphertext_sha256)
            try await ReleaseRoutes.audit(sql, tenant: tenant, form: form, actor: account, action: "content.attachment.read", subject: entry, at: DB.time(now()), category: "content").run()
            let res = try FormAdmin.json(.ok, CiphertextBody(id: entry.uuidString.lowercased(), tenantId: tenant.uuidString.lowercased(), formId: form.uuidString.lowercased(),
                                                           generationId: gen.uuidString.lowercased(), keyId: row.kid, package: String(decoding: bytes, as: UTF8.self)))
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }

        // getCiphertext: the sealed package of one submission; both rights, fresh login, audited
        tenants.get("forms", ":formId", "entries", ":entryId", "ciphertext") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), entry = try FormAdmin.uuidParam(req, "entryId")
            let account = s.accountID!
            let scope = PermissionTarget.form(customer: tenant, form: form)
            try await perms.authorize(account: account, "content.read", on: scope, exists: try await formExists(tenant, form))
            try await perms.authorize(account: account, "content.decrypt", on: scope)
            try await guardian.requireFreshAuthentication(s, now: now())
            guard let row = try await sql.raw("""
                SELECT o.id, o.ciphertext_sha256, o.ciphertext AS ciphertext, o.kid AS kid, g.generation_id AS generation_id
                FROM stored_objects o
                JOIN submissions s ON s.customer_id = o.customer_id AND s.form_id = o.form_id AND s.id = o.submission_id
                LEFT JOIN customer_key_generations g ON g.customer_id = o.customer_id AND g.kid = o.kid
                WHERE o.customer_id = \(bind: DB.bin(tenant)) AND o.form_id = \(bind: DB.bin(form)) AND o.submission_id = \(bind: DB.bin(entry))
                  AND o.object_role = 'data' AND o.ordinal_no = 0 AND o.state = 'ready' AND s.state = 'accepted'
                """).first(decoding: PackageRow.self), let gen = row.generation_id.flatMap({ DB.uuid($0.data) }) else { throw Abort(.notFound) }
            let bytes = try await StoredContent.read(req, sql: sql, customer: tenant, form: form, object: row.id, fallback: row.ciphertext, hash: row.ciphertext_sha256)
            try await ReleaseRoutes.audit(sql, tenant: tenant, form: form, actor: account, action: "content.ciphertext.read", subject: entry, at: DB.time(now()), category: "content").run()
            let res = try FormAdmin.json(.ok, CiphertextBody(id: entry.uuidString.lowercased(), tenantId: tenant.uuidString.lowercased(), formId: form.uuidString.lowercased(),
                                                           generationId: gen.uuidString.lowercased(), keyId: row.kid, package: String(decoding: bytes, as: UTF8.self)))
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
    }
}
