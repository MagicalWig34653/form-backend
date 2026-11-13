// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormCore
import FormPersistence
import Foundation
import SQLKit

/// Runs only inside the authorized cleanup transaction. Bounded deletes preserve live leases/work.
enum OpsMaintenance {
    struct Result: Codable { let deleted: [String: Int]; let batchLimit: Int }
    struct Count: Decodable { let n: Int }
    static func purge(_ sql: SQLDatabase, now: Date) async throws -> Result {
        let days = Int(try await SystemSettings.value("ops.retentionDays", sql: sql))!
        let cutoff = DB.time(now.addingTimeInterval(-Double(days) * 86400))
        var deleted: [String: Int] = [:]
        let statements: [(String, SQLQueryString)] = [
            ("events", "DELETE FROM ops_events WHERE occurred_at < \(bind: cutoff) LIMIT 1000"),
            ("mail", "DELETE FROM mail_deliveries WHERE state IN ('smtp-accepted','abandoned') AND updated_at < \(bind: cutoff) AND effect_id IS NULL LIMIT 1000"),
            ("webhooks", "DELETE FROM webhook_outbox WHERE state IN ('succeeded','failed-terminal') AND completed_at < \(bind: cutoff) AND effect_id IS NULL LIMIT 1000"),
            ("oauthRequests", "DELETE FROM oauth_authorization_requests WHERE expires_at < \(bind: cutoff) LIMIT 1000"),
            ("oauthCodes", "DELETE FROM oauth_codes WHERE expires_at < \(bind: cutoff) LIMIT 1000"),
            ("oauthRefresh", "DELETE FROM oauth_refresh_tokens WHERE expires_at < \(bind: cutoff) AND NOT EXISTS (SELECT 1 FROM (SELECT replaced_by FROM oauth_refresh_tokens WHERE replaced_by IS NOT NULL) refs WHERE refs.replaced_by=oauth_refresh_tokens.id) LIMIT 1000"),
            ("oauthTokens", "DELETE FROM mcp_tokens WHERE expires_at < \(bind: cutoff) LIMIT 1000"),
            ("oauthGrants", "DELETE FROM oauth_grants WHERE expires_at < \(bind: cutoff) AND NOT EXISTS (SELECT 1 FROM mcp_tokens t WHERE t.grant_id=oauth_grants.id) AND NOT EXISTS (SELECT 1 FROM oauth_codes c WHERE c.grant_id=oauth_grants.id) AND NOT EXISTS (SELECT 1 FROM oauth_refresh_tokens r WHERE r.grant_id=oauth_grants.id) LIMIT 1000"),
            ("throttles", "DELETE FROM auth_throttles WHERE expires_at < \(bind: DB.time(now)) AND (locked_until IS NULL OR locked_until < \(bind: DB.time(now))) LIMIT 1000")
        ]
        for (name, statement) in statements {
            try await sql.raw(statement).run()
            deleted[name] = try await sql.raw("SELECT ROW_COUNT() AS n").first(decoding: Count.self)?.n ?? 0
        }
        deleted["abuseIPs"] = try await purgeAbuse(sql, now: now)
        return Result(deleted: deleted, batchLimit: 1000)
    }
    /// Expired abuse bans and stale counters (window elapsed, never banned). Active bans are kept.
    @discardableResult
    static func purgeAbuse(_ sql: SQLDatabase, now: Date) async throws -> Int {
        let window = Int(try await SystemSettings.value("abuse.windowSeconds", sql: sql))!
        try await sql.raw("DELETE FROM ingest_abuse_ips WHERE (blocked_until IS NOT NULL AND blocked_until <= \(bind: DB.time(now))) OR (blocked_until IS NULL AND window_start < \(bind: DB.time(now.addingTimeInterval(-Double(window))))) LIMIT 1000").run()
        return try await sql.raw("SELECT ROW_COUNT() AS n").first(decoding: Count.self)?.n ?? 0
    }
}
