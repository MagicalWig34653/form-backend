// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormCore
import FormFlow
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// confirmPublication and publishRelease (contracts/auth/p5b-ergaenzung.md E7, rechte.md, abbildung.md).
/// Publishing is only possible from a fully authenticated, fresh human session with a prior confirmation bound to
/// session, account, form, draft revision and the document hash. One transaction creates all immutable versions,
/// the release, consumes the confirmation and sets `current_release_id` (and `active` on the first release, ADR 0009 F8).
enum ReleaseRoutes {
    static let freshness: TimeInterval = 300       // anmeldung.md: fresh authentication for H actions, at most 5 min
    static let confirmationLifetime: TimeInterval = 300

    private struct Hex64 { static func valid(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) } } }

    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        let form = tenants.grouped("forms", ":formId")

        form.post("publication-confirmations") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), formID = try FormAdmin.uuidParam(req, "formId")
            struct B: Decodable { let draftId: String; let revision: Int; let hash: String; let confirm: Bool }
            let b: B = try FormAdmin.decodeStrict(req, allowed: ["draftId", "revision", "hash", "confirm"])
            guard b.confirm, b.revision >= 1, Hex64.valid(b.hash), let draftID = lowerUUID(b.draftId) else { throw Abort(.badRequest) }
            let account = s.accountID!
            let exists = try await sql.raw("SELECT COUNT(*) AS c FROM forms WHERE id = \(bind: DB.bin(formID)) AND customer_id = \(bind: DB.bin(tenant))").first(decoding: FormAdmin.CountRow.self)?.c == 1
            try await perms.authorize(account: account, "release.publish", on: .form(customer: tenant, form: formID), exists: exists)
            let authAt = try await freshAuthentication(sql, session: s.id, now: now())
            let id = UUID(), t0 = now()
            let expires = t0.addingTimeInterval(confirmationLifetime)
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                // Locking read first (see DraftRoutes): no snapshot may exist before it (MariaDB error 1020).
                guard let row = try await DraftStore.load(tx, tenant: tenant, form: formID, draft: draftID, forUpdate: true) else { throw Abort(.notFound) }
                try await PermissionService(sql: tx).authorize(account: account, "release.publish", on: .form(customer: tenant, form: formID))
                // The client hash is only a comparison value; the stored document's hash is recomputed.
                let actual = Data(SHA256.hash(data: Data(row.document_json.utf8)))
                guard row.revision == UInt64(b.revision), actual == row.document_sha256.data, DocHash.hex(actual) == b.hash else { throw Abort(.conflict) }
                do { try DocumentValidator.validate(try JCS.parse(Data(row.document_json.utf8)), tenant: tenant, form: formID) } catch let e as DocumentInvalid { throw ValidationFailed(e) }
                try await tx.raw("""
                    INSERT INTO publication_confirmations (id, session_id, account_id, customer_id, form_id, draft_id, draft_revision, candidate_sha256, authenticated_at, created_at, expires_at)
                    VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(s.id)), \(bind: DB.bin(account)), \(bind: DB.bin(tenant)), \(bind: DB.bin(formID)), \(bind: DB.bin(draftID)),
                      \(bind: Int(row.revision)), \(bind: Blob(actual)), \(bind: DB.time(authAt)), \(bind: DB.time(t0)), \(bind: DB.time(expires)))
                    """).run()
                try await audit(tx, tenant: tenant, form: formID, actor: account, action: "release.confirm", subject: draftID, at: DB.time(t0)).run()
            }
            return try FormAdmin.json(.created, ConfirmationBody(confirmationId: id.uuidString.lowercased(), expiresAt: iso(expires)))
        }

        form.post("releases") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), formID = try FormAdmin.uuidParam(req, "formId")
            let account = s.accountID!
            guard let rawKey = req.headers.first(name: "Idempotency-Key")?.trimmingCharacters(in: .whitespacesAndNewlines), (1...190).contains(rawKey.utf8.count) else { throw Abort(.badRequest) }
            struct B: Decodable { let draftId: String; let revision: Int; let hash: String; let confirmationId: String; let rebind: JSONAnyIgnored? }
            let b: B = try FormAdmin.decodeStrict(req, allowed: ["draftId", "revision", "hash", "confirmationId", "rebind"])
            guard b.revision >= 1, Hex64.valid(b.hash), let draftID = lowerUUID(b.draftId), let confirmationID = lowerUUID(b.confirmationId) else { throw Abort(.badRequest) }
            if b.rebind != nil { throw ValidationFailed(detail: "rebind wird in dieser Version nicht unterstützt (Domainbindungen bleiben unverändert)") }
            let exists = try await sql.raw("SELECT COUNT(*) AS c FROM forms WHERE id = \(bind: DB.bin(formID)) AND customer_id = \(bind: DB.bin(tenant))").first(decoding: FormAdmin.CountRow.self)?.c == 1
            try await perms.authorize(account: account, "release.publish", on: .form(customer: tenant, form: formID), exists: exists)

            let keyDigest = Blob(Data(SHA256.hash(data: Data(rawKey.utf8))))
            let requestDigest = Blob(DocHash.sha256(.object(["confirmationId": .string(b.confirmationId), "draftId": .string(b.draftId), "hash": .string(b.hash), "revision": .int(Int64(b.revision))])))
            struct Idem: Decodable { let request_digest: Blob; let result_id: Blob; let state: String }
            func existing() async throws -> Idem? {
                try await sql.raw("""
                    SELECT request_digest, result_id, state FROM admin_action_idempotency
                    WHERE actor_kind = 'account' AND actor_id = \(bind: DB.bin(account)) AND customer_id = \(bind: DB.bin(tenant)) AND action_name = 'publishRelease'
                      AND target_id = \(bind: DB.bin(formID)) AND key_digest = \(bind: keyDigest)
                    """).first(decoding: Idem.self)
            }
            func replay(_ e: Idem) async throws -> Response {
                guard e.request_digest == requestDigest, e.state == "complete", let rid = DB.uuid(e.result_id.data) else { throw Abort(.conflict) }
                return try await releaseResponse(sql, .ok, tenant: tenant, form: formID, release: rid)
            }
            if let e = try await existing() { return try await replay(e) }

            let t0 = now()
            do {
                let releaseID: UUID = try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    let ts = DB.time(t0)
                    let releaseID = UUID()
                    // Reserve the key first: a concurrent duplicate blocks here and then fails with 1062.
                    try await tx.raw("""
                        INSERT INTO admin_action_idempotency (actor_kind, actor_id, customer_id, action_name, target_id, key_digest, request_digest, result_id, state, fence, created_at)
                        VALUES ('account', \(bind: DB.bin(account)), \(bind: DB.bin(tenant)), 'publishRelease', \(bind: DB.bin(formID)), \(bind: keyDigest), \(bind: requestDigest),
                          \(bind: DB.bin(releaseID)), 'complete', 0, \(bind: ts))
                        """).run()
                    struct FormLock: Decodable { let active: Int }
                    guard try await tx.raw("SELECT active FROM forms WHERE id = \(bind: DB.bin(formID)) AND customer_id = \(bind: DB.bin(tenant)) FOR UPDATE").first(decoding: FormLock.self) != nil else { throw Abort(.notFound) }
                    // No go-live without a retention period (ADR 0012 no. 2): 409 with the reason; the transaction (incl. the idempotency key) rolls back.
                    struct Cnt: Decodable { let c: Int }
                    guard try await tx.raw("SELECT COUNT(*) AS c FROM settings WHERE scope_key = \(bind: Retention.scopeKey(formID)) AND setting_key = \(bind: Retention.settingKey)").first(decoding: Cnt.self)?.c == 1 else { throw RetentionProblem.missing }
                    // Confirmation: bound to this session, account, form, draft revision and hash; single use; unexpired.
                    struct Conf: Decodable { let session_id: Blob; let account_id: Blob; let draft_id: Blob; let draft_revision: UInt64; let candidate_sha256: Blob; let expires_at: Date; let consumed_at: Date?; let revoked_at: Date? }
                    guard let c = try await tx.raw("""
                        SELECT session_id, account_id, draft_id, draft_revision, candidate_sha256, expires_at, consumed_at, revoked_at FROM publication_confirmations
                        WHERE id = \(bind: DB.bin(confirmationID)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(formID)) FOR UPDATE
                        """).first(decoding: Conf.self) else { throw Abort(.notFound) }
                    guard c.session_id.data == DB.bin(s.id).data, c.account_id.data == DB.bin(account).data, c.draft_id.data == DB.bin(draftID).data,
                          c.consumed_at == nil, c.revoked_at == nil else { throw Abort(.conflict) }
                    guard c.expires_at > t0 else { throw Abort(.gone) }
                    guard let row = try await DraftStore.load(tx, tenant: tenant, form: formID, draft: draftID, forUpdate: true) else { throw Abort(.notFound) }
                    // All row locks are taken (idempotency insert, form, confirmation, draft); only now plain reads (snapshot) follow.
                    try await PermissionService(sql: tx).authorize(account: account, "release.publish", on: .form(customer: tenant, form: formID))
                    let actual = Data(SHA256.hash(data: Data(row.document_json.utf8)))
                    guard row.revision == UInt64(b.revision), row.revision == c.draft_revision, actual == row.document_sha256.data, actual == c.candidate_sha256.data, DocHash.hex(actual) == b.hash else { throw Abort(.conflict) }
                    let document = try JCS.parse(Data(row.document_json.utf8))
                    let checked: DocumentValidator.Checked
                    do { checked = try DocumentValidator.check(document, tenant: tenant, form: formID) } catch let e as DocumentInvalid { throw ValidationFailed(e) }

                    // Immutable versions.
                    let formSemver = checked.form["version"]!.string!, flowSemver = checked.flow["version"]!.string!
                    let formHash = DocHash.sha256(checked.form), flowHash = DocHash.sha256(checked.flow)
                    let formV = try await version(tx, tenant: tenant, kind: "form", id: formID, semver: formSemver, hash: formHash)
                    if formV.isNew {
                        let sec = checked.form["security"]!, st = checked.form["storage"]!
                        try await tx.raw("""
                            INSERT INTO form_versions (customer_id, form_id, version_no, contract_version, definition_json, definition_sha256, encryption_profile, transport_policy, validation_profile,
                              legacy_adapter_ref, special_categories, storage_backend, storage_connection_id, max_upload_bytes, created_by, created_at)
                            VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(formID)), \(bind: Int(formV.no)), '0.1.0', \(bind: canonicalText(checked.form)), \(bind: Blob(formHash)), 'hpke-v2',
                              \(bind: sec["transport"]?.string ?? "off"), 'typed-v1', NULL, \(bind: sec["specialCategories"]!.bool! ? 1 : 0), 'db', NULL, \(bind: Int(st["maxSubmissionBytes"]!.int!)),
                              \(bind: DB.bin(account)), \(bind: ts))
                            """).run()
                    }
                    let flowV = try await version(tx, tenant: tenant, kind: "workflow", id: checked.flowID, semver: flowSemver, hash: flowHash)
                    if flowV.isNew {
                        try await tx.raw("""
                            INSERT INTO workflow_versions (customer_id, workflow_id, version_no, contract_version, graph_json, graph_sha256, created_at)
                            VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(checked.flowID)), \(bind: Int(flowV.no)), '0.1.0', \(bind: canonicalText(checked.flow)), \(bind: Blob(flowHash)), \(bind: ts))
                            """).run()
                    }
                    var viewRefs: [(id: UUID, no: UInt64)] = []
                    for (i, v) in checked.views.enumerated() {
                        let h = DocHash.sha256(v)
                        let vv = try await version(tx, tenant: tenant, kind: "view", id: checked.viewIDs[i], semver: v["version"]!.string!, hash: h)
                        if vv.isNew {
                            try await tx.raw("""
                                INSERT INTO view_versions (customer_id, form_id, view_id, version_no, contract_version, definition_json, definition_sha256, created_at)
                                VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(formID)), \(bind: DB.bin(checked.viewIDs[i])), \(bind: Int(vv.no)), '0.1.0', \(bind: canonicalText(v)), \(bind: Blob(h)), \(bind: ts))
                                """).run()
                        }
                        viewRefs.append((checked.viewIDs[i], vv.no))
                    }
                    // Manifest = references of everything the release resolves (no modules/blocks/scripts in this scope).
                    func ref(_ id: UUID, _ v: JSONValue, _ h: Data) -> JSONValue { .object(["id": .string(DraftStore.lower(id)), "version": v, "sha256": .string(DocHash.hex(h))]) }
                    let used = Set((checked.flow["nodes"]?.object ?? [:]).values.compactMap { $0["block"]?["id"]?.string })
                    let blockRefs = try used.sorted().map { try FlowDefinition.builtinReference(id: $0) }
                    let moduleRefs: [JSONValue] = used.isEmpty ? [] : try FlowDefinition.builtinModules.map { data in
                        let module = try JCS.parse(data)
                        return .object(["id": module["id"]!, "version": module["version"]!, "sha256": .string(DocHash.hex(Data(SHA256.hash(data: data))))])
                    }
                    let manifest: JSONValue = .object([
                        "blocks": .array(blockRefs), "modules": .array(moduleRefs), "sandboxProfiles": .array([]), "scripts": .array([]),
                        "form": ref(formID, checked.form["version"]!, formHash), "flow": ref(checked.flowID, checked.flow["version"]!, flowHash),
                        "views": .array(zip(checked.viewIDs, checked.views).map { ref($0, $1["version"]!, DocHash.sha256($1)) }),
                    ])
                    struct N: Decodable { let n: Int }
                    let releaseNo = (try await tx.raw("SELECT COALESCE(MAX(release_version_no), 0) AS n FROM releases WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(formID))").first(decoding: N.self)?.n ?? 0) + 1
                    let auditID = UUID()
                    try await audit(tx, tenant: tenant, form: formID, actor: account, action: "release.publish", subject: releaseID, at: ts, id: auditID).run()
                    try await tx.raw("""
                        INSERT INTO releases (id, customer_id, form_id, form_version_no, workflow_id, workflow_version_no, release_version_no, dependency_manifest_json, manifest_sha256,
                          confirmed_by, confirmed_at, confirmation_audit_id)
                        VALUES (\(bind: DB.bin(releaseID)), \(bind: DB.bin(tenant)), \(bind: DB.bin(formID)), \(bind: Int(formV.no)), \(bind: DB.bin(checked.flowID)), \(bind: Int(flowV.no)), \(bind: releaseNo),
                          \(bind: canonicalText(manifest)), \(bind: Blob(DocHash.sha256(manifest))), \(bind: DB.bin(account)), \(bind: ts), \(bind: DB.bin(auditID)))
                        """).run()
                    for r in viewRefs {
                        try await tx.raw("""
                            INSERT INTO release_views (customer_id, form_id, release_id, view_id, view_version_no)
                            VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(formID)), \(bind: DB.bin(releaseID)), \(bind: DB.bin(r.id)), \(bind: Int(r.no)))
                            """).run()
                    }
                    try await tx.raw("UPDATE publication_confirmations SET consumed_at = \(bind: ts), release_id = \(bind: DB.bin(releaseID)) WHERE id = \(bind: DB.bin(confirmationID))").run()
                    // First successful publication activates the form (ADR 0009 F8); later ones only move the pointer.
                    try await tx.raw("UPDATE forms SET current_release_id = \(bind: DB.bin(releaseID)), active = 1 WHERE id = \(bind: DB.bin(formID))").run()
                    return releaseID
                }
                return try await releaseResponse(sql, .created, tenant: tenant, form: formID, release: releaseID)
            } catch {
                // Lost the race for the same key: the winner committed, evaluate its row.
                if DB.isDuplicateKey(error), let e = try await existing() { return try await replay(e) }
                throw error
            }
        }
    }

    // MARK: helpers

    /// Resolves (kind, id, semver) to a local version number; same semver with other content is a conflict.
    static func version(_ tx: SQLDatabase, tenant: UUID, kind: String, id: UUID, semver: String, hash: Data) async throws -> (no: UInt64, isNew: Bool) {
        struct R: Decodable { let version_no: UInt64; let content_sha256: Blob }
        if let r = try await tx.raw("""
            SELECT version_no, content_sha256 FROM resource_versions
            WHERE customer_id = \(bind: DB.bin(tenant)) AND resource_kind = \(bind: kind) AND resource_id = \(bind: DB.bin(id)) AND semantic_version = \(bind: semver) FOR UPDATE
            """).first(decoding: R.self) {
            guard r.content_sha256.data == hash else { throw VersionConflict(kind: kind == "workflow" ? "Ablauf" : kind == "view" ? "Ansicht" : "Formular") }
            return (r.version_no, false)
        }
        struct N: Decodable { let n: Int }
        var next = (try await tx.raw("SELECT COALESCE(MAX(version_no), 0) AS n FROM resource_versions WHERE customer_id = \(bind: DB.bin(tenant)) AND resource_kind = \(bind: kind) AND resource_id = \(bind: DB.bin(id))").first(decoding: N.self)?.n ?? 0) + 1
        if kind == "form" {
            // An imported form already holds form_versions rows (version 1, contract "migration-review") that have no
            // resource_versions entry: the next number must lie above them, otherwise the release collides (duplicate key).
            let taken = try await tx.raw("SELECT COALESCE(MAX(version_no), 0) AS n FROM form_versions WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(id))").first(decoding: N.self)?.n ?? 0
            next = max(next, taken + 1)
        }
        try await tx.raw("""
            INSERT INTO resource_versions (customer_id, resource_kind, resource_id, semantic_version, version_no, content_sha256)
            VALUES (\(bind: DB.bin(tenant)), \(bind: kind), \(bind: DB.bin(id)), \(bind: semver), \(bind: next), \(bind: Blob(hash)))
            """).run()
        return (UInt64(next), true)
    }

    static func canonicalText(_ v: JSONValue) -> String { String(decoding: JCS.canonicalize(v), as: UTF8.self) }
    static func lowerUUID(_ s: String) -> UUID? { s == s.lowercased() && s.count == 36 ? UUID(uuidString: s) : nil }
    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d) }

    static func audit(_ tx: SQLDatabase, tenant: UUID, form: UUID?, actor: UUID, action: String, subject: UUID, at: String, id: UUID = UUID(), category: String = "release") -> SQLRawBuilder {
        tx.raw("""
            INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
            VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(tenant)), \(bind: form.map(DB.bin)), \(bind: DB.bin(actor)), 'human', \(bind: category), \(bind: action), \(bind: DB.bin(subject)), \(bind: at), '{}')
            """)
    }

    /// authenticated_at of the session; throws when older than the freshness window.
    static func freshAuthentication(_ sql: SQLDatabase, session: UUID, now: Date) async throws -> Date {
        struct R: Decodable { let authenticated_at: Date? }
        guard let at = try await sql.raw("SELECT authenticated_at FROM sessions WHERE id = \(bind: DB.bin(session))").first(decoding: R.self)?.authenticated_at,
              now.timeIntervalSince(at) <= freshness else { throw ReauthenticationRequired() }
        return at
    }

    /// Release body per flow/release.schema.json, rebuilt from the immutable rows (also used for replays).
    static func releaseResponse(_ sql: SQLDatabase, _ status: HTTPResponseStatus, tenant: UUID, form: UUID, release: UUID) async throws -> Response {
        struct R: Decodable { let form_version_no: UInt64; let workflow_id: Blob; let workflow_version_no: UInt64; let release_version_no: UInt64; let confirmation_audit_id: Blob; let confirmed_at: Date; let dependency_manifest_json: String }
        struct Ver: Decodable { let definition_json: String; let definition_sha256: Blob }
        struct G: Decodable { let graph_json: String; let graph_sha256: Blob }
        struct V: Decodable { let view_id: Blob; let definition_json: String; let definition_sha256: Blob }
        guard let r = try await sql.raw("SELECT form_version_no, workflow_id, workflow_version_no, release_version_no, confirmation_audit_id, confirmed_at, dependency_manifest_json FROM releases WHERE id = \(bind: DB.bin(release)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").first(decoding: R.self),
              let f = try await sql.raw("SELECT definition_json, definition_sha256 FROM form_versions WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND version_no = \(bind: Int(r.form_version_no))").first(decoding: Ver.self),
              let g = try await sql.raw("SELECT graph_json, graph_sha256 FROM workflow_versions WHERE customer_id = \(bind: DB.bin(tenant)) AND workflow_id = \(bind: r.workflow_id) AND version_no = \(bind: Int(r.workflow_version_no))").first(decoding: G.self)
        else { throw Abort(.notFound) }
        let views = try await sql.raw("""
            SELECT v.view_id AS view_id, v.definition_json AS definition_json, v.definition_sha256 AS definition_sha256 FROM release_views rv
            JOIN view_versions v ON v.customer_id = rv.customer_id AND v.form_id = rv.form_id AND v.view_id = rv.view_id AND v.version_no = rv.view_version_no
            WHERE rv.release_id = \(bind: DB.bin(release)) ORDER BY rv.view_id
            """).all(decoding: V.self)
        func ref(_ id: UUID, _ json: String, _ h: Blob) throws -> JSONValue {
            .object(["id": .string(DraftStore.lower(id)), "version": try JCS.parse(Data(json.utf8))["version"] ?? .null, "sha256": .string(DocHash.hex(h.data))])
        }
        let dependencies = try JCS.parse(Data(r.dependency_manifest_json.utf8))
        let body: JSONValue = .object([
            "contractVersion": .string("0.1.0"), "proposalStatus": .string("VORGESCHLAGEN"), "id": .string(DraftStore.lower(release)), "tenantId": .string(DraftStore.lower(tenant)),
            "form": try ref(form, f.definition_json, f.definition_sha256),
            "views": .array(try views.map { try ref(DB.uuid($0.view_id.data)!, $0.definition_json, $0.definition_sha256) }),
            "flow": try ref(DB.uuid(r.workflow_id.data)!, g.graph_json, g.graph_sha256),
            "modules": dependencies["modules"] ?? .array([]), "blocks": dependencies["blocks"] ?? .array([]), "scripts": dependencies["scripts"] ?? .array([]), "sandboxProfiles": dependencies["sandboxProfiles"] ?? .array([]),
            "publication": .object(["actorKind": .string("human"), "confirmationAuditId": .string(DraftStore.lower(DB.uuid(r.confirmation_audit_id.data)!)), "confirmedAt": .string(iso(r.confirmed_at))]),
            "version": .string("\(r.release_version_no).0.0"),
        ])
        let res = Response(status: status)
        res.body = .init(data: JCS.canonicalize(body))
        res.headers.contentType = .json
        return res
    }
}

struct ConfirmationBody: Encodable { let confirmationId: String; let expiresAt: String }

/// Decodes any JSON value and discards it (only its presence matters).
struct JSONAnyIgnored: Decodable { init(from decoder: Decoder) throws { _ = try? decoder.singleValueContainer() } }
