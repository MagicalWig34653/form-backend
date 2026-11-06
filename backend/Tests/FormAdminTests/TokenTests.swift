// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
@testable import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

final class TokenTests: XCTestCase {
    func testTokenBoundaryCannotDecryptPublishOrCrossTenant() {
        let c = UUID(), f = UUID()
        let token = TokenIdentity(id: UUID(), accountID: UUID(), scopes: ["konfiguration.lesen", "entwurf.schreiben"], boundary: .init(tenantId: c, formId: f))
        XCTAssertTrue(token.permits("draft.write", on: .form(customer: c, form: f)))
        for right in ["content.decrypt", "content.read", "release.publish", "token.manage", "key.manage", "flow.approve"] {
            XCTAssertFalse(token.permits(right, on: .form(customer: c, form: f)))
        }
        XCTAssertFalse(token.permits("form.read", on: .form(customer: UUID(), form: f)))
        XCTAssertFalse(token.permits("form.read", on: .form(customer: c, form: UUID())))
        XCTAssertFalse(token.permits("form.read", on: .customer(c)))
    }

    func testTokenLifecycleAndLiveRights() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer()
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed = 1 WHERE id = \(bind: DB.bin(a))").run()
            for right in ["token.manage", "form.read"] { try await fx.grant(a, right, customer: c, by: a) }
            let service = TokenService(db: fx.app.db(.mysql))
            let result = try await service.create(account: a, label: "synthetic", scopes: ["konfiguration.lesen"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(2 * 86400))
            XCTAssertTrue(result.token.hasPrefix("kfm_")); XCTAssertEqual(result.token.count, 68)
            let identity = try await service.resolve(result.token)
            try await identity.authorize(PermissionService(sql: fx.sql), "form.read", on: .customer(c))
            struct R: Decodable { let token_hash: Blob; let last_used_at: Date? }
            let row = try await fx.sql.raw("SELECT token_hash,last_used_at FROM mcp_tokens WHERE id = \(bind: DB.bin(result.id))").first(decoding: R.self)!
            XCTAssertEqual(row.token_hash.data, TokenService.digest(result.token)); XCTAssertNotNil(row.last_used_at)
            let user = try await fx.login(a)
            try await user.get("account/tokens") { res in
                XCTAssertEqual(res.status, .ok); XCTAssertFalse(res.body.string.contains(result.token)); XCTAssertFalse(res.body.string.contains("token_hash"))
            }
            let createBody = "{\"label\":\"HTTP-Test\",\"tenantId\":\"\(c)\",\"scopes\":[\"konfiguration.lesen\"],\"expiresAt\":\"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 86400)))\"}"
            try await user.post("account/tokens", createBody, csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            var httpSecret = ""
            try await user.post("account/tokens", createBody) {
                XCTAssertEqual($0.status, .created)
                XCTAssertEqual($0.headers.first(name: .cacheControl), "no-store")
                let obj = try JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as! [String: String]
                httpSecret = obj["token"]!
            }
            try await user.get("account/tokens") { XCTAssertFalse($0.body.string.contains(httpSecret)) }
            // No CSRF or cookie is needed on selected reads; forbidden routes cannot fall back to a cookie.
            let h = HTTPHeaders([("Authorization", "Bearer " + result.token)])
            try await fx.app.test(.GET, "admin/api/v1/tenants/\(c)/forms", headers: h) { XCTAssertEqual($0.status, .ok) }
            try await fx.app.test(.GET, "admin/api/v1/account/tokens", headers: h) { XCTAssertEqual($0.status, .unauthorized) }
            try await fx.app.test(.POST, "admin/api/v1/tenants/\(c)/forms", headers: h) { XCTAssertEqual($0.status, .unauthorized) }
            try await fx.sql.raw("UPDATE auth_throttles SET failures = 120 WHERE scope = 'admin-route'").run()
            try await fx.app.test(.GET, "admin/api/v1/tenants/\(c)/forms", headers: h) {
                XCTAssertEqual($0.status, .tooManyRequests); XCTAssertNotNil($0.headers.first(name: "Retry-After"))
            }
            try await fx.sql.raw("UPDATE permission_assignments SET revoked_at = NOW(6) WHERE account_id = \(bind: DB.bin(a)) AND permission = 'form.read'").run()
            do { try await identity.authorize(PermissionService(sql: fx.sql), "form.read", on: .customer(c)); XCTFail("live removal ignored") } catch {}
            do { _ = try await service.create(account: a, label: "escalation", scopes: ["entwurf.schreiben"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(2 * 86400)); XCTFail("escalation") } catch {}
            do { _ = try await service.create(account: a, label: "decrypt", scopes: ["content.decrypt"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(2 * 86400)); XCTFail("decrypt scope") } catch {}
            try await service.revoke(account: a, id: result.id)
            do { _ = try await service.resolve(result.token); XCTFail("revoked") } catch {}
            try await fx.sql.raw("UPDATE mcp_tokens SET revoked_at = NULL, expires_at = '2000-01-01' WHERE id = \(bind: DB.bin(result.id))").run()
            do { _ = try await service.resolve(result.token); XCTFail("expired") } catch {}
            do { _ = try await service.resolve("kfm_" + String(repeating: "a", count: 64)); XCTFail("legacy/unknown") } catch {}
        }
    }

    func testTokenDraftMutationUsesRevisionAndCannotPublish() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer()
            let f = try await fx.form(customer: c)
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed = 1 WHERE id = \(bind: DB.bin(a))").run()
            for right in ["token.manage", "form.read", "draft.write", "draft.export", "release.publish", "content.decrypt"] { try await fx.grant(a, right, customer: c, by: a) }
            let doc = DraftStore.standardDocument(tenant: c, form: f, name: "Test")
            let draft = try await DraftStore.insert(fx.sql, tenant: c, form: f, account: a, document: doc, base: nil, now: DB.time(Date()))
            let service = TokenService(db: fx.app.db(.mysql))
            let issued = try await service.create(account: a, label: "draft", scopes: ["konfiguration.lesen", "entwurf.schreiben"], boundary: .init(tenantId: c, formId: f), expiresAt: Date().addingTimeInterval(2 * 86400))
            let h = HTTPHeaders([("Authorization", "Bearer " + issued.token), ("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")])
            let base = "admin/api/v1/tenants/\(c)/forms/\(f)"
            let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"entwurf_aendern\",\"arguments\":{\"tenantId\":\"\(c)\",\"formId\":\"\(f)\",\"draftId\":\"\(draft.id)\",\"expectedRevision\":1,\"document\":\(String(decoding: JCS.canonicalize(doc), as: UTF8.self))}}}"
            try await fx.app.test(.POST, "mcp", headers: h, body: .init(string: body)) {
                XCTAssertEqual($0.status, .ok); XCTAssertTrue($0.body.string.contains("\"isError\":false")); XCTAssertTrue($0.body.string.contains("\"revision\":2"))
            }
            try await fx.app.test(.POST, "mcp", headers: h, body: .init(string: body)) { XCTAssertTrue($0.body.string.contains("\"isError\":true")) }
            // Cookie presence must not turn a Bearer request into a human action.
            let human = try await fx.login(a)
            var mixed = h; mixed.add(name: .cookie, value: human.cookie!)
            for path in [base + "/publication-confirmations", base + "/releases"] {
                try await fx.app.test(.POST, path, headers: mixed, body: .init(string: "{}")) { XCTAssertEqual($0.status, .unauthorized) }
            }
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed = 0 WHERE id = \(bind: DB.bin(a))").run()
            try await fx.app.test(.GET, base, headers: h) {
                XCTAssertEqual($0.status, .unauthorized); XCTAssertTrue($0.headers.first(name: "WWW-Authenticate")?.contains("resource_metadata") == true)
            }
        }
    }

