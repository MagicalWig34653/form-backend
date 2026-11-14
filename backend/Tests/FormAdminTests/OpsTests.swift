// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import Fluent
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTVapor
import XCTest

final class OpsUnitTests: XCTestCase {
    func testScopedReadDoesNotConferSystemOrForeignAccess() {
        let c = UUID(), f = UUID(), foreign = UUID()
        let grants = [Grant(permission: "audit.read", scope: .form(customer: c, form: f))]
        XCTAssertTrue(OpsRoutes.permitted(grants, customer: c, form: f))
        XCTAssertFalse(OpsRoutes.permitted(grants, customer: c, form: foreign))
        XCTAssertFalse(OpsRoutes.permitted([Grant(permission: "system.manage", scope: .system)], customer: c, form: f))
        XCTAssertFalse(grants[0].scope.covers(.system))
    }
    func testMailBudgetCannotBeBypassedByPriorityOrRepetition() {
        XCTAssertFalse(OpsScheduler.shouldSend(count: 100, suppressed: 10, due: false))
        XCTAssertFalse(OpsScheduler.shouldSend(count: 0, suppressed: 0, due: true))
        XCTAssertTrue(OpsScheduler.shouldSend(count: 1, suppressed: 0, due: true))
        XCTAssertTrue(OpsScheduler.shouldSend(count: 0, suppressed: 100, due: true))
    }
    func testRegistryValidatesAlarmConfiguration() throws {
        for (key, invalid) in [("ops.threshold", "3"), ("ops.intervalSeconds", "0"), ("ops.retentionDays", "366"), ("ops.recipient", "a@example.test\r\nBcc: x@example.test"), ("ops.connection", "arbitrary")] {
            let entry = SettingsRegistry.entries.first { $0.key == key }!
            XCTAssertThrowsError(try entry.validate(invalid))
        }
        let recipient = SettingsRegistry.entries.first { $0.key == "ops.recipient" }!
        try recipient.validate("ops@example.test")
        XCTAssertEqual(try SettingsRegistry.resolve(recipient, env: [recipient.envName: ""], stored: [recipient.key: "ops@example.test"]).value, "")
    }
}

