// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// createDraft, getDraft, updateDraft (contracts/auth/admin-api.openapi.yaml).
enum DraftRoutes {
    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        let drafts = tenants.grouped("forms", ":formId", "drafts")

        // createDraft: from the given release, else from the current release, else the standard document.
        drafts.post { req async throws -> Response in
            let s = try await ConfigurationIdentity.require(req, guardian: guardian, db: db, mutation: true, now: now)
            if s.token == nil { try await guardian.budget(req) }
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            let base: UUID? = try {
                guard req.body.data?.readableBytes ?? 0 > 0 else { return nil }
                struct B: Decodable { let baseReleaseId: String? }
                let b: B = try FormAdmin.decodeStrict(req, allowed: ["baseReleaseId"])
                guard let raw = b.baseReleaseId else { return nil }
                guard raw == raw.lowercased(), let u = UUID(uuidString: raw) else { throw Abort(.badRequest) }
                return u
            }()
            let account = s.accountID!
            struct F: Decodable { let name: String?; let current_release_id: Blob? }
            let f = try await sql.raw("SELECT name, current_release_id FROM forms WHERE id = \(bind: DB.bin(form)) AND customer_id = \(bind: DB.bin(tenant))").first(decoding: F.self)
            try await s.authorize(perms, "draft.write", on: .form(customer: tenant, form: form), exists: f != nil)
            let release = base ?? f?.current_release_id.flatMap { DB.uuid($0.data) }
            let document: JSONValue
            if let release {
                guard let doc = try await DraftStore.documentOfRelease(sql, tenant: tenant, form: form, release: release) else { throw Abort(.notFound) }
                document = doc
            } else {
                document = DraftStore.standardDocument(tenant: tenant, form: form, name: f?.name ?? "Formular")
            }
            do { try DocumentValidator.validate(document, tenant: tenant, form: form) } catch let e as DocumentInvalid { throw ValidationFailed(e) }
            let t = DB.time(now())
            let created = try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                let created = try await DraftStore.insert(tx, tenant: tenant, form: form, account: account, document: document, base: release, now: t)
                if let token = s.token {
                    try await TokenService.auditDraft(tx, token: token, tenant: tenant, form: form, draft: created.id, revision: 1, outcome: "success", action: "draft.create", at: now())
                }
                return created
            }
            let canonical = String(decoding: JCS.canonicalize(document), as: UTF8.self)
            return draftResponse(.created, id: created.id, revision: 1, hash: created.hash, document: canonical)
        }

        drafts.get(":draftId") { req async throws -> Response in
            let s = try await ConfigurationIdentity.require(req, guardian: guardian, db: db, mutation: false, now: now)
            if s.token == nil { try await guardian.budget(req) }
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), draft = try FormAdmin.uuidParam(req, "draftId")
            let row = try await DraftStore.load(sql, tenant: tenant, form: form, draft: draft)
            try await s.authorize(perms, "form.read", on: .form(customer: tenant, form: form), exists: row != nil)
            let r = row!
            return draftResponse(.ok, id: draft, revision: r.revision, hash: r.document_sha256.data, document: r.document_json)
        }

        // updateDraft: whole-document replace guarded by If-Match (428 missing, 412 stale); the hash is always server-side.
        // Vapor collects only 16 KiB by default; documents may be up to DocumentValidator.maxDocumentBytes.
        drafts.on(.PATCH, ":draftId", body: .collect(maxSize: ByteCount(value: DocumentValidator.maxDocumentBytes))) { req async throws -> Response in
            let s = try await ConfigurationIdentity.require(req, guardian: guardian, db: db, mutation: true, now: now)
            if s.token == nil { try await guardian.budget(req) }
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), draft = try FormAdmin.uuidParam(req, "draftId")
            do {
                let account = s.accountID!
                let exists = try await DraftStore.load(sql, tenant: tenant, form: form, draft: draft) != nil
                try await s.authorize(perms, "draft.write", on: .form(customer: tenant, form: form), exists: exists)
                guard let match = req.headers.first(name: .ifMatch) else { throw Abort(.preconditionRequired) }
                guard let expected = parseETag(match) else { throw Abort(.preconditionFailed) }
                guard req.headers.contentType == .json else { throw Abort(.unsupportedMediaType) }
                guard var buf = req.body.data, buf.readableBytes <= DocumentValidator.maxDocumentBytes, let data = buf.readData(length: buf.readableBytes) else { throw Abort(.payloadTooLarge) }
                let document: JSONValue
                do { document = try JCS.parse(data) } catch { throw ValidationFailed(detail: "kein gültiges JSON (nur ganze Zahlen, keine doppelten Schlüssel)") }
                do { try DocumentValidator.validate(document, tenant: tenant, form: form) } catch let e as DocumentInvalid { throw ValidationFailed(e) }
                let canonical = JCS.canonicalize(document)
                let hash = Data(SHA256.hash(data: canonical))
                let t = DB.time(now())
                let newRevision: UInt64 = try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    // Locking read FIRST: a consistent (snapshot) read before it would make MariaDB fail with error 1020
                    // "Record has changed since last read" for the loser of a race instead of letting it see the new revision.
                    guard let row = try await DraftStore.load(tx, tenant: tenant, form: form, draft: draft, forUpdate: true) else { throw Abort(.notFound) }
                    try await s.authorize(PermissionService(sql: tx), "draft.write", on: .form(customer: tenant, form: form))
                    guard row.revision == expected else { throw Abort(.preconditionFailed) }
                    try await tx.raw("""
                        UPDATE form_drafts SET revision = revision + 1, document_json = \(bind: String(decoding: canonical, as: UTF8.self)), document_sha256 = \(bind: Blob(hash)),
                          updated_by = \(bind: DB.bin(account)), updated_at = \(bind: t)
                        WHERE id = \(bind: DB.bin(draft))
                        """).run()
                    if let token = s.token {
                        try await TokenService.auditDraft(tx, token: token, tenant: tenant, form: form, draft: draft, revision: row.revision + 1, outcome: "success", at: now())
                    }
                    return row.revision + 1
                }
                return draftResponse(.ok, id: draft, revision: newRevision, hash: hash, document: String(decoding: canonical, as: UTF8.self))
            } catch {
                if let token = s.token {
                    try await TokenService.auditDraft(sql, token: token, tenant: tenant, form: form, draft: draft,
                        revision: req.headers.first(name: .ifMatch).flatMap(parseETag), outcome: "failed", at: now())
                }
                throw error
            }
        }
    }

    static func parseETag(_ raw: String) -> UInt64? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("W/") { s.removeFirst(2) }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty, s.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt64(s), n >= 1 else { return nil }
        return n
    }

    static func draftResponse(_ status: HTTPResponseStatus, id: UUID, revision: UInt64, hash: Data, document: String) -> Response {
        let res = Response(status: status)
        res.body = .init(data: DraftStore.draftBody(id: id, revision: revision, hash: hash, canonicalDocument: document))
        res.headers.contentType = .json
        res.headers.replaceOrAdd(name: .eTag, value: "\"\(revision)\"")
        return res
    }
}
