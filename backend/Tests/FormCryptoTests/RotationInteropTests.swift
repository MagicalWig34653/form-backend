// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation
import XCTest
@testable import FormCrypto

final class RotationInteropTests: XCTestCase {
    func testBrowserRewrapOpensInSwift() throws {
        struct Vector: Decodable {
            struct Case: Decodable { let name: String; let source: String; let plaintext: String; let package: String }
            let oldSecret: String; let newSecret: String; let cases: [Case]
        }
        func unhex(_ s: String) throws -> Data {
            guard s.count % 2 == 0 else { throw FormCryptoError.format }
            var d = Data(); var i = s.startIndex
            while i < s.endIndex { let end = s.index(i, offsetBy: 2); guard let b = UInt8(s[i..<end], radix: 16) else { throw FormCryptoError.format }; d.append(b); i = end }; return d
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: root.appendingPathComponent("pwa/src/lib/crypto/fixtures/rotation.json")))
        let old = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: unhex(vector.oldSecret))
        let new = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: unhex(vector.newSecret))
        XCTAssertEqual(vector.cases.count, 3)
        for c in vector.cases {
            let source = try PackageV2(c.source), result = try PackageV2(c.package)
            XCTAssertEqual(source.iv, result.iv, c.name); XCTAssertEqual(source.ciphertext, result.ciphertext, c.name); XCTAssertEqual(source.tag, result.tag, c.name)
            XCTAssertEqual(try source.open(recipient: old), try unhex(c.plaintext), c.name)
            XCTAssertEqual(try result.open(recipient: new), try unhex(c.plaintext), c.name)
            XCTAssertThrowsError(try result.open(recipient: old), c.name)
        }
    }
}
