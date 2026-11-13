// SPDX-License-Identifier: AGPL-3.0-only
import FormPersistence
import Foundation
import SQLKit
import XCTest
@testable import FormAuth

final class SecretStoreTests: XCTestCase {
    private let key = try! StaticServerKey(Data(repeating: 7, count: 32))

    func testRoundTripIsEncryptedAndBoundToItsReference() async throws {
        try await DBFixture.with { f in
            let store = SecretStore(db: f.app.db(.mysql), keys: key)
            let secret = Data((0..<32).map { UInt8($0 + 1) })
            let ref = try await store.put(secret)
            XCTAssertTrue(SecretStore.validRef(ref))
            let back = try await store.get(ref)
            XCTAssertEqual(back, secret)
            struct Ct: Decodable { let ciphertext: Blob }
            let raw = try await f.sql.raw("SELECT ciphertext FROM managed_secrets WHERE ref = \(bind: ref)").first(decoding: Ct.self)!.ciphertext.data
            XCTAssertNil(raw.range(of: secret), "plaintext is not stored")
            // swapped rows do not authenticate (AAD = reference)
            let other = try await store.put(Data(repeating: 9, count: 32))
            try await f.sql.raw("UPDATE managed_secrets SET ciphertext = \(bind: Blob(raw)) WHERE ref = \(bind: other)").run()
            let swapped = try await store.get(other)
            XCTAssertNil(swapped)
            // another server key cannot open it; bit flips are detected
            let otherKey = SecretStore(db: f.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 8, count: 32)))
            let withOther = try await otherKey.get(ref)
            XCTAssertNil(withOther)
            var flipped = raw; flipped[20] ^= 1
            try await f.sql.raw("UPDATE managed_secrets SET ciphertext = \(bind: Blob(flipped)) WHERE ref = \(bind: ref)").run()
            let tampered = try await store.get(ref)
            XCTAssertNil(tampered)
            // malformed / unknown references are simply absent
            for bad in ["", "s1:nope", "s2:" + UUID().uuidString.lowercased(), "s1:" + UUID().uuidString, "s1:" + UUID().uuidString.lowercased()] {
                let r = try await store.get(bad)
                XCTAssertNil(r, bad)
            }
            do { _ = try await store.put(Data(count: 201)); XCTFail() } catch let e as SecretStore.Failure { XCTAssertEqual(e, .tooLong) }
        }
    }
}
