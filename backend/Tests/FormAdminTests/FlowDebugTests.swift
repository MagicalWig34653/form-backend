// SPDX-License-Identifier: AGPL-3.0-only
import FormAuth
import FormFlow
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

final class FlowDebugTests: XCTestCase {
    private func object(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }

    func testMaskedEventCannotAcceptRawFieldsAndHasFixedTTL() throws {
        let start = Date(timeIntervalSince1970: 1800000000), id = UUID()
        let ref = FlowDebugEvent.Reference(id: id, version: "1.0.0", sha256: String(repeating: "a", count: 64))
        let event = try FlowDebugEvent(tenant: id, form: ref, release: ref, execution: id, session: id, sequence: 1, mode: "observe", started: start, at: start.addingTimeInterval(1), kind: .fieldChanged, node: "rename", visit: 1, status: .success, inputFieldIDs: ["email"], outputFieldIDs: ["email", "email"])
        let bytes = try JSONEncoder().encode(event), o = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(o["effectMode"] as? String, "observe-only"); XCTAssertEqual(o["ttlSeconds"] as? Int, 900)
        XCTAssertEqual(o["tenantId"] as? String, id.uuidString.lowercased())
        XCTAssertEqual((o["input"] as? [[String: Any]])?.first?["display"] as? String, "[MASKIERT]")
        XCTAssertEqual((o["output"] as? [Any])?.count, 1)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(iso.date(from: o["expiresAt"] as! String)!.timeIntervalSince(iso.date(from: o["recordingStartedAt"] as! String)!), 900)
        XCTAssertThrowsError(try FlowDebugEvent(tenant: id, form: ref, release: ref, execution: id, session: id, sequence: 1, mode: "observe", started: start, at: start.addingTimeInterval(900), kind: .failed, node: "end", visit: 1, status: .failed))
        XCTAssertThrowsError(try FlowDebugEvent(tenant: id, form: ref, release: ref, execution: id, session: id, sequence: 1, mode: "production", started: start, at: start, kind: .failed, node: "end", visit: 1, status: .failed))
        XCTAssertThrowsError(try FlowDebugEvent(tenant: id, form: ref, release: ref, execution: id, session: id, sequence: 1, mode: "observe", started: start, at: start, kind: .failed, node: "body\nsecret", visit: 1, status: .failed))
    }

    func testDebugRightsOwnerMaskingAndExpiry() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            for r in ["form.create", "form.read", "draft.write", "release.publish"] { try await f.grant(user, r, customer: tenant, by: root) }
            let c = try await f.login(user)
            var form = "", draft = "", hash = "", confirmation = "", release = ""
            try await c.post("tenants/\(tenant)/forms", "{\"name\":\"Debugtest\"}") { form = object($0)["id"] as? String ?? "" }
            try await c.get("tenants/\(tenant)/forms/\(form)") { draft = (object($0)["draftIds"] as? [String])?.first ?? "" }
            try await c.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { hash = object($0)["hash"] as? String ?? "" }
            try await c.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { confirmation = object($0)["confirmationId"] as? String ?? "" }
            try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key": "debug-release"]) { XCTAssertEqual($0.status, .created, text($0)); release = object($0)["id"] as? String ?? "" }
            let base = "tenants/\(tenant)/forms/\(form)/debug-jobs", body = "{\"releaseId\":\"\(release)\",\"mode\":\"observe\"}"
            try await c.post(base, body) { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(user, "debug.read", customer: tenant, by: root)
            var debug = ""
            try await c.post(base, body) { XCTAssertEqual($0.status, .created, text($0)); XCTAssertEqual($0.headers.first(name: .cacheControl), "no-store"); debug = object($0)["id"] as? String ?? ""; XCTAssertEqual(object($0)["status"] as? String, "waiting") }
            try await c.get("\(base)/\(debug)") { XCTAssertEqual($0.status, .ok); XCTAssertEqual((object($0)["events"] as? [Any])?.count, 0) }
            try await c.post(base, "{\"releaseId\":\"\(release)\",\"mode\":\"test\"}") { XCTAssertEqual($0.status, .forbidden) }
            let other = try await f.account(); try await f.grant(other, "debug.read", customer: tenant, by: root)
            let oc = try await f.login(other)
            try await oc.send(.DELETE, "\(base)/\(debug)") { XCTAssertEqual($0.status, .forbidden) }
            try await c.send(.DELETE, "\(base)/\(debug)") { XCTAssertEqual($0.status, .noContent) }
            try await c.get("\(base)/\(debug)") { XCTAssertEqual(object($0)["status"] as? String, "cancelled"); XCTAssertEqual((object($0)["events"] as? [Any])?.count, 0) }
            var expiring = ""
            try await c.post(base, body) { expiring = object($0)["id"] as? String ?? "" }
            try await f.sql.raw("UPDATE debug_requests SET expires_at = '2020-01-01 00:00:00.000000' WHERE id = \(bind: DB.bin(UUID(uuidString: expiring)!))").run()
            try await c.get("\(base)/\(expiring)") { XCTAssertEqual($0.status, .gone) }
            try await f.sql.raw("UPDATE permission_assignments SET revoked_at = '2026-11-03 12:00:00' WHERE account_id = \(bind: DB.bin(user)) AND permission = 'debug.read'").run()
            try await c.get("\(base)/\(debug)") { XCTAssertEqual($0.status, .forbidden) }
        }
    }

    func testTargetManagementRequiresOwnRightAndNeverEnablesNetworkSink() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer(), c = try await f.login(user)
            let base = "tenants/\(tenant)/test-targets", body = "{\"name\":\"Testsenke\",\"targetKind\":\"mail-sink\",\"enabled\":false,\"confirm\":true,\"recipientAllowlist\":[\"sink@example.invalid\"]}"
            try await c.post(base, body) { XCTAssertEqual($0.status, .notFound) }
            try await f.grant(user, "system.manage", customer: tenant, by: root)
            try await c.post(base, body) { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(user, "test-target.manage", customer: tenant, by: root)
            var target = ""
            try await c.post(base, body) { XCTAssertEqual($0.status, .created, text($0)); target = object($0)["id"] as? String ?? "" }
            try await c.get(base) { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(user, "test.run", customer: tenant, by: root)
            try await c.get(base) { XCTAssertEqual($0.status, .ok, text($0)); XCTAssertFalse(text($0).contains("sink@example.invalid")) }
            try await c.send(.PATCH, "\(base)/\(target)", body: body) { XCTAssertEqual($0.status, .preconditionRequired) }
            try await c.send(.PATCH, "\(base)/\(target)", body: body, headers: ["If-Match": "\"1\""]) { XCTAssertEqual($0.status, .ok, text($0)); XCTAssertEqual(object($0)["revision"] as? Int, 2) }
            try await c.send(.PATCH, "\(base)/\(target)", body: body, headers: ["If-Match": "\"1\""]) { XCTAssertEqual($0.status, .preconditionFailed) }
            try await c.post(base, body.replacingOccurrences(of: "\"enabled\":false", with: "\"enabled\":true")) { XCTAssertEqual($0.status, .unprocessableEntity) }
        }
    }
}
