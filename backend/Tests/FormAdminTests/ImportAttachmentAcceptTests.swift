// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormCore
@testable import FormMigration
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

/// Cards 8E8CEC06 / FF958178: a legacy file name (`file1Name`) alone is no review cause, and open review cases can be accepted by a reasoned decision.
extension ImportRehearsalTests {
    func accept(_ h: Harness, _ id: String, body: String) async throws -> (HTTPStatus, [String: Any], String) {
        var out: (HTTPStatus, [String: Any], String) = (.ok, [:], "")
        try await h.user.send(.POST, "migration/jobs/\(id)/accept-review", body: body) { res in out = (res.status, jsonObject(res), res.body.string) }
        return out
    }

    /// Regression: all 106 attachments of the QA run stayed in review because `file1Name` counted as a cause. Now only real causes park a row;
    /// the sealed attachment package is imported byte-identical, the report counts migrated attachments and names that live only in the dump.
    func testFileNameAloneIsNoReviewCauseAndAttachmentIsReleased() async throws {
        try await withHarness { h in
            let id = try await importedJob(h)
            let withAttachment = h.source.expected.values.filter { $0.packages["attachment"] != nil }
            XCTAssertGreaterThan(withAttachment.count, 2)
            XCTAssertTrue(withAttachment.allSatisfy { $0.reviewCause == nil })
            // No open case for any row with a file name only (and a valid data package).
            let issues = try await h.count("migration_issues", "issue_code='unsupported-content'")
            XCTAssertEqual(issues, h.source.expected.values.filter { $0.reviewCause != nil }.count)
            try await confirmProbe(h, id)
            let released = try await release(h, id)
            XCTAssertEqual(released.0, .ok, released.2)
            for item in withAttachment {
                let state = try await h.scalar("SELECT state AS v FROM submissions WHERE id=\(unhexUUID(item.uuid))")
                XCTAssertEqual(state, "accepted", "submission with attachment \(item.uuid) must be released")
                let stored = try await h.blob("SELECT ciphertext AS v FROM stored_objects WHERE submission_id=\(unhexUUID(item.uuid)) AND object_role='attachment' AND ordinal_no=0")
                XCTAssertEqual(stored, Data(try XCTUnwrap(item.packages["attachment"]).0.utf8), "attachment package must be byte-identical")
            }
            // Report: counts only.
            let job = try await stateOf(h, id)
            let report = try XCTUnwrap(job["report"] as? [String: Any])
            let counts = try XCTUnwrap(report["attachments"] as? [String: Int])
            XCTAssertEqual(counts["migrated"], withAttachment.count)
            XCTAssertEqual(counts["namesOnlyInSource"], withAttachment.count)
            XCTAssertEqual(counts["notMigrated"], 2, "the row with a file name but no sealed package and the plaintext file1 row")
            // The row with a name but no package is imported normally: present, no open case.
            let nameOnlyRows = try await h.count("submissions s", "NOT EXISTS (SELECT 1 FROM stored_objects o WHERE o.submission_id=s.id)")
            XCTAssertGreaterThan(nameOnlyRows, 0)
            let openCases = try await h.count("migration_issues", "state='open' AND source_table='anfragen'")
            let byCode = try await h.scalar("SELECT GROUP_CONCAT(CONCAT(issue_code,':',c)) AS v FROM (SELECT issue_code, COUNT(*) AS c FROM migration_issues WHERE source_table='anfragen' AND state='open' GROUP BY issue_code) x") ?? "-"
            print("MEASURE open anfragen cases by code: \(byCode)")
            XCTAssertGreaterThan(openCases, 0)
            // The file names themselves are not in the report or the target (plaintext metadata stays in the source dump).
            let dump = try await h.scalar("SELECT CONCAT_WS('|',(SELECT GROUP_CONCAT(report_json) FROM migration_jobs),(SELECT GROUP_CONCAT(safe_details_json) FROM audit_events)) AS v") ?? ""
            XCTAssertFalse(dump.contains("Anhang-3.pdf")); XCTAssertFalse(dump.contains("Nur-Name.pdf"))
        }
    }