/// Compiled but not executed: MariaDB trigger, permission, paging, cleanup and audit regression.
final class OpsDatabaseTests: XCTestCase {
    /// Regression (operator runs, GET ops/access answered 400 on every call after the Umstieg): forms.name is nullable and the import stores
    /// unnamed forms as NULL; the access lookup must list them instead of failing to decode the row.
    func testAccessListsFormsWithoutName() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer(), f = try await fx.form(customer: c)
            let user = try await fx.login(a)
            try await fx.grant(a, "audit.read", customer: c, form: f, by: a)
            try await fx.sql.raw("UPDATE forms SET name = NULL WHERE id = \(bind: DB.bin(f))").run()
            try await user.get("ops/access") { res in
                XCTAssertEqual(res.status, .ok)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                XCTAssertEqual((json["forms"] as? [[String: Any]])?.count, 1)
            }
            try await user.get("ops?form=\(f)") { XCTAssertEqual($0.status, .ok) }
        }
    }
    func testLiveRightsPagingChronologyAndCleanup() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer(), f = try await fx.form(customer: c), other = try await fx.form(customer: c)
            let user = try await fx.login(a)
            try await fx.grant(a, "audit.read", customer: c, form: f, by: a)
            let sub = UUID(), delivery = UUID()
            try await fx.sql.raw("INSERT INTO submissions (id,customer_id,form_id,release_evidence,environment,state,removable,malware_scan_status) VALUES (\(bind: DB.bin(sub)),\(bind: DB.bin(c)),\(bind: DB.bin(f)),'legacy-unknown','production','accepted',1,'none')").run()
            try await fx.sql.raw("INSERT INTO mail_deliveries (id,customer_id,form_id,submission_id,environment,mail_kind,identity_scope,transport_kind,state,attempts,created_at,updated_at) VALUES (\(bind: DB.bin(delivery)),\(bind: DB.bin(c)),\(bind: DB.bin(f)),\(bind: DB.bin(sub)),'production','organisation','form-mail','smtp','waiting-manual',0,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6))").run()
            try await fx.sql.raw("UPDATE mail_deliveries SET state='smtp-accepted',attempts=1 WHERE id=\(bind: DB.bin(delivery))").run()
            // A rolled-back state change must not leave a journal event.
            enum Rollback: Error { case expected }
            do {
                try await fx.app.db(.mysql).transaction { conn in
                    try await (conn as! SQLDatabase).raw("UPDATE mail_deliveries SET state='uncertain',last_error_code='synthetic@example.test' WHERE id=\(bind: DB.bin(delivery))").run()
                    throw Rollback.expected
                }
            } catch Rollback.expected {}
            try await user.get("ops?form=\(f)&event=arbitrary") { XCTAssertEqual($0.status, .badRequest) }
            try await user.get("ops?form=\(f)&limit=101") { XCTAssertEqual($0.status, .badRequest) }
            var cursor: UInt64 = 0
            try await user.get("ops?form=\(f)&limit=1") { res in
                XCTAssertEqual(res.status, .ok)
                let page = try JSONDecoder().decode(TestPage.self, from: Data(buffer: res.body))
                XCTAssertEqual(page.items.count, 1); XCTAssertEqual(page.items.first?.event, "accepted")
                cursor = try XCTUnwrap(page.next, "second event missing from the first page")
            }
            try await user.get("ops?form=\(f)&before=\(cursor)") { res in
                let page = try JSONDecoder().decode(TestPage.self, from: Data(buffer: res.body))
                XCTAssertEqual(page.items.count, 1); XCTAssertEqual(page.items.first?.event, "failed")
                XCTAssertFalse(String(buffer: res.body).contains("synthetic@example.test"))
            }
            try await user.get("ops?form=\(f)&alarms=1") { res in
                XCTAssertEqual(try JSONDecoder().decode(TestPage.self, from: Data(buffer: res.body)).items.count, 0)
            }
            try await user.get("ops?form=\(other)") { XCTAssertEqual($0.status, .notFound) }
            try await user.get("ops?form=\(f)&submission=\(sub)") { XCTAssertEqual($0.status, .forbidden) }
            try await fx.grant(a, "content.read", customer: c, form: f, by: a)
            try await user.get("ops?form=\(f)&submission=\(sub)") { XCTAssertEqual($0.status, .ok) }
            try await user.send(.POST, "ops/cleanup", body: "{}") { XCTAssertNotEqual($0.status, .ok) }
            try await fx.grant(a, "system.manage", system: true, by: a)
            try await user.send(.POST, "ops/cleanup", body: "{}", csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await fx.sql.raw("UPDATE ops_events SET occurred_at='2000-01-01'").run()
            try await user.send(.POST, "ops/cleanup", body: "{}") { XCTAssertEqual($0.status, .ok) }
            struct N: Decodable { let n: Int }
            let count = try await fx.sql.raw("SELECT COUNT(*) AS n FROM ops_events").first(decoding: N.self)!.n
            XCTAssertEqual(count, 0)
            let audits = try await fx.sql.raw("SELECT COUNT(*) AS n FROM audit_events WHERE action_code='ops.cleanup'").first(decoding: N.self)!.n
            XCTAssertEqual(audits, 1)
            try await fx.sql.raw("UPDATE permission_assignments SET revoked_at=UTC_TIMESTAMP(6) WHERE account_id=\(bind: DB.bin(a)) AND permission='audit.read'").run()
            try await user.get("ops?form=\(f)") { XCTAssertEqual($0.status, .forbidden) }
        }
    }
    /// Events are stamped by the database clock (trigger UTC_TIMESTAMP), the default window by the app clock. A database
    /// clock that runs ahead (Docker VM drift, separate DB host) must not hide the newest events from the default list.
    func testDefaultWindowShowsEventsStampedAheadOfTheAppClock() async throws {
        try await AdminFixture.with { fx in
            let a = try await fx.account(), c = try await fx.customer(), f = try await fx.form(customer: c)
            let user = try await fx.login(a)
            try await fx.grant(a, "audit.read", customer: c, form: f, by: a)
            let sub = UUID(), delivery = UUID()
            try await fx.sql.raw("INSERT INTO submissions (id,customer_id,form_id,release_evidence,environment,state,removable,malware_scan_status) VALUES (\(bind: DB.bin(sub)),\(bind: DB.bin(c)),\(bind: DB.bin(f)),'legacy-unknown','production','accepted',1,'none')").run()
            try await fx.sql.raw("INSERT INTO mail_deliveries (id,customer_id,form_id,submission_id,environment,mail_kind,identity_scope,transport_kind,state,attempts,created_at,updated_at) VALUES (\(bind: DB.bin(delivery)),\(bind: DB.bin(c)),\(bind: DB.bin(f)),\(bind: DB.bin(sub)),'production','organisation','form-mail','smtp','waiting-manual',0,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6))").run()
            // Simulate a database clock two seconds ahead of the app for this event.
            try await fx.sql.raw("UPDATE ops_events SET occurred_at=UTC_TIMESTAMP(6) + INTERVAL 2 SECOND WHERE form_id=\(bind: DB.bin(f))").run()
            try await user.get("ops?form=\(f)") { res in
                XCTAssertEqual(res.status, .ok)
                let page = try JSONDecoder().decode(TestPage.self, from: Data(buffer: res.body))
                XCTAssertEqual(page.items.map(\.event), ["failed"])
            }
            // An explicit upper bound still applies.
            let to = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
            try await user.get("ops?form=\(f)&to=\(to)") { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(try JSONDecoder().decode(TestPage.self, from: Data(buffer: res.body)).items.count, 0)
            }
        }
    }
    func testPersistentAlarmThrottleSuppressionAndFailureBarrier() async throws {
        try await AdminFixture.with { fx in
            let connection = UUID(), customer = UUID(), form = UUID()
            try await fx.sql.raw("INSERT INTO connections (id,kind,name,safe_config_json,enabled) VALUES (\(bind: DB.bin(connection)),'smtp','synthetic','{\"host\":\"smtp.example.test\",\"port\":587,\"security\":\"starttls\"}',1)").run()
            let at = Date()
            for (key, value) in [("ops.connection", connection.uuidString), ("ops.sender", "sender@example.test"), ("ops.recipient", "ops@example.test"), ("ops.intervalSeconds", "60")] {
                try await SystemSettings.write(fx.sql, key: key, value: value, at: DB.time(at))
            }
            func event(_ priority: Int) async throws {
                try await fx.sql.raw("INSERT INTO ops_events (customer_id,form_id,source_id,event,operation,priority,occurred_at) VALUES (\(bind: DB.bin(customer)),\(bind: DB.bin(form)),\(bind: DB.bin(UUID())),'failed','mail',\(bind: priority),\(bind: DB.time(at)))").run()
            }
            let secrets = SecretStore(db: fx.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 7, count: 32)))
            let worker = OpsScheduler(db: fx.app.db(.mysql), secrets: secrets, allowedNets: [], allowInsecure: false, now: { at })
            var sent = 0
            try await event(1)
            try await fx.sql.raw("UPDATE ops_events SET id=id+100").run()
            try await worker.alarm(fx.sql) { _, _ in sent += 1 }
            // Simulates an auto-ID allocated earlier whose transaction committed after the first batch.
            try await fx.sql.raw("INSERT INTO ops_events (id,customer_id,form_id,source_id,event,operation,priority,occurred_at) VALUES (50,\(bind: DB.bin(customer)),\(bind: DB.bin(form)),\(bind: DB.bin(UUID())),'failed','mail',2,\(bind: DB.time(at)))").run()
            try await worker.alarm(fx.sql) { _, _ in sent += 1 }
            XCTAssertEqual(sent, 1) // Higher priority cannot bypass the global interval.
            struct S: Decodable { let suppressed: UInt64; let outcome: String }
            let state = try await fx.sql.raw("SELECT suppressed,outcome FROM ops_alarm_state").first(decoding: S.self)!
            XCTAssertEqual(state.suppressed, 1)
            try await fx.sql.raw("UPDATE ops_alarm_state SET last_sent_at='2000-01-01'").run()
            enum SendFailure: Error { case expected }
            do {
                try await worker.alarm(fx.sql) { _, message in
                    XCTAssertTrue(message.body.contains("Unterdrückte Wiederholungen: 1"))
                    XCTAssertTrue(message.subject.contains("2"))
                    throw SendFailure.expected
                }
            } catch SendFailure.expected {}
            let failed = try await fx.sql.raw("SELECT suppressed,outcome FROM ops_alarm_state").first(decoding: S.self)!
            XCTAssertEqual(failed.outcome, "failed")
            try await worker.alarm(fx.sql) { _, _ in XCTFail("No retry after the persisted send barrier") }
        }
    }
    struct TestPage: Decodable { let items: [OpsRoutes.Item]; let next: UInt64? }
}
