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

/// Finding "Upload-Verlust": an attachment whose sealed package is larger than the database's max_allowed_packet was reported as accepted
/// (driver success) while NO row existed. Now the ingest must never answer 2xx without stored data: it refuses BEFORE writing (413, existing
/// code `payload_too_large`), and the submission/objects tables stay untouched. Works with any test database below ~26 MB packet size
/// (the attachment is sized from the live limit; backend/integration-test.sh with P3B_DB_ARGS=--max-allowed-packet=4194304 keeps it fast).
final class IngestPacketLimitTests: XCTestCase {
    private struct V: Decodable { let v: String }
    private struct C: Decodable { let c: Int }
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }

    private func multipart(_ boundary: String, text: [(String, String)], file: (field: String, name: String, type: String, data: Data)) -> Data {
        var d = Data()
        for (k, v) in text { d += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
        d += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\r\nContent-Type: \(file.type)\r\n\r\n".utf8) + file.data + Data("\r\n".utf8)
        return d + Data("--\(boundary)--\r\n".utf8)
    }

    func testAttachmentLargerThanTheDatabasePacketIsRefusedNotSilentlyLost() async throws {
        try await AdminFixture.with { f in
            let limit = Int(try await f.sql.raw("SELECT CAST(@@global.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
            try XCTSkipIf(limit <= 0 || limit >= 26_000_000, "test database packet limit \(limit) cannot be exceeded by an allowed upload (max 20 MB)")
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            for r in ["form.create", "form.read", "draft.write", "release.publish", "key.manage"] { try await f.grant(user, r, customer: tenant, by: root) }
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

            // The attachment is as large as the limit itself: its sealed package (base64, about 4/3) can never fit one packet.
            let size = min(limit, 20_000_000)
            let big = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x41, count: size)
            let (status, body) = try await send(content: big, key: "big-1")
            let subs = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c ?? -1
            let objs = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects").first(decoding: C.self)?.c ?? -1
            let stored = try await f.sql.raw("SELECT CAST(IFNULL(MAX(OCTET_LENGTH(ciphertext)),0) AS CHAR) AS v FROM stored_objects").first(decoding: V.self)?.v ?? "?"
            print("MEASURE ingest, attachment \(size) bytes at max_allowed_packet=\(limit): HTTP \(status) body \(body.prefix(200)); submissions=\(subs) stored_objects=\(objs) largest stored ciphertext=\(stored)")
            XCTAssertFalse((200..<300).contains(status), "never accepted when the data cannot be stored (got \(status))")
            XCTAssertEqual(status, 413)
            XCTAssertTrue(body.contains("payload_too_large"), body)
            XCTAssertEqual(subs, 0); XCTAssertEqual(objs, 0)

            // The service stays usable: a small attachment through the same connections is accepted and stored completely.
            let (okStatus, okBody) = try await send(content: Data("%PDF-1.4\n".utf8) + Data(repeating: 1, count: 1000), key: "small-1")
            XCTAssertEqual(okStatus, 200, okBody)
            let subs2 = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c
            let objs2 = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE OCTET_LENGTH(ciphertext) = byte_count").first(decoding: C.self)?.c
            XCTAssertEqual(subs2, 1); XCTAssertEqual(objs2, 2)
            // A large attachment that does fit (2 MB, above the check threshold, so the post-write verification runs) is stored completely.
            if limit > 4_000_000 {
                let (midStatus, midBody) = try await send(content: Data("%PDF-1.4\n".utf8) + Data(repeating: 2, count: 2_000_000), key: "mid-1")
                XCTAssertEqual(midStatus, 200, midBody)
                let objs3 = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE OCTET_LENGTH(ciphertext) = byte_count").first(decoding: C.self)?.c
                XCTAssertEqual(objs3, 4)
            }
        }
    }
}
