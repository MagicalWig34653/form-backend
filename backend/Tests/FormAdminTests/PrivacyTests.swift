// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormAuth
import FormCore
@testable import FormCrypto
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// Deletion, hold, retention and ciphertext export through the real routes (ADR 0012).
final class PrivacyTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }

    private struct World { let tenant: UUID; let form: String; let admin: TestClient; let root: UUID; let user: UUID; let seed: Data; let sk: Curve25519.KeyAgreement.PrivateKey }

    private func world(_ f: AdminFixture, rights: [String]) async throws -> World {
        let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
        for r in ["form.create", "form.read", "draft.write", "release.publish", "key.manage"] + Array(Set(rights + (rights.contains("content.hold") ? ["content.decrypt"] : []))) { try await f.grant(user, r, customer: tenant, by: root) }
        let c = try await f.login(user)
        var form = "", draft = "", hash = "", conf = ""
        try await c.post("tenants/\(tenant)/forms", "{\"name\":\"Kontakt\"}") { form = obj($0)["id"] as? String ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)") { draft = (obj($0)["draftIds"] as? [String])?.first ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { hash = obj($0)["hash"] as? String ?? "" }
        try await c.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { conf = obj($0)["confirmationId"] as? String ?? "" }
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(conf)\"}", headers: ["Idempotency-Key": "k"]) { XCTAssertEqual($0.status, .created) }
        let sk = Curve25519.KeyAgreement.PrivateKey()
        try await f.sql.raw("INSERT INTO account_keys (account_id, public_key, created_at) VALUES (\(bind: DB.bin(user)), \(bind: Blob(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)), NOW(6))").run()
        let b64 = { (n: Int) in Data(repeating: 7, count: n).base64URLString }
        let provision: [String: Any] = ["publicKey": sk.publicKey.rawRepresentation.base64URLString, "access": ["enc": b64(32), "sealed": b64(48)], "recovery": ["salt": b64(32), "iterations": 600000, "iv": b64(12), "wrap": b64(48)]]
        try await c.send(.PUT, "tenants/\(tenant)/customer-key", body: String(decoding: JSONSerialization.data(withJSONObject: provision), as: UTF8.self)) { XCTAssertEqual($0.status, .created) }
        var seed = Data()
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: obj($0)["signingSeed"] as? String ?? "") ?? Data() }
        return World(tenant: tenant, form: form, admin: c, root: root, user: user, seed: seed, sk: sk)
    }

    private func submit(_ f: AdminFixture, _ w: World, _ marker: String, key: String) async throws -> String {
        let pairs = [("nachricht", marker)]
        let canonical = try RequestSignature.canonical(fields: PHPValue.array(pairs.map { ($0.0, PHPValue.string($0.1)) }))
        let stamp = String(Int64(Date().timeIntervalSince1970))
        let sig = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: w.form, timestamp: stamp, canonical: canonical), seed: w.seed)
        var h = HTTPHeaders()
        h.contentType = .urlEncodedForm
        h.add(name: "X-Kubus-Timestamp", value: stamp); h.add(name: "X-Kubus-Signature", value: sig.base64EncodedString()); h.add(name: "Idempotency-Key", value: key)
        let body = pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" }.joined(separator: "&")
        var id = ""
        try await f.app.test(.POST, "api/v2/submit/?f=\(w.form)", headers: h, body: ByteBuffer(string: body)) { res async throws in
            XCTAssertEqual(res.status, .ok, text(res)); id = ((obj(res)["submission"] as? [String: Any])?["id"] as? String) ?? ""
        }
        return id
    }

    /// Builds the complete current proof list and wraps only CEKs under the customer's symmetric long-term key.
    private func holdBody(_ w: World, entry: String, held: Bool, replacements: Bool = true) async throws -> String {
        var items: [[String: Any]] = []
        try await w.admin.get("tenants/\(w.tenant)/forms/\(w.form)/entries/\(entry)/hold-objects") { r async throws in
            XCTAssertEqual(r.status, .ok, text(r)); items = obj(r)["items"] as? [[String: Any]] ?? []
        }
        var proofs: [[String: Any]] = []
        for item in items {
            var proof: [String: Any] = ["objectId": item["id"]!, "expectedRevision": item["revision"]!, "expectedSha256": item["ciphertext_sha256"]!, "sourceGenerationId": item["sourceGenerationId"]!]
            if held && replacements, let wire = item["package"] as? String {
                let p = try PackageV2(wire)
                if p.wrap == "hpke" {
                    let cek = try HPKE.open(p.b, enc: p.a, recipient: w.sk, info: Data("kubus-anfrage v2".utf8), aad: Data(p.kid.utf8))
                    let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: w.sk.rawRepresentation), salt: Data(), info: Data("kubus-langzeit v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
                    let iv = AES.GCM.Nonce().withUnsafeBytes { Data($0) }
                    let wrapped = try sealGCM(cek, key: key, nonce: iv, aad: Data(p.kid.utf8))
                    proof["replacementPackage"] = "KUBUS-AEAD:2|\(p.kid)|sym|\(iv.base64EncodedString()):\(wrapped.base64EncodedString())|\(p.iv.base64EncodedString())|\(p.ciphertext.base64EncodedString())|\(p.tag.base64EncodedString())"
                }
            }
            proofs.append(proof)
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["held": held, "objects": proofs]), as: UTF8.self)
    }

    private func count(_ f: AdminFixture, _ table: String) async throws -> Int {
        try await f.sql.raw("SELECT COUNT(*) AS c FROM \(unsafeRaw: table)").first(decoding: C.self)?.c ?? -1
    }

    func testDeletionNeedsRightHoldBlocksItAndLeavesAProof() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, rights: ["content.read", "content.hold"])  // no content.delete yet
            let a = try await submit(f, w, "DEL-A", key: "a"), b = try await submit(f, w, "DEL-B", key: "b")
            let base = "tenants/\(w.tenant)/forms/\(w.form)/entries"
            try await w.admin.send(.DELETE, "\(base)/\(a)") { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(w.user, "content.delete", customer: w.tenant, by: w.root)
            // a held submission is not deleted, not even on request
            try await w.admin.send(.PUT, "\(base)/\(a)/hold", body: try await holdBody(w, entry: a, held: true)) { XCTAssertEqual($0.status, .ok, text($0)) }
            try await w.admin.send(.DELETE, "\(base)/\(a)") { XCTAssertEqual($0.status, .conflict) }
            try await w.admin.post("\(base)/delete", "{\"ids\":[\"\(a)\",\"\(b)\",\"\(UUID().uuidString.lowercased())\"]}") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res))
                XCTAssertEqual(obj(res)["deleted"] as? [String], [b]); XCTAssertEqual(obj(res)["held"] as? [String], [a]); XCTAssertEqual((obj(res)["missing"] as? [String])?.count, 1)
            }
            var n = try await count(f, "submissions"); XCTAssertEqual(n, 1)
            n = try await count(f, "stored_objects"); XCTAssertEqual(n, 1)
            // proof stays, without content
            struct D: Decodable { let reason_code: String; let deleted_count: Int; let safe_snapshot_json: String }
            let rec = try await f.sql.raw("SELECT reason_code, deleted_count, safe_snapshot_json FROM deletion_records").all(decoding: D.self)
            XCTAssertEqual(rec.count, 1); XCTAssertEqual(rec[0].reason_code, "request"); XCTAssertEqual(rec[0].safe_snapshot_json, "{}")
            // release the hold, delete for real; a second delete is 404
            try await w.admin.send(.PUT, "\(base)/\(a)/hold", body: try await holdBody(w, entry: a, held: false)) { XCTAssertEqual($0.status, .ok) }
            try await w.admin.send(.DELETE, "\(base)/\(a)") { XCTAssertEqual($0.status, .noContent) }
            try await w.admin.send(.DELETE, "\(base)/\(a)") { XCTAssertEqual($0.status, .notFound) }
            n = try await count(f, "submissions"); XCTAssertEqual(n, 0)
            n = try await count(f, "deletion_records"); XCTAssertEqual(n, 2)
            // replaying the same request must not bring the content back
            let pairs = [("nachricht", "DEL-A")]
            let canonical = try RequestSignature.canonical(fields: PHPValue.array(pairs.map { ($0.0, PHPValue.string($0.1)) }))
            let stamp = String(Int64(Date().timeIntervalSince1970))
            let sig = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: w.form, timestamp: stamp, canonical: canonical), seed: w.seed)
            var h = HTTPHeaders()
            h.contentType = .urlEncodedForm
            h.add(name: "X-Kubus-Timestamp", value: stamp); h.add(name: "X-Kubus-Signature", value: sig.base64EncodedString()); h.add(name: "Idempotency-Key", value: "a")
            try await f.app.test(.POST, "api/v2/submit/?f=\(w.form)", headers: h, body: ByteBuffer(string: "nachricht=DEL%2DA")) { XCTAssertEqual($0.status, .conflict) }
            n = try await count(f, "submissions"); XCTAssertEqual(n, 0)
            struct A: Decodable { let action_code: String }
            let acts = try await f.sql.raw("SELECT action_code FROM audit_events WHERE category = 'privacy'").all(decoding: A.self).map(\.action_code)
            XCTAssertTrue(acts.contains("content.hold.set") && acts.contains("content.hold.clear") && acts.contains("content.delete"))
            // a form-only grant is enough for the content rights, but plain readers are not
            let reader = try await f.account()
            try await f.grant(reader, "content.read", customer: w.tenant, form: UUID(uuidString: w.form)!, by: w.root)
            let rc = try await f.login(reader)
            try await rc.send(.PUT, "\(base)/\(b)/hold", body: "{\"held\":true}") { XCTAssertEqual($0.status, .forbidden) }
            try await rc.post("\(base)/delete", "{\"ids\":[\"\(b)\"]}") { XCTAssertEqual($0.status, .forbidden) }
        }
    }

    func testRetentionPolicyDueDatesAndThePurgeJob() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, rights: ["content.read", "content.hold"])
            let policy = "tenants/\(w.tenant)/forms/\(w.form)/retention"
            // the policy is a customer-level privacy right; a content right is not enough
            try await w.admin.send(.PUT, policy, body: "{\"days\":30}") { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(w.user, "privacy.manage", customer: w.tenant, by: w.root)
            let old = try await submit(f, w, "RET-OLD", key: "old"), kept = try await submit(f, w, "RET-HELD", key: "held")
            try await w.admin.send(.PUT, policy, body: "{\"days\":0}") { XCTAssertEqual($0.status.code, 422) }
            try await w.admin.send(.PUT, policy, body: "{\"days\":\"30\"}") { XCTAssertEqual($0.status.code, 422) }
            try await w.admin.send(.PUT, policy, body: "{}") { XCTAssertEqual($0.status.code, 422) }
            try await w.admin.send(.PUT, policy, body: "{\"days\":30}") { XCTAssertEqual($0.status, .ok, text($0)); XCTAssertEqual(obj($0)["days"] as? Int, 30) }
            try await w.admin.get(policy) { XCTAssertEqual(obj($0)["days"] as? Int, 30) }
            // existing rows got a due date; a submission made now gets one too
            let fresh = try await submit(f, w, "RET-NEW", key: "new")
            struct Due: Decodable { let n: Int }
            let withDue = try await f.sql.raw("SELECT COUNT(*) AS n FROM submissions WHERE retention_due_at IS NOT NULL").first(decoding: Due.self)?.n
            XCTAssertEqual(withDue, 3)
            try await w.admin.send(.PUT, "tenants/\(w.tenant)/forms/\(w.form)/entries/\(kept)/hold", body: try await holdBody(w, entry: kept, held: true)) { XCTAssertEqual($0.status, .ok) }
            // before the due date nothing happens; after it, only the not held ones go
            var n = try await SubmissionEraser.purgeDue(db: f.app.db(.mysql), now: Date().addingTimeInterval(29 * 86_400)); XCTAssertEqual(n, 0)
            n = try await SubmissionEraser.purgeDue(db: f.app.db(.mysql), now: Date().addingTimeInterval(31 * 86_400)); XCTAssertEqual(n, 2)
            struct Left: Decodable { let id: Blob }
            let left = try await f.sql.raw("SELECT id FROM submissions").all(decoding: Left.self).compactMap { DB.uuid($0.id.data)?.uuidString.lowercased() }
            XCTAssertEqual(left, [kept]); XCTAssertFalse(left.contains(old) || left.contains(fresh))
            struct R: Decodable { let reason_code: String; let actor_id: Blob? }
            let recs = try await f.sql.raw("SELECT reason_code, actor_id FROM deletion_records").all(decoding: R.self)
            XCTAssertEqual(recs.count, 2); XCTAssertTrue(recs.allSatisfy { $0.reason_code == "retention" && $0.actor_id == nil })
            // switching the policy off removes the due dates
            try await w.admin.send(.PUT, policy, body: "{\"days\":null}") { XCTAssertEqual($0.status, .ok); XCTAssertTrue(obj($0)["days"] is NSNull || obj($0)["days"] == nil) }
            let none = try await f.sql.raw("SELECT COUNT(*) AS n FROM submissions WHERE retention_due_at IS NOT NULL").first(decoding: Due.self)?.n
            XCTAssertEqual(none, 0)
            let again = try await SubmissionEraser.purgeDue(db: f.app.db(.mysql), now: Date().addingTimeInterval(400 * 86_400)); XCTAssertEqual(again, 0)
        }
    }

    func testCiphertextExportIsPagedAuditedAndReadableOnlyWithTheKey() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, rights: ["content.read"])
            for i in 0..<3 { _ = try await submit(f, w, "EXPORT-MARKER-\(i)", key: "e\(i)") }
            let url = "tenants/\(w.tenant)/forms/\(w.form)/export"
            try await w.admin.get(url) { XCTAssertEqual($0.status, .forbidden) }  // content.export missing
            try await f.grant(w.user, "content.export", customer: w.tenant, by: w.root)
            var packages: [String] = []
            var cursor: String? = nil
            repeat {
                var next: String? = nil
                try await w.admin.get(url + "?limit=2" + (cursor.map { "&cursor=\($0)" } ?? "")) { res async throws in
                    XCTAssertEqual(res.status, .ok, text(res)); XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                    let items = obj(res)["items"] as? [[String: Any]] ?? []
                    packages += items.compactMap { $0["package"] as? String }
                    next = obj(res)["nextCursor"] as? String
                }
                cursor = next
            } while cursor != nil
            XCTAssertEqual(packages.count, 3)
            let plains = try packages.map { String(decoding: try PackageV2($0).open(recipient: w.sk), as: UTF8.self) }
            for i in 0..<3 { XCTAssertTrue(plains.contains { $0.contains("EXPORT-MARKER-\(i)") }) }
            XCTAssertFalse(packages.joined().contains("EXPORT-MARKER"))
            struct A: Decodable { let c: Int }
            let audited = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'content.export'").first(decoding: A.self)?.c
            XCTAssertEqual(audited, 2)
            // another customer's data cannot be reached through this form's URL
            let other = try await f.customer()
            try await w.admin.get("tenants/\(other)/forms/\(w.form)/export") { XCTAssertTrue([403, 404].contains($0.status.code)) }
        }
    }

    /// Review findings (Codex Astra 3): metadata objects, debug graph and a changed retention policy.
    func testErasureTakesMetadataAndDebugGraphAndRechecksTheDueDate() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, rights: ["content.read", "content.delete", "privacy.manage"])
            let id = try await submit(f, w, "GRAPH", key: "g")
            let sub = DB.bin(UUID(uuidString: id)!), t = DB.bin(w.tenant), form = DB.bin(UUID(uuidString: w.form)!)
            let meta = DB.bin(UUID()), dbgObj = DB.bin(UUID()), dbgReq = DB.bin(UUID())
            // a sealed metadata object without submission of its own, referenced by the data object
            try await f.sql.raw("""
                INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
                SELECT \(bind: meta), customer_id, form_id, NULL, 'object-metadata', 0, 0, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state
                FROM stored_objects WHERE submission_id = \(bind: sub) AND object_role = 'data'
                """).run()
            try await f.sql.raw("UPDATE stored_objects SET metadata_object_id = \(bind: meta) WHERE submission_id = \(bind: sub) AND object_role = 'data'").run()
            // a debug recording of this submission with one sealed debug object
            try await f.sql.raw("""
                INSERT INTO debug_requests (id, customer_id, form_id, release_id, requested_by, mode, environment, state, submission_id, expires_at)
                SELECT \(bind: dbgReq), customer_id, form_id, release_id, \(bind: DB.bin(w.user)), 'observe', 'production', 'complete', id, DATE_ADD(NOW(), INTERVAL 1 HOUR) FROM submissions WHERE id = \(bind: sub)
                """).run()
            try await f.sql.raw("INSERT INTO debug_events (customer_id, form_id, debug_request_id, sequence_no, occurred_at, masked_event_json, expires_at) VALUES (\(bind: t), \(bind: form), \(bind: dbgReq), 1, NOW(), '{}', DATE_ADD(NOW(), INTERVAL 1 HOUR))").run()
            try await f.sql.raw("""
                INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, expires_at, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
                SELECT \(bind: dbgObj), customer_id, form_id, NULL, 'debug', 0, 0, DATE_ADD(NOW(), INTERVAL 1 HOUR), backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state
                FROM stored_objects WHERE submission_id = \(bind: sub) AND object_role = 'data'
                """).run()
            try await f.sql.raw("INSERT INTO debug_objects (customer_id, form_id, debug_request_id, sequence_no, object_id) VALUES (\(bind: t), \(bind: form), \(bind: dbgReq), 1, \(bind: dbgObj))").run()

            // a retention pass that selected the row before the policy was lifted must not delete it
            try await f.grant(w.user, "content.hold", customer: w.tenant, by: w.root)
            try await w.admin.send(.PUT, "tenants/\(w.tenant)/forms/\(w.form)/retention", body: "{\"days\":null}") { XCTAssertEqual($0.status, .ok) }
            let late = try await f.app.db(.mysql).transaction { c in
                try await SubmissionEraser.erase(c as! SQLDatabase, tenant: w.tenant, form: UUID(uuidString: w.form)!, ids: [UUID(uuidString: id)!], reason: "retention", actor: nil, now: Date().addingTimeInterval(900 * 86_400), requireDue: true)
            }
            XCTAssertTrue(late.deleted.isEmpty)
            var n = try await count(f, "submissions"); XCTAssertEqual(n, 1)

            // the request path removes the whole graph in one go
            try await w.admin.send(.DELETE, "tenants/\(w.tenant)/forms/\(w.form)/entries/\(id)") { XCTAssertEqual($0.status, .noContent, text($0)) }
            for table in ["submissions", "stored_objects", "debug_objects", "debug_events"] { n = try await count(f, table); XCTAssertEqual(n, 0, table) }
            n = try await count(f, "debug_requests"); XCTAssertEqual(n, 1)  // the request stays, unlinked
            struct L: Decodable { let submission_id: Blob? }
            let link = try await f.sql.raw("SELECT submission_id FROM debug_requests").first(decoding: L.self)
            XCTAssertNil(link?.submission_id)
        }
    }
    func testRotationHoldRequiresCompleteCurrentInventoryAndAtomicSymmetricRewrap() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, rights: ["content.read", "content.hold"])
            let entry = try await submit(f, w, "HOLD-INVENTORY", key: "hold-list")
            let sub = DB.bin(try XCTUnwrap(UUID(uuidString: entry))), metadata = DB.bin(UUID())
            // Attachment and recursively referenced metadata must be covered even though metadata has no submission_id.
            try await f.sql.raw("""
                INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
                SELECT \(bind: DB.bin(UUID())), customer_id, form_id, submission_id, 'attachment', 0, 0, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state FROM stored_objects WHERE submission_id = \(bind: sub) AND object_role = 'data'
                """).run()
            try await f.sql.raw("""
                INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
                SELECT \(bind: metadata), customer_id, form_id, NULL, 'object-metadata', 0, 0, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state FROM stored_objects WHERE submission_id = \(bind: sub) AND object_role = 'data'
                """).run()
            try await f.sql.raw("UPDATE stored_objects SET metadata_object_id = \(bind: metadata) WHERE submission_id = \(bind: sub) AND object_role = 'data'").run()
            let url = "tenants/\(w.tenant)/forms/\(w.form)/entries/\(entry)/hold"
            // Missing/wrongly typed required members fail structural decoding (400), before any DB mutation.
            for malformed in ["{\"held\":true}", "{\"held\":true,\"objects\":null}", "{\"held\":true,\"objects\":{}}", "{\"objects\":[]}"] {
                try await w.admin.send(.PUT, url, body: malformed) {
                    XCTAssertEqual($0.status, .badRequest, text($0))
                    XCTAssertEqual(obj($0)["code"] as? String, "bad_request", text($0))
                }
                let untouched = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE customer_id = \(bind: DB.bin(w.tenant)) AND wrap_kind = 'hpke' AND revision = 0").first(decoding: C.self)?.c
                XCTAssertEqual(untouched, 3)
                let notHeld = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions WHERE id = \(bind: sub) AND removable = 1").first(decoding: C.self)?.c
                XCTAssertEqual(notHeld, 1)
                let holdAudit = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE customer_id = \(bind: DB.bin(w.tenant)) AND action_code IN ('content.hold.set','content.hold.clear')").first(decoding: C.self)?.c
                XCTAssertEqual(holdAudit, 0)
            }
            // A structurally valid but incomplete list reaches the inventory check and remains a conflict.
            try await w.admin.send(.PUT, url, body: "{\"held\":true,\"objects\":[]}") { XCTAssertEqual($0.status, .conflict, text($0)) }
            let complete = try await holdBody(w, entry: entry, held: true)
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(complete.utf8)) as? [String: Any])
            let proofs = try XCTUnwrap(document["objects"] as? [[String: Any]])
            XCTAssertEqual(proofs.count, 3)
            func body(_ list: [[String: Any]], held: Bool = true) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject: ["held": held, "objects": list]), as: UTF8.self)
            }
            try await w.admin.send(.PUT, url, body: body(Array(proofs.dropLast()))) { XCTAssertEqual($0.status, .conflict, text($0)) }
            try await w.admin.send(.PUT, url, body: body(proofs + [proofs[0]])) { XCTAssertEqual($0.status, .conflict, text($0)) }
            var stale = proofs; stale[0]["expectedRevision"] = 99
            try await w.admin.send(.PUT, url, body: body(stale)) { XCTAssertEqual($0.status, .conflict, text($0)) }
            var wrongDigest = proofs; wrongDigest[0]["expectedSha256"] = String(repeating: "0", count: 64)
            try await w.admin.send(.PUT, url, body: body(wrongDigest)) { XCTAssertEqual($0.status, .conflict, text($0)) }
            try await w.admin.send(.PUT, url, body: try await holdBody(w, entry: entry, held: true, replacements: false)) { XCTAssertEqual($0.status, .conflict, text($0)) }
            // Failed protection must leave every package and the flag unchanged.
            let unchanged = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE wrap_kind = 'hpke' AND revision = 0").first(decoding: C.self)?.c
            XCTAssertEqual(unchanged, 3)
            let removable = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions WHERE id = \(bind: sub) AND removable = 1").first(decoding: C.self)?.c
            XCTAssertEqual(removable, 1)
            try await w.admin.send(.PUT, url, body: complete) { XCTAssertEqual($0.status, .ok, text($0)) }
            struct O: Decodable { let ciphertext: Blob; let revision: Int; let wrap_kind: String }
            let objects = try await f.sql.raw("SELECT ciphertext,revision,wrap_kind FROM stored_objects").all(decoding: O.self)
            XCTAssertEqual(objects.count, 3)
            for o in objects {
                XCTAssertEqual(o.wrap_kind, "sym"); XCTAssertEqual(o.revision, 1)
                let plaintext = try PackageV2(String(decoding: o.ciphertext.data, as: UTF8.self)).open(recipient: w.sk)
                XCTAssertTrue(String(decoding: plaintext, as: UTF8.self).contains("HOLD-INVENTORY"))
            }
            // A stale list fails after the committed revision change, and an unhold may never replace packages.
            try await w.admin.send(.PUT, url, body: complete) { XCTAssertEqual($0.status, .conflict, text($0)) }
            let currentBody = try await holdBody(w, entry: entry, held: false)
            var current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(currentBody.utf8)) as? [String: Any])
            var currentProofs = try XCTUnwrap(current["objects"] as? [[String: Any]])
            currentProofs[0]["replacementPackage"] = proofs[0]["replacementPackage"]
            current["objects"] = currentProofs
            try await w.admin.send(.PUT, url, body: String(decoding: JSONSerialization.data(withJSONObject: current), as: UTF8.self)) { XCTAssertEqual($0.status.code, 422, text($0)) }
            try await w.admin.send(.PUT, url, body: try await holdBody(w, entry: entry, held: false)) { XCTAssertEqual($0.status, .ok, text($0)) }
        }
    }

    func testLocalSearchAccessAndExportAuditRecheckLiveRightsAndRejectPersonalData() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, rights: ["content.read"])
            let base = "tenants/\(w.tenant)/forms/\(w.form)"
            try await w.admin.get(base + "/entries/local-access") { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(w.user, "content.decrypt", customer: w.tenant, by: w.root)
            try await w.admin.get(base + "/entries/local-access") {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(obj($0)["canExport"] as? Bool, false)
                XCTAssertEqual(obj($0)["canDelete"] as? Bool, false)
                XCTAssertEqual($0.headers.first(name: .cacheControl), "no-store")
            }
            try await w.admin.post(base + "/export/audit", "{}") { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(w.user, "content.export", customer: w.tenant, by: w.root)
            try await w.admin.post(base + "/export/audit", "{\"query\":\"SYNTHETIC-PERSON\"}") { XCTAssertEqual($0.status, .badRequest) }
            try await w.admin.post(base + "/export/audit", "{}", csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await w.admin.post(base + "/export/audit", "{}", origin: false) { XCTAssertEqual($0.status, .forbidden) }
            let other = try await f.customer()
            try await w.admin.post("tenants/\(other)/forms/\(w.form)/export/audit", "{}") { XCTAssertEqual($0.status, .notFound) }
            try await w.admin.post(base + "/export/audit", "{}") { XCTAssertEqual($0.status, .noContent) }
            let count = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'content.export.local'").first(decoding: C.self)?.c
            XCTAssertEqual(count, 1)
            try await f.sql.raw("UPDATE permission_assignments SET revoked_at = NOW(6) WHERE account_id = \(bind: DB.bin(w.user)) AND permission = 'content.decrypt'").run()
            try await w.admin.post(base + "/export/audit", "{}") { XCTAssertEqual($0.status, .forbidden) }
            try await w.admin.get(base + "/entries/local-access") { XCTAssertEqual($0.status, .forbidden) }
            let unchanged = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'content.export.local'").first(decoding: C.self)?.c
            XCTAssertEqual(unchanged, 1)
            struct Details: Decodable { let safe_details_json: String }
            let details = try await f.sql.raw("SELECT safe_details_json FROM audit_events WHERE action_code = 'content.export.local'").all(decoding: Details.self)
            XCTAssertTrue(details.allSatisfy { $0.safe_details_json == "{}" })
            try await f.grant(w.user, "content.decrypt", customer: w.tenant, by: w.root)
            try await f.sql.raw("UPDATE sessions SET authenticated_at = DATE_SUB(NOW(6), INTERVAL 45 MINUTE) WHERE account_id = \(bind: DB.bin(w.user)) AND state = 'authenticated'").run()
            try await w.admin.post(base + "/export/audit", "{}") {
                XCTAssertEqual(obj($0)["code"] as? String, "reauthentication_required")
            }
            try await w.admin.get(base + "/entries/local-access") {
                XCTAssertEqual(obj($0)["code"] as? String, "reauthentication_required")
            }
        }
    }

}