    /// The acceptance path: reason required, only case state changes, audit with reason, release afterwards moves only what is really readable.
    func testAcceptReviewCasesNeedsReasonAndKeepsUnreadableRowsInReview() async throws {
        try await withHarness { h in
            let id = try await importedJob(h)
            try await confirmProbe(h, id)
            let first = try await release(h, id)
            XCTAssertEqual(first.0, .ok, first.2)
            let reviewed = h.source.expected.values.filter { $0.reviewCause != nil }
            XCTAssertEqual(reviewed.count, 3)
            let openBefore = try await h.count("migration_issues", "state='open' AND source_table='anfragen'")
            XCTAssertEqual(openBefore, 3)

            // Reason is mandatory: nothing changes for a missing, empty, short or overlong reason, or unknown fields.
            for body in ["{}", "{\"reason\":\"\"}", "{\"reason\":\"   kurz  \"}", "{\"reason\":\"\(String(repeating: "x", count: 201))\"}", "{\"reason\":\"ausreichend lang\",\"all\":true}", "{\"reason\":1}"] {
                let refused = try await accept(h, id, body: body)
                XCTAssertEqual(refused.0, .badRequest, "\(body) -> \(refused.2)")
            }
            let still = try await h.count("migration_issues", "state='open' AND source_table='anfragen'")
            XCTAssertEqual(still, openBefore)
            let noAudit = try await h.count("audit_events", "action_code='migration.job.accept-review'")
            XCTAssertEqual(noAudit, 0)

            let before = try await effects(h)
            let acceptedBefore = try await h.count("submissions", "state='accepted'")
            let otherOpen = try await h.count("migration_issues", "state='open' AND source_table<>'anfragen'")
            let ok = try await accept(h, id, body: "{\"reason\":\"  Pruefung durch Betreiber, Altdaten bleiben in der Quelle  \"}")
            XCTAssertEqual(ok.0, .ok, ok.2)
            XCTAssertEqual(ok.1["accepted"] as? Int, 3)
            let open = try await h.count("migration_issues", "state='open' AND source_table='anfragen'")
            XCTAssertEqual(open, 0)
            // Cases of other tables (unmapped tables, statistics) are never touched.
            let otherAfter = try await h.count("migration_issues", "state='open' AND source_table<>'anfragen'")
            XCTAssertEqual(otherAfter, otherOpen)
            let decided = try await h.count("migration_issues", "state='accepted-with-decision' AND decision_ref='Pruefung durch Betreiber, Altdaten bleiben in der Quelle'")
            XCTAssertEqual(decided, 3)
            // Nothing else changed: no submission, package, ledger row, effect.
            let after = try await effects(h)
            XCTAssertEqual(after, before)
            let stateCounts = try await h.count("submissions", "state='accepted'")
            XCTAssertEqual(stateCounts, acceptedBefore, "accepting a case releases nothing")
            // Audit with the reason and the count.
            let audit = try await h.scalar("SELECT safe_details_json AS v FROM audit_events WHERE action_code='migration.job.accept-review'") ?? ""
            XCTAssertEqual(jsonObjectFrom(audit)["accepted"] as? Int, 3)
            XCTAssertEqual(jsonObjectFrom(audit)["reason"] as? String, "Pruefung durch Betreiber, Altdaten bleiben in der Quelle")
            XCTAssertFalse(audit.contains(h.source.password))

            // Repeatable, accepts nothing more.
            let again = try await accept(h, id, body: "{\"reason\":\"zweiter Aufruf ohne Wirkung\"}")
            XCTAssertEqual(again.1["accepted"] as? Int, 0)

            // The release now frees exactly the row with a readable :2 data package (defective and :1 packages stay in review).
            let second = try await release(h, id)
            XCTAssertEqual(second.0, .ok, second.2)
            XCTAssertEqual(second.1["newlyReleased"] as? Int, 1, second.2)
            XCTAssertEqual(second.1["kept"] as? Int, h.source.submissionCount - acceptedBefore - 1, second.2)
            let reviewLeft = try await h.count("submissions", "state='migration-review'")
            XCTAssertEqual(reviewLeft, h.source.submissionCount - acceptedBefore - 1)
            let bad = try await h.count("stored_objects", "ciphertext IS NOT NULL AND SHA2(ciphertext,256)<>LOWER(HEX(ciphertext_sha256))")
            XCTAssertEqual(bad, 0)
        }
    }

    /// Gate: only a real import in review (not a rehearsal), and it needs the migration right plus fresh login like the other actions.
    func testAcceptReviewIsRefusedForRehearsalAndWithoutRight() async throws {
        try await withHarness { h in
            let rehearsal = try await dryRun(h)
            let refused = try await accept(h, rehearsal.id, body: "{\"reason\":\"Probe im Pruefenlauf\"}")
            XCTAssertEqual(refused.0, .conflict, refused.2)
            let unknown = try await accept(h, "00000000-0000-0000-0000-000000000000", body: "{\"reason\":\"gibt es nicht\"}")
            XCTAssertEqual(unknown.0, .notFound)
        }
    }
}
