// SPDX-License-Identifier: AGPL-3.0-only
import FormStorage
import Fluent
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Physically removes submissions with everything that hangs on them (sealed objects, mail jobs, workflow state) and writes
/// a `deletion_records` row that survives the deletion (ADR 0012). Held submissions (`removable = 0`) are never touched.
/// Statistics events and the webhook outbox are kept on purpose: they carry no content and prove what happened.
public struct RetentionPartiallyFailed: Error { public let deleted: Int, failed: Int }

public enum SubmissionEraser {
    public struct Outcome: Equatable, Sendable { public var deleted: [UUID] = [], held: [UUID] = [], missing: [UUID] = [], pending: [UUID] = [] }

    /// Persist intent before remote I/O. A process crash can then never make partially deleted objects readable again.
    public static func prepare(_ db: SQLDatabase, tenant: UUID, form: UUID, ids: [UUID], now: Date, requireDue: Bool = false) async throws {
        struct S: Decodable { let removable: Int; let due: Date? }
        for id in Set(ids).sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let row = try await db.raw("SELECT removable, retention_due_at AS due FROM submissions WHERE id = \(bind: DB.bin(id)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) FOR UPDATE").first(decoding: S.self), row.removable == 1 else { continue }
            if requireDue, row.due.map({ $0 > now }) ?? true { continue }
            try await db.raw("UPDATE stored_objects SET state = 'deleting' WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND submission_id = \(bind: DB.bin(id))").run()
        }
    }

    private struct Row: Decodable { let id: Blob; let removable: Int; let due: Date? }
    private struct IdRow: Decodable { let id: Blob }

    /// Deletes `ids` of one form in `db` (must already be a transaction). Locks the rows first, so a concurrent hold or a
    /// second deletion waits and then sees the final state. `actor == nil` marks the retention job.
    // Production callers must commit prepare() in a preceding transaction before invoking erase().
    public static func erase(_ db: SQLDatabase, tenant: UUID, form: UUID, ids: [UUID], reason: String, actor: UUID?, now: Date, requireDue: Bool = false, storage: StorageService? = nil) async throws -> Outcome {
        // Share the generation fence with rotation/hold before acquiring submission/object locks.
        _ = try await db.raw("SELECT id FROM customers WHERE id = \(bind: DB.bin(tenant)) FOR UPDATE").first(decoding: IdRow.self)
        var out = Outcome()
        let at = DB.time(now)
        let t = DB.bin(tenant), f = DB.bin(form)
        var seen = Set<UUID>()
        for id in ids where seen.insert(id).inserted {
            guard let row = try await db.raw("SELECT id, removable, retention_due_at AS due FROM submissions WHERE id = \(bind: DB.bin(id)) AND customer_id = \(bind: t) AND form_id = \(bind: f) FOR UPDATE").first(decoding: Row.self) else {
                out.missing.append(id); continue
            }
            if row.removable != 1 { out.held.append(id); continue }
            // retention: the policy may have changed since the job selected the row; re-check under the row lock
            if requireDue, row.due.map({ $0 > now }) ?? true { out.missing.append(id); continue }
            let s = DB.bin(id)
            // Lock and inventory all direct objects and recursively owned metadata before any destructive SQL.
            var objects = try await db.raw("SELECT \(StorageService.ObjectRow.columns) FROM stored_objects WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND (submission_id = \(bind: s) OR (object_role = 'debug' AND submission_id IS NULL AND id IN (SELECT d.object_id FROM debug_objects d JOIN debug_requests r ON r.customer_id = d.customer_id AND r.form_id = d.form_id AND r.id = d.debug_request_id WHERE r.customer_id = \(bind: t) AND r.form_id = \(bind: f) AND r.submission_id = \(bind: s)))) FOR UPDATE").all(decoding: StorageService.ObjectRow.self)
            struct M: Decodable { let metadata_object_id: Blob? }
            var index = 0
            var known = Set(objects.map { $0.id.data })
            while index < objects.count {
                let parent = objects[index]; index += 1
                if let m = try await db.raw("SELECT metadata_object_id FROM stored_objects WHERE id = \(bind: parent.id)").first(decoding: M.self)?.metadata_object_id, known.insert(m.data).inserted {
                    guard let child = try await db.raw("SELECT \(StorageService.ObjectRow.columns) FROM stored_objects WHERE id = \(bind: m) AND customer_id = \(bind: t) AND form_id = \(bind: f) AND object_role = 'object-metadata' AND (submission_id IS NULL OR submission_id = \(bind: s)) FOR UPDATE").first(decoding: StorageService.ObjectRow.self) else { throw Abort(.conflict, reason: "metadata_invalid") }
                    objects.append(child)
                }
            }
            // A malformed/shared metadata graph must fail before destructive remote I/O.
            for object in objects {
                let incoming = try await db.raw("SELECT id FROM stored_objects WHERE metadata_object_id = \(bind: object.id) FOR UPDATE").all(decoding: IdRow.self)
                guard incoming.allSatisfy({ known.contains($0.id.data) }) else { throw Abort(.conflict, reason: "metadata_shared") }
            }
            for object in objects {
                try await db.raw("UPDATE stored_objects SET state = 'deleting' WHERE id = \(bind: object.id)").run()
            }
            var remoteFailed = false
            for object in objects where object.backend != "db" {
                do {
                    guard let storage else { throw StorageError("storage_unavailable") }
                    try await storage.deleteRemote(object, sql: db)
                } catch { remoteFailed = true }
            }
            if remoteFailed { out.pending.append(id); continue } // commit deleting; no deletion proof yet
            // detach every pointer into the rows that go away, then delete children before parents
            // debug recordings of this submission: links, sealed debug objects and events go with it; the request row stays unlinked
            let debugObjects = try await db.raw("""
                SELECT DISTINCT o.object_id AS id FROM debug_objects o JOIN debug_requests r ON r.customer_id = o.customer_id AND r.form_id = o.form_id AND r.id = o.debug_request_id
                WHERE r.customer_id = \(bind: t) AND r.form_id = \(bind: f) AND r.submission_id = \(bind: s)
                """).all(decoding: IdRow.self)
            try await db.raw("""
                DELETE o FROM debug_objects o JOIN debug_requests r ON r.customer_id = o.customer_id AND r.form_id = o.form_id AND r.id = o.debug_request_id
                WHERE r.customer_id = \(bind: t) AND r.form_id = \(bind: f) AND r.submission_id = \(bind: s)
                """).run()
            // debug links that point at the submission's own objects
            try await db.raw("""
                DELETE o FROM debug_objects o JOIN stored_objects x ON x.customer_id = o.customer_id AND x.form_id = o.form_id AND x.id = o.object_id
                WHERE x.customer_id = \(bind: t) AND x.form_id = \(bind: f) AND x.submission_id = \(bind: s)
                """).run()
            try await db.raw("""
                DELETE e FROM debug_events e JOIN debug_requests r ON r.customer_id = e.customer_id AND r.form_id = e.form_id AND r.id = e.debug_request_id
                WHERE r.customer_id = \(bind: t) AND r.form_id = \(bind: f) AND r.submission_id = \(bind: s)
                """).run()
            for o in debugObjects {
                try await db.raw("DELETE FROM stored_objects WHERE id = \(bind: o.id) AND customer_id = \(bind: t) AND form_id = \(bind: f) AND object_role = 'debug' AND submission_id IS NULL").run()
            }
            try await db.raw("UPDATE debug_requests SET submission_id = NULL WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND submission_id = \(bind: s)").run()
            // the webhook outbox is kept (delivery proof) but must not point at effects that go away
            try await db.raw("""
                UPDATE webhook_outbox w JOIN workflow_effects e ON e.customer_id = w.customer_id AND e.form_id = w.form_id AND e.id = w.effect_id
                JOIN workflow_runs r ON r.customer_id = e.customer_id AND r.form_id = e.form_id AND r.id = e.run_id
                SET w.effect_id = NULL WHERE r.customer_id = \(bind: t) AND r.form_id = \(bind: f) AND r.submission_id = \(bind: s)
                """).run()
            try await db.raw("UPDATE submissions SET source_submission_id = NULL WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND source_submission_id = \(bind: s)").run()
            try await db.raw("UPDATE submissions SET mail_manifest_object_id = NULL, mail_manifest_payload_sha256 = NULL WHERE id = \(bind: s)").run()
            try await db.raw("""
                DELETE d FROM workflow_resumptions d JOIN workflow_runs r ON r.customer_id = d.customer_id AND r.form_id = d.form_id AND r.id = d.run_id
                WHERE r.customer_id = \(bind: t) AND r.form_id = \(bind: f) AND r.submission_id = \(bind: s)
                """).run()
            try await db.raw("""
                DELETE d FROM workflow_approvals d JOIN workflow_runs r ON r.customer_id = d.customer_id AND r.form_id = d.form_id AND r.id = d.run_id
                WHERE r.customer_id = \(bind: t) AND r.form_id = \(bind: f) AND r.submission_id = \(bind: s)
                """).run()
            try await db.raw("DELETE FROM mail_deliveries WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND submission_id = \(bind: s)").run()
            try await db.raw("""
                DELETE d FROM workflow_effects d JOIN workflow_runs r ON r.customer_id = d.customer_id AND r.form_id = d.form_id AND r.id = d.run_id
                WHERE r.customer_id = \(bind: t) AND r.form_id = \(bind: f) AND r.submission_id = \(bind: s)
                """).run()
            try await db.raw("DELETE FROM workflow_runs WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND submission_id = \(bind: s)").run()
            // Detach metadata graph after remote confirmation; remove children below with the submission.
            for object in objects {
                try await db.raw("DELETE FROM debug_objects WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND object_id = \(bind: object.id)").run()
                try await db.raw("UPDATE stored_objects SET metadata_object_id = NULL WHERE id = \(bind: object.id)").run()
            }
            // sealed metadata objects (no submission of their own) go with their parent objects
            let meta = try await db.raw("""
                SELECT DISTINCT m.id AS id FROM stored_objects p JOIN stored_objects m ON m.customer_id = p.customer_id AND m.form_id = p.form_id AND m.id = p.metadata_object_id
                WHERE p.customer_id = \(bind: t) AND p.form_id = \(bind: f) AND p.submission_id = \(bind: s) AND m.submission_id IS NULL AND m.object_role = 'object-metadata'
                """).all(decoding: IdRow.self)
            try await db.raw("UPDATE stored_objects SET metadata_object_id = NULL WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND submission_id = \(bind: s)").run()
            try await db.raw("DELETE FROM stored_objects WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND submission_id = \(bind: s)").run()
            for m in meta {
                try await db.raw("""
                    DELETE FROM stored_objects WHERE id = \(bind: m.id) AND customer_id = \(bind: t) AND form_id = \(bind: f)
                      AND NOT EXISTS (SELECT 1 FROM stored_objects q WHERE q.customer_id = \(bind: t) AND q.form_id = \(bind: f) AND q.metadata_object_id = \(bind: m.id))
                    """).run()
            }
            for object in objects.reversed() {
                try await db.raw("DELETE FROM stored_objects WHERE id = \(bind: object.id) AND customer_id = \(bind: t) AND form_id = \(bind: f)").run()
            }
            // the key stays so a replay of the same request is not accepted as new content; it only no longer points to data
            try await db.raw("UPDATE ingest_idempotency SET result_state = 'deleted' WHERE customer_id = \(bind: t) AND form_id = \(bind: f) AND submission_id = \(bind: s)").run()
            try await db.raw("DELETE FROM submissions WHERE id = \(bind: s) AND customer_id = \(bind: t) AND form_id = \(bind: f)").run()
            try await db.raw("""
                INSERT INTO deletion_records (id, customer_id, form_id, subject_id, actor_id, category, reason_code, deleted_count, deleted_at, safe_snapshot_json)
                VALUES (\(bind: DB.bin(UUID())), \(bind: t), \(bind: f), \(bind: s), \(bind: actor.map(DB.bin)), 'submission', \(bind: reason), 1, \(bind: at), '{}')
                """).run()
            out.deleted.append(id)
        }
        return out
    }

    /// True while a real import (`dry_run = 0`) can still be resumed: queued, running, paused or failed (MigrationService /
    /// SetupMigrationRoutes: resume is allowed from paused/failed; review, closed never continue), or while the command-line import
    /// holds its lock (it runs without a job). Resuming compares the target snapshots, so deleted rows would read as `missing_target`.
    /// `form` restricts the job check to jobs whose plan contains this (target) form; the lock check stays global.
    static func importMayResume(_ sql: SQLDatabase, form: UUID? = nil) async throws -> Bool {
        struct C: Decodable { let c: Int }
        let open: SQLQueryString = "SELECT COUNT(*) AS c FROM migration_jobs WHERE dry_run = 0 AND state IN ('queued','running','paused','failed')"
        let query: SQLQueryString
        if let form { query = "\(open) AND JSON_CONTAINS_PATH(plan_json, 'one', \(bind: "$.formCustomers.\"" + form.uuidString.lowercased() + "\""))" } else { query = open }
        if (try await sql.raw(query).first(decoding: C.self)?.c ?? 0) > 0 { return true }
        return try await sql.raw("SELECT IF(IS_USED_LOCK('form_legacy_import') IS NULL, 0, 1) AS c").first(decoding: C.self)?.c == 1
    }

    /// One bounded retention pass over all forms: submissions that are removable and past `retention_due_at`.
    /// Imported submissions (`state = 'migration-review'`) are kept while an import can still be resumed (see `importMayResume`).
    /// Each submission is its own transaction, so one failure never blocks the rest.
    public static func purgeDue(db: Database, now: Date, batch: Int = 200, storage: StorageService? = nil) async throws -> Int {
        struct Due: Decodable { let id: Blob; let customer_id: Blob; let form_id: Blob }
        let sql = db as! SQLDatabase
        let skipImported = try await importMayResume(sql)
        let due = try await sql.raw("""
            SELECT id, customer_id, form_id FROM submissions
            WHERE removable = 1 AND retention_due_at IS NOT NULL AND retention_due_at <= \(bind: DB.time(now))
              AND NOT (\(literal: skipImported ? 1 : 0) = 1 AND state = 'migration-review')
            ORDER BY retention_due_at LIMIT \(literal: batch)
            """).all(decoding: Due.self)
        var n = 0, failed = 0
        for d in due {
            guard let id = DB.uuid(d.id.data), let c = DB.uuid(d.customer_id.data), let f = DB.uuid(d.form_id.data) else { continue }
            // one failing submission must not stop the rest of the pass (the next pass tries it again)
            do {
                try await db.transaction { conn in
                    try await prepare(conn as! SQLDatabase, tenant: c, form: f, ids: [id], now: now, requireDue: true)
                }
                let out = try await db.transaction { conn in
                    try await erase(conn as! SQLDatabase, tenant: c, form: f, ids: [id], reason: "retention", actor: nil, now: now, requireDue: true, storage: storage)
                }
                n += out.deleted.count
            } catch {
                failed += 1
            }
        }
        if failed > 0 { throw RetentionPartiallyFailed(deleted: n, failed: failed) }
        return n
    }

    public static let lockName = "form_retention"

    /// Like `purgeDue`, but only when this replica obtains the cluster-wide lock without waiting (nil = someone else runs it).
    public static func purgeDueIfLeader(db: Database, now: Date, storage: StorageService? = nil) async throws -> Int? {
        struct L: Decodable { let l: Int? }
        let sql = db as! SQLDatabase
        return try await sql.withSession { session in
            guard try await session.raw("SELECT GET_LOCK(\(literal: lockName), 0) AS l").first(decoding: L.self)?.l == 1 else { return nil }
            do {
                let n = try await purgeDue(db: db, now: now, storage: storage)
                _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                return n
            } catch {
                _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                throw error
            }
        }
    }
}

