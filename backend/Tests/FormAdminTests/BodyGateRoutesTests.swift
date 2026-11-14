// SPDX-License-Identifier: AGPL-3.0-only
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// Codex final review, finding 2: PATCH drafts/:draftId (1 MiB), POST migration/jobs (1 MiB), PUT/GET settings (32 KiB) and POST /mcp (64 KiB)
/// collected their body BEFORE authentication, throttling and the shared byte budget. Measurement as in BodyBudgetRouteTests: the budget
/// counters prove whether a reservation (hence the permission to buffer) happened. Real MariaDB (backend/integration-test.sh).
/// Without the gates these tests fail: authenticated requests get no reservation (`granted` stays 0) and an exhausted budget does not
/// answer 503, because the handler runs and collects the body.
final class BodyGateRoutesTests: XCTestCase {
    private let kib = 1 << 10
    private func code(_ r: XCTHTTPResponse) -> String { (jsonObject(r)["code"] as? String) ?? "" }
    private func body(_ n: Int) -> ByteBuffer { ByteBuffer(repeating: 0x41, count: n) }

    private func migrationSecrets(_ f: AdminFixture) throws {
        let secrets = SecretStore(db: f.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 31, count: 32)))
        SetupMigrationRoutes.register(f.app, guardian: f.guardian, secrets: secrets, allowInsecure: true, startWorker: false)
    }

    /// Every gated route: (method, path, limit in bytes, headers builder). `exhausted` fills the budget so that any body over ~9.5 KiB is refused.
    private func exhaust(_ budget: BodyBudget) throws -> BodyBudget.Lease {
        try XCTUnwrap(budget.reserve(bodyBytes: 340_000))   // 1_020_000 of 1 MiB: 28_576 bytes left, i.e. bodies > 9_525 bytes do not fit
    }

    func testAnonymousRequestsAreRefusedBeforeAnyReservation() async throws {
        try await AdminFixture.with { f in
            try self.migrationSecrets(f)
            let budget = BodyBudget(capacity: 1 << 20); f.app.bodyBudget = budget
            let t = UUID().uuidString.lowercased(), id = UUID().uuidString.lowercased()
            let busy = try self.exhaust(budget)   // even with a full budget an anonymous request must be answered 401 (authentication first), not 503
            var cookieless = HTTPHeaders(); cookieless.contentType = .json; cookieless.add(name: "Origin", value: AdminFixture.origin)
            for (method, path, size) in [(HTTPMethod.PATCH, "admin/api/v1/tenants/\(t)/forms/\(id)/drafts/\(id)", 1 << 20 - 1),
                                         (.POST, "admin/api/v1/migration/jobs", 1 << 20 - 1), (.PUT, "admin/api/v1/settings", 30 * self.kib)] {
                try await f.app.test(method, path, headers: cookieless, body: self.body(size)) { r async throws in
                    XCTAssertEqual(r.status, .unauthorized, path)
                }
            }
            var mcp = cookieless; mcp.add(name: "Accept", value: "application/json, text/event-stream")
            try await f.app.test(.POST, "mcp", headers: mcp, body: self.body(60 * self.kib)) { XCTAssertEqual($0.status, .unauthorized) }
            var bogus = mcp; bogus.replaceOrAdd(name: .authorization, value: "Bearer ofa_nonsense")
            try await f.app.test(.POST, "mcp", headers: bogus, body: self.body(60 * self.kib)) { XCTAssertEqual($0.status, .unauthorized) }
            try await f.app.test(.PATCH, "admin/api/v1/tenants/\(t)/forms/\(id)/drafts/\(id)", headers: bogus, body: self.body(900 * self.kib)) { XCTAssertEqual($0.status, .unauthorized) }
            XCTAssertEqual(budget.granted, 1, "only the occupying lease; nothing was reserved (or buffered) for the anonymous requests")
            XCTAssertEqual(budget.refused, 0)
            busy.release()
        }
    }

    func testDraftPatchNeedsReservationAndAnswers413And503BeforeCollecting() async throws {
        try await AdminFixture.with { f in
            let budget = BodyBudget(capacity: 192 << 20); f.app.bodyBudget = budget
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            try await f.grant(user, "draft.write", customer: tenant, by: root)
            let admin = try await f.login(user)
            let form = UUID().uuidString.lowercased(), draft = UUID().uuidString.lowercased()
            let path = "admin/api/v1/tenants/\(tenant)/forms/\(form)/drafts/\(draft)"
            // wrong Origin / missing CSRF: 403 before the reservation
            try await f.app.test(.PATCH, path, headers: admin.headers(origin: false), body: self.body(100 * self.kib)) { XCTAssertEqual($0.status, .forbidden) }
            try await f.app.test(.PATCH, path, headers: admin.headers(csrf: false), body: self.body(100 * self.kib)) { XCTAssertEqual($0.status, .forbidden) }
            XCTAssertEqual(budget.granted, 0)
            // declared length above the document limit: 413 without reservation
            try await f.app.test(.PATCH, path, headers: admin.headers(), body: self.body((1 << 20) + 1)) { r async throws in
                XCTAssertEqual(r.status, .payloadTooLarge); XCTAssertEqual(self.code(r), "payload_too_large")
            }
            XCTAssertEqual(budget.granted, 0)
            // admitted: reservation of 3x the declared length, given back afterwards (the draft does not exist, so the handler refuses it)
            try await f.app.test(.PATCH, path, headers: admin.headers(), body: self.body(100 * self.kib)) { r async throws in
                XCTAssertNotEqual(r.status, .serviceUnavailable); XCTAssertNotEqual(r.status, .payloadTooLarge); XCTAssertNotEqual(r.status, .unauthorized)
            }
            XCTAssertEqual(budget.granted, 1)
            XCTAssertEqual(budget.peak, 100 * self.kib * BodyBudget.memoryFactor)
            XCTAssertEqual(budget.inFlight, 0)
        }
        try await AdminFixture.with { f in
            let budget = BodyBudget(capacity: 1 << 20); f.app.bodyBudget = budget
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            try await f.grant(user, "draft.write", customer: tenant, by: root)
            let admin = try await f.login(user)
            let busy = try self.exhaust(budget)
            try await f.app.test(.PATCH, "admin/api/v1/tenants/\(tenant)/forms/\(UUID().uuidString.lowercased())/drafts/\(UUID().uuidString.lowercased())", headers: admin.headers(), body: self.body(12_000)) { r async throws in
                XCTAssertEqual(r.status, .serviceUnavailable); XCTAssertEqual(self.code(r), "body_budget_exhausted"); XCTAssertEqual(r.headers.first(name: "Retry-After"), "1")
            }
            XCTAssertEqual(budget.granted, 1, "only the occupying lease")
            busy.release()
        }
    }

    func testMigrationJobsAuthorizeAndReserveBeforeCollecting() async throws {
        try await AdminFixture.with { f in
            try self.migrationSecrets(f)
            let budget = BodyBudget(capacity: 1 << 20); f.app.bodyBudget = budget
            let actor = try await f.account(), other = try await f.account()
            try await f.grant(actor, "migration.run", system: true, by: actor)
            try await SystemSettings.write(f.sql, key: "migration.enabled", value: "true", at: DB.time(Date()))
            let admin = try await f.login(actor), unprivileged = try await f.login(other)
            // no migration.run: 403, nothing reserved
            try await f.app.test(.POST, "admin/api/v1/migration/jobs", headers: unprivileged.headers(), body: self.body(1 << 20)) { XCTAssertTrue([.forbidden, .notFound].contains($0.status), "\($0.status)") }
            XCTAssertEqual(budget.granted, 0)
            // declared length above the 1 MiB limit: 413 without reservation
            try await f.app.test(.POST, "admin/api/v1/migration/jobs", headers: admin.headers(), body: self.body((1 << 20) + 1)) { XCTAssertEqual($0.status, .payloadTooLarge) }
            XCTAssertEqual(budget.granted, 0)
            // admitted (the JSON is invalid, so the handler refuses it), lease given back
            try await f.app.test(.POST, "admin/api/v1/migration/jobs", headers: admin.headers(), body: self.body(2_000)) { r async throws in
                XCTAssertNotEqual(r.status, .serviceUnavailable); XCTAssertNotEqual(r.status, .payloadTooLarge); XCTAssertNotEqual(r.status, .unauthorized)
            }
            XCTAssertEqual(budget.granted, 1); XCTAssertEqual(budget.peak, 2_000 * BodyBudget.memoryFactor); XCTAssertEqual(budget.inFlight, 0)
            // budget occupied: 503, not read
            let busy = try self.exhaust(budget)
            try await f.app.test(.POST, "admin/api/v1/migration/jobs", headers: admin.headers(), body: self.body(12_000)) { r async throws in
                XCTAssertEqual(r.status, .serviceUnavailable); XCTAssertEqual(self.code(r), "body_budget_exhausted")
            }
            busy.release()
        }
    }

    func testSettingsAndMCPBodiesAreReservedAfterAuthentication() async throws {
        try await AdminFixture.with { f in
            let budget = BodyBudget(capacity: 192 << 20); f.app.bodyBudget = budget
            let account = try await f.account(), tenant = try await f.customer()
            try await f.sql.raw("UPDATE accounts SET mcp_allowed=1 WHERE id=\(bind: DB.bin(account))").run()
            for right in ["token.manage", "form.read"] { try await f.grant(account, right, customer: tenant, by: account) }
            let admin = try await f.login(account)
            let issued = try await TokenService(db: f.app.db(.mysql)).create(account: account, label: "synthetic", scopes: ["konfiguration.lesen"], boundary: .init(tenantId: tenant, formId: nil), expiresAt: Date().addingTimeInterval(172_800))
            let bearer = HTTPHeaders([("Authorization", "Bearer " + issued.token), ("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")])
            let ping = ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")
            // settings: 33 KiB declared against the 32 KiB limit is refused before the budget; an authenticated 4 KiB body is reserved and returned
            try await f.app.test(.PUT, "admin/api/v1/settings", headers: admin.headers(), body: self.body(33 * self.kib)) { XCTAssertEqual($0.status, .payloadTooLarge) }
            XCTAssertEqual(budget.granted, 0)
            try await f.app.test(.PUT, "admin/api/v1/settings", headers: admin.headers(), body: self.body(4 * self.kib)) { XCTAssertNotEqual($0.status, .serviceUnavailable); XCTAssertNotEqual($0.status, .unauthorized) }
            XCTAssertEqual(budget.granted, 1); XCTAssertEqual(budget.peak, 4 * self.kib * BodyBudget.memoryFactor); XCTAssertEqual(budget.inFlight, 0)
            // mcp: a valid token passes the gate once; the token rate limit is charged once per request (gate and handler share the identity)
            struct C: Decodable { let c: Int }
            func charges() async throws -> Int { try await f.sql.raw("SELECT CAST(COALESCE(SUM(failures),0) AS SIGNED) AS c FROM auth_throttles WHERE scope = 'admin-route'").first(decoding: C.self)?.c ?? 0 }
            let before = try await charges()
            try await f.app.test(.POST, "mcp", headers: bearer, body: ping) { XCTAssertEqual($0.status, .ok) }
            XCTAssertEqual(budget.granted, 2); XCTAssertEqual(budget.inFlight, 0)
            let after = try await charges()
            XCTAssertEqual(after - before, 1, "one token charge per request (test requests carry no socket address, so no IP charge), not doubled by gate plus handler")
            try await f.app.test(.POST, "mcp", headers: bearer, body: self.body(65 * self.kib)) { XCTAssertEqual($0.status, .payloadTooLarge) }
            XCTAssertEqual(budget.granted, 2)
        }
        try await AdminFixture.with { f in
            let budget = BodyBudget(capacity: 1 << 20); f.app.bodyBudget = budget
            let account = try await f.account(), tenant = try await f.customer()
            try await f.sql.raw("UPDATE accounts SET mcp_allowed=1 WHERE id=\(bind: DB.bin(account))").run()
            for right in ["token.manage", "form.read"] { try await f.grant(account, right, customer: tenant, by: account) }
            let admin = try await f.login(account)
            let issued = try await TokenService(db: f.app.db(.mysql)).create(account: account, label: "synthetic", scopes: ["konfiguration.lesen"], boundary: .init(tenantId: tenant, formId: nil), expiresAt: Date().addingTimeInterval(172_800))
            let bearer = HTTPHeaders([("Authorization", "Bearer " + issued.token), ("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")])
            let busy = try self.exhaust(budget)
            try await f.app.test(.POST, "mcp", headers: bearer, body: self.body(12_000)) { r async throws in
                XCTAssertEqual(r.status, .serviceUnavailable); XCTAssertEqual(self.code(r), "body_budget_exhausted")
            }
            try await f.app.test(.PUT, "admin/api/v1/settings", headers: admin.headers(), body: self.body(12_000)) { r async throws in
                XCTAssertEqual(r.status, .serviceUnavailable); XCTAssertEqual(self.code(r), "body_budget_exhausted")
            }
            XCTAssertEqual(budget.granted, 1)
            busy.release()
        }
    }
}
