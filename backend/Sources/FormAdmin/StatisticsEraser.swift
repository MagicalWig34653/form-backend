// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormPersistence
import Foundation
import SQLKit

/// Erases new events independently of submissions. Legacy rows and deletion proofs are never purged here.
public enum StatisticsEraser {
    private struct Event: Decodable { let id: Blob; let occurred_at: Date }
    public static let lockName = "form_statistics_retention"

    /// Caller supplies a transaction; row locks make concurrent retention/manual deletion count each event once.
    public static func erase(_ sql: SQLDatabase, tenant: UUID, form: UUID, reason: String, actor: UUID?, now: Date, dueOnly: Bool = false, limit: Int? = nil) async throws -> Int {
        let due: SQLQueryString = dueOnly ? " AND expires_at <= \(bind: DB.time(now))" : ""
        let bound: SQLQueryString = limit.map { " LIMIT \(literal: max(1, min($0, 200)))" } ?? ""
        let rows = try await sql.raw("""
            SELECT id, occurred_at FROM statistics_events WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))
            \(due) ORDER BY expires_at, id \(bound) FOR UPDATE
            """).all(decoding: Event.self)
        guard !rows.isEmpty || !dueOnly else { return 0 }
        for row in rows {
            try await sql.raw("DELETE FROM statistics_events WHERE id = \(bind: row.id) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").run()
        }
        try await sql.raw("""
            INSERT INTO deletion_records (id, customer_id, form_id, actor_id, category, reason_code, range_from, range_until, deleted_count, deleted_at, safe_snapshot_json)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: actor.map(DB.bin)), 'statistics', \(bind: reason),
                \(bind: DB.time(rows.map(\.occurred_at).min() ?? now)), \(bind: DB.time(rows.map(\.occurred_at).max() ?? now)), \(bind: rows.count), \(bind: DB.time(now)), '{}')
            """).run()
        return rows.count
    }

    /// Each batch has its own transaction. A monotonic deadline bounds work between batches.
    public static func purgeDue(db: Database, now: Date, batch: Int = 200, maxBatches: Int = 50, budgetSeconds: Double = 20) async throws -> Int {
        struct Scope: Decodable { let customer_id: Blob; let form_id: Blob }
        let started = ProcessInfo.processInfo.systemUptime
        var deleted = 0
        for _ in 0..<max(0, maxBatches) {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime - started < budgetSeconds else { break }
            guard let scope = try await (db as! SQLDatabase).raw("""
                SELECT customer_id, form_id FROM statistics_events WHERE expires_at <= \(bind: DB.time(now))
                ORDER BY expires_at, id LIMIT 1
                """).first(decoding: Scope.self),
                  let tenant = DB.uuid(scope.customer_id.data), let form = DB.uuid(scope.form_id.data) else { break }
            deleted += try await db.transaction { conn in
                try await erase(conn as! SQLDatabase, tenant: tenant, form: form, reason: "retention", actor: nil, now: now, dueOnly: true, limit: batch)
            }
        }
        return deleted
    }

    public static func hasDue(db: Database, now: Date) async throws -> Bool {
        struct Remaining: Decodable { let c: Int }
        return try await (db as! SQLDatabase).raw("""
            SELECT EXISTS(SELECT 1 FROM statistics_events WHERE expires_at <= \(bind: DB.time(now))) AS c
            """).first(decoding: Remaining.self)?.c == 1
    }

    public static func purgeDueIfLeader(db: Database, now: Date) async throws -> Int? {
        struct Lock: Decodable { let l: Int? }
        return try await (db as! SQLDatabase).withSession { session in
            guard try await session.raw("SELECT GET_LOCK(\(literal: lockName), 0) AS l").first(decoding: Lock.self)?.l == 1 else { return nil }
            do {
                let n = try await purgeDue(db: db, now: now)
                try await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                return n
            } catch {
                try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                throw error
            }
        }
    }
}
