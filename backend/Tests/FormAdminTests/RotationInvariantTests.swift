// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCrypto
import FormPersistence
import Foundation
import XCTest
@testable import FormAdmin

final class RotationInvariantTests: XCTestCase {
    func testBrowserReplacementEnforcesCASPayloadAndWrapRules() throws {
        struct Vector: Decodable {
            struct Case: Decodable { let source: String; let package: String }
            let cases: [Case]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: root.appendingPathComponent("pwa/src/lib/crypto/fixtures/rotation.json")))
        for c in v.cases {
            let source = try PackageV2(c.source), target = try PackageV2(c.package)
            let hash = Data(SHA256.hash(data: Data(c.source.utf8)))
            let row = RotationRoutes.Object(id: DB.bin(UUID()), form_id: DB.bin(UUID()), kid: source.kid, revision: 3, ciphertext_sha256: Blob(hash), payload_sha256: Blob(Data(SHA256.hash(data: source.iv + source.ciphertext + source.tag))), ciphertext: Blob(Data(c.source.utf8)), backend: "db", wrap_kind: source.wrap, held: nil)
            let proof = RotationRoutes.Replacement(expectedRevision: 3, expectedSha256: RotationRoutes.hex(hash), package: c.package)
            XCTAssertEqual(try RotationRoutes.replacement(row, proof, target: target.kid).wire, c.package)
            XCTAssertThrowsError(try RotationRoutes.replacement(row, proof, target: source.kid))
            XCTAssertThrowsError(try RotationRoutes.replacement(row, .init(expectedRevision: 2, expectedSha256: proof.expectedSha256, package: c.package), target: target.kid))
            XCTAssertThrowsError(try RotationRoutes.replacement(row, .init(expectedRevision: 3, expectedSha256: String(repeating: "0", count: 64), package: c.package), target: target.kid))
            var changed = c.package.components(separatedBy: "|")
            changed[4] = Data(repeating: 0, count: 12).base64EncodedString()
            XCTAssertThrowsError(try RotationRoutes.replacement(row, .init(expectedRevision: 3, expectedSha256: proof.expectedSha256, package: changed.joined(separator: "|")), target: target.kid))
            if target.wrap == "hpke" { XCTAssertThrowsError(try RotationRoutes.replacement(row, proof, target: target.kid, hold: true)) }
        }
    }
}
