// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTVapor
import XCTest

final class SettingsTests: XCTestCase {
    func testSystemRightIsExplicitAndCannotBeScopedToCustomer() {
        XCTAssertTrue(PermissionCatalog.all.contains("system.settings"))
        XCTAssertFalse(GrantScope.customer(UUID()).covers(.system))
        XCTAssertFalse(TokenIdentity.scopeRights.values.contains { $0.contains("system.settings") })
    }
    func testMCPLimitChangesWithoutRestart() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer()
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed = 1 WHERE id = \(bind: DB.bin(a))").run()
            for right in ["token.manage", "form.read"] { try await fx.grant(a, right, customer: c, by: a) }
            let issued = try await TokenService(db: fx.app.db(.mysql)).create(account: a, label: "limits", scopes: ["konfiguration.lesen"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(86400))
            let headers = HTTPHeaders([("Authorization", "Bearer " + issued.token), ("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")])
            try await SystemSettings.write(fx.sql, key: "mcp.requestsPerMinute", value: "2", at: DB.time(Date()))
            for expected in [HTTPResponseStatus.ok, .ok, .tooManyRequests] {
                try await fx.app.test(.POST, "mcp", headers: headers, body: .init(string: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")) { XCTAssertEqual($0.status, expected) }
            }
            try await SystemSettings.write(fx.sql, key: "mcp.requestsPerMinute", value: "4", at: DB.time(Date()))
            try await fx.app.test(.POST, "mcp", headers: headers, body: .init(string: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")) { XCTAssertEqual($0.status, .ok) }
        }
    }
    // DB integration coverage is compiled here; deliberately not run without Docker.
    func testSettingsRightsCSRFRevisionAndAudit() async throws {
        try await AdminFixture.with { fx in
            let account = try await fx.account()
            let user = try await fx.login(account)
            try await user.get("settings") { XCTAssertEqual($0.status, .notFound) }
            try await fx.grant(account, "system.settings", system: true, by: account)
            var revision = ""
            try await user.get("settings") { res in
                XCTAssertEqual(res.status, .ok)
                let data = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as! [String: Any]
                revision = data["revision"] as! String
            }
            let invalid = "{\"revision\":\"\(revision)\",\"values\":{\"mcp.requestsPerMinute\":\"70\",\"not.registered\":\"x\"}}"
            try await user.send(.PUT, "settings", body: invalid) { XCTAssertEqual($0.status, .unprocessableEntity) }
            let unchanged = try await SystemSettings.read(fx.sql)
            XCTAssertNil(unchanged["mcp.requestsPerMinute"])
            let duplicate = "{\"revision\":\"\(revision)\",\"values\":{\"mcp.requestsPerMinute\":\"70\",\"mcp.requestsPerMinute\":\"80\"}}"
            try await user.send(.PUT, "settings", body: duplicate) { XCTAssertEqual($0.status, .badRequest) }
            let body = "{\"revision\":\"\(revision)\",\"values\":{\"mcp.requestsPerMinute\":\"70\"}}"
            try await user.send(.PUT, "settings", body: body, csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await user.send(.PUT, "settings", body: body) { XCTAssertEqual($0.status, .ok) }
            try await user.send(.PUT, "settings", body: body) { XCTAssertEqual($0.status, .conflict) }
            struct Audit: Decodable { let details: String }
            let audit = try await fx.sql.raw("SELECT safe_details_json AS details FROM audit_events WHERE action_code = 'system.settings.update'").first(decoding: Audit.self)!
            XCTAssertTrue(audit.details.contains("mcp.requestsPerMinute"))
            XCTAssertFalse(audit.details.contains("70"))
            try await fx.sql.raw("UPDATE sessions SET authenticated_at = '2000-01-01' WHERE account_id = \(bind: DB.bin(account))").run()
            try await user.get("settings") { XCTAssertEqual($0.status, .forbidden) }
        }
    }
}
