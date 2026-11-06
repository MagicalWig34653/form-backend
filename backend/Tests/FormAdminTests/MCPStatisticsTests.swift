// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

final class MCPStatisticsUnitTests: XCTestCase {
    func testInputRejectsUnboundedAndUnknownArguments() throws {
        let args: [String: JSONValue] = ["tenantId": .string(UUID().uuidString), "formId": .string(UUID().uuidString)]
        let input = try MCPStatistics.Input(args)
        XCTAssertEqual(input.days, 30); XCTAssertEqual(input.limit, 50)
        for (key, raw) in [("days", "0"), ("days", "367"), ("limit", "101"), ("limit", "0"), ("limit", "true"), ("sql", "1")] {
            var invalid = args; invalid[key] = try JCS.parse(Data(raw.utf8))
            XCTAssertThrowsError(try MCPStatistics.Input(invalid), raw)
        }
        XCTAssertThrowsError(try MCPStatistics.Input(["tenantId": .string(UUID().uuidString)]))
        var max = args; max["days"] = try JCS.parse(Data("366".utf8)); max["limit"] = try JCS.parse(Data("100".utf8))
        XCTAssertEqual(try MCPStatistics.Input(max).limit, 100)
    }
    func testUTCWindowAcrossLeapDayAndYearBoundary() {
        let now = ISO8601DateFormatter().date(from: "2024-03-01T00:15:00Z")!
        let window = MCPStatistics.window(days: 2, now: now)
        XCTAssertEqual(window.0, "2024-02-29"); XCTAssertEqual(window.1, "2024-03-01")
        XCTAssertEqual(MCPStatistics.window(days: 366, now: now).0, "2023-03-02")
    }
    func testExplicitScopeNeverExpandsExistingTokens() {
        XCTAssertEqual(TokenIdentity.scopeRights["statistik.lesen"], ["statistics.read"])
        XCTAssertFalse(TokenIdentity.scopeRights["konfiguration.lesen"]!.contains("statistics.read"))
        XCTAssertFalse(TokenIdentity.scopeRights["entwurf.schreiben"]!.contains("statistics.read"))
    }
    func testRegistryHasUniqueReadOnlyToolsAndAds() {
        XCTAssertEqual(Set(MCPStatistics.names).count, 6)
        XCTAssertEqual(MCPStatistics.descriptions.count, 6)
        XCTAssertEqual(MCPStatistics.names.last, "ads_statistics")
    }
}

/// Written and compiled here; execution requires the synthetic MariaDB fixture.
final class MCPStatisticsDBTests: XCTestCase {
    func testBoundariesLiveRevocationMetadataAndTokenBudget() async throws {
        try await AdminFixture.with { fx in
            let account = try await fx.account(), tenant = try await fx.customer()
            let form = try await fx.form(customer: tenant), other = try await fx.form(customer: tenant)
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed=1 WHERE id=\(bind: DB.bin(account))").run()
            for right in ["token.manage", "statistics.read"] { try await fx.grant(account, right, customer: tenant, form: form, by: account) }
            let service = TokenService(db: fx.app.db(.mysql))
            let issued = try await service.create(account: account, label: "synthetic", scopes: ["statistik.lesen"], boundary: .init(tenantId: tenant, formId: form), expiresAt: Date().addingTimeInterval(172800))
            let h = HTTPHeaders([("Authorization", "Bearer " + issued.token), ("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")])
            func call(_ name: String, form target: UUID, extra: String = "", success: Bool) async throws {
                let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":{\"tenantId\":\"\(tenant)\",\"formId\":\"\(target)\"\(extra)}}}"
                try await fx.app.test(.POST, "mcp", headers: h, body: .init(string: body)) {
                    XCTAssertEqual($0.status, .ok)
                    XCTAssertTrue($0.body.string.contains("\"isError\":\(success ? "false" : "true")"), $0.body.string)
                }
            }
            for name in MCPStatistics.names { try await call(name, form: form, success: true) }
            try await call("statistik_kpis", form: other, success: false)
            let foreign = try await fx.customer(), foreignForm = try await fx.form(customer: foreign)
            try await call("statistik_kpis", form: foreignForm, success: false)
            try await fx.app.test(.GET, ".well-known/oauth-authorization-server") {
                XCTAssertEqual($0.status, .ok)
                let meta = try JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as! [String: Any]
                XCTAssertNotNil(meta["issuer"]); XCTAssertNotNil(meta["authorization_endpoint"]); XCTAssertNotNil(meta["token_endpoint"])
                XCTAssertEqual(meta["response_types_supported"] as? [String], ["code"])
                XCTAssertTrue((meta["scopes_supported"] as? [String])?.contains("statistik.lesen") == true)
            }
            try await fx.app.test(.GET, ".well-known/oauth-protected-resource") {
                XCTAssertEqual($0.status, .ok); XCTAssertTrue($0.body.string.contains("authorization_servers"))
            }
            try await fx.sql.raw("UPDATE permission_assignments SET revoked_at=NOW(6) WHERE account_id=\(bind: DB.bin(account)) AND permission='statistics.read'").run()
            try await call("statistik_kpis", form: form, success: false)
            try await fx.app.test(.POST, "mcp", headers: h, body: .init(string: "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")) {
                XCTAssertFalse($0.body.string.contains("statistik_kpis"))
            }
            try await SystemSettings.write(fx.sql, key: "mcp.requestsPerMinute", value: "1", at: DB.time(Date()))
            try await fx.sql.raw("DELETE FROM auth_throttles").run()
            let ping = ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}")
            try await fx.app.test(.POST, "mcp", headers: h, body: ping) { XCTAssertEqual($0.status, .ok) }
            try await fx.app.test(.POST, "mcp", headers: h, body: ping) { XCTAssertEqual($0.status, .tooManyRequests) }
            try await fx.grant(account, "statistics.read", customer: tenant, form: form, by: account)
            let second = try await service.create(account: account, label: "independent", scopes: ["statistik.lesen"], boundary: .init(tenantId: tenant, formId: form), expiresAt: Date().addingTimeInterval(172800))
            var independent = h; independent.replaceOrAdd(name: .authorization, value: "Bearer " + second.token)
            try await fx.app.test(.POST, "mcp", headers: independent, body: ping) { XCTAssertEqual($0.status, .ok) }
            struct Audit: Decodable { let actor_id: Blob?; let safe_details_json: String }
            let audits = try await fx.sql.raw("SELECT actor_id,safe_details_json FROM audit_events WHERE category='statistics'").all(decoding: Audit.self)
            XCTAssertEqual(audits.count, 6)
            for row in audits { XCTAssertNil(row.actor_id); XCTAssertEqual(row.safe_details_json, "{}") }
        }
    }
}

