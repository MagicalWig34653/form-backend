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

/// The whole chain through the real routes: form -> publish -> customer key -> SDK credentials -> signed submission ->
/// idempotent replay -> the customer (holder of the private key) reads the plaintext. The server never sees a key.
final class IngestEndToEndTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private func publishedForm(_ f: AdminFixture, rights: [String] = ["form.create", "form.read", "draft.write", "release.publish", "key.manage"], openSchema: Bool = false) async throws -> (tenant: UUID, form: String, admin: TestClient, root: UUID) {
        let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
        for r in rights { try await f.grant(user, r, customer: tenant, by: root) }
        let c = try await f.login(user)
        var form = "", draft = "", hash = "", conf = ""
        try await c.post("tenants/\(tenant)/forms", "{\"name\":\"Kontakt\"}") { form = obj($0)["id"] as? String ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)") { draft = (obj($0)["draftIds"] as? [String])?.first ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { hash = obj($0)["hash"] as? String ?? "" }
        try await c.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { conf = obj($0)["confirmationId"] as? String ?? "" }
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(conf)\"}", headers: ["Idempotency-Key": "k"]) { XCTAssertEqual($0.status, .created) }
        // Tests that submit arbitrary field names run against a form without a field schema (accepts everything).
        if openSchema { try await f.sql.raw("UPDATE form_versions SET definition_json = JSON_SET(definition_json, '$.fields', JSON_OBJECT())").run() }
        return (tenant, form, c, root)
    }

    private func urlencoded(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" }.joined(separator: "&")
    }

    /// What the SDK does: canonicalise, sign with the seed, send urlencoded with the Idempotency-Key.
    private func submit(_ app: Application, form: String, seed: Data, pairs: [(String, String)], key: String? = nil, ts: Int64? = nil, _ check: (XCTHTTPResponse) async throws -> Void) async throws {
        let fields = PHPValue.array(pairs.map { ($0.0, PHPValue.string($0.1)) })
        let canonical = try RequestSignature.canonical(fields: fields)
        let stamp = String(ts ?? Int64(Date().timeIntervalSince1970))
        let sig = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: form, timestamp: stamp, canonical: canonical), seed: seed)
        var h = HTTPHeaders()
        h.contentType = .urlEncodedForm
        h.add(name: "X-Kubus-Timestamp", value: stamp); h.add(name: "X-Kubus-Signature", value: sig.base64EncodedString())
        if let key { h.add(name: "Idempotency-Key", value: key) }
        try await app.test(.POST, "api/v2/submit/?f=\(form)", headers: h, body: ByteBuffer(string: urlencoded(pairs)), afterResponse: check)
    }

    func testActiveSwitchStopsAndResumesIngestWithAuditAndRight() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, admin, root) = try await publishedForm(f, openSchema: true)
            let pk = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(pk.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            var cfg: [String: Any] = [:]
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { cfg = obj($0) }
            let seed = try XCTUnwrap(Data(base64URLString: cfg["signingSeed"] as? String ?? ""))
            let pairs = [("nachricht", "aktiv")]
            try await submit(f.app, form: form, seed: seed, pairs: pairs, key: "a1") { XCTAssertEqual($0.status, .ok, text($0)) }
            let path = "tenants/\(tenant)/forms/\(form)/active"
            // wrong right, no CSRF, bad bodies change nothing
            let reader = try await f.account(); try await f.grant(reader, "form.read", customer: tenant, by: root)
            try await (try await f.login(reader)).send(.PUT, path, body: "{\"active\":false}") { XCTAssertEqual($0.status, .forbidden) }
            try await admin.send(.PUT, path, body: "{\"active\":false}", csrf: false) { XCTAssertNotEqual($0.status, .noContent) }
            try await admin.send(.PUT, path, body: "{\"active\":\"no\"}") { XCTAssertNotEqual($0.status, .noContent) }
            try await admin.send(.PUT, path, body: "{\"active\":false,\"x\":1}") { XCTAssertEqual($0.status, .badRequest) }
            try await submit(f.app, form: form, seed: seed, pairs: pairs, key: "a2") { XCTAssertEqual($0.status, .ok) }
            // switch off: ingest answers 404, switching on resumes it; both audited
            try await admin.send(.PUT, path, body: "{\"active\":false}") { XCTAssertEqual($0.status, .noContent) }
            try await submit(f.app, form: form, seed: seed, pairs: pairs, key: "a3") { XCTAssertEqual($0.status, .notFound) }
            try await admin.get("tenants/\(tenant)/forms/\(form)") { XCTAssertEqual(obj($0)["active"] as? Bool, false) }
            try await admin.send(.PUT, path, body: "{\"active\":true}") { XCTAssertEqual($0.status, .noContent) }
            try await submit(f.app, form: form, seed: seed, pairs: pairs, key: "a3") { XCTAssertEqual($0.status, .ok) }
            let audits = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code IN ('form.activate','form.deactivate')").first(decoding: C.self)?.c
            XCTAssertEqual(audits, 2)
            try await admin.send(.PUT, "tenants/\(tenant)/forms/\(UUID())/active", body: "{\"active\":true}") { XCTAssertEqual($0.status, .notFound) }
        }
    }

    func testFromPublishedFormToDecryptedSubmission() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, admin, _) = try await publishedForm(f)
            // before any key: no customer key, no credentials
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { res async throws in XCTAssertEqual(res.status.code, 422) }
            try await admin.get("tenants/\(tenant)/customer-key") { XCTAssertEqual($0.status, .notFound) }
            // the customer generates the pair on their own side; only the public half is registered
            let sk = Curve25519.KeyAgreement.PrivateKey()
            let pk = sk.publicKey.rawRepresentation
            let kid = try keyID(pk)
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(pk.base64URLString)\"}") { res async throws in
                XCTAssertEqual(res.status, .created, text(res)); XCTAssertEqual(obj(res)["keyId"] as? String, kid)
            }
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .conflict) }
            try await admin.get("tenants/\(tenant)/customer-key") { XCTAssertEqual(obj($0)["keyId"] as? String, kid) }

            var cfg: [String: Any] = [:]
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { res async throws in
                XCTAssertEqual(res.status, .created, text(res)); cfg = obj(res)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
            }
            XCTAssertEqual(cfg["customerKeyId"] as? String, kid)
            let seed = try XCTUnwrap(Data(base64URLString: cfg["signingSeed"] as? String ?? ""))
            XCTAssertEqual(seed.count, 32)
            // the private signing seed is NOT stored; the public key is; the digest secret is encrypted
            let seedLeak = try await f.sql.raw("SELECT COUNT(*) AS c FROM form_protocol_keys WHERE public_key = \(bind: Blob(seed))").first(decoding: C.self)?.c
            XCTAssertEqual(seedLeak, 0)
            struct R: Decodable { let secret_ref: String? }
            let ref = try await f.sql.raw("SELECT secret_ref FROM form_protocol_keys WHERE purpose = 'digest-hmac'").first(decoding: R.self)?.secret_ref ?? ""
            XCTAssertTrue(ref.hasPrefix("s1:"))
            struct Ct: Decodable { let ciphertext: Blob }
            let raw = try await f.sql.raw("SELECT ciphertext FROM managed_secrets WHERE ref = \(bind: ref)").first(decoding: Ct.self)?.ciphertext.data
            XCTAssertNotNil(raw)
            XCTAssertEqual(raw?.count, 12 + 32 + 16)

            // the SDK submits: accepted, stored as ciphertext, readable only with the customer's private key
            let pairs = [("nachricht", "Grüße / END-TO-END-MARKER-4711")]
            var id = ""
            try await submit(f.app, form: form, seed: seed, pairs: pairs, key: "submit-1") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res)); id = ((obj(res)["submission"] as? [String: Any])?["id"] as? String) ?? ""
            }
            XCTAssertNotEqual(id, "")
            // replay with the same key and body: the same submission, no second row
            try await submit(f.app, form: form, seed: seed, pairs: pairs, key: "submit-1") { res async throws in
                XCTAssertEqual(res.status, .ok); XCTAssertEqual((obj(res)["submission"] as? [String: Any])?["id"] as? String, id)
            }
            // same key, other content: conflict
            try await submit(f.app, form: form, seed: seed, pairs: [("nachricht", "anders")], key: "submit-1") { XCTAssertEqual($0.status, .conflict) }
            // unknown field on a 'reject' form: 422 with field names only, nothing stored
            try await submit(f.app, form: form, seed: seed, pairs: [("nachricht", "x"), ("zusatz", "GEHEIM-WERT")], key: "submit-bad") { res async throws in
                XCTAssertEqual(res.status, .unprocessableEntity); XCTAssertFalse(text(res).contains("GEHEIM-WERT"))
            }
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c
            XCTAssertEqual(n, 1)

            struct Obj: Decodable { let ciphertext: Blob; let kid: String }
            let objRow = try await f.sql.raw("SELECT ciphertext, kid FROM stored_objects").first(decoding: Obj.self)
            let o = try XCTUnwrap(objRow)
            XCTAssertEqual(o.kid, kid)
            let wire = String(decoding: o.ciphertext.data, as: UTF8.self)
            XCTAssertFalse(wire.contains("END-TO-END-MARKER"))
            let plain = String(decoding: try PackageV2(wire).open(recipient: sk), as: UTF8.self)
            XCTAssertTrue(plain.contains("END-TO-END-MARKER-4711"), "the customer can read what was submitted")
            // somebody else's key cannot
            XCTAssertThrowsError(try PackageV2(wire).open(recipient: Curve25519.KeyAgreement.PrivateKey()))

            // wrong signer / stale timestamp / tampered body are refused without a trace
            try await submit(f.app, form: form, seed: Data((0..<32).map { UInt8($0) }), pairs: pairs) { XCTAssertEqual($0.status, .forbidden) }
            try await submit(f.app, form: form, seed: seed, pairs: pairs, ts: Int64(Date().timeIntervalSince1970) - 4000) { XCTAssertEqual($0.status, .forbidden) }
            let still = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c
            XCTAssertEqual(still, 1)
        }
    }

    func testEntriesListAndCiphertextForTheBrowserToDecrypt() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, admin, root) = try await publishedForm(f, rights: ["form.create", "form.read", "draft.write", "release.publish", "key.manage", "content.read", "content.decrypt"])
            let sk = Curve25519.KeyAgreement.PrivateKey()
            // a low-order point would make every later submission fail: refused up front (review M1)
            let lowOrder = Data([1] + [UInt8](repeating: 0, count: 31)).base64URLString
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(lowOrder)\"}") { XCTAssertEqual($0.status.code, 422) }
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            var seed = Data()
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: obj($0)["signingSeed"] as? String ?? "") ?? Data() }
            var ids: [String] = []
            for i in 0..<3 {
                try await submit(f.app, form: form, seed: seed, pairs: [("nachricht", "LIST-MARKER-\(i)")], key: "k\(i)") { ids.append(((obj($0)["submission"] as? [String: Any])?["id"] as? String) ?? "") }
            }
            // metadata only, no package, paginated
            var seen: [String] = []
            var cursor: String? = nil
            repeat {
                var next: String? = nil
                try await admin.get("tenants/\(tenant)/forms/\(form)/entries?limit=2" + (cursor.map { "&cursor=\($0)" } ?? "")) { res async throws in
                    XCTAssertEqual(res.status, .ok, text(res)); XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                    XCTAssertFalse(text(res).contains("KUBUS-AEAD"))
                    seen += ((obj(res)["items"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                    next = obj(res)["nextCursor"] as? String
                }
                cursor = next
            } while cursor != nil
            XCTAssertEqual(Set(seen), Set(ids)); XCTAssertEqual(seen.count, 3)

            // ciphertext: the browser gets the sealed package and can open it with its own key
            var wire = ""
            try await admin.get("tenants/\(tenant)/forms/\(form)/entries/\(ids[0])/ciphertext") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res)); XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                XCTAssertEqual(obj(res)["format"] as? String, "KUBUS-AEAD:2"); wire = obj(res)["package"] as? String ?? ""
            }
            XCTAssertFalse(wire.contains("LIST-MARKER"))
            XCTAssertTrue(String(decoding: try PackageV2(wire).open(recipient: sk), as: UTF8.self).contains("LIST-MARKER"))
            let audited = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'content.ciphertext.read'").first(decoding: C.self)?.c
            XCTAssertEqual(audited, 1)
            // an unknown cursor is a client error, a submission without received_at stays listable and pages stay complete (review M2)
            try await admin.get("tenants/\(tenant)/forms/\(form)/entries?cursor=\(Data(repeating: 9, count: 16).base64URLString)") { XCTAssertEqual($0.status, .badRequest) }
            try await f.sql.raw("UPDATE submissions SET received_at = NULL WHERE id = \(bind: DB.bin(UUID(uuidString: ids[1])!))").run()
            var all: [String] = []
            var cur: String? = nil
            repeat {
                var nxt: String? = nil
                try await admin.get("tenants/\(tenant)/forms/\(form)/entries?limit=1" + (cur.map { "&cursor=\($0)" } ?? "")) { res async throws in
                    all += ((obj(res)["items"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }; nxt = obj(res)["nextCursor"] as? String
                }
                cur = nxt
            } while cur != nil
            XCTAssertEqual(Set(all), Set(ids)); XCTAssertEqual(all.count, 3)
            // unknown entry / other form's entry -> 404
            try await admin.get("tenants/\(tenant)/forms/\(form)/entries/\(UUID().uuidString.lowercased())/ciphertext") { XCTAssertEqual($0.status, .notFound) }
            // stale login -> reauthentication required, nothing handed out
            try await f.sql.raw("UPDATE sessions SET authenticated_at = '2020-01-01 00:00:00.000000'").run()
            try await admin.get("tenants/\(tenant)/forms/\(form)/entries/\(ids[0])/ciphertext") { res async throws in XCTAssertNotEqual(res.status, .ok); XCTAssertFalse(text(res).contains("KUBUS-AEAD")) }
            // read without decrypt: list works, ciphertext is forbidden
            let reader = try await f.account()
            try await f.grant(reader, "content.read", customer: tenant, by: root)
            let rc = try await f.login(reader)
            try await rc.get("tenants/\(tenant)/forms/\(form)/entries") { XCTAssertEqual($0.status, .ok) }
            try await rc.get("tenants/\(tenant)/forms/\(form)/entries/\(ids[0])/ciphertext") { res async throws in XCTAssertEqual(res.status, .forbidden); XCTAssertFalse(text(res).contains("KUBUS-AEAD")) }
            // a deactivated customer's submissions are no longer readable (review M3)
            try await f.sql.raw("UPDATE customers SET state = 'disabled' WHERE id = \(bind: DB.bin(tenant))").run()
            try await rc.get("tenants/\(tenant)/forms/\(form)/entries") { XCTAssertEqual($0.status, .notFound) }
            try await f.sql.raw("UPDATE customers SET state = 'active' WHERE id = \(bind: DB.bin(tenant))").run()
            // no rights at all: the form does not exist for them
            let stranger = try await f.login(try await f.account())
            try await stranger.get("tenants/\(tenant)/forms/\(form)/entries") { XCTAssertEqual($0.status, .notFound) }
        }
    }

    func testStatisticsCountsAcceptedSubmissionsPerDayWithItsOwnRight() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, admin, root) = try await publishedForm(f, rights: ["form.create", "form.read", "draft.write", "release.publish", "key.manage", "statistics.read"], openSchema: true)
            let sk = Curve25519.KeyAgreement.PrivateKey()
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            var seed = Data()
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: obj($0)["signingSeed"] as? String ?? "") ?? Data() }
            for i in 0..<3 { try await submit(f.app, form: form, seed: seed, pairs: [("n", "\(i)")], key: "s\(i)") { XCTAssertEqual($0.status, .ok) } }
            // Submissions without a signed visit context are only counted on the bounded legacy path (received before the fixed UTC
            // introduction day 2026-11-03), so the fixture uses fixed timestamps instead of "now - n days" (the test must not age out).
            try await f.sql.raw("UPDATE submissions SET received_at = '2026-10-31 12:00:00.000000' ORDER BY id LIMIT 1").run()
            try await f.sql.raw("UPDATE submissions SET received_at = '2026-10-29 12:00:00.000000' WHERE received_at > '2026-11-01' ORDER BY id LIMIT 1").run()
            try await f.sql.raw("UPDATE submissions SET received_at = '2026-08-05 12:00:00.000000' WHERE received_at > '2026-11-01'").run()
            try await admin.get("tenants/\(tenant)/forms/\(form)/statistics?days=366") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res)); XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                XCTAssertEqual(obj(res)["total"] as? Int, 3)
                XCTAssertEqual(((obj(res)["days"] as? [[String: Any]]) ?? []).count, 3)
            }
            try await admin.get("tenants/\(tenant)/forms/\(form)/statistics?days=0") { XCTAssertEqual($0.status, .badRequest) }
            // a reader without statistics.read is refused, a stranger sees nothing
            let reader = try await f.account()
            try await f.grant(reader, "form.read", customer: tenant, by: root)
            try await (try await f.login(reader)).get("tenants/\(tenant)/forms/\(form)/statistics") { XCTAssertEqual($0.status, .forbidden) }
            try await (try await f.login(try await f.account())).get("tenants/\(tenant)/forms/\(form)/statistics") { XCTAssertEqual($0.status, .notFound) }
        }
    }

    private func multipart(_ boundary: String, text: [(String, String)], files: [(field: String, name: String, type: String, data: Data)]) -> Data {
        var d = Data()
        for (k, v) in text { d += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
        for f in files { d += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.field)\"; filename=\"\(f.name)\"\r\nContent-Type: \(f.type)\r\n\r\n".utf8) + f.data + Data("\r\n".utf8) }
        return d + Data("--\(boundary)--\r\n".utf8)
    }

    func testMultipartUploadIsSignedSealedPerAttachmentAndValidated() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, admin, _) = try await publishedForm(f, rights: ["form.create", "form.read", "draft.write", "release.publish", "key.manage", "content.read", "content.decrypt"])
            let sk = Curve25519.KeyAgreement.PrivateKey()
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            var seed = Data()
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: obj($0)["signingSeed"] as? String ?? "") ?? Data() }
            let pdf = Data("%PDF-1.4\nATTACHMENT-MARKER-9\n".utf8) + Data(repeating: 7, count: 100)
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 1, count: 50)

            func send(files: [(field: String, name: String, type: String, data: Data)], sign: [(String, FileField)]? = nil, key: String? = nil, _ check: (XCTHTTPResponse) async throws -> Void) async throws {
                let fields = PHPValue.array([("nachricht", PHPValue.string("Erika"))])
                let meta = try sign ?? Self.fileFields(files)
                let canonical = try RequestSignature.canonical(fields: fields, files: meta)
                let ts = String(Int64(Date().timeIntervalSince1970))
                let sig = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: form, timestamp: ts, canonical: canonical), seed: seed)
                var h = HTTPHeaders(); h.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=XBOUNDX")
                h.add(name: "X-Kubus-Timestamp", value: ts); h.add(name: "X-Kubus-Signature", value: sig.base64EncodedString())
                if let key { h.add(name: "Idempotency-Key", value: key) }
                let body = multipart("XBOUNDX", text: [("nachricht", "Erika")], files: files)
                try await f.app.test(.POST, "api/v2/submit/?f=\(form)", headers: h, body: ByteBuffer(data: body), afterResponse: check)
            }

            // one single file plus a list: accepted, 1 data object + 3 attachment objects, each readable only with the customer key
            try await send(files: [("antrag", "antrag.pdf", "application/pdf", pdf), ("bilder[]", "a.png", "image/png", png), ("bilder[]", "b.png", "image/png", png)], key: "up-1") { XCTAssertEqual($0.status, .ok, text($0)) }
            struct O: Decodable { let object_role: String; let ordinal_no: Int; let ciphertext: Blob }
            let rows = try await f.sql.raw("SELECT object_role, ordinal_no, ciphertext FROM stored_objects ORDER BY object_role + 0, ordinal_no").all(decoding: O.self)
            XCTAssertEqual(rows.map(\.object_role), ["data", "attachment", "attachment", "attachment"])
            let wires = rows.map { String(decoding: $0.ciphertext.data, as: UTF8.self) }
            XCTAssertTrue(wires.allSatisfy { !$0.contains("ATTACHMENT-MARKER") })
            // sorted names: antrag (ordinal 0), bilder[0] (1), bilder[1] (2)
            XCTAssertEqual(try PackageV2(wires[1]).open(recipient: sk), pdf)
            XCTAssertEqual(try PackageV2(wires[2]).open(recipient: sk), png)
            let meta = String(decoding: try PackageV2(wires[0]).open(recipient: sk), as: UTF8.self)
            XCTAssertTrue(meta.contains("\"antrag\":{\"name\":\"antrag.pdf\"") && meta.contains("\"bilder\":[{"), meta)
            XCTAssertFalse(meta.contains("ATTACHMENT-MARKER"))
            // replay: same key and content -> same submission, nothing stored twice
            try await send(files: [("antrag", "antrag.pdf", "application/pdf", pdf), ("bilder[]", "a.png", "image/png", png), ("bilder[]", "b.png", "image/png", png)], key: "up-1") { XCTAssertEqual($0.status, .ok) }
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects").first(decoding: C.self)?.c
            XCTAssertEqual(n, 4)

            // the attachment packages are served like the data package (rights, freshness, audit) and open with the customer key
            struct Sub: Decodable { let id: Blob }
            let subRow = try await f.sql.raw("SELECT id FROM submissions").first(decoding: Sub.self)
            let entryID = DB.uuid(try XCTUnwrap(subRow).id.data)!.uuidString.lowercased()
            for (n, expected) in [(0, pdf), (1, png), (2, png)] {
                try await admin.get("tenants/\(tenant)/forms/\(form)/entries/\(entryID)/attachments/\(n)") { res async throws in
                    XCTAssertEqual(res.status, .ok, text(res)); XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                    let opened = try PackageV2(obj(res)["package"] as? String ?? "").open(recipient: sk)
                    XCTAssertEqual(opened, expected)
                }
            }
            try await admin.get("tenants/\(tenant)/forms/\(form)/entries/\(entryID)/attachments/3") { XCTAssertEqual($0.status, .notFound) }
            try await admin.get("tenants/\(tenant)/forms/\(form)/entries/\(entryID)/attachments/x") { XCTAssertEqual($0.status, .badRequest) }
            // refusals leave no trace: type mismatch (png bytes named .pdf), unknown extension, too many files, same field twice, tampered content
            try await send(files: [("x", "x.pdf", "application/pdf", png)]) { XCTAssertEqual($0.status.code, 415) }
            try await send(files: [("x", "x.exe", "application/octet-stream", pdf)]) { XCTAssertEqual($0.status.code, 415) }
            try await send(files: Array(repeating: ("x[]", "x.pdf", "application/pdf", pdf), count: 6)) { XCTAssertEqual($0.status.code, 415) }
            try await send(files: [("x", "x.pdf", "application/pdf", pdf), ("x", "y.pdf", "application/pdf", pdf)]) { XCTAssertEqual($0.status.code, 415) }
            try await send(files: [("antrag", "antrag.pdf", "application/pdf", pdf + Data([1]))], sign: try Self.fileFields([("antrag", "antrag.pdf", "application/pdf", pdf)])) { XCTAssertEqual($0.status, .forbidden) }
            let still = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c
            XCTAssertEqual(still, 1)
        }
    }

    private static func fileFields(_ files: [(field: String, name: String, type: String, data: Data)]) throws -> [(String, FileField)] {
        var order: [String] = []; var groups: [String: (list: Bool, items: [SignedFile])] = [:]
        for f in files {
            let list = f.field.hasSuffix("[]"); let base = list ? String(f.field.dropLast(2)) : f.field
            if groups[base] == nil { order.append(base); groups[base] = (list, []) }
            groups[base]!.items.append(SignedFile(name: f.name, type: f.type, error: 0, size: Int64(f.data.count), content: f.data))
        }
        return order.map { ($0, groups[$0]!.list ? FileField.multiple(groups[$0]!.items.map { .single($0) }) : .single(groups[$0]!.items[0])) }
    }

    func testRotationKeepsThePreviousKeyForAGraceAndRevokesTheOneBefore() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, admin, _) = try await publishedForm(f)
            let sk = Curve25519.KeyAgreement.PrivateKey()
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            var seeds: [Data] = []
            for _ in 0..<3 {
                try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { res async throws in
                    XCTAssertEqual(res.status, .created); seeds.append(Data(base64URLString: obj(res)["signingSeed"] as? String ?? "") ?? Data())
                }
            }
            let pairs = [("nachricht", "x")]
            try await submit(f.app, form: form, seed: seeds[2], pairs: pairs) { XCTAssertEqual($0.status, .ok, text($0)) }            // current
            try await submit(f.app, form: form, seed: seeds[1], pairs: pairs) { XCTAssertEqual($0.status, .ok) }                      // previous, within grace
            try await submit(f.app, form: form, seed: seeds[0], pairs: pairs) { XCTAssertEqual($0.status, .forbidden) }               // revoked
            // after the grace the previous key stops working
            try await f.sql.raw("UPDATE form_protocol_keys SET valid_until = '2020-01-01 00:00:00.000000' WHERE state = 'previous'").run()
            try await submit(f.app, form: form, seed: seeds[1], pairs: pairs) { XCTAssertEqual($0.status, .forbidden) }
            // the digest key was created once only
            let d = try await f.sql.raw("SELECT COUNT(*) AS c FROM form_protocol_keys WHERE purpose = 'digest-hmac'").first(decoding: C.self)?.c
            XCTAssertEqual(d, 1)
        }
    }

    func testRightsFreshnessAndInputChecksOfTheKeyOperations() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, admin, root) = try await publishedForm(f)
            let pkBody = { (k: Data) in "{\"publicKey\":\"\(k.base64URLString)\"}" }
            // invalid keys: wrong length, low-order/zero point, not base64url, extra member
            for bad in [Data(count: 31), Data(count: 32), Data(repeating: 1, count: 33)] {
                try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: pkBody(bad)) { XCTAssertEqual($0.status.code, 422) }
            }
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"!!\"}") { XCTAssertEqual($0.status.code, 422) }
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"AAAA\",\"x\":1}") { XCTAssertEqual($0.status, .badRequest) }
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: pkBody(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation), csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            // without key.manage: covered but forbidden (403); stranger: 404
            let reader = try await f.account(), stranger = try await f.account()
            try await f.grant(reader, "form.read", customer: tenant, by: root)
            let r = try await f.login(reader), s = try await f.login(stranger)
            let pk = pkBody(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            try await r.send(.PUT, "tenants/\(tenant)/customer-key", body: pk) { XCTAssertEqual($0.status, .forbidden) }
            try await s.send(.PUT, "tenants/\(tenant)/customer-key", body: pk) { XCTAssertEqual($0.status, .notFound) }
            try await r.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { XCTAssertEqual($0.status, .forbidden) }
            try await s.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { XCTAssertEqual($0.status, .notFound) }
            try await s.get("tenants/\(tenant)/customer-key") { XCTAssertEqual($0.status, .notFound) }
            // a stale session must re-authenticate before keys are issued
            try await f.sql.raw("UPDATE sessions SET authenticated_at = '2020-01-01 00:00:00.000000' WHERE state = 'authenticated'").run()
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: pk) { res async throws in
                XCTAssertEqual(res.status, .forbidden); XCTAssertEqual(obj(res)["code"] as? String, "reauthentication_required")
            }
            let none = try await f.sql.raw("SELECT COUNT(*) AS c FROM customer_key_generations").first(decoding: C.self)?.c
            XCTAssertEqual(none, 0)
        }
    }

    // MARK: the real PHP SDK against the real server over HTTP

    private struct PHPResult { let status: Int32; let out: String; let err: String }

    private func runPHP(_ args: [String]) async throws -> PHPResult {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["php"] + args
            let o = Pipe(), e = Pipe()
            p.standardOutput = o; p.standardError = e
            try p.run()
            let outData = o.fileHandleForReading.readDataToEndOfFile(), errData = e.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return PHPResult(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
        }.value
    }

    private func phpAvailable() async -> Bool {
        guard let r = try? await runPHP(["-r", "exit(extension_loaded('sodium') && extension_loaded('curl') && PHP_VERSION_ID >= 80200 ? 0 : 1);"]) else { return false }
        return r.status == 0
    }

    func testPHPSDKSubmitsToTheRealServerAndTheCustomerDecrypts() async throws {
        guard await phpAvailable() else { throw XCTSkip("php >= 8.2 with sodium and curl not available") }
        let sdk = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sdk/php/bin/submit.php").path
        try await AdminFixture.with { f in
            let (tenant, form, admin, _) = try await publishedForm(f, openSchema: true)
            let sk = Curve25519.KeyAgreement.PrivateKey()
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            var cfg: [String: Any] = [:]
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { cfg = obj($0) }
            // credentials file exactly as an operator would save the API answer: mode 0600 in a private directory
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-e2e-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
            let credFile = dir.appendingPathComponent("credentials.json")
            FileManager.default.createFile(atPath: credFile.path, contents: try JSONSerialization.data(withJSONObject: cfg), attributes: [.posixPermissions: 0o600])

            // a real listening server on a free loopback port
            // (not app.startup(): that would parse the test runner's command line as a Vapor command)
            try await f.app.server.start(address: .hostname("127.0.0.1", port: 0))
            defer { f.app.server.shutdown() }   // a started HTTPServer must be shut down before the application deinitializes
            let port = try XCTUnwrap(f.app.http.server.shared.localAddress?.port)
            let url = "http://127.0.0.1:\(port)"

            let marker = "PHP-SDK-MARKER-\(UUID().uuidString.prefix(8))"
            let r1 = try await runPHP([sdk, "--credentials", credFile.path, "--url", url, "--key", "sdk-key-1",
                                      "nachricht=Grüße / \(marker) \u{1F30D}", "name=Beispiel", "liste[]=b", "liste[]=a", "karte[y]=1", "karte[x]=2"])
            XCTAssertEqual(r1.status, 0, "stderr: \(r1.err)")
            let id = r1.out.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertNotNil(UUID(uuidString: id), "output was: \(r1.out.debugDescription)")
            // retry with the same key (what the SDK does after a lost answer): same submission, no second row
            let r2 = try await runPHP([sdk, "--credentials", credFile.path, "--url", url, "--key", "sdk-key-1",
                                      "nachricht=Grüße / \(marker) \u{1F30D}", "name=Beispiel", "liste[]=b", "liste[]=a", "karte[y]=1", "karte[x]=2"])
            XCTAssertEqual(r2.status, 0, r2.err); XCTAssertEqual(r2.out.trimmingCharacters(in: .whitespacesAndNewlines), id)
            // same key with other content -> rejected (exit 1), nothing stored
            let r3 = try await runPHP([sdk, "--credentials", credFile.path, "--url", url, "--key", "sdk-key-1", "nachricht=anders"])
            XCTAssertEqual(r3.status, 1); XCTAssertTrue(r3.err.contains("409"))
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c
            XCTAssertEqual(n, 1)

            // the customer reads exactly what the SDK sent (canonical JSON with sorted keys)
            struct Obj: Decodable { let ciphertext: Blob }
            let row = try await f.sql.raw("SELECT ciphertext FROM stored_objects").first(decoding: Obj.self)
            let wire = String(decoding: try XCTUnwrap(row).ciphertext.data, as: UTF8.self)
            XCTAssertFalse(wire.contains(marker))
            let plain = String(decoding: try PackageV2(wire).open(recipient: sk), as: UTF8.self)
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])
            let fields = try XCTUnwrap(parsed["fields"] as? [String: Any])
            XCTAssertEqual(fields["nachricht"] as? String, "Grüße / \(marker) \u{1F30D}")
            XCTAssertEqual(fields["liste"] as? [String], ["b", "a"])
            XCTAssertEqual(fields["karte"] as? [String: String], ["x": "2", "y": "1"])

            // files through the real PHP SDK: the multipart body and the signed metadata must match what the server derives
            let pdfFile = dir.appendingPathComponent("Antrag Müller.pdf"), picA = dir.appendingPathComponent("a.png"), picB = dir.appendingPathComponent("b.png")
            let pdfBytes = Data("%PDF-1.7\nSDK-FILE-MARKER\n".utf8) + Data((0..<300).map { UInt8($0 % 251) })
            let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<64).map { UInt8($0) })
            try pdfBytes.write(to: pdfFile); try pngBytes.write(to: picA); try pngBytes.write(to: picB)
            let rf1 = try await runPHP([sdk, "--credentials", credFile.path, "--url", url, "--key", "sdk-files-1", "--file=antrag=\(pdfFile.path)", "--file=bilder=\(picA.path)", "--file=bilder=\(picB.path)", "name=Mit Dateien"])
            XCTAssertEqual(rf1.status, 0, "stderr: \(rf1.err)")
            let nObjects = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE object_role = 'attachment'").first(decoding: C.self)?.c
            XCTAssertEqual(nObjects, 3)
            struct A: Decodable { let ordinal_no: Int; let ciphertext: Blob }
            let atts = try await f.sql.raw("SELECT ordinal_no, ciphertext FROM stored_objects WHERE object_role = 'attachment' ORDER BY ordinal_no").all(decoding: A.self)
            guard atts.count == 3 else { XCTFail("attachments: \(atts.count), SDK: \(rf1.out) \(rf1.err)"); return }
            XCTAssertEqual(try PackageV2(String(decoding: atts[0].ciphertext.data, as: UTF8.self)).open(recipient: sk), pdfBytes)
            XCTAssertEqual(try PackageV2(String(decoding: atts[2].ciphertext.data, as: UTF8.self)).open(recipient: sk), pngBytes)
            // a file the SDK itself refuses never reaches the server
            let exe = dir.appendingPathComponent("x.exe"); try Data("MZ".utf8).write(to: exe)
            let rf2 = try await runPHP([sdk, "--credentials", credFile.path, "--url", url, "--file=datei=\(exe.path)"])
            XCTAssertEqual(rf2.status, 64, rf2.err)

            // refusals as seen by the SDK: wrong key (403), unknown form (404), unreachable server (transport, exit 2), bad usage
            let other = dir.appendingPathComponent("other.json")
            var wrong = cfg
            let seed2 = Data((0..<32).map { UInt8(200 - $0) })
            wrong["signingSeed"] = seed2.base64URLString
            wrong["signingPublicKey"] = try Curve25519.Signing.PrivateKey(rawRepresentation: seed2).publicKey.rawRepresentation.base64URLString
            FileManager.default.createFile(atPath: other.path, contents: try JSONSerialization.data(withJSONObject: wrong), attributes: [.posixPermissions: 0o600])
            let r4 = try await runPHP([sdk, "--credentials", other.path, "--url", url, "nachricht=x"])
            XCTAssertEqual(r4.status, 1); XCTAssertTrue(r4.err.contains("403"), r4.err)
            var unknown = wrong; unknown["formId"] = UUID().uuidString.lowercased()
            let third = dir.appendingPathComponent("unknown.json")
            FileManager.default.createFile(atPath: third.path, contents: try JSONSerialization.data(withJSONObject: unknown), attributes: [.posixPermissions: 0o600])
            let r5 = try await runPHP([sdk, "--credentials", third.path, "--url", url, "nachricht=x"])
            XCTAssertEqual(r5.status, 1); XCTAssertTrue(r5.err.contains("404"), r5.err)
            let r6 = try await runPHP([sdk, "--credentials", credFile.path, "--url", "http://127.0.0.1:1", "nachricht=x"])
            XCTAssertEqual(r6.status, 2, r6.err)
            let r7 = try await runPHP([sdk, "--credentials", credFile.path, "--url", url, "a.b=1"])
            XCTAssertEqual(r7.status, 64)
            let still = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c
            XCTAssertEqual(still, 2)   // the plain submission and the one with files
            XCTAssertFalse((r1.out + r1.err + r4.err).contains(cfg["signingSeed"] as? String ?? "?"), "the seed never appears in SDK output")
        }
    }
}
