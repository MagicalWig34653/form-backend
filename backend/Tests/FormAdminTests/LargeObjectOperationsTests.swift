// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
@testable import FormCrypto
import FormFlow
import FormIngest
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// Card C4D13F4D: objects above 16 MiB - 1 (an attachment of about 20 MB is a sealed package of about 27 MB) must survive every operation that reads or
/// rewrites a whole object cell: key rotation, hold rewrap, flow resume context. MySQLNIO cannot send or receive a statement or row of that size
/// (see ChunkedBlob); these routes used `SELECT ... ciphertext` / `UPDATE ... SET ciphertext = <bound value>` and failed for exactly such objects.
/// Needs a database with a packet limit above ~60 MiB:
/// P3B_DB_ARGS=--max-allowed-packet=67108864 backend/integration-test.sh --filter LargeObjectOperations
final class LargeObjectOperationsTests: XCTestCase {
    private struct V: Decodable { let v: String }
    private struct Len: Decodable { let n: Int; let h: Blob; let k: String; let rev: Int; let bc: Int; let sha: Blob }
    private func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body).prefix(300), as: UTF8.self) }
    private func b64(_ n: Int) -> String { Data(repeating: 7, count: n).base64URLString }
    private func pattern(_ size: Int, seed: Int) -> Data {
        var d = Data(count: size); for i in stride(from: 0, to: size, by: 4099) { d[i] = UInt8(truncatingIfNeeded: i / 4099 + seed) }
        return d
    }
    private func requireBigPackets(_ f: AdminFixture) async throws {
        let limit = Int(try await f.sql.raw("SELECT CAST(@@global.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
        try XCTSkipIf(limit < 60_000_000, "needs max_allowed_packet >= 64 MiB (got \(limit))")
    }

    // MARK: rotation / hold world (same shape as RotationTests)

    private struct World {
        let tenant: UUID, form: UUID, submission: UUID, user: UUID, other: UUID
        let client: TestClient
        let old: Curve25519.KeyAgreement.PrivateKey, next: Curve25519.KeyAgreement.PrivateKey
        var path: String { "tenants/\(tenant)/key-rotation" }
    }
    private func world(_ f: AdminFixture) async throws -> World {
        let user = try await f.account(), other = try await f.account(), tenant = try await f.customer()
        let form = try await f.form(customer: tenant), submission = UUID()
        for a in [user, other] {
            for right in ["key.manage", "content.decrypt", "content.hold", "identity.manage"] { try await f.grant(a, right, customer: tenant, by: user) }
            try await f.sql.raw("INSERT INTO account_keys (account_id, public_key, created_at) VALUES (\(bind: DB.bin(a)), \(bind: Blob(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)), NOW(6))").run()
        }
        let c = try await f.login(user)
        let old = Curve25519.KeyAgreement.PrivateKey(), next = Curve25519.KeyAgreement.PrivateKey()
        let w = World(tenant: tenant, form: form, submission: submission, user: user, other: other, client: c, old: old, next: next)
        let recovery: [String: Any] = ["salt": b64(32), "iterations": 600000, "iv": b64(12), "wrap": b64(48)]
        let body = try json(["publicKey": old.publicKey.rawRepresentation.base64URLString, "access": ["enc": b64(32), "sealed": b64(48)], "recovery": recovery])
        try await c.send(.PUT, "tenants/\(tenant)/customer-key", body: body) { XCTAssertEqual($0.status, .created, text($0)) }
        let kid = try keyID(old.publicKey.rawRepresentation)
        try await c.send(.PUT, "tenants/\(tenant)/key-access/\(other)", body: json(["kid": kid, "enc": b64(32), "sealed": b64(48)])) { XCTAssertEqual($0.status, .created, text($0)) }
        try await f.sql.raw("""
            INSERT INTO submissions (id, customer_id, form_id, release_evidence, environment, state, removable, malware_scan_status)
            VALUES (\(bind: DB.bin(submission)), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), 'legacy-unknown', 'legacy-unknown', 'accepted', 1, 'none')
            """).run()
        return w
    }
    /// Stores a sealed object exactly like ingest does (head in the INSERT, the rest appended in pieces) and checks the cell in the database.
    private func store(_ f: AdminFixture, _ w: World, role: String, ordinal: Int, plain: Data) async throws -> (id: UUID, package: PackageV2, wire: Data) {
        let id = UUID(), p = try PackageV2.seal(plain, recipient: w.old.publicKey.rawRepresentation), wire = Data(p.wire.utf8)
        try await f.sql.raw("""
            INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, expires_at, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
            VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(w.tenant)), \(bind: DB.bin(w.form)), \(bind: DB.bin(w.submission)), \(bind: role), \(bind: ordinal), 0, DATE_ADD(NOW(), INTERVAL 1 HOUR), 'db', \(bind: ChunkedBlob.head(wire)), 'KUBUS-AEAD:2', 'hpke', \(bind: p.kid), 'raw', \(bind: Blob(sha256(wire))), \(bind: Blob(sha256(p.iv + p.ciphertext + p.tag))), \(bind: wire.count), 'ready')
            """).run()
        try await ChunkedBlob.append(wire, to: .objectCiphertext, key: DB.bin(id), on: f.sql)
        try await assertIntact(f, id, wire: wire, kid: p.kid, revision: 0)
        return (id, p, wire)
    }
    /// Length and SHA-256 of the WHOLE cell are checked inside the database, so a lost or damaged tail cannot hide behind a driver read.
    private func assertIntact(_ f: AdminFixture, _ id: UUID, wire: Data, kid: String, revision: Int, line: UInt = #line) async throws {
        let row = try await f.sql.raw("SELECT CAST(OCTET_LENGTH(ciphertext) AS SIGNED) AS n, UNHEX(SHA2(ciphertext, 256)) AS h, kid AS k, revision AS rev, byte_count AS bc, ciphertext_sha256 AS sha FROM stored_objects WHERE id = \(bind: DB.bin(id))").first(decoding: Len.self)
        let r = try XCTUnwrap(row, line: line)
        XCTAssertEqual(r.n, wire.count, "stored length", line: line); XCTAssertEqual(r.bc, wire.count, "byte_count", line: line)
        XCTAssertEqual(r.h.data, sha256(wire), "stored cell hash", line: line); XCTAssertEqual(r.sha.data, sha256(wire), "ciphertext_sha256", line: line)
        XCTAssertEqual(r.k, kid, line: line); XCTAssertEqual(r.rev, revision, line: line)
    }
    private func rewrap(_ p: PackageV2, from: Curve25519.KeyAgreement.PrivateKey, to kid: String, key: Curve25519.KeyAgreement.PrivateKey, sym: Bool) throws -> PackageV2 {
        let cek = try HPKE.open(p.b, enc: p.a, recipient: from, info: Data("kubus-anfrage v2".utf8), aad: Data(p.kid.utf8))
        let a: Data, b: Data
        if sym {
            let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key.rawRepresentation), salt: Data(), info: Data("kubus-langzeit v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
            a = Data(repeating: 9, count: 12); b = try sealGCM(cek, key: k, nonce: a, aad: Data(kid.utf8))
        } else {
            let sealed = try HPKE.seal(cek, recipient: key.publicKey.rawRepresentation, info: Data("kubus-anfrage v2".utf8), aad: Data(kid.utf8)); a = sealed.enc; b = sealed.ciphertext
        }
        return try PackageV2("KUBUS-AEAD:2|\(kid)|\(sym ? "sym" : "hpke")|\(a.base64EncodedString()):\(b.base64EncodedString())|\(p.iv.base64EncodedString())|\(p.ciphertext.base64EncodedString())|\(p.tag.base64EncodedString())")
    }

    /// Key rotation of a submission with a 19.9 MB attachment (package about 27 MB): list, replace, finish, decrypt with the new key, bytes exact.
    func testKeyRotationWithAttachmentAbove16MiBRunsToTheEndAndDecryptsExactly() async throws {
        try await AdminFixture.with { f in
            try await requireBigPackets(f)
            let w = try await world(f)
            let small = Data("{\"nachricht\":\"Erika\"}".utf8), big = pattern(19_900_000, seed: 1), mid = pattern(9_000_000, seed: 2)
            let objects = [try await store(f, w, role: "data", ordinal: 0, plain: small), try await store(f, w, role: "attachment", ordinal: 0, plain: big), try await store(f, w, role: "attachment", ordinal: 1, plain: mid)]
            XCTAssertGreaterThan(objects[1].wire.count, 16_777_215, "the test object must exceed the driver packet limit")
            let plains = [small, big, mid]
            let begin = try json(["publicKey": w.next.publicKey.rawRepresentation.base64URLString, "access": [w.user, w.other].map { ["accountId": $0.uuidString.lowercased(), "enc": b64(32), "sealed": b64(48)] }, "recovery": ["salt": b64(32), "iterations": 600000, "iv": b64(12), "wrap": b64(48)]])
            try await w.client.send(.POST, w.path, body: begin) { XCTAssertEqual($0.status, .created, text($0)) }
            let oldKid = objects[0].package.kid, newKid = try keyID(w.next.publicKey.rawRepresentation)

            // listing: every object (page by page) arrives complete with the stored hash
            var seen: [String: [String: Any]] = [:]
            var after: String?, pages = 0
            repeat {
                var next: String?
                try await w.client.get(w.path + "/objects?kid=\(oldKid)&limit=100" + (after.map { "&after=\($0)" } ?? "")) { res in
                    XCTAssertEqual(res.status, .ok, text(res)); guard res.status == .ok else { return }
                    let o = jsonObject(res)
                    for item in o["items"] as? [[String: Any]] ?? [] { seen[item["id"] as? String ?? ""] = item }
                    next = o["next"] as? String
                }
                after = next; pages += 1
            } while after != nil && pages < 10
            XCTAssertEqual(Set(seen.keys), Set(objects.map { $0.id.uuidString.lowercased() }))
            for o in objects {
                guard let item = seen[o.id.uuidString.lowercased()] else { continue }
                let wire = try XCTUnwrap(item["package"] as? String, "package of \(o.wire.count) bytes")
                XCTAssertEqual(Data(wire.utf8).count, o.wire.count); XCTAssertEqual(sha256(Data(wire.utf8)), sha256(o.wire), "listed package hash")
                XCTAssertEqual(item["ciphertext_sha256"] as? String, sha256(o.wire).hex)
            }
            print("MEASURE rotation listing pages=\(pages) objects=\(seen.count) largest package=\(objects[1].wire.count) bytes")

            // replacement packages of the documented maximum (body limit 64 MiB) are written completely
            var replaced: [PackageV2] = []
            for o in objects {
                let r = try rewrap(o.package, from: w.old, to: newKid, key: w.next, sym: false)
                replaced.append(r)
                let body = try json(["expectedRevision": 0, "expectedSha256": sha256(o.wire).hex, "package": r.wire])
                try await w.client.send(.PUT, w.path + "/objects/\(o.id)", body: body) { XCTAssertEqual($0.status, .noContent, text($0)) }
                try await assertIntact(f, o.id, wire: Data(r.wire.utf8), kid: newKid, revision: 1)
            }
            try await w.client.post(w.path + "/finish", try json(["kid": oldKid])) { XCTAssertEqual($0.status, .noContent, text($0)) }

            // decryption with the new key after the rotation: bytes exact
            for (i, o) in objects.enumerated() {
                let back = try await ChunkedBlob.read(.objectCiphertext, key: DB.bin(o.id), on: f.sql)
                XCTAssertEqual(back, Data(replaced[i].wire.utf8))
                let opened = try PackageV2(String(decoding: try XCTUnwrap(back), as: UTF8.self)).open(recipient: w.next)
                XCTAssertEqual(opened.count, plains[i].count); XCTAssertEqual(sha256(opened), sha256(plains[i]), "plaintext hash after rotation, object \(i)")
            }
        }
    }

    /// Hold (legal hold) with sym re-protection of a 19.9 MB attachment, then release.
    func testHoldRewrapOfAttachmentAbove16MiBIsStoredCompletely() async throws {
        try await AdminFixture.with { f in
            try await requireBigPackets(f)
            let w = try await world(f)
            let small = Data("{\"nachricht\":\"Erika\"}".utf8), big = pattern(19_900_000, seed: 3)
            let objects = [try await store(f, w, role: "data", ordinal: 0, plain: small), try await store(f, w, role: "attachment", ordinal: 0, plain: big)]
            let kid = objects[0].package.kid, base = "tenants/\(w.tenant)/forms/\(w.form)/entries/\(w.submission)"
            var items: [[String: Any]] = []
            try await w.client.get(base + "/hold-objects") { res in
                XCTAssertEqual(res.status, .ok, text(res)); items = jsonObject(res)["items"] as? [[String: Any]] ?? []
            }
            XCTAssertEqual(items.count, 2)
            var proofs: [[String: Any]] = [], replaced: [UUID: PackageV2] = [:]
            for item in items {
                let id = UUID(uuidString: item["id"] as? String ?? "")!, o = try XCTUnwrap(objects.first { $0.id == id })
                XCTAssertEqual(Data((item["package"] as? String ?? "").utf8), o.wire, "listed package must be complete")
                let r = try rewrap(o.package, from: w.old, to: kid, key: w.old, sym: true); replaced[id] = r
                proofs.append(["objectId": item["id"]!, "expectedRevision": item["revision"]!, "expectedSha256": item["ciphertext_sha256"]!, "sourceGenerationId": item["sourceGenerationId"]!, "replacementPackage": r.wire])
            }
            try await w.client.send(.PUT, base + "/hold", body: json(["held": true, "objects": proofs])) { XCTAssertEqual($0.status, .ok, text($0)) }
            for o in objects { try await assertIntact(f, o.id, wire: Data(try XCTUnwrap(replaced[o.id]).wire.utf8), kid: kid, revision: 1) }
            let back = try await ChunkedBlob.read(.objectCiphertext, key: DB.bin(objects[1].id), on: f.sql)
            let stored = try PackageV2(String(decoding: try XCTUnwrap(back), as: UTF8.self))
            XCTAssertEqual(stored.wrap, "sym"); XCTAssertEqual(sha256(stored.iv + stored.ciphertext + stored.tag), sha256(objects[1].package.iv + objects[1].package.ciphertext + objects[1].package.tag), "payload untouched")
            // release: list again (the sym package of 27 MB is read in pieces) and clear
            var again: [[String: Any]] = []
            try await w.client.get(base + "/hold-objects") { res in XCTAssertEqual(res.status, .ok, text(res)); again = jsonObject(res)["items"] as? [[String: Any]] ?? [] }
            let released = again.map { ["objectId": $0["id"]!, "expectedRevision": $0["revision"]!, "expectedSha256": $0["ciphertext_sha256"]!, "sourceGenerationId": $0["sourceGenerationId"]!] as [String: Any] }
            try await w.client.send(.PUT, base + "/hold", body: json(["held": false, "objects": released])) { XCTAssertEqual($0.status, .ok, text($0)) }
        }
    }

    // MARK: flow world (approval flow: the run waits with an encrypted checkpoint)

    private struct FlowWorld { let tenant: UUID; let form: String; let client: TestClient; let seed: Data; let key: Curve25519.KeyAgreement.PrivateKey }
    private func node(_ kind: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(extra.merging(["kind": .string(kind), "label": .object(["de": .string(kind)])]) { _, b in b })
    }
    private func flowWorld(_ f: AdminFixture) async throws -> FlowWorld {
        let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
        for right in ["form.create", "form.read", "draft.write", "release.publish", "key.manage", "flow.execute", "flow.resume", "content.read", "content.decrypt"] { try await f.grant(user, right, customer: tenant, by: root) }
        let c = try await f.login(user)
        var form = "", draft = "", doc = JSONValue.null, hash = "", confirmation = ""
        try await c.post("tenants/\(tenant)/forms", "{\"name\":\"Ablauf\"}") { XCTAssertEqual($0.status, .created, text($0)); form = jsonObject($0)["id"] as? String ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)") { draft = (jsonObject($0)["draftIds"] as? [String])?.first ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { doc = try JCS.parse(Data(buffer: $0.body))["document"] ?? .null }
        var top = try XCTUnwrap(doc.object), graph = try XCTUnwrap(top["flow"]?.object)
        var nodes: [String: JSONValue] = ["entry": node("entry"), "end": node("end", ["result": .string("success")]), "rejected": node("end", ["result": .string("rejected")])]
        nodes["set"] = node("block", ["block": try FlowDefinition.builtinReference(id: "core.set-fields"), "location": .string("backend-worker"), "config": .object(["values": .object(["nachricht": .string("FLOW-TRANSFORMED")])]), "inputBindings": .object([:])])
        nodes["action"] = node("approval", ["permission": .string("flow.approve"), "timeoutMs": .int(60000), "onTimeout": .string("reject"), "requireHuman": .bool(true)])
        let edges = [("entry", "next", "set"), ("set", "next", "action"), ("action", "approved", "end"), ("action", "rejected", "rejected")]
        graph["nodes"] = .object(nodes)
        graph["edges"] = .array(edges.map { .object(["from": .string($0.0), "port": .string($0.1), "to": .string($0.2)]) })
        top["flow"] = .object(graph); doc = .object(top)
        try await c.send(.PATCH, "tenants/\(tenant)/forms/\(form)/drafts/\(draft)", body: String(decoding: JCS.canonicalize(doc), as: UTF8.self), headers: ["If-Match": "\"1\""]) {
            XCTAssertEqual($0.status, .ok, text($0)); hash = jsonObject($0)["hash"] as? String ?? ""
        }
        try await c.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":2,\"hash\":\"\(hash)\",\"confirm\":true}") {
            XCTAssertEqual($0.status, .created, text($0)); confirmation = jsonObject($0)["confirmationId"] as? String ?? ""
        }
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":2,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key": "publish"]) { XCTAssertEqual($0.status, .created, text($0)) }
        let sk = Curve25519.KeyAgreement.PrivateKey()
        try await c.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
        var seed = Data()
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: jsonObject($0)["signingSeed"] as? String ?? "") ?? Data() }
        return FlowWorld(tenant: tenant, form: form, client: c, seed: seed, key: sk)
    }
    private func submit(_ f: AdminFixture, _ w: FlowWorld, attachment content: Data) async throws -> String {
        let signed = FileField.single(SignedFile(name: "antrag.pdf", type: "application/pdf", error: 0, size: Int64(content.count), content: content))
        let canonical = try RequestSignature.canonical(fields: PHPValue.array([("nachricht", PHPValue.string("Erika"))]), files: [("antrag", signed)])
        let ts = String(Int64(Date().timeIntervalSince1970))
        let sig = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: w.form, timestamp: ts, canonical: canonical), seed: w.seed)
        var h = HTTPHeaders(); h.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=XBOUNDX")
        h.add(name: "X-Kubus-Timestamp", value: ts); h.add(name: "X-Kubus-Signature", value: sig.base64EncodedString()); h.add(name: "Idempotency-Key", value: "flow-big")
        var body = Data("--XBOUNDX\r\nContent-Disposition: form-data; name=\"nachricht\"\r\n\r\nErika\r\n".utf8)
        body += Data("--XBOUNDX\r\nContent-Disposition: form-data; name=\"antrag\"; filename=\"antrag.pdf\"\r\nContent-Type: application/pdf\r\n\r\n".utf8) + content + Data("\r\n--XBOUNDX--\r\n".utf8)
        var id = ""
        try await f.app.test(.POST, "api/v2/submit/?f=\(w.form)", headers: h, body: ByteBuffer(data: body)) {
            XCTAssertEqual($0.status, .ok, text($0)); id = (jsonObject($0)["submission"] as? [String: Any])?["id"] as? String ?? ""
        }
        return id
    }

    /// Flow run whose submission carries a 19.9 MB attachment: resume context, checkpoint read and the proof check of resume must work
    /// (they load every required object; before, the whole-cell SELECT lost the attachment).
    func testFlowRunContextAndProofWithAttachmentAbove16MiB() async throws {
        try await AdminFixture.with { f in
            try await requireBigPackets(f)
            let w = try await flowWorld(f)
            let content = Data("%PDF-1.4\n".utf8) + pattern(19_900_000 - 9, seed: 5)
            let entry = try await submit(f, w, attachment: content)
            struct Run: Decodable { let id: Blob; let steps_used: UInt64; let revision: UInt64; let checkpoint_object_id: Blob; let submission_id: Blob; let release_id: Blob; let state: String; let checkpoint_json: String; let deadline_at: Date; let wake_at: Date?; let budget_json: String; let active_time_ms: UInt64 }
            let runRow = try await f.sql.raw("SELECT id,submission_id,release_id,state,revision,checkpoint_object_id,checkpoint_json,deadline_at,wake_at,budget_json,steps_used,active_time_ms FROM workflow_runs").first(decoding: Run.self)
            let run = try XCTUnwrap(runRow)
            XCTAssertEqual(DB.uuid(run.submission_id.data)?.uuidString.lowercased(), entry)
            let path = "tenants/\(w.tenant)/forms/\(w.form)/runs/\(DB.uuid(run.id.data)!)"
            var items: [[String: Any]] = []
            try await w.client.get(path + "/resume-context") { res in
                XCTAssertEqual(res.status, .ok, text(res)); items = jsonObject(res)["requiredObjects"] as? [[String: Any]] ?? []
            }
            XCTAssertTrue(items.contains { ($0["role"] as? String) == "attachment" && ($0["byteCount"] as? Int ?? 0) > 16_777_215 }, "attachment listed with its size")
            try await w.client.get(path + "/checkpoint/ciphertext") { XCTAssertEqual($0.status, .ok, text($0)) }
            // the proof check of resume: every required object is read whole and opened with its CEK
            let typed = FlowRunRoutes.Run(id: run.id, submission_id: run.submission_id, release_id: run.release_id, state: run.state, revision: run.revision, checkpoint_object_id: run.checkpoint_object_id, checkpoint_json: run.checkpoint_json, deadline_at: run.deadline_at, wake_at: run.wake_at, budget_json: run.budget_json, steps_used: run.steps_used, active_time_ms: run.active_time_ms)
            let objects = try await FlowRunRoutes.requiredObjects(f.sql, tenant: w.tenant, form: UUID(uuidString: w.form)!, run: typed, withCiphertext: true)
            XCTAssertEqual(objects.count, 3, "checkpoint, data, attachment")
            var proofs: [FlowRunRoutes.Proof] = []
            for o in objects {
                let wire = try XCTUnwrap(o.ciphertext?.data), p = try PackageV2(String(decoding: wire, as: UTF8.self))
                let cek = try HPKE.open(p.b, enc: p.a, recipient: w.key, info: Data("kubus-anfrage v2".utf8), aad: Data(p.kid.utf8))
                proofs.append(.init(objectId: DB.uuid(o.id.data)!.uuidString.lowercased(), expectedRevision: o.revision, expectedSha256: FlowRunRoutes.hex(o.ciphertext_sha256.data), cek: cek.base64EncodedString()))
                if o.object_role == "attachment" { XCTAssertEqual(sha256(try p.open(recipient: w.key)), sha256(content), "attachment bytes exact") }
            }
            let state = try FlowRunRoutes.validateProof(.init(objects: proofs), objects: objects, checkpoint: run.checkpoint_object_id)
            XCTAssertEqual(state.steps, Int(run.steps_used))
        }
    }
}