    func testTokenMCPProtocol() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer()
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed = 1 WHERE id = \(bind: DB.bin(a))").run()
            for right in ["token.manage", "form.read"] { try await fx.grant(a, right, customer: c, by: a) }
            let result = try await TokenService(db: fx.app.db(.mysql)).create(account: a, label: "mcp", scopes: ["konfiguration.lesen"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(2 * 86400))
            let h = HTTPHeaders([("Authorization", "Bearer " + result.token), ("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream"), ("MCP-Protocol-Version", "2025-06-18")])
            for path in ["mcp", "mcp/"] {
                try await fx.app.test(.POST, path, headers: h, body: .init(string: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")) {
                    XCTAssertEqual($0.status, .ok); XCTAssertTrue($0.body.string.contains("entwurf_lesen")); XCTAssertFalse($0.body.string.contains("entwurf_aendern"))
                }
            }
            for (body, code) in [("{", "-32700"), ("[]", "-32600"), ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown\"}", "-32601"), ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"publish\",\"arguments\":{}}}", "-32602")] {
                try await fx.app.test(.POST, "mcp", headers: h, body: .init(string: body)) { XCTAssertTrue($0.body.string.contains(code)) }
            }
            try await fx.app.test(.POST, "mcp", headers: h, body: .init(string: "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) { XCTAssertEqual($0.status, .accepted); XCTAssertEqual($0.body.readableBytes, 0) }
            try await fx.app.test(.GET, "mcp", headers: h) { XCTAssertEqual($0.status, .methodNotAllowed) }
            var bad = h; bad.add(name: "Origin", value: "https://evil.example")
            try await fx.app.test(.POST, "mcp", headers: bad, body: .init(string: "{}")) { XCTAssertEqual($0.status, .forbidden) }
        }
    }
}