/// Runs the retention pass periodically while the application is up.
public struct RetentionScheduler: LifecycleHandler {
    let interval: TimeInterval
    let now: @Sendable () -> Date
    public init(interval: TimeInterval = 3600, now: @escaping @Sendable () -> Date = { Date() }) { self.interval = interval; self.now = now }

    public func didBoot(_ app: Application) throws {
        let storage = app.storage[StorageServiceKey.self]
        let db = app.db(.mysql), logger = app.logger, interval = interval, now = now
        let task = Task.detached {
            var delay = interval
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                delay = interval
                do {
                    if let n = try await SubmissionEraser.purgeDueIfLeader(db: db, now: now(), storage: storage), n > 0 { logger.info("retention", metadata: ["deleted": "\(n)"]) }
                } catch {
                    logger.warning("retention failed", metadata: ["type": "\(type(of: error))"])
                }
                do {
                    if let n = try await StatisticsEraser.purgeDueIfLeader(db: db, now: now()), n > 0 { logger.info("statistics retention", metadata: ["deleted": "\(n)"]) }
                    if try await StatisticsEraser.hasDue(db: db, now: now()) { delay = min(interval, 60) }
                } catch {
                    delay = min(interval, 60)
                    logger.warning("statistics retention failed", metadata: ["type": "\(type(of: error))"])
                }
            }
        }
        app.storage[RetentionTaskKey.self] = task
    }

    public func shutdown(_ app: Application) { app.storage[RetentionTaskKey.self]?.cancel() }
}

private struct RetentionTaskKey: StorageKey { typealias Value = Task<Void, Never> }
