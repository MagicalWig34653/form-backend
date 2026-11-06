// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

enum HoldRewrapRoutes {
    struct Proof: Decodable {
        let objectId: UUID; let expectedRevision: UInt64; let expectedSha256: String
        let sourceGenerationId: UUID; let replacementPackage: String?
    }
    struct Input: Decodable { let held: Bool; let objects: [Proof] }
    struct Row: Decodable {
        let id: Blob; let submission_id: Blob?; let metadata_object_id: Blob?; let generation_id: Blob
        let object_role: String
    }
    static func inventory(_ tx: SQLDatabase, tenant: UUID, form: UUID, entry: UUID) async throws -> [Row] {
        let rows = try await tx.raw("""
            SELECT o.id, o.submission_id, o.metadata_object_id, g.generation_id, o.object_role FROM stored_objects o
            JOIN customer_key_generations g ON g.customer_id = o.customer_id AND g.kid = o.kid
            WHERE o.customer_id = \(bind: DB.bin(tenant)) AND o.form_id = \(bind: DB.bin(form)) FOR UPDATE
            """).all(decoding: Row.self)
        var selected = Set(rows.filter { $0.submission_id?.data == DB.bin(entry).data && !["debug", "statistics-metadata"].contains($0.object_role) }.map { $0.id.data })
        var changed = true
        while changed {
            changed = false
            for r in rows where selected.contains(r.id.data) {
                if let meta = r.metadata_object_id, selected.insert(meta.data).inserted { changed = true }
            }
        }
        let result = rows.filter { selected.contains($0.id.data) }
        guard result.count == selected.count else { throw Abort(.conflict) }
        return result
    }
    static func object(_ tx: SQLDatabase, tenant: UUID, id: Blob) async throws -> RotationRoutes.Object {
        guard let r = try await tx.raw("SELECT id, form_id, kid, revision, ciphertext_sha256, payload_sha256, ciphertext, backend, wrap_kind FROM stored_objects WHERE customer_id = \(bind: DB.bin(tenant)) AND id = \(bind: id) FOR UPDATE").first(decoding: RotationRoutes.Object.self) else { throw Abort(.conflict) }; return r
    }
    static func apply(_ tx: SQLDatabase, tenant: UUID, form: UUID, entry: UUID, account: UUID, input: Input) async throws {
        let rows = try await inventory(tx, tenant: tenant, form: form, entry: entry)
        guard input.objects.count == rows.count, Set(input.objects.map(\.objectId)).count == rows.count,
              Set(input.objects.map { DB.bin($0.objectId).data }) == Set(rows.map { $0.id.data }) else { throw Abort(.conflict, reason: "Hold-Objektliste ist nicht vollständig") }
        for r in rows {
            let p = input.objects.first { DB.bin($0.objectId).data == r.id.data }!
            let o = try await object(tx, tenant: tenant, id: r.id)
            guard p.sourceGenerationId == DB.uuid(r.generation_id.data), p.expectedRevision == o.revision,
                  p.expectedSha256 == RotationRoutes.hex(o.ciphertext_sha256.data) else { throw Abort(.conflict) }
            if let replacement = p.replacementPackage {
                guard input.held else { throw ValidationFailed(detail: "Beim Aufheben kein Ersatzpaket zulässig") }
                try await PermissionService(sql: tx).authorize(account: account, "content.decrypt", on: .form(customer: tenant, form: form))
                try await RotationRoutes.requireAccess(tx, tenant: tenant, account: account, kid: o.kid)
                let b = RotationRoutes.Replacement(expectedRevision: p.expectedRevision, expectedSha256: p.expectedSha256, package: replacement)
                try await RotationRoutes.store(tx, tenant: tenant, row: o, package: RotationRoutes.replacement(o, b, target: o.kid, hold: true))
            } else if input.held && o.wrap_kind != "sym" { throw Abort(.conflict, reason: "HPKE-Objekt benötigt sym-Nachschutz") }
        }
    }
    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        tenants.get("forms", ":formId", "entries", ":entryId", "hold-objects") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), entry = try FormAdmin.uuidParam(req, "entryId")
            try await perms.authorize(account: s.accountID!, "content.hold", on: .form(customer: tenant, form: form), exists: try await KeyRoutes.customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let items: [[String: Any]] = try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard try await KeyRoutes.customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                guard try await tx.raw("SELECT COUNT(*) AS c FROM submissions WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND id = \(bind: DB.bin(entry)) FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c == 1 else { throw Abort(.notFound) }
                var items: [[String: Any]] = []
                for r in try await inventory(tx, tenant: tenant, form: form, entry: entry) {
                    let o = try await object(tx, tenant: tenant, id: r.id)
                    let canDecrypt = try await PermissionService(sql: tx).can(account: s.accountID!, "content.decrypt", on: .form(customer: tenant, form: form))
                    items.append(["id": DB.uuid(r.id.data)!.uuidString.lowercased(), "kid": o.kid, "revision": o.revision, "ciphertext_sha256": RotationRoutes.hex(o.ciphertext_sha256.data), "package": (canDecrypt ? o.ciphertext : nil).map { String(decoding: $0.data, as: UTF8.self) } as Any? ?? NSNull(), "formId": form.uuidString.lowercased(), "wrapKind": o.wrap_kind, "sourceGenerationId": DB.uuid(r.generation_id.data)!.uuidString.lowercased()])
                }
                return items
            }
            let res = try MailRoutes.anyJSON(["items": items]); res.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return res
        }
    }
}
