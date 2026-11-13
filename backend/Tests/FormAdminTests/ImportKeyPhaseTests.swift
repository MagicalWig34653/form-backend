// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import Crypto
import FormAuth
import FormCore
import FormCrypto
@testable import FormMigration
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

/// Key phase of the import ("Phase datenschluessel: Datenbankfehler beim Schreiben ins Ziel"), end to end: real legacy schema in a real
/// MariaDB source, real target MariaDB, the admin HTTP routes and the job worker. No mocked failure: every cause is a state the
/// databases really have (a generation already in the target, two active keys in the source, a blocking trigger, ...).
extension ImportRehearsalTests {
    struct Started { let id: String; let plan: [String: Any] }

    /// Dry run through the routes with an edited plan; returns the job and its state after the worker ran.
    func startJob(_ h: Harness, edit: (inout [String: Any]) -> Void = { _ in }) async throws -> (Started, [String: Any]) {
        let (_, inventory, text) = try await h.test()
        let schema = try XCTUnwrap(inventory["schemaHMAC"] as? String, text)
        var plan = try plan(inventory)
        edit(&plan)
        let (status, created) = try await h.createJob(plan: plan, schema: schema)
        XCTAssertEqual(status, .ok, created)
        let id = try XCTUnwrap(jsonObjectFrom(created)["id"] as? String)
        try await h.service.tick()
        return (Started(id: id, plan: plan), try await stateOf(h, id))
    }
    func importNow(_ h: Harness, _ id: String) async throws -> [String: Any] {
        let status = try await h.action(id, "import"); XCTAssertEqual(status, .ok)
        try await h.service.tick()
        return try await stateOf(h, id)
    }
    /// A customer of the plan that already exists in the target (set up or imported before) with one key generation.
    func seedTargetGeneration(_ h: Harness, kid: String, publicKey: Data, number: Int, state: String) async throws {
        try await h.fx.sql.raw("INSERT IGNORE INTO customers (id,name,state,created_at) VALUES (\(unsafeRaw: unhexUUID(RehearsalSource.alpha)),'Müller & Söhne GmbH','disabled','1970-01-01 00:00:00')").run()
        try await h.fx.sql.raw("INSERT INTO customer_key_generations (generation_id,customer_id,kid,generation_no,public_key,state,created_at) VALUES (UNHEX(REPLACE(UUID(),'-','')),\(unsafeRaw: unhexUUID(RehearsalSource.alpha)),\(bind: kid),\(literal: number),\(bind: Blob(publicKey)),\(bind: state),UTC_TIMESTAMP(6))").run()
    }
    func generations(_ h: Harness) async throws -> String {
        try await h.scalar("SELECT IFNULL(GROUP_CONCAT(CONCAT(generation_no,state,':',kid) ORDER BY generation_no SEPARATOR ','),'-') AS v FROM customer_key_generations") ?? "?"
    }
    func noImportRows(_ h: Harness, _ message: String) async throws {
        for table in ["forms", "submissions", "stored_objects", "migration_objects"] {
            let n = try await h.count(table)
            XCTAssertEqual(n, 0, "\(message): \(table) must stay empty")
        }
    }
    static let oldKid = RehearsalSource.kid(RehearsalSource.alphaOld), activeKid = RehearsalSource.kid(RehearsalSource.alphaActive)

    // MARK: hypothesis a: the customer already has generations in the target

