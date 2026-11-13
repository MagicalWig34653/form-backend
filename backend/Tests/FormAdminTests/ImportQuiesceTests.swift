// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
@testable import FormMigration
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

/// One snapshot, quiesce checked in code (ADR 0043): no delta, rehearsal fingerprint, `rehearse`, `source_changed`.
extension ImportRehearsalTests {
    /// Same snapshot again through the job path: pause (as after a crash), resume, worker. Returns the job state afterwards.
    func repeatImport(_ h: Harness, _ id: String) async throws -> [String: Any] {
        try await h.fx.sql.raw("UPDATE migration_jobs SET state='paused' WHERE id=\(bind: DB.bin(UUID(uuidString: id)!))").run()
        let resumed = try await h.action(id, "resume"); XCTAssertEqual(resumed, .ok)
        try await h.service.tick()
        let state = try await stateOf(h, id)
        XCTAssertEqual(state["state"] as? String, "review", "error=\(state["error"] ?? "-")")
        return state
    }

    /// `delta` is an unknown action; `rehearse` only from a rehearsal in review or from `source_changed`.
    func testDeltaIsGoneAndRehearseOnlyFromAllowedStates() async throws {
        try await withHarness(perForm: 2, statistics: 0) { h in
            let (job, dry) = try await startJob(h)
            XCTAssertEqual(dry["state"] as? String, "review", "error=\(dry["error"] ?? "-")")
            let fingerprint = ((dry["report"] as? [String: Any])?["sourceFingerprint"] as? String) ?? ""
            XCTAssertEqual(fingerprint.count, 64, "the rehearsal report carries the source fingerprint")
            let delta = try await h.action(job.id, "delta", body: "{\"dumpSHA256\":\"\(String(repeating: "cd", count: 32))\"}"); XCTAssertEqual(delta, .notFound)
            // review + dry run: allowed, same plan again as a rehearsal
            let again = try await h.action(job.id, "rehearse"); XCTAssertEqual(again, .ok)
            let queued = try await stateOf(h, job.id); XCTAssertEqual(queued["state"] as? String, "queued")
            try await h.service.tick()
            let rehearsed = try await stateOf(h, job.id)
            XCTAssertEqual(rehearsed["state"] as? String, "review"); XCTAssertEqual(rehearsed["dryRun"] as? Bool, true)
            XCTAssertEqual((rehearsed["report"] as? [String: Any])?["sourceFingerprint"] as? String, fingerprint, "quiet source: same fingerprint")
            // failed with another cause, paused and queued: refused
            for (state, code) in [("failed", "conflict"), ("paused", "interrupted"), ("queued", "")] {
                try await h.fx.sql.raw("UPDATE migration_jobs SET state=\(bind: state),error_code=\(bind: code) WHERE id=\(bind: DB.bin(UUID(uuidString: job.id)!))").run()
                let refused = try await h.action(job.id, "rehearse"); XCTAssertEqual(refused, .conflict, state)
            }
            try await h.fx.sql.raw("UPDATE migration_jobs SET state='review',error_code=NULL WHERE id=\(bind: DB.bin(UUID(uuidString: job.id)!))").run()
            // after the real import (review, no dry run) there is no rehearsal either
            let imported = try await importNow(h, job.id); XCTAssertEqual(imported["state"] as? String, "review", "error=\(imported["error"] ?? "-")")
            XCTAssertEqual(imported["dryRun"] as? Bool, false)
            let late = try await h.action(job.id, "rehearse"); XCTAssertEqual(late, .conflict)
        }
    }

    /// `resume` cannot help after a changed source or snapshot: refused with a named 409, other failures stay resumable.
    func testResumeRefusedAfterSourceOrSnapshotChange() async throws {
        try await withHarness(perForm: 2, statistics: 0) { h in
            let (job, _) = try await startJob(h)
            let bin = DB.bin(UUID(uuidString: job.id)!)
            for code in ["source_changed", "source_not_quiesced", "snapshot_changed"] {
                try await h.fx.sql.raw("UPDATE migration_jobs SET state='failed',dry_run=0,error_code=\(bind: code) WHERE id=\(bind: bin)").run()
                var body = ""; var status = HTTPStatus.ok
                try await h.user.send(.POST, "migration/jobs/\(job.id)/resume", body: "{}") { status = $0.status; body = $0.body.string }
                XCTAssertEqual(status, .conflict, code); XCTAssertTrue(body.contains("resume_not_possible"), body)
                let still = try await stateOf(h, job.id); XCTAssertEqual(still["state"] as? String, "failed", code)
            }
            try await h.fx.sql.raw("UPDATE migration_jobs SET state='failed',error_code='conflict' WHERE id=\(bind: bin)").run()
            let resumable = try await h.action(job.id, "resume"); XCTAssertEqual(resumable, .ok)
        }
    }