extension TokenTests {
    func testTokenSelfRevocationWithoutManageStillRequiresFreshOwnerSession() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), other = try await fx.account(), c = try await fx.customer()
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed = 1 WHERE id = \(bind: DB.bin(a))").run()
            for right in ["token.manage", "form.read"] { try await fx.grant(a, right, customer: c, by: a) }
            let service = TokenService(db: fx.app.db(.mysql))
            let issued = try await service.create(account: a, label: "self", scopes: ["konfiguration.lesen"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(172800))
            try await fx.sql.raw("UPDATE permission_assignments SET revoked_at = NOW(6) WHERE account_id = \(bind: DB.bin(a))").run()
            let owner = try await fx.login(a), stranger = try await fx.login(other)
            let path = "account/tokens/\(issued.id)"
            try await stranger.send(.DELETE, path) { XCTAssertEqual($0.status, .notFound) }
            try await owner.send(.DELETE, path, csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await fx.sql.raw("UPDATE sessions SET authenticated_at = '2000-01-01' WHERE account_id = \(bind: DB.bin(a))").run()
            try await owner.send(.DELETE, path) { XCTAssertEqual($0.status, .forbidden) }
            let fresh = try await fx.login(a)
            try await fresh.send(.DELETE, path) { XCTAssertEqual($0.status, .noContent) }
            do { _ = try await service.resolve(issued.token); XCTFail("revoked token resolved") } catch is TokenService.Invalid {}
        }
    }

    func testTokenMCPDispatchBudgetsAreIsolatedAndCountedOnce() async throws {
        try await AdminFixture.with { fx in
            // This regression exercises dispatch accounting above 60 requests; explicitly raise the new default.
            try await SystemSettings.write(fx.sql, key: "mcp.requestsPerMinute", value: "120", at: DB.time(Date()))
            try await fx.sql.raw("DELETE FROM auth_throttles").run()
            var lastHeaders = HTTPHeaders(), lastBody = ""
            for _ in 0..<2 {
                let a = try await fx.account(), c = try await fx.customer()
                try await fx.sql.raw("UPDATE accounts SET mcp_allowed = 1 WHERE id = \(bind: DB.bin(a))").run()
                for right in ["token.manage", "form.read"] { try await fx.grant(a, right, customer: c, by: a) }
                let issued = try await TokenService(db: fx.app.db(.mysql)).create(account: a, label: "budget", scopes: ["konfiguration.lesen"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(172800))
                let h = HTTPHeaders([("Authorization", "Bearer " + issued.token), ("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")])
                let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"formulare_auflisten\",\"arguments\":{\"tenantId\":\"\(c)\"}}}"
                lastHeaders = h; lastBody = body
                for _ in 0..<59 {
                    try await fx.app.test(.POST, "mcp", headers: h, body: .init(string: body)) {
                        XCTAssertEqual($0.status, .ok); XCTAssertTrue($0.body.string.contains("\"isError\":false"))
                    }
                }
            }
            struct Counts: Decodable { let subjects: Int; let calls: Int }
            let counts = try await fx.sql.raw("SELECT COUNT(DISTINCT subject_hmac) AS subjects, SUM(failures) AS calls FROM auth_throttles WHERE scope = 'admin-route'").first(decoding: Counts.self)!
            XCTAssertEqual(counts.subjects, 2); XCTAssertEqual(counts.calls, 118)
            struct C: Decodable { let c: Int }
            let uses = try await fx.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'token.use'").first(decoding: C.self)!
            XCTAssertEqual(uses.c, 118)
            let socketRequest = Request(application: fx.app, method: .POST, url: "/mcp", headers: lastHeaders,
                collectedBody: ByteBuffer(string: lastBody), remoteAddress: try .init(ipAddress: "203.0.113.9", port: 1234), on: fx.app.eventLoopGroup.next())
            let response = try await fx.app.responder.respond(to: socketRequest).get()
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(response.body.string?.contains("\"isError\":false") == true)
            let after = try await fx.sql.raw("SELECT COUNT(DISTINCT subject_hmac) AS subjects, SUM(failures) AS calls FROM auth_throttles WHERE scope = 'admin-route'").first(decoding: Counts.self)!
            XCTAssertEqual(after.subjects, 3); XCTAssertEqual(after.calls, 120) // one IP + one token, no child charge

        }
    }

    func testTokenDraftAuditIsAtomicAndFailuresAreDistinct() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer(), f = try await fx.form(customer: c)
            try await fx.sql.raw("UPDATE accounts SET mcp_allowed = 1 WHERE id = \(bind: DB.bin(a))").run()
            for right in ["token.manage", "draft.write", "draft.export"] { try await fx.grant(a, right, customer: c, by: a) }
            let doc = DraftStore.standardDocument(tenant: c, form: f, name: "Audit")
            let draft = try await DraftStore.insert(fx.sql, tenant: c, form: f, account: a, document: doc, base: nil, now: DB.time(Date()))
            let issued = try await TokenService(db: fx.app.db(.mysql)).create(account: a, label: "audit", scopes: ["entwurf.schreiben"], boundary: .init(tenantId: c), expiresAt: Date().addingTimeInterval(172800))
            let path = "admin/api/v1/tenants/\(c)/forms/\(f)/drafts/\(draft.id)"
            var h = HTTPHeaders([("Authorization", "Bearer " + issued.token), ("Content-Type", "application/json"), ("If-Match", "\"1\"")])
            let body = ByteBuffer(data: JCS.canonicalize(doc))
            try await fx.app.test(.PATCH, path, headers: h, body: body) { XCTAssertEqual($0.status, .ok) }
            try await fx.app.test(.PATCH, path, headers: h, body: body) { XCTAssertEqual($0.status, .preconditionFailed) }
            struct Audit: Decodable { let actor_id: Blob; let customer_id: Blob; let form_id: Blob; let subject_id: Blob; let safe_details_json: String }
            let success = try await fx.sql.raw("SELECT actor_id,customer_id,form_id,subject_id,safe_details_json FROM audit_events WHERE action_code = 'draft.update'").all(decoding: Audit.self)
            XCTAssertEqual(success.count, 1)
            let r = success[0]
            XCTAssertEqual(DB.uuid(r.actor_id.data), a); XCTAssertEqual(DB.uuid(r.customer_id.data), c)
            XCTAssertEqual(DB.uuid(r.form_id.data), f); XCTAssertEqual(DB.uuid(r.subject_id.data), draft.id)
            let details = try JSONSerialization.jsonObject(with: Data(r.safe_details_json.utf8)) as! [String: Any]
            XCTAssertEqual(details["token_id"] as? String, issued.id.uuidString)
            XCTAssertEqual(details["revision"] as? Int, 2); XCTAssertEqual(details["outcome"] as? String, "success")
            // Force the success audit to fail: the draft update must roll back as well.
            try await fx.sql.raw("CREATE TRIGGER reject_draft_audit BEFORE INSERT ON audit_events FOR EACH ROW BEGIN IF NEW.action_code = 'draft.update' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'synthetic audit failure'; END IF; END").run()
            h.replaceOrAdd(name: .ifMatch, value: "\"2\"")
            try await fx.app.test(.PATCH, path, headers: h, body: body) { XCTAssertEqual($0.status, .internalServerError) }
            let current = try await DraftStore.load(fx.sql, tenant: c, form: f, draft: draft.id)
            XCTAssertEqual(current?.revision, 2)
            struct C: Decodable { let c: Int }
            let failures = try await fx.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'draft.update.failed' AND JSON_UNQUOTE(JSON_EXTRACT(safe_details_json, '$.outcome')) = 'failed'").first(decoding: C.self)!
            XCTAssertEqual(failures.c, 2)
        }
    }
}
