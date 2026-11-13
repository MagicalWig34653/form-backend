// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTVapor
import XCTest

final class AuditUnitTests: XCTestCase {
    func testScopeClauseOnlyFromAuditReadGrants() {
        let c = UUID(), f = UUID()
        XCTAssertNil(AuditRoutes.scopeClause([]))
        XCTAssertNil(AuditRoutes.scopeClause([Grant(permission: "system.manage", scope: .system), Grant(permission: "content.read", scope: .customer(c))]))
        XCTAssertNotNil(AuditRoutes.scopeClause([Grant(permission: "audit.read", scope: .form(customer: c, form: f))]))
        XCTAssertNotNil(AuditRoutes.scopeClause([Grant(permission: "audit.read", scope: .system)]))
    }
    func testCodeValidation() {
        XCTAssertTrue(AuditRoutes.isCode("key.access.repair", max: 100))
        XCTAssertFalse(AuditRoutes.isCode("", max: 100))
        XCTAssertFalse(AuditRoutes.isCode("a b", max: 100))
        XCTAssertFalse(AuditRoutes.isCode("a'; DROP", max: 100))
        XCTAssertFalse(AuditRoutes.isCode(String(repeating: "a", count: 65), max: 64))
    }
}

/// MariaDB: rights, isolation, filters, paging and the metadata-only projection of GET /audit.
final class AuditDatabaseTests: XCTestCase {
    struct TestPage: Decodable { let items: [AuditRoutes.Item]; let nextCursor: String? }
    struct IdRow: Decodable { let id: Blob }

    func testRightsIsolationFiltersPagingAndNoDetails() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), other = try await fx.account(), actorB = try await fx.account()
            let c1 = try await fx.customer(), c2 = try await fx.customer()
            let f1 = try await fx.form(customer: c1), f1b = try await fx.form(customer: c1), f2 = try await fx.form(customer: c2)
            func insert(_ customer: UUID?, _ form: UUID?, actor: UUID?, action: String, category: String, at: String, details: String = "{}") async throws {
                try await fx.sql.raw("""
                    INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, occurred_at, safe_details_json)
                    VALUES (\(bind: DB.bin(UUID())), \(bind: customer.map(DB.bin)), \(bind: form.map(DB.bin)), \(bind: actor.map(DB.bin)), 'human', \(bind: category), \(bind: action), \(bind: at), \(bind: details))
                    """).run()
            }
            try await insert(c1, f1, actor: actorB, action: "key.rotate", category: "key", at: "2026-11-01 10:00:00.000000", details: "{\"hostname\":\"geheim.example.test\"}")
            try await insert(c1, f1, actor: a, action: "key.access.repair", category: "key", at: "2026-11-02 10:00:00.000000")
            try await insert(c1, f1b, actor: a, action: "release.publish", category: "release", at: "2026-11-03 10:00:00.000000")
            try await insert(c2, f2, actor: a, action: "key.rotate", category: "key", at: "2026-11-04 10:00:00.000000")
            try await insert(nil, nil, actor: a, action: "system.settings.update", category: "system", at: "2026-11-05 10:00:00.000000")
            let user = try await fx.login(other)
            let page = { (r: XCTHTTPResponse) in try JSONDecoder().decode(TestPage.self, from: Data(buffer: r.body)) }

            // No audit.read at all (also with other rights): 403.
            try await fx.grant(other, "content.read", customer: c1, form: f1, by: a)
            try await user.get("audit") { XCTAssertEqual($0.status, .forbidden) }
            // Form grant: exactly that form.
            try await fx.grant(other, "audit.read", customer: c1, form: f1, by: a)
            try await user.get("audit") { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                XCTAssertEqual(try page(res).items.map(\.action), ["key.access.repair", "key.rotate"])
                XCTAssertFalse(String(buffer: res.body).contains("geheim.example.test"))
                XCTAssertFalse(String(buffer: res.body).contains("details"))
            }
            // Narrowing to a foreign form never widens.
            try await user.get("audit?form=\(f2)") { XCTAssertEqual(try page($0).items.count, 0) }
            try await user.get("audit?customer=\(c2)") { XCTAssertEqual(try page($0).items.count, 0) }
            // Customer grant: all forms of c1, no foreign customer, no system rows.
            try await fx.grant(other, "audit.read", customer: c1, by: a)
            try await user.get("audit") { XCTAssertEqual(try page($0).items.count, 3) }
            // Filters.
            try await user.get("audit?action=release.publish") { XCTAssertEqual(try page($0).items.map(\.action), ["release.publish"]) }
            try await user.get("audit?category=key") { XCTAssertEqual(try page($0).items.count, 2) }
            try await user.get("audit?actor=\(actorB)") { XCTAssertEqual(try page($0).items.map(\.action), ["key.rotate"]) }
            try await user.get("audit?from=2026-11-02T00:00:00Z&to=2026-11-02T23:59:59Z") { XCTAssertEqual(try page($0).items.map(\.action), ["key.access.repair"]) }
            for bad in ["limit=0", "limit=101", "actor=x", "from=gestern", "action=a%20b", "from=2026-11-03T00:00:00Z&to=2026-11-01T00:00:00Z", "cursor=AAAA"] {
                try await user.get("audit?\(bad)") { XCTAssertEqual($0.status, .badRequest, bad) }
            }
            // Paging, newest first, no duplicates.
            var seen: [String] = [], cursor: String? = nil
            repeat {
                try await user.get("audit?limit=1" + (cursor.map { "&cursor=\($0)" } ?? "")) { res in
                    let p = try page(res)
                    seen += p.items.map(\.id)
                    cursor = p.nextCursor
                }
            } while cursor != nil
            XCTAssertEqual(seen.count, 3)
            XCTAssertEqual(Set(seen).count, 3)
            // A cursor from a row outside the caller's scope is refused.
            let foreign = try await fx.sql.raw("SELECT id FROM audit_events WHERE customer_id = \(bind: DB.bin(c2))").first(decoding: IdRow.self)!
            try await user.get("audit?cursor=\(foreign.id.data.base64URLString)") { XCTAssertEqual($0.status, .badRequest) }
            // System grant sees everything including rows without customer.
            try await fx.grant(other, "audit.read", system: true, by: a)
            try await user.get("audit") { res in
                let p = try page(res)
                XCTAssertEqual(p.items.count, 5)
                XCTAssertEqual(p.items.first?.action, "system.settings.update")
                XCTAssertNil(p.items.first?.customerId)
            }
            try await user.get("audit?customer=\(c2)") { XCTAssertEqual(try page($0).items.count, 1) }
            // Unauthenticated: 401.
            try await TestClient(app: fx.app, cookie: nil, csrf: nil).get("audit") { XCTAssertEqual($0.status, .unauthorized) }
        }
    }
}
