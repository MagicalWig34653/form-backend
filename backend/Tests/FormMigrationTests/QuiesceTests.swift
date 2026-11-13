// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormAuth
import FormPersistence
import SQLKit
import XCTest
@testable import FormMigration

extension MigrationTests {
    // DB tests only (backend/integration-test.sh). ADR 0043: source fingerprint, quiesce check, one snapshot.
    private func quietPlan(_ t: MigrationTests, _ name: String) -> ImportPlan {
        ImportPlan(namespace: name, dumpSHA256: String(repeating: "0", count: 64), customers: [t.customer: "Synthetisch"], formCustomers: [t.form: t.customer])
    }

    func testSourceFingerprintIsStableAndFollowsEveryChange() async throws {
        try await withDatabases { source, target, secrets in
            let importer = try LegacyImporter(source: source, target: target, secrets: secrets, hmacKey: Data(repeating: 22, count: 32))
            let first = try await importer.sourceFingerprint(), second = try await importer.sourceFingerprint()
            XCTAssertEqual(first.count, 64); XCTAssertEqual(first, second)
            let report = try await importer.run(plan: self.quietPlan(self, "fp"), dryRun: true)
            XCTAssertEqual(report.sourceFingerprint, first, "the rehearsal reports the fingerprint")
            var seen: Set<String> = [first]
            for statement in ["INSERT INTO anfragen (ID,UUID,formularUUID,time,data,removable) VALUES (2,'77777777-7777-4777-8777-777777777777',\(literalForm(self.form)),1700000001,'unsupported-synthetic-packet',0)",
                              "UPDATE anfragen SET removable=1-removable WHERE ID=1",
                              "DELETE FROM anfragen WHERE ID=2"] {
                try await source.raw(SQLQueryString(statement)).run()
                let next = try await importer.sourceFingerprint()
                XCTAssertFalse(seen.contains(next), statement); seen.insert(next)
            }
        }
    }

    func testChangeBetweenRehearsalAndImportAbortsWithSourceChangedWithoutWrites() async throws {
        let changes = [("insert", "INSERT INTO anfragen (ID,UUID,formularUUID,time,data,removable) VALUES (2,'77777777-7777-4777-8777-777777777777',\(literalForm(form)),1700000001,'unsupported-synthetic-packet',0)"),
                       ("update", "UPDATE anfragen SET removable=1-removable WHERE ID=1"),
                       ("delete", "DELETE FROM anfragen WHERE ID=1")]
        for (name, statement) in changes {
            try await withDatabases { source, target, secrets in
                let importer = try LegacyImporter(source: source, target: target, secrets: secrets, hmacKey: Data(repeating: 22, count: 32))
                let plan = self.quietPlan(self, "chg-" + name)
                let rehearsal = try await importer.run(plan: plan, dryRun: true)
                try await source.raw(SQLQueryString(statement)).run()
                do { _ = try await importer.run(plan: plan, expectedSourceFingerprint: rehearsal.sourceFingerprint); XCTFail("\(name): changed source accepted") }
                catch ImportFailure.sourceChanged { }
                for table in ["customers", "migration_runs", "migration_objects", "submissions", "forms"] {
                    let n = try await importer.scalar(target, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM \(table)")
                    XCTAssertEqual(n, "0", "\(name): \(table) must stay empty")
                }
                // A new rehearsal takes the new state; with its fingerprint the import runs.
                let again = try await importer.run(plan: plan, dryRun: true)
                XCTAssertNotEqual(again.sourceFingerprint, rehearsal.sourceFingerprint)
                _ = try await importer.run(plan: plan, expectedSourceFingerprint: again.sourceFingerprint)
                let subs = try await importer.scalar(target, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM submissions")
                XCTAssertEqual(subs, name == "delete" ? "0" : (name == "insert" ? "2" : "1"), "\(name): the target mirrors the new source state")
            }
        }
    }

    func testWriteDuringImportFailsTheRunAsNotQuiesced() async throws {
        try await withDatabases { source, target, secrets in
            let importer = try LegacyImporter(source: source, target: target, secrets: secrets, hmacKey: Data(repeating: 22, count: 32))
            let plan = self.quietPlan(self, "notquiet")
            let rehearsal = try await importer.run(plan: plan, dryRun: true)
            var written = false
            do {
                _ = try await importer.run(plan: plan, expectedSourceFingerprint: rehearsal.sourceFingerprint) { table, _ in
                    // The legacy system is written while the import runs (another connection, outside of the snapshot).
                    if table == "anfragen" && !written { written = true; try await source.raw("UPDATE anfragen SET removable=1-removable WHERE ID=1").run() }
                }
                XCTFail("A write during the import must fail the run")
            } catch ImportFailure.sourceNotQuiesced { }
            XCTAssertTrue(written)
            let state = try await importer.scalar(target, "SELECT state AS v FROM migration_runs")
            XCTAssertEqual(state, "failed")
        }
    }

    func testCLIStartToEndCheckWithoutExpectedFingerprint() async throws {
        try await withDatabases { source, target, secrets in
            let importer = try LegacyImporter(source: source, target: target, secrets: secrets, hmacKey: Data(repeating: 22, count: 32))
            var written = false
            do {
                _ = try await importer.run(plan: self.quietPlan(self, "cli-end")) { _, _ in
                    if !written { written = true; try await source.raw("UPDATE anfragen SET removable=1-removable WHERE ID=1").run() }
                }
                XCTFail("start/end comparison missing")
            } catch ImportFailure.sourceNotQuiesced { }
        }
    }
}

private func literalForm(_ form: String) -> String { "'\(form)'" }
