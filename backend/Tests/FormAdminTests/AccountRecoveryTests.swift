// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

final class AccountRecoveryTests: XCTestCase {
    func testRecoveryCreationIsolationCASValidationAndUpgradeReplay() async throws {
        try await AdminFixture.with { f in
            let user = try await f.account(), other = try await f.account()
            let c = try await f.login(user), d = try await f.login(other)
            let pk = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLString
            func body(_ revision: String? = nil, iterations: Int = 600000) throws -> String {
                let b: [String: Any] = ["publicKey": pk, "expectedRevision": revision as Any? ?? NSNull(), "recovery": ["salt": Data(repeating: 1, count: 32).base64URLString, "iterations": iterations, "iv": Data(repeating: 2, count: 12).base64URLString, "wrap": Data(repeating: 3, count: 48).base64URLString]]
                return String(decoding: try JSONSerialization.data(withJSONObject: b), as: UTF8.self)
            }
            try await c.send(.PUT, "me/account-recovery", body: body(), csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await c.send(.PUT, "me/account-recovery", body: body(iterations: 1)) { XCTAssertEqual($0.status.code, 422) }
            var revision = ""
            try await c.send(.PUT, "me/account-recovery", body: body()) { r in
                XCTAssertEqual(r.status, .ok); revision = jsonObject(r)["revision"] as? String ?? ""
                XCTAssertEqual(r.headers.first(name: .cacheControl), "no-store")
            }
            XCTAssertFalse(revision.isEmpty)
            try await c.get("me/key-bundle") { r in
                XCTAssertEqual(jsonObject(r)["accountPublicKey"] as? String, pk)
                XCTAssertEqual((jsonObject(r)["recovery"] as? [String: Any])?["revision"] as? String, revision)
            }
            try await d.get("me/key-bundle") { XCTAssertTrue(jsonObject($0)["recovery"] is NSNull) }
            try await c.send(.PUT, "me/account-recovery", body: body()) { XCTAssertEqual($0.status, .conflict) }
            try await c.send(.PUT, "me/account-recovery", body: body(revision)) { XCTAssertEqual($0.status, .ok) }
            try await c.send(.PUT, "me/account-recovery", body: body(revision)) { XCTAssertEqual($0.status, .conflict) }
            let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("db/upgrades/0027-account-recovery.sql").path
            let outcome = try await MigrationRunner(db: f.sql).run(schemaFile: schema, name: "0027-account-recovery")
            XCTAssertEqual(outcome, .alreadyApplied)
        }
    }
}
