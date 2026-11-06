// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormPersistence
import SQLKit

/// REST and MCP share this aggregate-only projection and suppression rule.
enum AdsStatistics {
    struct Row: Decodable { let segment: String; let visits: Int; let submits: Int }
    struct Group: Encodable {
        let segment: String
        let visits: Int
        let submits: Int
        var conversion: Double? { visits == 0 ? nil : Double(submits) / Double(visits) }
        enum CodingKeys: String, CodingKey { case segment, visits, submits, conversion }
        init(_ row: Row) { segment = row.segment; visits = row.visits; submits = row.submits }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(segment, forKey: .segment); try c.encode(visits, forKey: .visits); try c.encode(submits, forKey: .submits)
            try c.encode(conversion, forKey: .conversion)
        }
    }
    struct Body: Encodable {
        let from: String, to: String
        let available = true
        let campaignsAvailable = false
        let minimumGroupSize = 5
        let groups: [Group]
        let suppressed: Bool
    }
    static func project(_ rows: [Row], from: String, to: String) -> Body {
        // Suppress the entire row if either nonzero cell is small; no totals reveal complements.
        let safe = rows.filter { ($0.visits == 0 || $0.visits >= 5) && ($0.submits == 0 || $0.submits >= 5) }
        return Body(from: from, to: to, groups: safe.map(Group.init), suppressed: safe.count != rows.count)
    }
    static func read(sql: SQLDatabase, tenant: UUID, form: UUID, days: Int, now: Date) async throws -> Body {
        let (from, to) = MCPStatistics.window(days: days, now: now)
        let rows = try await sql.raw("""
            SELECT CASE WHEN ads_present IS NULL THEN 'unknown' WHEN ads_present=1 THEN 'ads' ELSE 'nonAds' END AS segment,
              CAST(SUM(event_kind='visit') AS SIGNED) AS visits, CAST(SUM(event_kind='submit') AS SIGNED) AS submits
            FROM statistics_events
            WHERE customer_id=\(bind: DB.bin(tenant)) AND form_id=\(bind: DB.bin(form)) AND environment='production'
              AND event_kind IN ('visit','submit') AND occurred_at >= \(bind: from + " 00:00:00.000000")
              AND occurred_at <= \(bind: to + " 23:59:59.999999") AND expires_at > \(bind: DB.time(now))
            GROUP BY segment ORDER BY segment
            """).all(decoding: Row.self)
        return project(rows, from: from, to: to)
    }
}
