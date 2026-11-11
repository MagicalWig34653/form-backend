// SPDX-License-Identifier: AGPL-3.0-only
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

final class DomainStatisticsRetentionTests: XCTestCase {
    private struct IDs: Decodable { let release_id: Blob; let view_id: Blob }
    private struct Count: Decodable { let c: Int }

    private func publish(_ f: AdminFixture, tenant: UUID, user: UUID, root: UUID) async throws -> (TestClient, UUID, IDs) {
        for right in ["form.create", "form.read", "draft.write", "release.publish", "statistics.read"] { try await f.grant(user, right, customer: tenant, by: root) }
        let c = try await f.login(user)
        var id = "", draft = "", hash = "", confirmation = ""
        try await c.post("tenants/\(tenant)/forms", "{\"name\":\"Statistik\"}") { id = jsonObject($0)["id"] as? String ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(id)") { draft = (jsonObject($0)["draftIds"] as? [String])?.first ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(id)/drafts/\(draft)") { hash = jsonObject($0)["hash"] as? String ?? "" }
        try await c.post("tenants/\(tenant)/forms/\(id)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { confirmation = jsonObject($0)["confirmationId"] as? String ?? "" }
        try await c.send(.POST, "tenants/\(tenant)/forms/\(id)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key": "stats"]) { XCTAssertEqual($0.status, .created) }
        let form = UUID(uuidString: id)!
        let loaded = try await f.sql.raw("SELECT release_id, view_id FROM release_views WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").first(decoding: IDs.self)
        let ids = try XCTUnwrap(loaded)
        return (c, form, ids)
    }

    private func insert(_ f: AdminFixture, tenant: UUID, form: UUID, ids: IDs, event: String, at: String, environment: String = "production") async throws {
        try await f.sql.raw("""
            INSERT INTO statistics_events (id, customer_id, form_id, release_id, view_id, domain_alias, visit_pseudonym, event_kind, source, environment, submission_id, abandonment_evidence, occurred_at, expires_at)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: ids.release_id), \(bind: ids.view_id), \(bind: DB.bin(UUID())), \(bind: Blob(Data(repeating: 9, count: 16))), \(bind: event), \(bind: event == "submit" ? "ingest" : "client"), \(bind: environment), \(bind: event == "submit" ? DB.bin(UUID()) : nil), \(bind: event == "abandon" ? "client-signal" : nil), \(bind: at), DATE_ADD(\(bind: at), INTERVAL 13 MONTH))
            """).run()
    }