extension MCPStatisticsDBTests {
    func testSeededProductionEventsMatchRESTAndTruncateWithoutVisitorData() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer()
            for right in ["form.create", "form.read", "draft.write", "release.publish", "statistics.read", "token.manage"] { try await fx.grant(a, right, customer: c, by: a) }
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed=1 WHERE id=\(bind: DB.bin(a))").run()
            let client = try await fx.login(a)
            func object(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body))) as? [String: Any] ?? [:] }
            var form = "", draft = "", hash = "", confirmation = ""
            try await client.post("tenants/\(c)/forms", "{\"name\":\"Synthetisch\"}") { form = object($0)["id"] as? String ?? "" }
            try await client.get("tenants/\(c)/forms/\(form)") { draft = (object($0)["draftIds"] as? [String])?.first ?? "" }
            try await client.get("tenants/\(c)/forms/\(form)/drafts/\(draft)") { hash = object($0)["hash"] as? String ?? "" }
            try await client.post("tenants/\(c)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { confirmation = object($0)["confirmationId"] as? String ?? "" }
            try await client.send(.POST, "tenants/\(c)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key": "synthetic-statistics"]) { XCTAssertEqual($0.status, .created) }
            let f = try XCTUnwrap(UUID(uuidString: form))
            for n in 0..<106 {
                try await fx.sql.raw("""
                    INSERT INTO statistics_events (id,customer_id,form_id,release_id,view_id,domain_alias,visit_pseudonym,event_kind,source,environment,occurred_at,expires_at)
                    SELECT \(bind: DB.bin(UUID())),customer_id,form_id,release_id,view_id,\(bind: DB.bin(UUID())),\(bind: Blob(Data(repeating: UInt8(n), count: 16))),'visit','client',\(bind: n == 105 ? "test" : "production"),NOW(6),DATE_ADD(NOW(6),INTERVAL 13 MONTH)
                    FROM release_views WHERE form_id=\(bind: DB.bin(f)) LIMIT 1
                    """).run()
            }
            let service = TokenService(db: fx.app.db(.mysql))
            let issued = try await service.create(account: a, label: "statistics", scopes: ["statistik.lesen"], boundary: .init(tenantId: c, formId: f), expiresAt: Date().addingTimeInterval(172800))
            let token = try await service.resolve(issued.token)
            let args: [String: JSONValue] = ["tenantId": .string(c.uuidString), "formId": .string(form)]
            let input = try MCPStatistics.Input(args)
            let kpi = try await MCPStatistics.call("statistik_kpis", input: input, token: token, db: fx.app.db(.mysql), now: Date())["kpi"] as! [String: Any]
            XCTAssertEqual(kpi["visits"] as? Int, 105)
            try await client.get("tenants/\(c)/forms/\(form)/statistics") { XCTAssertEqual(object($0)["visits"] as? Int, kpi["visits"] as? Int) }
            let events = try await MCPStatistics.call("statistik_eintraege", input: input, token: token, db: fx.app.db(.mysql), now: Date())
            XCTAssertEqual(events["truncated"] as? Bool, true)
            let rows = try XCTUnwrap(events["events"] as? [[String: String]])
            XCTAssertEqual(rows.count, 50)
            XCTAssertEqual(Set(rows[0].keys), ["occurredAt", "kind"])
            let config = try await service.create(account: a, label: "configuration", scopes: ["konfiguration.lesen"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(172800))
            do {
                _ = try await MCPStatistics.call("statistik_kpis", input: input, token: try await service.resolve(config.token), db: fx.app.db(.mysql), now: Date())
                XCTFail("configuration token must not read statistics")
            } catch {}
        }
    }
}
