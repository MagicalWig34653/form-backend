// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
@testable import FormMigration
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

/// Preconditions of the target, named before the first write (also in the rehearsal): live forms and a customer name
/// that differs from the plan. Real MariaDB source and target, admin routes and job worker; no mocked failure.
extension ImportRehearsalTests {
    func seedTargetCustomer(_ h: Harness, name: String) async throws {
        try await h.fx.sql.raw("INSERT INTO customers (id,name,state,created_at) VALUES (\(unsafeRaw: unhexUUID(RehearsalSource.alpha)),\(bind: name),'disabled','1970-01-01 00:00:00')").run()
    }

    func testLiveFormInTargetIsNamedBeforeTheRehearsal() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            try await seedTargetCustomer(h, name: "Müller & Söhne GmbH")
            let live = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            try await h.fx.sql.raw("INSERT INTO forms (id,customer_id,name,active,created_at) VALUES (\(unsafeRaw: unhexUUID(live)),\(unsafeRaw: unhexUUID(RehearsalSource.alpha)),'Live-Formular',1,UTC_TIMESTAMP(6))").run()
            let (_, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "failed")
            XCTAssertEqual(dry["error"] as? String, "target_forms_live")
            for table in ["submissions", "stored_objects", "migration_objects", "migration_runs"] {
                let n = try await h.count(table)
                XCTAssertEqual(n, 0, "\(table) must stay empty")
            }
            let forms = try await h.count("forms")
            XCTAssertEqual(forms, 1, "the live form stays untouched")
        }
    }

    func testCustomerNameDifferingFromPlanIsNamedBeforeTheRehearsal() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            try await seedTargetCustomer(h, name: "Ganz anderer Name AG")
            let (_, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "failed")
            XCTAssertEqual(dry["error"] as? String, "customer_name_mismatch")
            try await noImportRows(h, "mismatch before the run")
            let runs = try await h.count("migration_runs")
            XCTAssertEqual(runs, 0)
            let name = try await h.scalar("SELECT name AS v FROM customers WHERE id=\(unhexUUID(RehearsalSource.alpha))")
            XCTAssertEqual(name, "Ganz anderer Name AG", "the target name must stay untouched")
        }
    }

    func testErrorCodesOfTargetPreconditions() {
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.targetFormsLive(ids: [])), "target_forms_live")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.customerNameMismatch(ids: [])), "customer_name_mismatch")
    }
}
