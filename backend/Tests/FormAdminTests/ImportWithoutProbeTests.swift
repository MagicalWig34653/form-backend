// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

/// Operator path, finding B (13.11.2026): a real legacy dump may hold no `:2` package at all (only `KUBUS-AEAD:1`/CBC, which stay review
/// cases after ADR 0001). Then no decryption probe is possible; the server decides from the stored import that none is required, and
/// "Altzugriff entfernen" closes the Umstieg. As soon as one `:2` package exists, the probe stays mandatory.
extension ImportRehearsalTests {
    func jobItem(_ h: Harness, _ id: String) async throws -> [String: Any] {
        var item: [String: Any] = [:]
        try await h.user.get("migration/jobs") { res in
            XCTAssertEqual(res.status, .ok)
            item = (jsonObject(res)["items"] as? [[String: Any]] ?? []).first { $0["id"] as? String == id } ?? [:]
        }
        return item
    }

    func testRemoveSourceWithoutV2PackagesNeedsNoProbe() async throws {
        try await withHarness { h in
            // Every package of the source in an old format: nothing the import can store as a readable :2 object.
            _ = try await h.source.on(h.fx) { s in
                try await s.raw("UPDATE anfragen SET data=IF(data IS NULL,NULL,'bGVnYWN5LWNiYw==|aXY=|:1'), file1Enc=NULL, mailBody=IF(mailBody IS NULL,NULL,'bGVnYWN5|:1'), mailBodyFiller=NULL").run()
            }
            let id = try await importedJob(h)
            let packages = try await h.count("stored_objects", "object_role='data'")
            XCTAssertEqual(packages, 0, "precondition: no :2 data package imported")
            let item = try await jobItem(h, id)
            XCTAssertEqual(item["probeRequired"] as? Bool, false, "the server says that no probe is possible")
            try await h.user.get("migration/jobs/\(id)/probe") { XCTAssertEqual($0.status, .notFound) }
            let closed = try await h.action(id, "remove-source")
            XCTAssertEqual(closed, .ok, "the Umstieg must be closable without a :2 package")
            let state = try await h.scalar("SELECT state AS v FROM migration_jobs")
            XCTAssertEqual(state, "closed")
            let secrets = try await h.scalar("SELECT CAST(source_json AS CHAR) AS v FROM migration_jobs")
            XCTAssertEqual(secrets, "{}", "the stored source credentials are gone")
            let audit = try await h.scalar("SELECT CAST(safe_details_json AS CHAR) AS v FROM audit_events WHERE action_code='migration.job.remove-source'")
            XCTAssertEqual(audit, "{\"withoutProbe\":\"no-v2-packages\"}")
            let kept = try await h.count("submissions", "state='migration-review'")
            XCTAssertEqual(kept, h.source.submissionCount, "the old-format submissions stay review cases")
        }
    }

    func testRemoveSourceWithV2PackagesStillNeedsProbeAndTest() async throws {
        try await withHarness { h in
            let id = try await importedJob(h)
            let item = try await jobItem(h, id)
            XCTAssertEqual(item["probeRequired"] as? Bool, true)
            let early = try await h.action(id, "remove-source")
            XCTAssertEqual(early, .conflict, "with :2 packages the probe stays mandatory")
            try await confirmProbe(h, id)
            let half = try await h.action(id, "remove-source")
            XCTAssertEqual(half, .conflict, "probe without test message is not enough")
            try await confirmProbe(h, id, testMessage: true)
            let closed = try await h.action(id, "remove-source")
            XCTAssertEqual(closed, .ok)
            let audit = try await h.scalar("SELECT CAST(safe_details_json AS CHAR) AS v FROM audit_events WHERE action_code='migration.job.remove-source'")
            XCTAssertEqual(audit, "{}")
        }
    }
}
