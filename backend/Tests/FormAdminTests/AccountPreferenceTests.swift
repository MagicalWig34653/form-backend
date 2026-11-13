// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTVapor
import XCTest

final class AccountPreferenceTests: XCTestCase {
    func testAllowlist() {
        XCTAssertNotNil(AccountPreferenceRoutes.validate("theme", .string("dark")))
        XCTAssertNotNil(AccountPreferenceRoutes.validate("accent", .string("schiefer")))
        XCTAssertNotNil(AccountPreferenceRoutes.validate("glow", .int(6)))
        XCTAssertNil(AccountPreferenceRoutes.validate("theme", .string("blue")))
        XCTAssertNil(AccountPreferenceRoutes.validate("accent", .string("blue")))
        XCTAssertNil(AccountPreferenceRoutes.validate("accent", .string("#0f766e")))
        XCTAssertNil(AccountPreferenceRoutes.validate("glow", .int(7)))
        XCTAssertNil(AccountPreferenceRoutes.validate("glow", .int(-1)))
        XCTAssertNil(AccountPreferenceRoutes.validate("glow", .bool(true)))
        XCTAssertNil(AccountPreferenceRoutes.validate("glow", .string("3")))
        XCTAssertNil(AccountPreferenceRoutes.validate("other", .string("dark")))
        XCTAssertEqual(AccountPreferenceRoutes.accents.count, 20)
    }

    // DB integration: runs with backend/integration-test.sh.
    func testOwnAccountReadWritePartialAndValidation() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), b = try await fx.account()
            let user = try await fx.login(a), other = try await fx.login(b)
            try await user.get("me/preferences") { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                XCTAssertTrue(jsonObject(res).isEmpty)
            }
            try await user.send(.PUT, "me/preferences", body: #"{"theme":"dark","accent":"blau","glow":3}"#) { res in
                XCTAssertEqual(res.status, .ok)
                let o = jsonObject(res)
                XCTAssertEqual(o["theme"] as? String, "dark")
                XCTAssertEqual(o["accent"] as? String, "blau")
                XCTAssertEqual(o["glow"] as? Int, 3)
            }
            // Partial update keeps the other keys.
            try await user.send(.PUT, "me/preferences", body: #"{"glow":0}"#) { res in
                XCTAssertEqual(res.status, .ok)
                let o = jsonObject(res)
                XCTAssertEqual(o["theme"] as? String, "dark")
                XCTAssertEqual(o["accent"] as? String, "blau")
                XCTAssertEqual(o["glow"] as? Int, 0)
            }
            // Invalid value, unknown key, wrong type, empty object: 422 and nothing changed.
            for body in [#"{"theme":"neon"}"#, #"{"theme":"light","foreign":"x"}"#, #"{"glow":true}"#, #"{"glow":9}"#, #"{"accent":"blue"}"#, "{}", "[]"] {
                try await user.send(.PUT, "me/preferences", body: body) { res in
                    XCTAssertEqual(res.status, .unprocessableEntity, body)
                    XCTAssertFalse(res.body.string.contains("neon"))
                }
            }
            try await user.send(.PUT, "me/preferences", body: #"{"glow":1,"glow":2}"#) { XCTAssertEqual($0.status, .badRequest) }
            try await user.get("me/preferences") { res in
                let o = jsonObject(res)
                XCTAssertEqual(o["theme"] as? String, "dark")
                XCTAssertEqual(o["glow"] as? Int, 0)
                XCTAssertEqual(o.count, 3)
            }
            // A second account sees nothing of the first one and writes only its own row.
            try await other.get("me/preferences") { XCTAssertTrue(jsonObject($0).isEmpty) }
            try await other.send(.PUT, "me/preferences", body: #"{"theme":"light"}"#) { XCTAssertEqual(jsonObject($0).count, 1) }
            try await user.get("me/preferences") { XCTAssertEqual(jsonObject($0)["theme"] as? String, "dark") }
            struct Count: Decodable { let n: Int }
            let rows = try await fx.sql.raw("SELECT COUNT(*) AS n FROM account_preferences WHERE account_id = \(bind: DB.bin(b))").first(decoding: Count.self)
            XCTAssertEqual(rows?.n, 1)
            // A stale session (older than the fresh-login window) still works: no reauthentication needed.
            try await fx.sql.raw("UPDATE sessions SET authenticated_at = '2000-01-01' WHERE account_id = \(bind: DB.bin(a))").run()
            try await user.send(.PUT, "me/preferences", body: #"{"theme":"system"}"#) { XCTAssertEqual($0.status, .ok) }
        }
    }

    func testRequiresSessionAndCSRF() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account()
            let user = try await fx.login(a)
            let anonymous = TestClient(app: fx.app, cookie: nil, csrf: nil)
            try await anonymous.get("me/preferences") { XCTAssertEqual($0.status, .unauthorized) }
            try await anonymous.send(.PUT, "me/preferences", body: #"{"theme":"dark"}"#) { XCTAssertEqual($0.status, .unauthorized) }
            try await user.send(.PUT, "me/preferences", body: #"{"theme":"dark"}"#, csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await user.send(.PUT, "me/preferences", body: #"{"theme":"dark"}"#, headers: ["Origin": "https://evil.example"]) { XCTAssertEqual($0.status, .forbidden) }
            try await user.get("me/preferences") { XCTAssertTrue(jsonObject($0).isEmpty) }
        }
    }
}