    func testDomainStatisticsConversionRightsAndDeletionProofSurvives() async throws {
        try await AdminFixture.with { f in
            let tenant = try await f.customer(), root = try await f.account(), user = try await f.account()
            let (c, form, ids) = try await publish(f, tenant: tenant, user: user, root: root)
            let path = "tenants/\(tenant)/forms/\(form)/statistics"
            try await c.get(path) { XCTAssertTrue(jsonObject($0)["conversion"] is NSNull) }
            let at = DB.time(Date())
            for event in ["visit", "visit", "begin", "submit", "abandon"] { try await insert(f, tenant: tenant, form: form, ids: ids, event: event, at: at) }
            try await insert(f, tenant: tenant, form: form, ids: ids, event: "visit", at: at, environment: "test")
            try await c.get(path) {
                XCTAssertEqual($0.status, .ok)
                let b = jsonObject($0)
                XCTAssertEqual(b["visits"] as? Int, 2); XCTAssertEqual(b["begins"] as? Int, 1)
                XCTAssertEqual(b["submits"] as? Int, 1); XCTAssertEqual(b["abandons"] as? Int, 1)
                XCTAssertEqual(b["total"] as? Int, 1); XCTAssertEqual(b["conversion"] as? Double, 0.5)
            }
            try await c.send(.DELETE, path) { XCTAssertEqual($0.status, .forbidden) }
            // Form-scoped delete must not grant this customer-level privacy action.
            try await f.grant(user, "statistics.delete", customer: tenant, form: form, by: root)
            try await c.send(.DELETE, path) { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(user, "statistics.delete", customer: tenant, by: root)
            let other = try await f.customer()
            try await c.send(.DELETE, "tenants/\(other)/forms/\(form)/statistics") { XCTAssertEqual($0.status, .notFound) }
            try await f.sql.raw("UPDATE sessions SET authenticated_at = DATE_SUB(NOW(), INTERVAL 45 MINUTE) WHERE account_id = \(bind: DB.bin(user))").run()
            try await c.send(.DELETE, path) { XCTAssertEqual($0.status, .forbidden) }
            let fresh = try await f.login(user)
            try await fresh.send(.DELETE, path) { XCTAssertEqual($0.status, .ok); XCTAssertEqual(jsonObject($0)["deleted"] as? Int, 6) }
            let n = try await StatisticsEraser.purgeDue(db: f.app.db(.mysql), now: Date().addingTimeInterval(900 * 86400))
            XCTAssertEqual(n, 0)
            let proof = try await f.sql.raw("SELECT COUNT(*) AS c FROM deletion_records WHERE category = 'statistics' AND deleted_count = 6 AND safe_snapshot_json = '{}'").first(decoding: Count.self)?.c
            XCTAssertEqual(proof, 1)
            let audit = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'statistics.delete'").first(decoding: Count.self)?.c
            XCTAssertEqual(audit, 1)
        }
    }

    func testDomainThirteenCalendarMonthsAndLeaderLock() async throws {
        try await AdminFixture.with { f in
            let tenant = try await f.customer(), root = try await f.account(), user = try await f.account()
            let (_, form, ids) = try await publish(f, tenant: tenant, user: user, root: root)
            try await insert(f, tenant: tenant, form: form, ids: ids, event: "visit", at: "2025-01-31 12:00:00.000000")
            try await f.sql.raw("""
                INSERT INTO legacy_statistics (source_id, source_namespace, legacy_uuid, customer_id, form_id, occurred_at, legacy_status)
                VALUES (1, 'synthetic-test', \(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), '2020-01-01 00:00:00', 'accepted')
                """).run()
            try await f.sql.raw("UPDATE statistics_events SET ads_present=1").run()
            let iso = ISO8601DateFormatter()
            let before = iso.date(from: "2026-02-28T11:59:59Z")!, due = iso.date(from: "2026-02-28T12:00:00Z")!
            let n0 = try await StatisticsEraser.purgeDue(db: f.app.db(.mysql), now: before); XCTAssertEqual(n0, 0)
            try await f.sql.withSession { session in
                try await session.raw("SELECT GET_LOCK(\(literal: StatisticsEraser.lockName), 0)").run()
                let blocked = try await StatisticsEraser.purgeDueIfLeader(db: f.app.db(.mysql), now: due)
                XCTAssertNil(blocked)
                try await session.raw("SELECT RELEASE_LOCK(\(literal: StatisticsEraser.lockName))").run()
            }
            let n1 = try await StatisticsEraser.purgeDueIfLeader(db: f.app.db(.mysql), now: due); XCTAssertEqual(n1, 1)
            let n2 = try await StatisticsEraser.purgeDueIfLeader(db: f.app.db(.mysql), now: due); XCTAssertEqual(n2, 0)
            let proof = try await f.sql.raw("SELECT COUNT(*) AS c FROM deletion_records WHERE category = 'statistics' AND reason_code = 'retention'").first(decoding: Count.self)?.c
            XCTAssertEqual(proof, 1)
            let legacy = try await f.sql.raw("SELECT COUNT(*) AS c FROM legacy_statistics").first(decoding: Count.self)?.c
            XCTAssertEqual(legacy, 1)
        }
    }
    func testDomainStatisticsLegacyCutoffAndDeletionNeverResurrectSubmissions() async throws {
        try await AdminFixture.with { f in
            let tenant = try await f.customer(), root = try await f.account(), user = try await f.account()
            let (client, form, ids) = try await publish(f, tenant: tenant, user: user, root: root)
            let at = DB.time(Date()), tracked = UUID()
            try await insert(f, tenant: tenant, form: form, ids: ids, event: "visit", at: at)
            try await insert(f, tenant: tenant, form: form, ids: ids, event: "submit", at: at)
            try await f.sql.raw("UPDATE statistics_events SET submission_id = \(bind: DB.bin(tracked)) WHERE event_kind = 'submit'").run()
            for (id, environment, state) in [(tracked, "production", "accepted"), (UUID(), "production", "accepted"), (UUID(), "test", "accepted"), (UUID(), "production", "rejected")] {
                try await f.sql.raw("""
                    INSERT INTO submissions (id, customer_id, form_id, release_id, release_evidence, received_at, environment, state, removable, malware_scan_status)
                    VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: ids.release_id), 'recorded', \(bind: at), \(bind: environment), \(bind: state), 1, 'none')
                    """).run()
            }
            try await f.sql.raw("""
                INSERT INTO submissions (id, customer_id, form_id, release_id, release_evidence, received_at, environment, state, removable, malware_scan_status)
                VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: ids.release_id), 'recorded', '2026-11-02 12:00:00', 'production', 'accepted', 1, 'none')
                """).run()
            let path = "tenants/\(tenant)/forms/\(form)/statistics?days=366"
            try await client.get(path) {
                XCTAssertEqual($0.status, .ok)
                let body = jsonObject($0)
                XCTAssertEqual(body["total"] as? Int, 2)
                XCTAssertEqual(body["submits"] as? Int, 2)
                XCTAssertEqual(body["visits"] as? Int, 1)
                XCTAssertEqual(body["conversion"] as? Double, 2)
                let days = body["days"] as? [[String: Any]]
                XCTAssertEqual(days?.count, 2)
                XCTAssertEqual(days?.compactMap { $0["count"] as? Int }.reduce(0, +), 2)
            }
            // An event remains counted after content erasure; its surviving row is not counted twice beforehand.
            try await f.sql.raw("DELETE FROM submissions WHERE id = \(bind: DB.bin(tracked))").run()
            try await client.get(path) { XCTAssertEqual(jsonObject($0)["total"] as? Int, 2) }
            try await f.grant(user, "statistics.delete", customer: tenant, by: root)
            try await client.send(.DELETE, "tenants/\(tenant)/forms/\(form)/statistics") { XCTAssertEqual($0.status, .ok) }
            try await client.get(path) { XCTAssertEqual(jsonObject($0)["total"] as? Int, 0) }
            // An empty second deletion must also persist a clearing boundary for legacy rows.
            try await client.send(.DELETE, "tenants/\(tenant)/forms/\(form)/statistics") { XCTAssertEqual($0.status, .ok) }
            try await client.get(path) { XCTAssertEqual(jsonObject($0)["total"] as? Int, 0) }
            let emptyProof = try await f.sql.raw("SELECT COUNT(*) AS c FROM deletion_records WHERE category='statistics' AND reason_code='request' AND deleted_count=0").first(decoding: Count.self)?.c
            XCTAssertEqual(emptyProof, 1)
            try await f.sql.raw("""
                INSERT INTO submissions (id, customer_id, form_id, release_id, release_evidence, received_at, environment, state, removable, malware_scan_status)
                VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: ids.release_id), 'recorded', '2026-11-02 13:00:00', 'production', 'accepted', 1, 'none')
                """).run()
            try await client.get(path) { XCTAssertEqual(jsonObject($0)["total"] as? Int, 0) }
        }
    }

    func testDomainRetentionDrainsMultipleBatchesAndReportsBudgetRemainder() async throws {
        try await AdminFixture.with { f in
            let tenant = try await f.customer(), root = try await f.account(), user = try await f.account()
            let (_, form, ids) = try await publish(f, tenant: tenant, user: user, root: root)
            for _ in 0..<605 {
                try await insert(f, tenant: tenant, form: form, ids: ids, event: "visit", at: "2025-01-01 00:00:00")
            }
            let now = Date()
            let first = try await StatisticsEraser.purgeDue(db: f.app.db(.mysql), now: now, maxBatches: 1)
            XCTAssertEqual(first, 200)
            let remains = try await StatisticsEraser.hasDue(db: f.app.db(.mysql), now: now)
            XCTAssertTrue(remains)
            let rest = try await StatisticsEraser.purgeDue(db: f.app.db(.mysql), now: now)
            XCTAssertEqual(rest, 405)
            let remainsAfter = try await StatisticsEraser.hasDue(db: f.app.db(.mysql), now: now)
            XCTAssertFalse(remainsAfter)
            let proof = try await f.sql.raw("SELECT CAST(SUM(deleted_count) AS SIGNED) AS c FROM deletion_records WHERE category = 'statistics'").first(decoding: Count.self)?.c
            XCTAssertEqual(proof, 605)
        }
    }

}
