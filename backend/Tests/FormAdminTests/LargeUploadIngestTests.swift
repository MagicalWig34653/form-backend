// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormAuth
import FormCore
@testable import FormCrypto
import FormPersistence
import FormStorage
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// QA finding "SDK upload 14-19.5 MB -> HTTP 500 at max_allowed_packet=64M" (MySQLNIO cannot send/receive a packet of 16 MiB - 1 or more, ChunkedBlob).
/// With a database at >= 64 MiB every upload up to the documented 20 MB must be accepted, stored completely, served back byte-exactly (attachment
/// endpoint, hash and decryption), and removed by retention without a failing maintenance pass.
/// Run: P3B_DB_ARGS=--max-allowed-packet=67108864 backend/integration-test.sh --filter LargeUploadIngest
final class LargeUploadIngestTests: XCTestCase {
    private struct V: Decodable { let v: String }
    private struct C: Decodable { let c: Int }
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }
    private func multipart(_ boundary: String, text: [(String, String)], file: (field: String, name: String, type: String, data: Data)) -> Data {
        var d = Data()
        for (k, v) in text { d += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
        d += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\r\nContent-Type: \(file.type)\r\n\r\n".utf8) + file.data + Data("\r\n".utf8)
        return d + Data("--\(boundary)--\r\n".utf8)
    }

    func testUploadsUpToTheDocumentedLimitAreStoredServedAndRetained() async throws {
        try await AdminFixture.with { f in
            let limit = Int(try await f.sql.raw("SELECT CAST(@@global.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
            try XCTSkipIf(limit < 60_000_000, "needs max_allowed_packet >= 64 MiB (got \(limit))")
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            for r in ["form.create", "form.read", "draft.write", "release.publish", "key.manage", "content.read", "content.decrypt"] { try await f.grant(user, r, customer: tenant, by: root) }
            let admin = try await f.login(user)
            var form = "", draft = "", hash = "", conf = ""
            try await admin.post("tenants/\(tenant)/forms", "{\"name\":\"Kontakt\"}") { form = obj($0)["id"] as? String ?? "" }
            try await admin.get("tenants/\(tenant)/forms/\(form)") { draft = (obj($0)["draftIds"] as? [String])?.first ?? "" }
            try await admin.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { hash = obj($0)["hash"] as? String ?? "" }
            try await admin.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { conf = obj($0)["confirmationId"] as? String ?? "" }
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(conf)\"}", headers: ["Idempotency-Key": "k"]) { XCTAssertEqual($0.status, .created) }
            let sk = Curve25519.KeyAgreement.PrivateKey()
            try await admin.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            var seed = Data()
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: obj($0)["signingSeed"] as? String ?? "") ?? Data() }

            func send(content: Data, key: String) async throws -> (Int, String) {
                let file = (field: "antrag", name: "antrag.pdf", type: "application/pdf", data: content)
                let signed = FileField.single(SignedFile(name: file.name, type: file.type, error: 0, size: Int64(content.count), content: content))
                let canonical = try RequestSignature.canonical(fields: PHPValue.array([("nachricht", PHPValue.string("Erika"))]), files: [("antrag", signed)])
                let ts = String(Int64(Date().timeIntervalSince1970))
                let sig = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: form, timestamp: ts, canonical: canonical), seed: seed)
                var h = HTTPHeaders(); h.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=XBOUNDX")
                h.add(name: "X-Kubus-Timestamp", value: ts); h.add(name: "X-Kubus-Signature", value: sig.base64EncodedString()); h.add(name: "Idempotency-Key", value: key)
                var out = (0, "")
                try await f.app.test(.POST, "api/v2/submit/?f=\(form)", headers: h, body: ByteBuffer(data: multipart("XBOUNDX", text: [("nachricht", "Erika")], file: file))) { out = (Int($0.status.code), String(decoding: Data(buffer: $0.body), as: UTF8.self)) }
                return out
            }

            // 12 MB (worked before), 14/17/19.5 MB (500 before) and the documented maximum (below 20 MB) (sealed package about 27 MB)
            for (n, size) in [12_000_000, 14_000_000, 17_000_000, 19_500_000, 19_999_999].enumerated() {
                var content = Data("%PDF-1.4\n".utf8) + Data(count: size - 9)
                for i in stride(from: 9, to: content.count, by: 4093) { content[i] = UInt8(truncatingIfNeeded: i / 4093 + n) }
                let (status, body) = try await send(content: content, key: "big-\(n)")
                print("MEASURE ingest attachment \(size) bytes at max_allowed_packet=\(limit): HTTP \(status)")
                XCTAssertEqual(status, 200, "\(size): \(body.prefix(200))")
                guard status == 200 else { continue }
                struct Sub: Decodable { let id: Blob }
                // every submission so far: stored completely, checked in the database (length and SHA-256 over the whole cell)
                let intact = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE OCTET_LENGTH(ciphertext) = byte_count AND UNHEX(SHA2(ciphertext, 256)) = ciphertext_sha256").first(decoding: C.self)?.c
                XCTAssertEqual(intact, 2 * (n + 1), "\(size): stored objects incomplete or damaged")
                let entry = try await f.sql.raw("SELECT s.id AS id FROM submissions s JOIN stored_objects o ON o.submission_id = s.id AND o.object_role = 'attachment' ORDER BY o.byte_count DESC LIMIT 1").first(decoding: Sub.self)
                let entryID = DB.uuid(try XCTUnwrap(entry).id.data)!.uuidString.lowercased()
                // read back through the admin API: package hash equals the stored hash, and it opens to the exact bytes sent
                try await admin.get("tenants/\(tenant)/forms/\(form)/entries/\(entryID)/attachments/0") { res async throws in
                    XCTAssertEqual(res.status, .ok, "\(size) read-back: \(String(decoding: Data(buffer: res.body).prefix(200), as: UTF8.self))")
                    guard res.status == .ok else { return }
                    let wire = obj(res)["package"] as? String ?? ""
                    let opened = try PackageV2(wire).open(recipient: sk)
                    XCTAssertEqual(opened.count, content.count, "\(size) length")
                    XCTAssertEqual(Data(SHA256.hash(data: opened)), Data(SHA256.hash(data: content)), "\(size) plaintext hash")
                }
            }

            // retention: a submission with large attachments is deleted (not skipped), maintenance finds nothing to repair and does not fail
            let total = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c
            XCTAssertEqual(total, 5)
            try await f.sql.raw("UPDATE submissions SET retention_due_at = '2000-01-01 00:00:00.000000'").run()
            let purged = try await SubmissionEraser.purgeDue(db: f.app.db(.mysql), now: Date(), storage: f.app.storage[StorageServiceKey.self])
            XCTAssertEqual(purged, 5)
            let left = try await f.sql.raw("SELECT (SELECT COUNT(*) FROM submissions) + (SELECT COUNT(*) FROM stored_objects) AS c").first(decoding: C.self)?.c
            XCTAssertEqual(left, 0, "retention must delete the submissions with their large objects")

            // Imported data: the import appends a cell in pieces, so the database can hold one above 16 MiB (here: a 12 MB upload grown to about 21 MB
            // with SQL, like an imported cell). Retention and the minute maintenance must handle it; before, the inventory read (`SELECT *` with the
            // whole cell) failed for such a row: "storage maintenance failed" every minute and the deletion never completed.
            let c2 = try await send(content: Data("%PDF-1.4\n".utf8) + Data(repeating: 7, count: 12_000_000), key: "grown")
            XCTAssertEqual(c2.0, 200, c2.1)
            for _ in 0..<5 { try await f.sql.raw("UPDATE stored_objects SET ciphertext = CONCAT(ciphertext, REPEAT('A', 1000000)), byte_count = byte_count + 1000000, ciphertext_sha256 = ciphertext_sha256 WHERE OCTET_LENGTH(ciphertext) > 1000000").run() }
            let grown = try await f.sql.raw("SELECT CAST(MAX(OCTET_LENGTH(ciphertext)) AS CHAR) AS v FROM stored_objects").first(decoding: V.self)?.v
            XCTAssertGreaterThan(Int(grown ?? "0") ?? 0, 16_777_216, "the test cell must exceed 16 MiB")
            try await f.sql.raw("UPDATE stored_objects SET state = 'deleting'").run()
            try await StorageMaintenance.run(service: try XCTUnwrap(f.app.storage[StorageServiceKey.self]))
            let left2 = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects").first(decoding: C.self)?.c
            XCTAssertEqual(left2, 0, "maintenance must complete the interrupted deletion")
        }
    }
}
