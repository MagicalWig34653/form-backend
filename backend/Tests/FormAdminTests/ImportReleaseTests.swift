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

/// Release of imported submissions (card 2DC195BE): `migration-review` -> `accepted` after the decryption probe, ledger kept consistent.
extension ImportRehearsalTests {
    /// Real import in review state (dry run, import), as in operation.
    func importedJob(_ h: Harness) async throws -> String {
        let job = try await dryRun(h)
        try await h.service.tick()
        _ = try await h.action(job.id, "import")
        try await h.service.tick()
        let state = try await stateOf(h, job.id)
        XCTAssertEqual(state["state"] as? String, "review", "error=\(state["error"] ?? "-")")
        return job.id
    }
    /// Probe through the routes exactly like the browser: read the sample, send its hash back (test message optional).
    func confirmProbe(_ h: Harness, _ id: String, testMessage: Bool = false) async throws {
        var hash = ""
        try await h.user.get("migration/jobs/\(id)/probe") { res in hash = jsonObject(res)["hash"] as? String ?? "" }
        XCTAssertEqual(hash.count, 64)
        try await h.user.send(.POST, "migration/jobs/\(id)/verify", body: "{\"hash\":\"\(hash)\",\"success\":true}") { XCTAssertEqual($0.status, .ok) }
        if testMessage {   // second step of the browser: the local test message (needs the confirmed probe)
            try await h.user.send(.POST, "migration/jobs/\(id)/verify", body: "{\"hash\":\"\(hash)\",\"success\":true,\"testHash\":\"\(String(repeating: "e", count: 64))\"}") { XCTAssertEqual($0.status, .ok) }
        }
    }
    func release(_ h: Harness, _ id: String) async throws -> (HTTPStatus, [String: Any], String) {
        var out: (HTTPStatus, [String: Any], String) = (.ok, [:], "")
        try await h.user.send(.POST, "migration/jobs/\(id)/release-submissions", body: "{}") { res in out = (res.status, jsonObject(res), res.body.string) }
        return out
    }
    func effects(_ h: Harness) async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for t in ["mail_deliveries", "webhook_outbox", "ops_events", "stored_objects", "submissions", "migration_objects", "migration_issues"] { out[t] = try await h.count(t) }
        out["packageHashes"] = Int(try await h.scalar("SELECT CAST(SUM(CRC32(CONCAT(HEX(id),LOWER(HEX(ciphertext_sha256))))) AS CHAR) AS v FROM stored_objects") ?? "-1") ?? -1
        out["badPackages"] = try await h.count("stored_objects", "ciphertext IS NOT NULL AND SHA2(ciphertext,256)<>LOWER(HEX(ciphertext_sha256))")
        return out
    }
    func uuidText(_ hex: String) -> String {
        let h = hex.lowercased()
        return [h.prefix(8), h.dropFirst(8).prefix(4), h.dropFirst(12).prefix(4), h.dropFirst(16).prefix(4), h.dropFirst(20)].map(String.init).joined(separator: "-")
    }

    func testReleaseNeedsProbeAndMovesOnlyCleanSubmissions() async throws {
        try await withHarness { h in
            let id = try await importedJob(h)
            let total = h.source.submissionCount
            let expectedClean = h.source.expected.values.filter { $0.reviewCause == nil && $0.packages["data"] != nil }.count
            XCTAssertGreaterThan(expectedClean, 0)
            let v1 = try await h.count("submissions", "state='migration-review'")
            XCTAssertEqual(v1, total)

            // Before the decryption probe: 409, nothing changes.
            let early = try await release(h, id)
            XCTAssertEqual(early.0, .conflict, early.2)
            let v2 = try await h.count("submissions", "state='accepted'")
            XCTAssertEqual(v2, 0)

            try await confirmProbe(h, id)   // probe only: no test message needed for reading entries
            let before = try await effects(h)
            let first = try await release(h, id)
            XCTAssertEqual(first.0, .ok, first.2)
            XCTAssertEqual(first.1["released"] as? Int, expectedClean)
            XCTAssertEqual(first.1["newlyReleased"] as? Int, expectedClean)
            XCTAssertEqual(first.1["kept"] as? Int, total - expectedClean)
            let v3 = try await h.count("submissions", "state='accepted'")
            XCTAssertEqual(v3, expectedClean)
            let v4 = try await h.count("submissions", "state='migration-review'")
            XCTAssertEqual(v4, total - expectedClean)
            // Nothing without a :2 data package was released.
            let v5 = try await h.count("submissions s", "s.state='accepted' AND NOT EXISTS (SELECT 1 FROM stored_objects o WHERE o.submission_id=s.id AND o.object_role='data' AND o.state='ready')")
            XCTAssertEqual(v5, 0)
            // Every submission with an open review case stays in review.
            for (uuid, item) in h.source.expected where item.reviewCause != nil {
                let v6 = try await h.scalar("SELECT state AS v FROM submissions WHERE id=\(unhexUUID(uuid))")
                XCTAssertEqual(v6, "migration-review", uuid)
            }
            // No new effect, packages byte-identical, ledger rows neither added nor removed.
            var after = try await effects(h)
            XCTAssertEqual(after, before)
            XCTAssertEqual(after["badPackages"], 0)

            // Idempotent: a second call releases nothing more and reports the same totals.
            let second = try await release(h, id)
            XCTAssertEqual(second.0, .ok)
            XCTAssertEqual(second.1["released"] as? Int, expectedClean)
            XCTAssertEqual(second.1["newlyReleased"] as? Int, 0)
            XCTAssertEqual(second.1["kept"] as? Int, total - expectedClean)
            after = try await effects(h)
            XCTAssertEqual(after, before)
            // Audit: one entry per call, only counts.
            let v7 = try await h.count("audit_events", "action_code='migration.job.release-submissions'")
            XCTAssertEqual(v7, 2)
            let details = try await h.scalar("SELECT safe_details_json AS v FROM audit_events WHERE action_code='migration.job.release-submissions' ORDER BY occurred_at LIMIT 1") ?? ""
            XCTAssertEqual(jsonObjectFrom(details)["released"] as? Int, expectedClean)
            XCTAssertFalse(details.contains(h.source.password))
        }
    }

    /// The ledger proof contains `submissions.state`: after the release a repetition of the import (resume of the same run) must find
    /// every object consistent (no `conflict`) and change nothing.
    func testRepeatedImportAfterReleaseReportsNoConflict() async throws {
        try await withHarness { h in
            let id = try await importedJob(h)
            try await confirmProbe(h, id)
            let released = try await release(h, id)
            XCTAssertEqual(released.0, .ok, released.2)
            let before = try await effects(h)
            let acceptedBefore = try await h.count("submissions", "state='accepted'")
            XCTAssertGreaterThan(acceptedBefore, 0)
            // Repetition: the importer over the same source and plan (as resume/retry does).
            let key = try await h.service.key()
            let refs = MigrationSource(host: h.host, database: h.source.name, username: h.source.reader, password: h.source.password, port: h.port, tls: "disable")
            let row = try await h.fx.sql.raw("SELECT * FROM migration_jobs WHERE id=\(bind: DB.bin(UUID(uuidString: id)!))").first(decoding: MigrationJob.self)
            let plan = try JSONDecoder().decode(ImportPlan.self, from: Data(try XCTUnwrap(row).plan_json.utf8))
            let secrets = h.secrets, sql = h.fx.sql, schema = try XCTUnwrap(row).expected_schema
            let outcome = try await h.service.withSource(refs) { source -> Result<ImportReport, ImportFailure> in
                do { return .success(try await LegacyImporter(source: source, target: sql, secrets: secrets, hmacKey: key).run(plan: plan, dryRun: false, expectedSchema: schema)) }
                catch let failure as ImportFailure { return .failure(failure) }
            }
            if case .failure(let failure) = outcome { XCTFail("repeated import after release failed: \(failure)") }
            let v8 = try await effects(h)
            XCTAssertEqual(v8, before)
            let v9 = try await h.count("submissions", "state='accepted'")
            XCTAssertEqual(v9, acceptedBefore)
            // A real change of a released row is still a conflict (the proof was rewritten, not weakened).
            let victim = try await h.scalar("SELECT LOWER(HEX(id)) AS v FROM submissions WHERE state='accepted' LIMIT 1") ?? ""
            try await h.fx.sql.raw(SQLQueryString("UPDATE submissions SET removable=1-removable WHERE id=X'\(victim)'")).run()
            let again = try await h.service.withSource(refs) { source -> Result<ImportReport, ImportFailure> in
                do { return .success(try await LegacyImporter(source: source, target: sql, secrets: secrets, hmacKey: key).run(plan: plan, dryRun: false, expectedSchema: schema)) }
                catch let failure as ImportFailure { return .failure(failure) }
            }
            if case .failure(let failure) = again, case .conflict = failure {} else { XCTFail("expected conflict for a changed row: \(again)") }
        }
    }

    func testReleaseRefusedForClosedJob() async throws {
        try await withHarness(perForm: 2, statistics: 0) { h in
            let id = try await importedJob(h)
            try await confirmProbe(h, id, testMessage: true)
            let closed = try await h.action(id, "remove-source"); XCTAssertEqual(closed, .ok)
            let late = try await release(h, id)
            XCTAssertEqual(late.0, .conflict, late.2)
            let v10 = try await h.count("submissions", "state='accepted'")
            XCTAssertEqual(v10, 0)
        }
    }

    /// Entries list and ciphertext: released submissions are served, the others are not.
    func testReleasedSubmissionsAppearInEntryListAndDetail() async throws {
        try await withHarness { h in
            let id = try await importedJob(h)
            // formB: its row with error text + plaintext file stays in review but has a ready data package (formA's review rows had that only through
            // `file1Name`, which is no review cause any more, task 8E8CEC06).
            let form = RehearsalSource.formB
            let customer = uuidText(try await h.scalar("SELECT HEX(customer_id) AS v FROM forms WHERE id=\(unhexUUID(form))") ?? "")
            let tenant = try XCTUnwrap(UUID(uuidString: customer))
            // The importer leaves customers disabled until the human cutover; the entries routes need an active one.
            try await h.fx.sql.raw("UPDATE customers SET state='active'").run()
            for permission in ["content.read", "content.decrypt"] { try await h.fx.grant(h.actor, permission, customer: tenant, by: h.actor) }
            func list() async throws -> Set<String> {
                var ids: Set<String> = []
                try await h.user.get("tenants/\(customer)/forms/\(form)/entries?limit=100") { res in
                    XCTAssertEqual(res.status, .ok)
                    ids = Set((jsonObject(res)["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
                }
                return ids
            }
            let v11 = try await list()
            XCTAssertEqual(v11, [], "before the release nothing is listed")
            try await confirmProbe(h, id)
            let result = try await release(h, id)
            XCTAssertEqual(result.0, .ok, result.2)
            let listed = try await list()
            let accepted = try await h.fx.sql.raw(SQLQueryString("SELECT LOWER(HEX(id)) AS v FROM submissions WHERE state='accepted' AND form_id=\(unhexUUID(form))")).all(decoding: V.self).map { uuidText($0.v) }
            XCTAssertFalse(accepted.isEmpty)
            XCTAssertEqual(listed, Set(accepted))
            let flagged = try await h.fx.sql.raw(SQLQueryString("SELECT LOWER(HEX(id)) AS v FROM submissions WHERE state='migration-review' AND form_id=\(unhexUUID(form)) AND EXISTS (SELECT 1 FROM stored_objects o WHERE o.submission_id=submissions.id AND o.object_role='data')")).all(decoding: V.self).map { uuidText($0.v) }
            XCTAssertFalse(flagged.isEmpty)
            XCTAssertTrue(listed.isDisjoint(with: flagged), "a submission left in review must not be listed")
            // Detail of a released submission: the sealed package, byte-identical to the imported one.
            let one = try XCTUnwrap(accepted.first)
            try await h.user.get("tenants/\(customer)/forms/\(form)/entries/\(one)/ciphertext") { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(jsonObject(res)["package"] as? String, h.source.expected[one]?.packages["data"]?.wire)
            }
            try await h.user.get("tenants/\(customer)/forms/\(form)/entries/\(flagged[0])/ciphertext") { XCTAssertEqual($0.status, .notFound) }
        }
    }
    struct V: Decodable { let v: String }
}