    func testTargetCustomerWithActiveKeyIsNamedConflictBeforeTheRun() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            // The new system was set up with a key for the customer; the import brings the old active key as a second active one.
            try await seedTargetGeneration(h, kid: "0123456789abcdef", publicKey: Data(repeating: 7, count: 32), number: 1, state: "active")
            let (_, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "failed")
            XCTAssertEqual(dry["error"] as? String, "key_conflict_number", "first clash: generation number 1 is taken (the old key brings number 1)")
            try await noImportRows(h, "conflict before the run")
            let kept = try await generations(h)
            XCTAssertEqual(kept, "1active:0123456789abcdef", "the target key must stay untouched")
        }
    }
    func testTargetCustomerWithActiveKeyAndFreeNumbersIsNamedActiveConflict() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            // Target generation uses number 9, so only "second active key" is left as the contradiction.
            try await seedTargetGeneration(h, kid: "0123456789abcdef", publicKey: Data(repeating: 7, count: 32), number: 9, state: "active")
            let (_, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "failed")
            XCTAssertEqual(dry["error"] as? String, "key_conflict_active")
            try await noImportRows(h, "conflict before the run")
        }
    }
    /// The same generation is already in the target (an earlier takeover or a run whose ledger entry is missing): taken over unchanged.
    func testIdenticalGenerationInTargetIsAdoptedWithoutDuplicate() async throws {
        try await withHarness(perForm: 2, statistics: 0) { h in
            try await seedTargetGeneration(h, kid: Self.oldKid, publicKey: RehearsalSource.alphaOld.publicKey.rawRepresentation, number: 1, state: "retiring")
            let (_, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "review", "error=\(dry["error"] ?? "-")")
            let (id) = try XCTUnwrap(dry["id"] as? String)
            let done = try await importNow(h, id)
            XCTAssertEqual(done["state"] as? String, "review", "error=\(done["error"] ?? "-")")
            let numbers = try await generations(h)
            XCTAssertEqual(numbers, "1retiring:\(Self.oldKid),2active:\(Self.activeKid)")
            let ledger = try await h.count("migration_objects", "source_table='datenschluessel'")
            XCTAssertEqual(ledger, 2, "both keys are in the ledger, the existing one adopted")
        }
    }

    // MARK: hypothesis b: the old store has two active keys for one customer

    func testTwoActiveKeysInSourceAreNamedBeforeTheRun() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            let extra = RehearsalSource.privateKey(0x55)
            try await h.source.on(h.fx) { s in
                try await s.raw("INSERT INTO datenschluessel (kid,publicKey,status,erstelltAm,erstelltVon) VALUES (\(bind: RehearsalSource.kid(extra)),\(bind: Blob(extra.publicKey.rawRepresentation)),'aktiv',1760000000,'99999999-9999-4999-8999-999999999999')").run()
            }
            let (_, dry) = try await startJob(h) { plan in
                var customers = plan["keyCustomers"] as? [String: String] ?? [:], numbers = plan["keyGenerationNumbers"] as? [String: Int] ?? [:]
                customers[RehearsalSource.kid(extra)] = RehearsalSource.alpha; numbers[RehearsalSource.kid(extra)] = 3
                plan["keyCustomers"] = customers; plan["keyGenerationNumbers"] = numbers
            }
            XCTAssertEqual(dry["state"] as? String, "failed")
            XCTAssertEqual(dry["error"] as? String, "key_conflict_plan")
            try await noImportRows(h, "conflict before the run")
        }
    }

    // MARK: hypothesis c: generation numbers of the plan clash

    func testDuplicateGenerationNumberInPlanIsNamedBeforeTheRun() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            let (_, dry) = try await startJob(h) { plan in
                var numbers = plan["keyGenerationNumbers"] as? [String: Int] ?? [:]
                numbers[Self.activeKid] = 1
                plan["keyGenerationNumbers"] = numbers
            }
            XCTAssertEqual(dry["state"] as? String, "failed")
            XCTAssertEqual(dry["error"] as? String, "key_conflict_plan")
            try await noImportRows(h, "conflict before the run")
        }
    }

    // MARK: hypothesis e: a key row the table cannot take

    /// erstelltAm = 0 (unknown) used to become NULL for a NOT NULL column: error 1048 "database" in the key phase.
    func testKeyWithoutCreationTimeIsImported() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            try await h.source.on(h.fx) { s in try await s.raw("UPDATE datenschluessel SET erstelltAm=0").run() }
            let (started, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "review", "error=\(dry["error"] ?? "-")")
            let done = try await importNow(h, started.id)
            XCTAssertEqual(done["state"] as? String, "review", "error=\(done["error"] ?? "-")")
            let numbers = try await generations(h)
            XCTAssertEqual(numbers, "1retiring:\(Self.oldKid),2active:\(Self.activeKid)")
        }
    }

    // MARK: abort in the key phase by a real target condition, resume, repetition, comparison with the source

    func testAbortInKeyPhaseNamesCauseResumesAndEndsLikeUninterruptedRun() async throws {
        var reference: [String: Int] = [:]
        try await withHarness(perForm: 3, statistics: 2) { h in
            let (started, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "review")
            _ = try await importNow(h, started.id)
            reference = try await fingerprint(h)
        }
        try await withHarness(perForm: 3, statistics: 2) { h in
            let (started, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "review", "error=\(dry["error"] ?? "-")")
            // A real condition of the target database: it refuses the active key (a stand-in for any constraint the importer cannot foresee).
            try await h.fx.sql.raw("CREATE TRIGGER fb_block_active_key BEFORE INSERT ON customer_key_generations FOR EACH ROW BEGIN IF NEW.state='active' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='geblockt'; END IF; END").run()
            let failed = try await importNow(h, started.id)
            XCTAssertEqual(failed["state"] as? String, "failed")
            XCTAssertEqual(failed["phase"] as? String, "datenschluessel")
            XCTAssertEqual(failed["error"] as? String, "database@1644", "number of the target error instead of a bare 'database'")
            // Partial state after the abort: customer and the retiring key are in the target and in the ledger, nothing else.
            let partial = try await generations(h)
            XCTAssertEqual(partial, "1retiring:\(Self.oldKid)")
            let customers = try await h.count("customers"), ledger = try await h.count("migration_objects")
            XCTAssertEqual(customers, 1); XCTAssertEqual(ledger, 2, "customer and first key")
            let forms = try await h.count("forms"), submissions = try await h.count("submissions")
            XCTAssertEqual(forms, 0); XCTAssertEqual(submissions, 0)
            let line = try XCTUnwrap(h.log.text.split(separator: "\n").first { $0.contains("migration job failed") && $0.contains("database") })
            XCTAssertTrue(line.contains("table=datenschluessel") && line.contains("code=1644") && line.contains("sqlstate=45000"), String(line))
            XCTAssertFalse(h.log.text.split(separator: "\n").contains { $0.contains("migration job failed") && $0.contains("geblockt") }, "the server message must not reach the failure log")
            // The same run is resumed after the cause is gone; the old key is recognised, the missing one written.
            try await h.fx.sql.raw("DROP TRIGGER fb_block_active_key").run()
            let status = try await h.action(started.id, "resume"); XCTAssertEqual(status, .ok)
            try await h.service.tick()
            let resumed = try await stateOf(h, started.id)
            XCTAssertEqual(resumed["state"] as? String, "review", "error=\(resumed["error"] ?? "-")")
            XCTAssertEqual(resumed["error"] as? String, "")
            let after = try await fingerprint(h)
            XCTAssertEqual(after, reference, "resumed run differs from an uninterrupted one: \(after.filter { reference[$0.key] != $0.value })")
            // Source against target: key material, numbers, states, row counts.
            var sourceKeys: [String] = []
            try await h.source.on(h.fx) { s in
                struct K: Decodable { let k: String }
                sourceKeys = try await s.raw("SELECT CONCAT(kid,':',LOWER(HEX(publicKey)),':',status) AS k FROM datenschluessel ORDER BY kid").all(decoding: K.self).map(\.k)
            }
            let targetKeys = try await h.scalar("SELECT GROUP_CONCAT(CONCAT(kid,':',LOWER(HEX(public_key)),':',IF(state='active','aktiv','auslaufend')) ORDER BY kid SEPARATOR ',') AS v FROM customer_key_generations")
            XCTAssertEqual(targetKeys, sourceKeys.joined(separator: ","))
            let finalGenerations = try await generations(h)
            XCTAssertEqual(finalGenerations, "1retiring:\(Self.oldKid),2active:\(Self.activeKid)")
            let subs = try await h.count("submissions")
            XCTAssertEqual(subs, h.source.submissionCount)
            // Repetition with the same snapshot changes and duplicates nothing; a delta does not exist (ADR 0043).
            let delta = try await h.action(started.id, "delta", body: "{\"dumpSHA256\":\"\(String(repeating: "cd", count: 32))\"}"); XCTAssertEqual(delta, .notFound)
            _ = try await repeatImport(h, started.id)
            var repeated = try await fingerprint(h); repeated["migration_issues"] = nil
            var expected = reference; expected["migration_issues"] = nil
            XCTAssertEqual(repeated, expected)
        }
    }
}
