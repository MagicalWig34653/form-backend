// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormMigration
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Session-only migration proposal API. Uses the existing system.manage grant on system scope.
enum LegacyConversionRoutes {
    struct Stored: Decodable { let draft_id: Blob; let report_json: String; let proposals_json: String }
    static func register(_ app: Application, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        for method in [HTTPMethod.POST, .GET] {
            app.on(method, "admin", "api", "v1", "migration", "legacy-forms", ":legacyFormId", "draft") { req async throws -> Response in
                let session = try await guardian.requireAuthenticated(req, mutation: method == .POST)
                try await guardian.budget(req)
                try await guardian.requireFreshAuthentication(session, now: now())
                let form = try FormAdmin.uuidParam(req, "legacyFormId"), account = session.accountID!
                if method == .POST, (req.body.data?.readableBytes ?? 0) > 0 { throw Abort(.badRequest) }
                let body: JSONValue = try await db.transaction { connection in
                    let tx = connection as! SQLDatabase
                    return try await perform(tx, form: form, account: account, method: method, now: now())
                }
                let response = Response(status: .ok, body: .init(data: JCS.canonicalize(body)))
                response.headers.contentType = .json
                response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return response
            }
        }
    }
    /// Shared transaction-scoped operation for HTTP and the migration worker.
    static func perform(_ tx: SQLDatabase, form: UUID, account: UUID, method: HTTPMethod, now: Date, includeDocument: Bool = true, permission: String = "system.manage") async throws -> JSONValue {
        try await PermissionService(sql: tx).authorize(account: account, permission, on: .system)
        struct F: Decodable { let customer_id: Blob; let active: Int; let current_release_id: Blob? }
        // Serialize concurrent conversions on the imported form, before any snapshot read.
        guard let f = try await tx.raw("SELECT customer_id, active, current_release_id FROM forms WHERE id = \(bind: DB.bin(form)) FOR UPDATE").first(decoding: F.self),
              let tenant = DB.uuid(f.customer_id.data) else { throw Abort(.notFound) }
        let at = DB.time(now)
        var stored = try await tx.raw("SELECT draft_id, report_json, proposals_json FROM migration_form_drafts WHERE form_id = \(bind: DB.bin(form))").first(decoding: Stored.self)
        var document: JSONValue?
        if method == .POST {
            guard f.active == 0, f.current_release_id == nil else { throw Abort(.conflict, reason: "Formular ist bereits freigegeben") }
            if stored == nil {
                struct V: Decodable { let definition_json: String }
                guard let v = try await tx.raw("""
                    SELECT definition_json FROM form_versions WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))
                    AND version_no = 1 AND contract_version = 'migration-review' AND legacy_adapter_ref = 'inactive:migration-review'
                    """).first(decoding: V.self) else { throw Abort(.notFound) }
                let result: LegacyFormConverter.Result
                do { result = try LegacyFormConverter.convert(Data(v.definition_json.utf8), standardDocument: DraftStore.standardDocument(tenant: tenant, form: form, name: "Formular")) }
                catch { throw Abort(.unprocessableEntity, reason: "Legacy-Projektion kann nicht konvertiert werden") }
                do { try DocumentValidator.validate(result.document, tenant: tenant, form: form) }
                catch { throw Abort(.unprocessableEntity, reason: "Vorschlag verletzt den Entwurfsvertrag") }
                let created = try await DraftStore.insert(tx, tenant: tenant, form: form, account: account, document: result.document, base: nil, now: at)
                let report = String(decoding: try JSONEncoder().encode(result.report), as: UTF8.self)
                let proposals = String(decoding: JCS.canonicalize(result.proposals), as: UTF8.self)
                try await tx.raw("""
                    INSERT INTO migration_form_drafts (form_id, draft_id, report_json, proposals_json, created_at)
                    VALUES (\(bind: DB.bin(form)), \(bind: DB.bin(created.id)), \(bind: report), \(bind: proposals), \(bind: at))
                    """).run()
                stored = Stored(draft_id: DB.bin(created.id), report_json: report, proposals_json: proposals)
                document = result.document
            }
        }
        guard let stored, let draft = DB.uuid(stored.draft_id.data) else { throw Abort(.notFound) }
        try await tx.raw("""
            INSERT INTO audit_events (id, actor_id, actor_kind, customer_id, form_id, category, action_code, occurred_at, safe_details_json)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), 'human', \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), 'system',
                \(bind: method == .POST ? "migration.draft.create" : "migration.draft.report"), \(bind: at), '{}')
            """).run()
        var response: [String: JSONValue] = ["legacyFormId": .string(form.uuidString.lowercased()), "draftId": .string(draft.uuidString.lowercased()),
            "report": try JCS.parse(Data(stored.report_json.utf8))]
        if method == .POST && includeDocument {
            // Retries return the existing editable draft without replacing human edits.
            if document == nil {
                guard let row = try await DraftStore.load(tx, tenant: tenant, form: form, draft: draft) else { throw Abort(.conflict) }
                document = try JCS.parse(Data(row.document_json.utf8))
            }
            response["document"] = document
            response["proposals"] = try JCS.parse(Data(stored.proposals_json.utf8))
        }
        return .object(response)
    }

}
