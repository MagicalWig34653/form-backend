// SPDX-License-Identifier: AGPL-3.0-only
import FormAuth
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

final class FormRoutesTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private struct Frm: Decodable { let active: Int; let name: String }

    func testListFormsIsScopedPaginatedAndHidesForeignTenants() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), c1Reader = try await f.account(), formReader = try await f.account(), nobody = try await f.account()
            let c1 = try await f.customer(), c2 = try await f.customer()
            let a = try await f.form(customer: c1, name: "a"), b = try await f.form(customer: c1, name: "b"), c = try await f.form(customer: c1, name: "c")
            _ = try await f.form(customer: c2, name: "other")
            try await f.grant(root, "form.read", system: true, by: root)
            try await f.grant(c1Reader, "form.read", customer: c1, by: root)
            try await f.grant(formReader, "form.read", customer: c1, form: a, by: root)

            let admin = try await f.login(root)
            var all: [String] = []
            var cursor: String? = nil
            repeat {
                try await admin.get("tenants/\(c1.uuidString)/forms?limit=2" + (cursor.map { "&cursor=\($0)" } ?? "")) { res async throws in
                    XCTAssertEqual(res.status, .ok)
                    XCTAssertEqual(res.headers.first(name: "Cache-Control"), "no-store")
                    let j = jsonObject(res)
                    all += (j["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                    cursor = j["nextCursor"] as? String
                }
            } while cursor != nil
            XCTAssertEqual(Set(all), Set([a, b, c].map { $0.uuidString.lowercased() }))
            XCTAssertEqual(all.count, 3)
            XCTAssertEqual(all, all.sorted())

            // customer scope: own tenant only, foreign tenant does not exist for them
            let reader = try await f.login(c1Reader)
            try await reader.get("tenants/\(c1.uuidString)/forms") { res async throws in XCTAssertEqual((jsonObject(res)["items"] as? [Any])?.count, 3) }
            try await reader.get("tenants/\(c2.uuidString)/forms") { res async throws in XCTAssertEqual(res.status, .notFound) }
            // form scope: only that form
            let one = try await f.login(formReader)
            try await one.get("tenants/\(c1.uuidString)/forms") { res async throws in
                let ids = (jsonObject(res)["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                XCTAssertEqual(ids, [a.uuidString.lowercased()])
            }
            // no grant at all
            let nobodyClient = try await f.login(nobody)
            try await nobodyClient.get("tenants/\(c1.uuidString)/forms") { res async throws in XCTAssertEqual(res.status, .notFound) }
            // unauthenticated, bad ids, bad paging
            try await TestClient(app: f.app, cookie: nil, csrf: nil).get("tenants/\(c1.uuidString)/forms") { res async throws in XCTAssertEqual(res.status, .unauthorized) }
            try await admin.get("tenants/not-a-uuid/forms") { res async throws in XCTAssertEqual(res.status, .badRequest) }
            try await admin.get("tenants/\(c1.uuidString)/forms?limit=0") { res async throws in XCTAssertEqual(res.status, .badRequest) }
            try await admin.get("tenants/\(c1.uuidString)/forms?limit=101") { res async throws in XCTAssertEqual(res.status, .badRequest) }
            try await admin.get("tenants/\(c1.uuidString)/forms?cursor=zz") { res async throws in XCTAssertEqual(res.status, .badRequest) }
        }
    }

    func testCreateFormChecksCSRFRightsScopeAndWritesAudit() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), reader = try await f.account(), formScoped = try await f.account()
            let c1 = try await f.customer(), c2 = try await f.customer(), dead = try await f.customer(state: "disabled")
            let existing = try await f.form(customer: c1)
            try await f.grant(root, "form.create", system: true, by: root)
            try await f.grant(reader, "form.read", customer: c1, by: root)
            try await f.grant(formScoped, "form.create", customer: c1, form: existing, by: root)
            let admin = try await f.login(root)
            let body = "{\"name\":\"Kontakt\"}"

            try await admin.post("tenants/\(c1.uuidString)/forms", body, csrf: false) { res async throws in XCTAssertEqual(jsonObject(res)["code"] as? String, "csrf_invalid") }
            try await admin.post("tenants/\(c1.uuidString)/forms", body, origin: false) { res async throws in XCTAssertEqual(res.status, .forbidden) }
            try await admin.post("tenants/\(c1.uuidString)/forms", "{\"name\":\"  \"}") { res async throws in XCTAssertEqual(res.status, .unprocessableEntity) }
            try await admin.post("tenants/\(c1.uuidString)/forms", "{\"name\":\"\(String(repeating: "x", count: 191))\"}") { res async throws in XCTAssertEqual(res.status, .unprocessableEntity) }
            try await admin.post("tenants/\(c1.uuidString)/forms", "{\"name\":\"a\\u0007b\"}") { res async throws in XCTAssertEqual(res.status, .unprocessableEntity) }
            try await admin.post("tenants/\(c1.uuidString)/forms", "{\"name\":\"x\",\"extra\":1}") { res async throws in XCTAssertNotEqual(res.status, .created) }
            let none = try await f.sql.raw("SELECT COUNT(*) AS c FROM forms WHERE customer_id = \(bind: DB.bin(c1))").first(decoding: C.self)?.c
            XCTAssertEqual(none, 1, "rejected requests must not create anything")

            var newID = ""
            try await admin.post("tenants/\(c1.uuidString)/forms", body) { res async throws in
                XCTAssertEqual(res.status, .created)
                let j = jsonObject(res)
                XCTAssertEqual(j["status"] as? String, "created")
                newID = j["id"] as? String ?? ""
            }
            let row = try await f.sql.raw("SELECT active, name FROM forms WHERE id = \(bind: DB.bin(UUID(uuidString: newID)!))").first(decoding: Frm.self)
            XCTAssertEqual(row?.active, 0)           // created inactive; activation is a separate decision (F8)
            XCTAssertEqual(row?.name, "Kontakt")
            let audit = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'form.create' AND subject_id = \(bind: DB.bin(UUID(uuidString: newID)!))").first(decoding: C.self)?.c
            XCTAssertEqual(audit, 1)

            // reader: covered but no action right -> 403; form-scoped grant does not cover the customer -> 404; foreign/disabled tenant -> 404
            try await (try await f.login(reader)).post("tenants/\(c1.uuidString)/forms", body) { res async throws in XCTAssertEqual(res.status, .forbidden) }
            try await (try await f.login(formScoped)).post("tenants/\(c1.uuidString)/forms", body) { res async throws in XCTAssertEqual(res.status, .notFound) }
            try await admin.post("tenants/\(dead.uuidString)/forms", body) { res async throws in XCTAssertEqual(res.status, .notFound) }
            try await admin.post("tenants/\(UUID().uuidString)/forms", body) { res async throws in XCTAssertEqual(res.status, .notFound) }
            _ = c2
        }
    }

    func testGetFormDistinguishesMissingForeignAndForbidden() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), reader = try await f.account(), noRight = try await f.account()
            let c1 = try await f.customer(), c2 = try await f.customer()
            let mine = try await f.form(customer: c1), theirs = try await f.form(customer: c2)
            try await f.grant(root, "form.read", system: true, by: root)
            try await f.grant(reader, "form.read", customer: c1, by: root)
            try await f.grant(noRight, "content.read", customer: c1, by: root)
            let r = try await f.login(reader)
            try await r.get("tenants/\(c1.uuidString)/forms/\(mine.uuidString)") { res async throws in
                XCTAssertEqual(res.status, .ok)
                let j = jsonObject(res)
                XCTAssertEqual(j["id"] as? String, mine.uuidString.lowercased())
                XCTAssertEqual(j["active"] as? Bool, false)
                XCTAssertEqual((j["draftIds"] as? [Any])?.count, 0)   // seeded directly, no standard draft
            }
            // path combines tenant c1 with a form of c2: not found, never forbidden
            try await r.get("tenants/\(c1.uuidString)/forms/\(theirs.uuidString)") { res async throws in XCTAssertEqual(res.status, .notFound) }
            try await r.get("tenants/\(c2.uuidString)/forms/\(theirs.uuidString)") { res async throws in XCTAssertEqual(res.status, .notFound) }
            try await r.get("tenants/\(c1.uuidString)/forms/\(UUID().uuidString)") { res async throws in XCTAssertEqual(res.status, .notFound) }
            // covered by another right but not form.read -> 403
            try await (try await f.login(noRight)).get("tenants/\(c1.uuidString)/forms/\(mine.uuidString)") { res async throws in XCTAssertEqual(res.status, .forbidden) }
            try await (try await f.login(root)).get("tenants/\(c2.uuidString)/forms/\(theirs.uuidString)") { res async throws in XCTAssertEqual(res.status, .ok) }
        }
    }

    func testFactorPendingSessionIsNotEnough() async throws {
        try await AdminFixture.with { f in
            let acc = try await f.account()
            let c1 = try await f.customer()
            try await f.grant(acc, "form.read", system: true, by: acc)
            let (_, anon) = try await f.sessions.createAnonymous()
            let (token, _) = try await f.sessions.rotate(from: anon, to: .factorPending, accountID: acc, method: "passkey", rightsVersion: 0)
            let c = TestClient(app: f.app, cookie: "\(SessionService.cookieName)=\(token)", csrf: nil)
            try await c.get("tenants/\(c1.uuidString)/forms") { res async throws in XCTAssertEqual(res.status, .unauthorized) }
        }
    }
}
