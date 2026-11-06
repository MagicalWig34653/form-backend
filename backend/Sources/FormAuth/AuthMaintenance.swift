// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Removes expired authentication state so the tables do not grow without bound (`GET session` creates a row per
/// cookie-less call). Rows stay for `retention` after they ended, so recent sessions remain visible for audit/debug.
public enum AuthMaintenance {
    public struct Result: Equatable, Sendable { public var challenges = 0, sessions = 0, throttles = 0, unusedClients = 0 }

    private struct Affected: Decodable { let n: Int }

    /// One bounded pass (at most `batch` rows per table per statement, repeated until a statement removes fewer).
    public static func purgeExpired(db: Database, now: Date, retention: TimeInterval = 7 * 86_400, batch: Int = 1000) async throws -> Result {
        let sql = db as! SQLDatabase
        let cutoff = DB.time(now.addingTimeInterval(-retention))
        let t = DB.time(now)
        precondition(batch > 0)
        var out = Result()
        // Serialize with registration and consent; remove dependent pending requests first.
        while true {
            let removed = try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                _ = try await SystemSettings.lock(tx, at: t)
                struct Client: Decodable { let id: Blob }
                let clients = try await tx.raw("SELECT id FROM oauth_clients c WHERE (created_at IS NULL OR created_at <= \(bind: DB.time(now.addingTimeInterval(-86400)))) AND NOT EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id = c.id) LIMIT \(literal: batch) FOR UPDATE").all(decoding: Client.self)
                for client in clients {
                    try await tx.raw("DELETE FROM oauth_authorization_requests WHERE client_id = \(bind: client.id)").run()
                    try await tx.raw("DELETE FROM oauth_clients WHERE id = \(bind: client.id)").run()
                }
                if !clients.isEmpty {
                    let details = "{\"count\":\(clients.count)}"
                    try await tx.raw("INSERT INTO audit_events (id,actor_kind,category,action_code,occurred_at,safe_details_json) VALUES (\(bind: DB.bin(UUID())),'service','auth','oauth.client.expire',\(bind: t),\(bind: details))").run()
                }
                return clients.count
            }
            out.unusedClients += removed
            if removed < batch { break }
        }
        _ = try await repeatDelete(sql, batch) { "DELETE FROM oauth_authorization_requests WHERE expires_at < \(bind: cutoff) LIMIT \(literal: $0)" }
        // Challenges: expired/consumed/revoked for longer than the retention, or belonging to a session about to go.
        out.challenges = try await repeatDelete(sql, batch) { """
            DELETE FROM auth_challenges
            WHERE expires_at < \(bind: cutoff) OR (consumed_at IS NOT NULL AND consumed_at < \(bind: cutoff)) OR (revoked_at IS NOT NULL AND revoked_at < \(bind: cutoff))
            LIMIT \(literal: $0)
            """ }
        // Sessions: ended (revoked, or absolute expiry passed) before the cutoff and no longer referenced by anything
        // (challenges, confirmations, resumptions, rotation chain: the oldest row of a chain goes first).
        out.sessions = try await repeatDelete(sql, batch) { """
            DELETE s FROM sessions s
            WHERE (s.absolute_expires_at < \(bind: cutoff) OR (s.revoked_at IS NOT NULL AND s.revoked_at < \(bind: cutoff)))
              AND NOT EXISTS (SELECT 1 FROM oauth_authorization_requests o WHERE o.session_id = s.id)
              AND NOT EXISTS (SELECT 1 FROM auth_challenges c WHERE c.session_id = s.id)
              AND NOT EXISTS (SELECT 1 FROM publication_confirmations p WHERE p.session_id = s.id)
              AND NOT EXISTS (SELECT 1 FROM workflow_resumptions w WHERE w.session_id = s.id)
              AND NOT EXISTS (SELECT 1 FROM sessions r WHERE r.replaced_by = s.id)
            LIMIT \(literal: $0)
            """ }
        out.throttles = try await repeatDelete(sql, batch) { "DELETE FROM auth_throttles WHERE expires_at < \(bind: t) AND (locked_until IS NULL OR locked_until < \(bind: t)) LIMIT \(literal: $0)" }
        return out
    }

    public static let lockName = "form_auth_maintenance"

    /// Runs `purgeExpired` only if this connection obtains the named lock without waiting (nil = another replica is purging).
    public static func purgeIfLeader(db: Database, now: Date) async throws -> Result? {
        struct L: Decodable { let l: Int? }
        let sql = db as! SQLDatabase
        return try await sql.withSession { session in
            guard try await session.raw("SELECT GET_LOCK(\(literal: lockName), 0) AS l").first(decoding: L.self)?.l == 1 else { return nil }
            do {
                let r = try await purgeExpired(db: db, now: now)
                _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                return r
            } catch {
                _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                throw error
            }
        }
    }

    private static func repeatDelete(_ sql: SQLDatabase, _ batch: Int, _ statement: (Int) -> SQLQueryString) async throws -> Int {
        var total = 0
        while true {
            let n = try await affectedRows(sql, statement(batch))
            total += n
            if n < batch { return total }
        }
    }

    private static func affectedRows(_ sql: SQLDatabase, _ q: SQLQueryString) async throws -> Int {
        // The MySQL driver reports affected rows through ROW_COUNT() on the same connection.
        try await (sql as! Database).transaction { conn in
            let tx = conn as! SQLDatabase
            try await tx.raw(q).run()
            return try await tx.raw("SELECT ROW_COUNT() AS n").first(decoding: Affected.self)?.n ?? 0
        }
    }
}

/// Runs `purgeExpired` periodically while the application is up. Failures are logged by type only.
public struct AuthMaintenanceScheduler: LifecycleHandler {
    let interval: TimeInterval
    let now: @Sendable () -> Date
    public init(interval: TimeInterval = 900, now: @escaping @Sendable () -> Date = { Date() }) { self.interval = interval; self.now = now }

    public func didBoot(_ app: Application) throws {
        let db = app.db(.mysql), logger = app.logger, interval = interval, now = now
        let task = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                do {
                    // Several replicas run this loop: only the one that gets the lock purges in this round.
                    guard let r = try await AuthMaintenance.purgeIfLeader(db: db, now: now()) else { continue }
                    if r != AuthMaintenance.Result() { logger.info("auth maintenance", metadata: ["challenges": "\(r.challenges)", "sessions": "\(r.sessions)", "throttles": "\(r.throttles)", "unusedClients": "\(r.unusedClients)"]) }
                } catch {
                    logger.warning("auth maintenance failed", metadata: ["type": "\(type(of: error))"])
                }
            }
        }
        app.storage[SchedulerTaskKey.self] = task
    }

    public func shutdown(_ app: Application) {
        app.storage[SchedulerTaskKey.self]?.cancel()
    }
}

private struct SchedulerTaskKey: StorageKey { typealias Value = Task<Void, Never> }
