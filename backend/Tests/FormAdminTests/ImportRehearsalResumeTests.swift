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

/// Rehearsal part 2: resume after a failure, interruption in the middle of the import, repetition, and very large rows.
extension ImportRehearsalTests {
    /// Dry run through the routes; returns the job id and schema hash. The dry run is the only way to start a job.
    func dryRun(_ h: Harness) async throws -> (id: String, schema: String) {
        let (_, inventory, text) = try await h.test()
        let schema = try XCTUnwrap(inventory["schemaHMAC"] as? String, text)
        let (status, created) = try await h.createJob(plan: try plan(inventory), schema: schema)
        XCTAssertEqual(status, .ok, created)
        return (try XCTUnwrap(jsonObjectFrom(created)["id"] as? String), schema)
    }
    func stateOf(_ h: Harness, _ id: String) async throws -> [String: Any] {
        try await h.jobs().first { $0["id"] as? String == id } ?? [:]
    }
    /// Counts of everything the import wrote (ids are random; content, counts and ledger are not).
    func fingerprint(_ h: Harness) async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for t in ["customers", "customer_key_generations", "data_key_recovery", "forms", "form_versions", "connections", "customer_connections", "submissions", "stored_objects", "ingest_idempotency", "webhook_endpoints", "legacy_statistics", "managed_secrets", "migration_objects", "migration_issues"] {
            out[t] = try await h.count(t)
        }
        out["distinctPackages"] = Int(try await h.scalar("SELECT CAST(COUNT(DISTINCT ciphertext_sha256) AS CHAR) AS v FROM stored_objects") ?? "-1") ?? -1
        return out
    }

    /// A missing key generation stops the dry run with a named cause, leaves nothing behind, and the same job continues after
    /// the cause is removed (resume).
    func testMissingKeyStopsDryRunWithCauseAndResumes() async throws {
        try await withHarness(perForm: 2, statistics: 0) { h in
            let stranger = RehearsalSource.privateKey(0x31)
            try await h.source.on(h.fx) { s in
                let wire = RehearsalSource.seal(Data("{\"x\":1}".utf8), stranger)
                try await s.raw("INSERT INTO anfragen (UUID,time,formularUUID,data,removable) VALUES ('dddddddd-0000-4000-8000-000000000001',1760000000,\(bind: RehearsalSource.formA),\(bind: wire),1)").run()
            }
            let job = try await dryRun(h)
            try await h.service.tick()
            let failed = try await stateOf(h, job.id)
            XCTAssertEqual(failed["state"] as? String, "failed")
            XCTAssertEqual(failed["error"] as? String, "unknownKeyGeneration@kid")
            for table in ["customers", "forms", "submissions", "stored_objects", "migration_runs"] {
                let n = try await h.count(table)
                XCTAssertEqual(n, 0, "failed dry run left rows in \(table)")
            }
            // Cause removed in the source (here: the row is deleted); the same job resumes.
            try await h.source.on(h.fx) { s in try await s.raw("DELETE FROM anfragen WHERE UUID='dddddddd-0000-4000-8000-000000000001'").run() }
            let resumed = try await h.action(job.id, "resume")
            XCTAssertEqual(resumed, .ok)
            try await h.service.tick()
            let ok = try await stateOf(h, job.id)
            XCTAssertEqual(ok["state"] as? String, "review", "error=\(ok["error"] ?? "-")")
            XCTAssertEqual(ok["error"] as? String, "")
            // The job's own failure line names the cause only (the trace-level query log of this test's setup statements is not the system).
            let failureLines = h.log.text.split(separator: "\n").filter { $0.contains("migration job failed") }
            XCTAssertFalse(failureLines.isEmpty)
            XCTAssertFalse(failureLines.contains { $0.contains("dddddddd") }, "row identity must not reach the failure log")
        }
    }

    /// Interrupt the real import (pause through the route, crash through the importer), resume and repeat: the end state equals
    /// an uninterrupted run and nothing is duplicated.
    func testInterruptedImportResumesAndRepetitionIsIdempotent() async throws {
        var reference: [String: Int] = [:]
        try await withHarness { h in
            let job = try await dryRun(h)
            try await h.service.tick()
            _ = try await h.action(job.id, "import")
            try await h.service.tick()
            reference = try await fingerprint(h)
            XCTAssertEqual(reference["submissions"], h.source.submissionCount)
        }
        try await withHarness { h in
            let job = try await dryRun(h)
            try await h.service.tick()
            let review = try await stateOf(h, job.id)["state"] as? String
            XCTAssertEqual(review, "review")
            _ = try await h.action(job.id, "import")
            // 1. Pause through the route while the real import runs (phase anfragen follows the small tables).
            let running = Task { try await h.service.tick() }
            var paused = false
            for _ in 0..<600 where !paused {
                try await Task.sleep(nanoseconds: 20_000_000)
                if try await stateOf(h, job.id)["phase"] as? String == "anfragen" {
                    let status = try await h.action(job.id, "pause"); XCTAssertEqual(status, .ok); paused = true
                }
            }
            try await running.value
            XCTAssertTrue(paused, "import finished before the pause could be requested")
            let afterPause = try await stateOf(h, job.id)
            XCTAssertEqual(afterPause["state"] as? String, "paused")
            XCTAssertEqual(afterPause["error"] as? String, "interrupted")
            let partial = try await h.count("submissions")
            XCTAssertLessThan(partial, h.source.submissionCount, "the pause came too late to prove a partial state")
            // 2. Crash: the importer stops after a few more rows without any cleanup (a killed process leaves the same state).
            let key = try await h.service.key()
            let refs = MigrationSource(host: h.host, database: h.source.name, username: h.source.reader, password: h.source.password, port: h.port, tls: "disable")
            let row = try await h.fx.sql.raw("SELECT * FROM migration_jobs WHERE id=\(bind: DB.bin(UUID(uuidString: job.id)!))").first(decoding: MigrationJob.self)
            let importPlan = try JSONDecoder().decode(ImportPlan.self, from: Data(try XCTUnwrap(row).plan_json.utf8))
            let secrets = h.secrets, sql = h.fx.sql, schema = job.schema
            let outcome = try await h.service.withSource(refs) { source -> Result<ImportReport, ImportFailure> in
                do { return .success(try await LegacyImporter(source: source, target: sql, secrets: secrets, hmacKey: key).run(plan: importPlan, dryRun: false, stopAfter: 5, expectedSchema: schema)) }
                catch let failure as ImportFailure { return .failure(failure) }
            }
            if case .failure(let failure) = outcome, case .interrupted = failure {} else { XCTFail("expected the importer to stop after 5 rows: \(outcome)") }
            // 3. Resume through the route: the job completes the same run.
            let resumed = try await h.action(job.id, "resume"); XCTAssertEqual(resumed, .ok)
            try await h.service.tick()
            let done = try await stateOf(h, job.id)
            XCTAssertEqual(done["state"] as? String, "review", "error=\(done["error"] ?? "-")")
            XCTAssertEqual(done["dryRun"] as? Bool, false)
            let after = try await fingerprint(h)
            XCTAssertEqual(after, reference, "interrupted and resumed run differs from an uninterrupted one: \(after.filter { reference[$0.key] != $0.value }) vs \(reference.filter { after[$0.key] != $0.value })")
            // 4. Repetition: a delta run (new snapshot id) and a second import change nothing and duplicate nothing.
            let delta = try await h.action(job.id, "delta", body: "{\"dumpSHA256\":\"\(String(repeating: "cd", count: 32))\"}"); XCTAssertEqual(delta, .ok)
            try await h.service.tick()
            let deltaState = try await stateOf(h, job.id)
            XCTAssertEqual(deltaState["state"] as? String, "review", "error=\(deltaState["error"] ?? "-")")
            _ = try await h.action(job.id, "import")
            try await h.service.tick()
            let again = try await stateOf(h, job.id)
            XCTAssertEqual(again["state"] as? String, "review", "error=\(again["error"] ?? "-")")
            let repeated = try await fingerprint(h)
            // Issues belong to a run (the delta run has its own snapshot id and reports the same open cases again); data rows must not change.
            var withoutIssues = repeated; withoutIssues["migration_issues"] = nil
            var referenceWithoutIssues = reference; referenceWithoutIssues["migration_issues"] = nil
            XCTAssertEqual(withoutIssues, referenceWithoutIssues, "repetition changed or duplicated rows: \(repeated.filter { reference[$0.key] != $0.value })")
            // The job report lists the same open cases after the repetition (the delta run resumes ledger entries and does not
            // report them again, the summary must not forget them).
            func issueSummary(_ job: [String: Any]) -> [String: Int] {
                let items = (job["report"] as? [String: Any])?["issues"] as? [[String: Any]] ?? []
                return Dictionary(uniqueKeysWithValues: items.map { ($0["code"] as? String ?? "?", $0["count"] as? Int ?? -1) })
            }
            XCTAssertEqual(issueSummary(again), issueSummary(done), "open cases vanished from the report after a repeated run")
            XCTAssertEqual(issueSummary(done)["unsupported-content"], 10)
        }
    }

    /// Large attachments: the legacy system accepts uploads up to 20 MB (nginx 22m). A row beyond the default max_allowed_packet
    /// of 16 MB cannot be read as hex JSON or written as a hex literal in one statement.
    func testLargeAttachmentIsImportedByteForByte() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            let wire = RehearsalSource.seal(Data("{\"x\":1}".utf8), RehearsalSource.alphaActive).split(separator: "|", omittingEmptySubsequences: false)
            let head = wire[0..<5].joined(separator: "|") + "|"
            let tail = "|" + wire[6]
            // 9.2 MB of base64 ciphertext (about 6.9 MB upload); valid package syntax, decrypting is not the point here.
            let uuid = "eeeeeeee-0000-4000-8000-000000000001"
            try await h.source.on(h.fx) { s in
                try await s.raw("INSERT INTO anfragen (UUID,time,formularUUID,sentServer,file1Enc,file1Name,malwareScanStatus,removable) VALUES (\(bind: uuid),1760000000,\(bind: RehearsalSource.formA),\(bind: RehearsalSource.smtpA),CONCAT(\(bind: head),REPEAT('QUJD',2300000),\(bind: tail)),'gross.bin','sauber',1)").run()
            }
            // A large data package without any other flag: silently dropped before the fix (no file name to trigger a review).
            let big = RehearsalSource.seal(Data("{\"x\":1}".utf8), RehearsalSource.alphaActive).split(separator: "|", omittingEmptySubsequences: false)
            let dataHead = big[0..<5].joined(separator: "|") + "|", dataTail = "|" + big[6]
            let dataUUID = "eeeeeeee-0000-4000-8000-000000000002"
            try await h.source.on(h.fx) { s in
                try await s.raw("INSERT INTO anfragen (UUID,time,formularUUID,sentServer,data,removable) VALUES (\(bind: dataUUID),1760000001,\(bind: RehearsalSource.formA),\(bind: RehearsalSource.smtpA),CONCAT(\(bind: dataHead),REPEAT('QUJD',1500000),\(bind: dataTail)),1)").run()
            }
            let job = try await dryRun(h)
            try await h.service.tick()
            let dry = try await stateOf(h, job.id)
            XCTAssertEqual(dry["state"] as? String, "review", "dry run: error=\(dry["error"] ?? "-")")
            _ = try await h.action(job.id, "import")
            try await h.service.tick()
            let done = try await stateOf(h, job.id)
            XCTAssertEqual(done["state"] as? String, "review", "import: error=\(done["error"] ?? "-")")
            let stored = try await h.blob("SELECT ciphertext AS v FROM stored_objects WHERE submission_id=\(unhexUUID(uuid)) AND object_role='attachment'")
            let storedData = try await h.blob("SELECT ciphertext AS v FROM stored_objects WHERE submission_id=\(unhexUUID(dataUUID)) AND object_role='data'")
            XCTAssertEqual(storedData?.count, dataHead.utf8.count + 6_000_000 + dataTail.utf8.count, "large data package was lost")
            let sub = try await h.count("submissions", "id=\(unhexUUID(uuid))")
            let objs = try await h.scalar("SELECT GROUP_CONCAT(CONCAT(object_role,':',byte_count,':',state)) AS v FROM stored_objects WHERE submission_id=\(unhexUUID(uuid))") ?? "-"
            let issues = try await h.scalar("SELECT GROUP_CONCAT(CONCAT(source_table,':',issue_code)) AS v FROM migration_issues WHERE source_table='anfragen'") ?? "-"
            print("MEASURE large sub=\(sub) objects=\(objs) issues=\(issues)")
            XCTAssertEqual(stored?.count, head.utf8.count + 9_200_000 + tail.utf8.count)
        }
    }
}
