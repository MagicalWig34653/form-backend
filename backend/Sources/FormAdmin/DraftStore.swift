// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormPersistence
import Foundation
import SQLKit

/// Draft documents: the standard document for a new form (ADR 0009 F2), reconstruction from a release, and the
/// `form_drafts` row access. The document is stored as RFC 8785 canonical text, so `document_sha256` is the hash of
/// exactly the stored bytes.
enum DraftStore {
    static func lower(_ u: UUID) -> String { u.uuidString.lowercased() }

    /// Standard document of a new form: one optional text field, one standard view, the empty flow entry -> end.
    /// `specialCategories` is a placeholder `false` until the editor sets it (ADR 0009 F3); the form is not a
    /// production configuration before a human reviews and publishes it.
    static func standardDocument(tenant: UUID, form: UUID, name: String) -> JSONValue {
        let formObj: JSONValue = .object([
            "contractVersion": .string("0.1.0"), "proposalStatus": .string("VORGESCHLAGEN"),
            "id": .string(lower(form)), "version": .string("1.0.0"), "tenantId": .string(lower(tenant)),
            "title": .object(["de": .string(name)]),
            "unknownFields": .string("reject"), "normalization": .string("typed-v1"),
            "fields": .object(["message": .object([
                "name": .string("nachricht"), "kind": .string("text"), "label": .object(["de": .string("Nachricht")]),
                "required": .bool(false), "hidden": .bool(false), "locked": .bool(false), "sensitive": .bool(false),
                "validation": .object(["type": .string("string")]),
            ])]),
            "security": .object(["encryptionProfile": .string("hpke-v2"), "specialCategories": .bool(false)]),
            "storage": .object(["adapter": .string("db"), "maxSubmissionBytes": .int(10_485_760), "onFailure": .string("reject-acceptance")]),
        ])
        let formHash = DocHash.hex(DocHash.sha256(formObj))
        let view: JSONValue = .object([
            "contractVersion": .string("0.1.0"), "proposalStatus": .string("VORGESCHLAGEN"),
            "id": .string(lower(UUID())), "version": .string("1.0.0"),
            "form": .object(["id": .string(lower(form)), "version": .string("1.0.0"), "sha256": .string(formHash)]),
            "title": .object(["de": .string(name)]),
            "theme": .object(["id": .string("standard"), "version": .string("1.0.0"), "parameters": .object([:])]),
            "steps": .array([.object(["id": .string("main"), "title": .object(["de": .string("Formular")]), "sections": .array([
                .object(["id": .string("main"), "title": .object(["de": .string("Angaben")]), "fields": .array([
                    .object(["fieldId": .string("message"), "readOnly": .bool(false), "disabled": .bool(false)]),
                ])]),
            ])])]),
        ])
        let flow: JSONValue = .object([
            "contractVersion": .string("0.1.0"), "proposalStatus": .string("VORGESCHLAGEN"),
            "id": .string(lower(UUID())), "version": .string("1.0.0"), "engineContractVersion": .string("0.1.0"),
            "entryNode": .string("entry"), "failurePolicy": .string("stop-and-record"),
            "limits": .object(["maxSteps": .int(1000), "activeTimeoutMs": .int(30_000), "maxElapsedMs": .int(86_400_000),
                               "memoryBytes": .int(67_108_864), "nodeTimeoutMs": .int(5_000), "maxStateBytes": .int(1_048_576)]),
            "nodes": .object([
                "entry": .object(["kind": .string("entry"), "label": .object(["de": .string("Eingang")])]),
                "end": .object(["kind": .string("end"), "label": .object(["de": .string("Erfolg")]), "result": .string("success")]),
            ]),
            "edges": .array([.object(["from": .string("entry"), "port": .string("next"), "to": .string("end")])]),
        ])
        return .object(["form": formObj, "flow": flow, "views": .array([view])])
    }

    struct DraftRow: Decodable { let id: Blob; let revision: UInt64; let document_json: String; let document_sha256: Blob; let base_release_id: Blob? }

    static func insert(_ tx: SQLDatabase, tenant: UUID, form: UUID, account: UUID, document: JSONValue, base: UUID?, now: String) async throws -> (id: UUID, hash: Data) {
        let id = UUID()
        let canonical = JCS.canonicalize(document)
        let hash = Data(SHA256.hash(data: canonical))
        try await tx.raw("""
            INSERT INTO form_drafts (id, customer_id, form_id, revision, base_release_id, document_json, document_sha256, created_by, created_at, updated_by, updated_at)
            VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), 1, \(bind: base.map(DB.bin)), \(bind: String(decoding: canonical, as: UTF8.self)),
              \(bind: Blob(hash)), \(bind: DB.bin(account)), \(bind: now), \(bind: DB.bin(account)), \(bind: now))
            """).run()
        return (id, hash)
    }

    static func load(_ sql: SQLDatabase, tenant: UUID, form: UUID, draft: UUID, forUpdate: Bool = false) async throws -> DraftRow? {
        try await sql.raw("""
            SELECT id, revision, document_json, document_sha256, base_release_id FROM form_drafts
            WHERE id = \(bind: DB.bin(draft)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) \(unsafeRaw: forUpdate ? "FOR UPDATE" : "")
            """).first(decoding: DraftRow.self)
    }

    /// Body of the `Draft` schema; the document text is embedded verbatim (it is already canonical JSON).
    static func draftBody(id: UUID, revision: UInt64, hash: Data, canonicalDocument: String) -> Data {
        Data("{\"document\":\(canonicalDocument),\"hash\":\"\(DocHash.hex(hash))\",\"id\":\"\(lower(id))\",\"revision\":\(revision)}".utf8)
    }

    /// Rebuilds the document of a release from its immutable version rows.
    static func documentOfRelease(_ sql: SQLDatabase, tenant: UUID, form: UUID, release: UUID) async throws -> JSONValue? {
        struct R: Decodable { let form_version_no: UInt64; let workflow_id: Blob; let workflow_version_no: UInt64 }
        struct F: Decodable { let definition_json: String }
        struct G: Decodable { let graph_json: String }
        struct V: Decodable { let definition_json: String }
        guard let r = try await sql.raw("""
            SELECT form_version_no, workflow_id, workflow_version_no FROM releases
            WHERE id = \(bind: DB.bin(release)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))
            """).first(decoding: R.self),
              let f = try await sql.raw("SELECT definition_json FROM form_versions WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND version_no = \(bind: Int(r.form_version_no))").first(decoding: F.self),
              let g = try await sql.raw("SELECT graph_json FROM workflow_versions WHERE customer_id = \(bind: DB.bin(tenant)) AND workflow_id = \(bind: r.workflow_id) AND version_no = \(bind: Int(r.workflow_version_no))").first(decoding: G.self)
        else { return nil }
        let views = try await sql.raw("""
            SELECT v.definition_json AS definition_json FROM release_views rv
            JOIN view_versions v ON v.customer_id = rv.customer_id AND v.form_id = rv.form_id AND v.view_id = rv.view_id AND v.version_no = rv.view_version_no
            WHERE rv.release_id = \(bind: DB.bin(release)) ORDER BY rv.view_id
            """).all(decoding: V.self)
        return .object([
            "form": try JCS.parse(Data(f.definition_json.utf8)), "flow": try JCS.parse(Data(g.graph_json.utf8)),
            "views": .array(try views.map { try JCS.parse(Data($0.definition_json.utf8)) }),
        ])
    }
}

