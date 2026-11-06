// SPDX-License-Identifier: AGPL-3.0-only
import FormAuth
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

final class DirectoryTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }
    private func items(_ r: XCTHTTPResponse) -> [[String: Any]] { obj(r)["items"] as? [[String: Any]] ?? [] }

    func testMeTenantsListingFollowsTheRightsAndHintsAreOnlyHints() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), sysAcc = try await f.account(), custAdmin = try await f.account(), formOnly = try await f.account(), nobody = try await f.account()
            let c1 = try await f.customer(), c2 = try await f.customer()
            let form1 = try await f.form(customer: c1)
            try await f.grant(sysAcc, "system.manage", system: true, by: root); try await f.grant(sysAcc, "form.read", system: true, by: root)
            try await f.grant(custAdmin, "form.read", customer: c1, by: root); try await f.grant(custAdmin, "form.create", customer: c1, by: root)
            try await f.grant(formOnly, "draft.write", customer: c1, form: form1, by: root)
            let sys = try await f.login(sysAcc), cust = try await f.login(custAdmin), fo = try await f.login(formOnly), nb = try await f.login(nobody)
            // /me
            try await sys.get("me") { res async throws in XCTAssertEqual(obj(res)["systemAdministrator"] as? Bool, true); XCTAssertEqual(obj(res)["id"] as? String, sysAcc.uuidString.lowercased()) }
            try await cust.get("me") { XCTAssertEqual(obj($0)["systemAdministrator"] as? Bool, false) }
            try await TestClient(app: f.app, cookie: nil, csrf: nil).get("me") { XCTAssertEqual($0.status, .unauthorized) }
            // tenants: system administrators see every customer, others only theirs, form-scoped grants reveal the customer but give no customer-wide hints
            try await sys.get("tenants") { res async throws in XCTAssertEqual(Set(items(res).compactMap { $0["id"] as? String }), [c1, c2].map { $0.uuidString.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) }) }
            try await cust.get("tenants") { res async throws in
                XCTAssertEqual(items(res).compactMap { $0["id"] as? String }, [c1.uuidString.lowercased()])
                XCTAssertEqual(items(res).first?["permissions"] as? [String], ["form.create", "form.read"])
            }
            try await fo.get("tenants") { res async throws in
                XCTAssertEqual(items(res).compactMap { $0["id"] as? String }, [c1.uuidString.lowercased()]); XCTAssertEqual(items(res).first?["permissions"] as? [String], [])
            }
            try await nb.get("tenants") { XCTAssertEqual(self.items($0).count, 0) }
            // creating a customer: system administrators only (others learn nothing), fresh login, strict body, audit
            try await sys.send(.POST, "tenants", body: "{\"name\":\"  Neue Praxis  \"}") { res async throws in XCTAssertEqual(res.status, .created); XCTAssertNotNil(UUID(uuidString: obj(res)["id"] as? String ?? "")) }
            let name = try await f.sql.raw("SELECT COUNT(*) AS c FROM customers WHERE name = 'Neue Praxis'").first(decoding: C.self)?.c; XCTAssertEqual(name, 1)
            let audit = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'customer.create'").first(decoding: C.self)?.c; XCTAssertEqual(audit, 1)
            try await cust.send(.POST, "tenants", body: "{\"name\":\"X\"}") { XCTAssertEqual($0.status, .notFound) }
            for bad in ["{\"name\":\"\"}", "{\"name\":\"a\\nb\"}", "{\"name\":\"x\",\"extra\":1}", "{}"] { try await sys.send(.POST, "tenants", body: bad) { XCTAssertTrue([400, 422].contains($0.status.code), bad) } }
            try await sys.send(.POST, "tenants", body: "{\"name\":\"Y\"}", csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await f.sql.raw("UPDATE sessions SET authenticated_at = '2020-01-01 00:00:00.000000' WHERE state = 'authenticated'").run()
            try await sys.send(.POST, "tenants", body: "{\"name\":\"Z\"}") { XCTAssertEqual(obj($0)["code"] as? String, "reauthentication_required") }
        }
    }

    func testCustomerConnectionsAndTheFormsMailConnectionAreVisibleToTheCustomersAdmin() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), sysAcc = try await f.account(), user = try await f.account(), stranger = try await f.account()
            let c1 = try await f.customer(), c2 = try await f.customer(); let form = try await f.form(customer: c1)
            try await f.grant(sysAcc, "system.manage", system: true, by: root)
            for r in ["form.read", "release.publish"] { try await f.grant(user, r, customer: c1, by: root) }
            try await f.grant(stranger, "form.read", customer: c2, by: root)
            let sys = try await f.login(sysAcc), u = try await f.login(user), st = try await f.login(stranger)
            var id = ""
            try await sys.send(.POST, "connections", body: "{\"kind\":\"smtp\",\"name\":\"Relay\",\"config\":{\"host\":\"127.0.0.1\",\"port\":2525,\"security\":\"plain\"}}") { id = obj($0)["id"] as? String ?? "" }
            try await u.get("tenants/\(c1)/connections") { XCTAssertEqual(self.items($0).count, 0, "not assigned yet") }
            try await sys.send(.PUT, "tenants/\(c1)/connections/\(id)") { XCTAssertEqual($0.status, .noContent) }
            try await u.get("tenants/\(c1)/connections") { res async throws in
                XCTAssertEqual(items(res).count, 1); XCTAssertEqual(items(res).first?["name"] as? String, "Relay"); XCTAssertFalse(String(decoding: Data(buffer: res.body), as: UTF8.self).contains("2525"), "no configuration for customer admins")
            }
            try await st.get("tenants/\(c1)/connections") { XCTAssertEqual($0.status, .notFound) }
            try await u.get("tenants/\(c1)/forms/\(form)") { XCTAssertTrue(obj($0)["mailConnectionId"] is NSNull || obj($0)["mailConnectionId"] == nil) }
            try await u.send(.PUT, "tenants/\(c1)/forms/\(form)/mail-connection", body: "{\"connectionId\":\"\(id)\"}") { XCTAssertEqual($0.status, .noContent) }
            try await u.get("tenants/\(c1)/forms/\(form)") { XCTAssertEqual(obj($0)["mailConnectionId"] as? String, id) }
        }
    }
}