    /// Jobs from before the fingerprint have none: the import asks for a new rehearsal and writes nothing.
    func testImportWithoutStoredFingerprintIsRefused() async throws {
        try await withHarness(perForm: 2, statistics: 0) { h in
            let (job, _) = try await startJob(h)
            try await h.fx.sql.raw("UPDATE migration_jobs SET report_json='{}' WHERE id=\(bind: DB.bin(UUID(uuidString: job.id)!))").run()
            var body = ""; var status = HTTPStatus.ok
            try await h.user.send(.POST, "migration/jobs/\(job.id)/import", body: "{}") { status = $0.status; body = $0.body.string }
            XCTAssertEqual(status, .conflict)
            XCTAssertTrue(body.contains("source_fingerprint_missing"), body)
            let customers = try await h.count("customers"); XCTAssertEqual(customers, 0)
            let rehearsal = try await h.action(job.id, "rehearse"); XCTAssertEqual(rehearsal, .ok)
            try await h.service.tick()
            let ok = try await importNow(h, job.id); XCTAssertEqual(ok["state"] as? String, "review", "error=\(ok["error"] ?? "-")")
        }
    }

    /// Insert, update and delete of one legacy row between rehearsal and import: `source_changed`, nothing written;
    /// a new rehearsal then imports the changed data (a deleted row is missing in the target).
    func testSourceChangeAfterRehearsalAbortsWithoutWritesThenRehearseAndImport() async throws {
        let changes: [(String, String)] = [
            ("insert", "INSERT INTO anfragen (UUID,time,formularUUID,data,removable) VALUES ('dddddddd-0000-4000-8000-0000000000aa',1760000000,'\(RehearsalSource.formA)',X'756e737570706f72746564',1)"),
            ("update", "UPDATE anfragen SET removable=1-removable ORDER BY ID LIMIT 1"),
            ("delete", "DELETE FROM anfragen ORDER BY ID DESC LIMIT 1"),
        ]
        for (name, statement) in changes {
            try await withHarness(perForm: 3, statistics: 1) { h in
                let (job, dry) = try await startJob(h)
                XCTAssertEqual(dry["state"] as? String, "review", "\(name): error=\(dry["error"] ?? "-")")
                let before = try await fingerprint(h)
                try await h.source.on(h.fx) { s in try await s.raw(SQLQueryString(statement)).run() }
                let failed = try await importNow(h, job.id)
                XCTAssertEqual(failed["state"] as? String, "failed", name)
                XCTAssertEqual(failed["error"] as? String, "source_changed", name)
                let after = try await fingerprint(h)
                XCTAssertEqual(after, before, "\(name): nothing may be written")
                let runs = try await h.count("migration_runs"); XCTAssertEqual(runs, 0, name)
                // Rehearse again, import with the new fingerprint.
                let rehearse = try await h.action(job.id, "rehearse"); XCTAssertEqual(rehearse, .ok, name)
                try await h.service.tick()
                let rehearsed = try await stateOf(h, job.id)
                XCTAssertEqual(rehearsed["state"] as? String, "review", "\(name): error=\(rehearsed["error"] ?? "-")")
                XCTAssertNotEqual((rehearsed["report"] as? [String: Any])?["sourceFingerprint"] as? String, (dry["report"] as? [String: Any])?["sourceFingerprint"] as? String, "\(name): new fingerprint")
                let done = try await importNow(h, job.id)
                XCTAssertEqual(done["state"] as? String, "review", "\(name): error=\(done["error"] ?? "-")")
                if name == "delete" {
                    let subs = try await h.count("submissions")
                    XCTAssertEqual(subs, h.source.submissionCount - 1, "the deleted legacy row must not appear in the target")
                }
            }
        }
    }
}
