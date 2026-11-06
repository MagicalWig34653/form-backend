// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Events are authoritative since the UTC introduction day; older submissions use a bounded legacy path.
enum StatisticsRoutes {
    struct Day: Encodable {
        let date: String
        let visits: Int, begins: Int, submits: Int, abandons: Int
        var count: Int { submits }
        var conversion: Double? { visits == 0 ? nil : Double(submits) / Double(visits) }
        enum CodingKeys: String, CodingKey { case date, count, visits, begins, submits, abandons, conversion }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date); try c.encode(count, forKey: .count)
            try c.encode(visits, forKey: .visits); try c.encode(begins, forKey: .begins)
            try c.encode(submits, forKey: .submits); try c.encode(abandons, forKey: .abandons)
            if let conversion { try c.encode(conversion, forKey: .conversion) } else { try c.encodeNil(forKey: .conversion) }
        }
    }
    struct Body: Encodable {
        let from: String, to: String
        let days: [Day]
        var visits: Int { days.reduce(0) { $0 + $1.visits } }
        var begins: Int { days.reduce(0) { $0 + $1.begins } }
        var submits: Int { days.reduce(0) { $0 + $1.submits } }
        var abandons: Int { days.reduce(0) { $0 + $1.abandons } }
        var total: Int { submits }
        var conversion: Double? { visits == 0 ? nil : Double(submits) / Double(visits) }
        enum CodingKeys: String, CodingKey { case from, to, total, days, visits, begins, submits, abandons, conversion }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(from, forKey: .from); try c.encode(to, forKey: .to); try c.encode(days, forKey: .days)
            try c.encode(total, forKey: .total); try c.encode(visits, forKey: .visits); try c.encode(begins, forKey: .begins)
            try c.encode(submits, forKey: .submits); try c.encode(abandons, forKey: .abandons)
            if let conversion { try c.encode(conversion, forKey: .conversion) } else { try c.encodeNil(forKey: .conversion) }
        }
    }
    private struct Row: Decodable { let d: String; let visits: Int, begins: Int, submits: Int, abandons: Int }

    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        func exists(_ tenant: UUID, _ form: UUID) async throws -> Bool {
            try await sql.raw("SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.id = \(bind: DB.bin(form)) AND f.customer_id = \(bind: DB.bin(tenant)) AND c.state = 'active'")
                .first(decoding: FormAdmin.CountRow.self)?.c == 1
        }
        tenants.get("forms", ":formId", "statistics", "ads") { req async throws -> Response in
            let session = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            let raw: String? = req.query["days"]
            guard let days = Int(raw ?? "30"), (1...366).contains(days) else { throw Abort(.badRequest) }
            try await perms.authorize(account: session.accountID!, "statistics.read", on: .form(customer: tenant, form: form), exists: try await exists(tenant, form))
            let response = try FormAdmin.json(.ok, try await AdsStatistics.read(sql: sql, tenant: tenant, form: form, days: days, now: now()))
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
        tenants.get("forms", ":formId", "statistics") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            let days: Int
            if let raw: String = req.query["days"] {
                guard let n = Int(raw), (1...366).contains(n) else { throw Abort(.badRequest) }
                days = n
            } else { days = 30 }
            try await perms.authorize(account: s.accountID!, "statistics.read", on: .form(customer: tenant, form: form), exists: try await exists(tenant, form))
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"; day.timeZone = TimeZone(identifier: "UTC"); day.locale = Locale(identifier: "en_US_POSIX")
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let end = now(), start = calendar.date(byAdding: .day, value: -(days - 1), to: end)!
            let from = day.string(from: start), to = day.string(from: end)
            let rows = try await sql.raw("""
                SELECT DATE_FORMAT(occurred_at, '%Y-%m-%d') AS d,
                    CAST(SUM(event_kind = 'visit') AS SIGNED) AS visits,
                    CAST(SUM(event_kind = 'begin') AS SIGNED) AS begins,
                    CAST(SUM(event_kind = 'submit') AS SIGNED) AS submits,
                    CAST(SUM(event_kind = 'abandon') AS SIGNED) AS abandons
                FROM (
                    SELECT e.occurred_at, e.event_kind FROM statistics_events e
                    WHERE e.customer_id = \(bind: DB.bin(tenant)) AND e.form_id = \(bind: DB.bin(form)) AND e.environment = 'production'
                      AND e.occurred_at >= \(bind: "\(from) 00:00:00.000000") AND e.occurred_at <= \(bind: "\(to) 23:59:59.999999")
                    UNION ALL
                    SELECT s.received_at AS occurred_at, 'submit' AS event_kind FROM submissions s
                    WHERE s.customer_id = \(bind: DB.bin(tenant)) AND s.form_id = \(bind: DB.bin(form))
                      AND s.environment = 'production' AND s.state = 'accepted'
                      AND s.received_at < '2026-11-03 00:00:00.000000'
                      AND DATE_ADD(s.received_at, INTERVAL 13 MONTH) > CAST(\(bind: DB.time(end)) AS DATETIME(6))
                      AND NOT EXISTS (
                        SELECT 1 FROM deletion_records d WHERE d.customer_id = s.customer_id AND d.form_id = s.form_id
                          AND d.category = 'statistics' AND d.reason_code = 'request' AND d.deleted_at >= s.received_at
                      )
                      AND s.received_at >= \(bind: "\(from) 00:00:00.000000") AND s.received_at <= \(bind: "\(to) 23:59:59.999999")
                      AND NOT EXISTS (
                        SELECT 1 FROM statistics_events e WHERE e.customer_id = s.customer_id AND e.form_id = s.form_id
                          AND e.environment = 'production' AND e.event_kind = 'submit' AND e.submission_id = s.id
                      )
                ) AS counted
                GROUP BY d ORDER BY d
                """).all(decoding: Row.self)
            let res = try FormAdmin.json(.ok, Body(from: from, to: to, days: rows.map { Day(date: $0.d, visits: $0.visits, begins: $0.begins, submits: $0.submits, abandons: $0.abandons) }))
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
        tenants.delete("forms", ":formId", "statistics") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            try await perms.authorize(account: s.accountID!, "statistics.delete", on: .customer(tenant), exists: try await exists(tenant, form))
            try await guardian.requireFreshAuthentication(s, now: now())
            let at = now(), actor = s.accountID!
            let deleted = try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                let n = try await StatisticsEraser.erase(tx, tenant: tenant, form: form, reason: "request", actor: actor, now: at)
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: actor, action: "statistics.delete", subject: form, at: DB.time(at), category: "statistics").run()
                return n
            }
            struct Result: Encodable { let deleted: Int }
            let res = try FormAdmin.json(.ok, Result(deleted: deleted))
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
    }
}
