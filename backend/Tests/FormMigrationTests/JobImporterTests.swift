// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormAuth
import FormPersistence
import SQLKit
import XCTest
@testable import FormMigration

extension MigrationTests {
    // DB tests only: compile in this package, execute separately against isolated MariaDB.
    func testJobSchemaPinRejectsBeforeCustomerWrites() async throws {
        try await withDatabases { source, target, secrets in
            let importer = try LegacyImporter(source: source, target: target, secrets: secrets, hmacKey: Data(repeating: 22, count: 32))
            let schema = try await importer.inspectSchema()
            XCTAssertEqual(schema.count, 64)
            let plan = ImportPlan(namespace: "schema-pin", dumpSHA256: String(repeating: "0", count: 64), customers: [self.customer: "Synthetisch"], formCustomers: [:])
            do {
                _ = try await importer.run(plan: plan, expectedSchema: String(repeating: "0", count: 64))
                XCTFail("A different schema must reject the import")
            } catch ImportFailure.invalidSource { }
            let count = try await importer.scalar(target, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM customers")
            XCTAssertEqual(count, "0")
        }
    }
    func testJobCheckpointPauseKeepsCommittedObjectsAndDryRunRollsBack() async throws {
        try await withDatabases { source, target, secrets in
            let importer = try LegacyImporter(source: source, target: target, secrets: secrets, hmacKey: Data(repeating: 22, count: 32))
            let plan = ImportPlan(namespace: "pause", dumpSHA256: String(repeating: "0", count: 64), customers: [self.customer: "Synthetisch"], formCustomers: [:])
            let schema = try await importer.inspectSchema()
            for dryRun in [true, false] {
                do {
                    _ = try await importer.run(plan: plan, dryRun: dryRun, expectedSchema: schema) { _, _ in throw ImportFailure.interrupted }
                    XCTFail("The checkpoint must propagate interruption")
                } catch ImportFailure.interrupted { }
                let count = try await importer.scalar(target, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM customers")
                XCTAssertEqual(count, dryRun ? "0" : "1")
            }
        }
    }
}

extension MigrationTests {
    func testDeltaNewSnapshotKeepsSourceIDsAndRejectsChangedRows() async throws {
        try await withDatabases { source, target, secrets in
            let importer = try LegacyImporter(source: source, target: target, secrets: secrets, hmacKey: Data(repeating: 22, count: 32))
            var plan = ImportPlan(namespace: "delta", dumpSHA256: String(repeating: "0", count: 64), customers: [self.customer: "Synthetisch"], formCustomers: [self.form: self.customer])
            _ = try await importer.run(plan: plan)
            try await source.raw("INSERT INTO anfragen (ID,UUID,formularUUID,time,data,removable) VALUES (2,'77777777-7777-4777-8777-777777777777',\(bind: self.form),1700000001,'unsupported-synthetic-packet',0)").run()
            plan.dumpSHA256 = String(repeating: "1", count: 64)
            _ = try await importer.run(plan: plan, dryRun: true)
            let dryCount = try await importer.scalar(target, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM submissions")
            XCTAssertEqual(dryCount, "1")
            _ = try await importer.run(plan: plan)
            _ = try await importer.run(plan: plan)
            let count = try await importer.scalar(target, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM submissions")
            XCTAssertEqual(count, "2")
            try await source.raw("UPDATE anfragen SET removable=1 WHERE ID=1").run()
            plan.dumpSHA256 = String(repeating: "2", count: 64)
            do { _ = try await importer.run(plan: plan); XCTFail("Changed source accepted") }
            catch ImportFailure.conflict { }
            let original = try await importer.scalar(target, "SELECT CAST(removable AS CHAR) AS v FROM submissions WHERE id=X'22222222222242228222222222222222'")
            XCTAssertEqual(original, "0")
        }
    }
}
