// SPDX-License-Identifier: AGPL-3.0-only
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

final class DomainAdminTests: XCTestCase {
    func testDomainHostnameValidation() throws {
        XCTAssertEqual(try DomainRoutes.host("WWW.Example.Test", adminHost: "admin.example.test"), "www.example.test")
        XCTAssertEqual(try DomainRoutes.host("xn--bcher-kva.example", adminHost: "admin.example.test"), "xn--bcher-kva.example")
        for value in ["admin.example.test", "ADMIN.EXAMPLE.TEST", "example.test.", "example.test:443", "*.example.test", "https://example.test", "a..test", "-bad.test", "127.0.0.1", "[::1]", "bücher.example", "a.test\n", "user@a.test", "a.test/path"] {
            XCTAssertThrowsError(try DomainRoutes.host(value, adminHost: "admin.example.test"), value)
        }
    }
    struct World { let root: UUID; let user: UUID; let tenant: UUID; let form: UUID; let view: UUID; let release: UUID; let client: TestClient }
    func setup(_ f: AdminFixture) async throws -> World {
        let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
        for right in ["form.create", "form.read", "draft.write", "release.publish"] { try await f.grant(user, right, customer: tenant, by: root) }
        let client = try await f.login(user)
        var form = "", draft = "", hash = "", confirmation = "", release = "", view = ""
        try await client.post("tenants/\(tenant)/forms", "{\"name\":\"Domains\"}") { form = jsonObject($0)["id"] as? String ?? "" }
        try await client.get("tenants/\(tenant)/forms/\(form)") { draft = (jsonObject($0)["draftIds"] as? [String])?.first ?? "" }
        try await client.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { hash = jsonObject($0)["hash"] as? String ?? "" }
        try await client.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { confirmation = jsonObject($0)["confirmationId"] as? String ?? "" }
        try await client.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key": "domain-world"]) {
            XCTAssertEqual($0.status, .created)
            release = jsonObject($0)["id"] as? String ?? ""
            view = ((jsonObject($0)["views"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        }
        return World(root: root, user: user, tenant: tenant, form: UUID(uuidString: form)!, view: UUID(uuidString: view)!, release: UUID(uuidString: release)!, client: client)
    }
    func body(_ w: World, hostname: String = "contact.example.test", enabled: Bool = false, production: Bool = false, view: UUID? = nil, release: UUID? = nil, confirm: Bool = true) -> String {
        "{\"hostname\":\"\(hostname)\",\"tenantId\":\"\(w.tenant)\",\"formId\":\"\(w.form)\",\"viewId\":\"\(view ?? w.view)\",\"releaseId\":\"\(release ?? w.release)\",\"mode\":\"\(production ? "production" : "testing")\",\"enabled\":\(enabled),\"confirm\":\(confirm)}"
    }
    func testDomainRightsCustomerScopeFreshnessAndTenantIsolation() async throws {
        try await AdminFixture.with { f in
            let w = try await setup(f)
            try await w.client.post("domains", body(w)) { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(w.user, "domain.manage", customer: w.tenant, form: w.form, by: w.root)
            try await w.client.post("domains", body(w)) { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(w.user, "domain.manage", customer: w.tenant, by: w.root)
            try await w.client.post("domains", body(w, confirm: false)) { XCTAssertEqual($0.status.code, 422) }
            try await w.client.post("domains", body(w, view: UUID())) { XCTAssertEqual($0.status.code, 422) }
            let other = try await f.customer()
            try await w.client.get("domains?tenantId=\(other)") { XCTAssertEqual($0.status, .notFound) }
            try await w.client.post("domains", body(w), csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await w.client.post("domains", body(w, enabled: true, production: true)) { XCTAssertEqual($0.status.code, 422) }
            try await f.sql.raw("UPDATE sessions SET authenticated_at=DATE_SUB(NOW(),INTERVAL 10 MINUTE) WHERE account_id=\(bind: DB.bin(w.user))").run()
            try await w.client.post("domains", body(w)) { XCTAssertEqual($0.status.code, 403) }
        }
    }
    func testDomainUniqueRevisionActivationAndAudit() async throws {
        try await AdminFixture.with { f in
            let w = try await setup(f)
            try await f.grant(w.user, "domain.manage", customer: w.tenant, by: w.root)
            var id = ""
            try await w.client.post("domains", body(w, hostname: "CONTACT.example.test")) {
                XCTAssertEqual($0.status, .created, String(buffer: $0.body)); id = jsonObject($0)["id"] as? String ?? ""
            }
            try await w.client.post("domains", body(w)) { XCTAssertEqual($0.status, .conflict) }
            try await w.client.send(.PATCH, "domains/\(id)", body: body(w, enabled: true, production: true)) { XCTAssertEqual($0.status, .preconditionRequired) }
            try await w.client.send(.PATCH, "domains/\(id)", body: body(w, enabled: true, production: true), headers: ["If-Match": "\"1\""]) { XCTAssertEqual($0.status, .ok, String(buffer: $0.body)) }
            try await w.client.send(.PATCH, "domains/\(id)", body: body(w), headers: ["If-Match": "\"1\""]) { XCTAssertEqual($0.status, .preconditionFailed) }
            try await w.client.get("domains?tenantId=\(w.tenant)") {
                let rows = jsonObject($0)["items"] as? [[String: Any]] ?? []
                XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["revision"] as? Int, 2); XCTAssertEqual(rows.first?["enabled"] as? Bool, true)
            }
            try await w.client.send(.DELETE, "domains/\(id)", body: "{\"confirm\":true}", headers: ["If-Match": "\"2\""]) { XCTAssertEqual($0.status, .conflict) }
            struct C: Decodable { let c: Int }
            let audited = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE category='domain' AND JSON_VALUE(safe_details_json,'$.hostname')='contact.example.test'").first(decoding: C.self)?.c
            XCTAssertEqual(audited, 2)
            try await w.client.send(.PATCH, "domains/\(id)", body: body(w), headers: ["If-Match": "\"2\""]) { XCTAssertEqual($0.status, .ok) }
            try await w.client.send(.DELETE, "domains/\(id)", body: "{\"confirm\":true}", headers: ["If-Match": "\"3\""]) { XCTAssertEqual($0.status, .noContent) }
        }
    }
    func testDomainAPIHostNamespacesAndForeignCustomerProtection() async throws {
        try await AdminFixture.with { f in
            let w = try await setup(f), other = try await setup(f)
            try await f.grant(w.user, "domain.manage", customer: w.tenant, by: w.root)
            try await f.grant(other.user, "domain.manage", customer: other.tenant, by: other.root)
            var id = ""
            func apiBody(_ form: UUID, enabled: Bool, revision: Int) -> String { "{\"hostname\":\"api.example.test\",\"formIds\":[\"\(form)\"],\"enabled\":\(enabled),\"expectedRevision\":\(revision),\"confirm\":true}" }
            try await w.client.post("api-hosts?tenantId=\(w.tenant)", apiBody(w.form, enabled: false, revision: 0)) { XCTAssertEqual($0.status, .ok, String(buffer: $0.body)); id = jsonObject($0)["id"] as? String ?? "" }
            try await w.client.post("domains", body(w, hostname: "api.example.test")) { XCTAssertEqual($0.status, .conflict) }
            try await w.client.post("api-hosts?tenantId=\(w.tenant)", apiBody(other.form, enabled: false, revision: 1)) { XCTAssertEqual($0.status.code, 422) }
            try await other.client.post("api-hosts?tenantId=\(other.tenant)", apiBody(other.form, enabled: false, revision: 1)) { XCTAssertEqual($0.status, .ok) }
            try await w.client.post("api-hosts?tenantId=\(w.tenant)", apiBody(w.form, enabled: true, revision: 2)) { XCTAssertEqual($0.status, .forbidden) }
            try await w.client.send(.DELETE, "api-hosts/\(id)/forms/\(other.form)", body: "{\"confirm\":true}", headers: ["If-Match": "\"1\""]) { XCTAssertEqual($0.status, .notFound) }
            try await w.client.get("api-hosts?tenantId=\(w.tenant)") { XCTAssertEqual((jsonObject($0)["items"] as? [[String: Any]])?.count, 1) }
            func releaseBody(_ release: UUID, hostRevision: Int, bindingRevision: Int) -> String {
                "{\"hostname\":\"api.example.test\",\"formIds\":[\"\(w.form)\"],\"enabled\":false,\"expectedRevision\":\(hostRevision),\"confirm\":true,\"releaseBindings\":[{\"formId\":\"\(w.form)\",\"releaseId\":\"\(release)\",\"expectedBindingRevision\":\(bindingRevision)}]}"
            }
            try await w.client.post("api-hosts?tenantId=\(w.tenant)", releaseBody(w.release, hostRevision: 2, bindingRevision: 1)) { XCTAssertEqual($0.status, .ok, String(buffer: $0.body)) }
            try await w.client.post("api-hosts?tenantId=\(w.tenant)", releaseBody(w.release, hostRevision: 3, bindingRevision: 1)) { XCTAssertEqual($0.status, .preconditionFailed) }
            try await w.client.post("api-hosts?tenantId=\(w.tenant)", releaseBody(other.release, hostRevision: 3, bindingRevision: 2)) { XCTAssertEqual($0.status.code, 422) }
            try await w.client.send(.DELETE, "api-hosts/\(id)/forms/\(w.form)", body: "{\"confirm\":true}", headers: ["If-Match": "\"2\""]) { XCTAssertEqual($0.status, .noContent) }
            // Removing/recreating the same (host, form) must never revive a stale binding revision (ABA).
            try await w.client.post("api-hosts?tenantId=\(w.tenant)", apiBody(w.form, enabled: false, revision: 4)) { XCTAssertEqual($0.status, .ok) }
            try await w.client.send(.DELETE, "api-hosts/\(id)/forms/\(w.form)", body: "{\"confirm\":true}", headers: ["If-Match": "\"2\""]) { XCTAssertEqual($0.status, .preconditionFailed) }
            try await w.client.send(.DELETE, "api-hosts/\(id)/forms/\(w.form)", body: "{\"confirm\":true}", headers: ["If-Match": "\"5\""]) { XCTAssertEqual($0.status, .noContent) }


        }
    }
}
