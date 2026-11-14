// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
@testable import FormCrypto
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// Card C4D13F4D: the legacy system allowed uploads up to 20 MB inside ONE `:2` package, so an imported data object can exceed 16 MiB - 1 as well.
/// The decryption probe ("Entschlüsselungsprobe") reads such an object; it must deliver it whole (the browser decrypts it) and confirm it.
/// Needs P3B_DB_ARGS=--max-allowed-packet=67108864 backend/integration-test.sh --filter ImportLargeAttachment
extension ImportRehearsalTests {
    func testDecryptionProbeDeliversImportedPackageAbove16MiBWhole() async throws {
        try await withHarness(perForm: 1, statistics: 1) { h in
            struct V: Decodable { let v: String }
            let limit = Int(try await h.fx.sql.raw("SELECT CAST(@@global.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
            try XCTSkipIf(limit < 60_000_000, "needs max_allowed_packet >= 64 MiB (got \(limit))")
            let id = try await importedJob(h)
            // the object the probe picks (first imported :2 data package) ...
            var firstHash = ""
            try await h.user.get("migration/jobs/\(id)/probe") { res in firstHash = jsonObject(res)["hash"] as? String ?? "" }
            XCTAssertEqual(firstHash.count, 64)
            struct Row: Decodable { let id: Blob }
            let found = try await h.fx.sql.raw("SELECT id FROM stored_objects WHERE ciphertext_sha256 = UNHEX(\(bind: firstHash)) AND object_role = 'data' LIMIT 1").first(decoding: Row.self)
            let row = try XCTUnwrap(found)
            // ... becomes what an import of a 19.9 MB legacy upload produces: one data package of about 27 MB, written in pieces like the importer does
            var plain = Data(count: 19_900_000); for i in stride(from: 0, to: plain.count, by: 4099) { plain[i] = UInt8(truncatingIfNeeded: i / 4099) }
            let sk = Curve25519.KeyAgreement.PrivateKey(), p = try PackageV2.seal(plain, recipient: sk.publicKey.rawRepresentation), wire = Data(p.wire.utf8)
            XCTAssertGreaterThan(wire.count, 16_777_215)
            try await h.fx.sql.raw("UPDATE stored_objects SET ciphertext = \(bind: ChunkedBlob.head(wire)), ciphertext_sha256 = \(bind: Blob(sha256(wire))), byte_count = \(bind: wire.count) WHERE id = \(bind: row.id)").run()
            try await ChunkedBlob.append(wire, to: .objectCiphertext, key: row.id, on: h.fx.sql)
            let stored = try await h.scalar("SELECT CONCAT(OCTET_LENGTH(ciphertext), ':', SHA2(ciphertext, 256)) AS v FROM stored_objects WHERE id = UNHEX('\(row.id.data.hex)')")
            XCTAssertEqual(stored, "\(wire.count):\(sha256(wire).hex)", "the imported cell is complete in the database")

            var probe: [String: Any] = [:], status = HTTPStatus.ok
            try await h.user.get("migration/jobs/\(id)/probe") { res in status = res.status; probe = jsonObject(res) }
            XCTAssertEqual(status, .ok)
            XCTAssertEqual(probe["hash"] as? String, sha256(wire).hex)
            let delivered = Data((probe["wire"] as? String ?? "").utf8)
            XCTAssertEqual(delivered.count, wire.count, "probe package length"); XCTAssertEqual(sha256(delivered), sha256(wire), "probe package hash")
            XCTAssertEqual(sha256(try PackageV2(probe["wire"] as? String ?? "").open(recipient: sk)), sha256(plain), "the delivered package opens to the exact bytes")
            try await h.user.send(.POST, "migration/jobs/\(id)/verify", body: "{\"hash\":\"\(sha256(wire).hex)\",\"success\":true}") { XCTAssertEqual($0.status, .ok, String(decoding: Data(buffer: $0.body).prefix(200), as: UTF8.self)) }
        }
    }
}
