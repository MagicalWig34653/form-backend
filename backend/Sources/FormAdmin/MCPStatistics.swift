// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Bounded, content-free statistics for one explicitly addressed form per call.
enum MCPStatistics {
    static let names = ["statistik_kpis", "statistik_zeitreihe", "statistik_statusverteilung", "statistik_formulare", "statistik_eintraege", "ads_statistics"]
    static let descriptions = [
        "KPI für ein Formular; Produktion, höchstens 366 UTC-Tage.",
        "Tägliche Zeitreihe für ein Formular; höchstens 366 Zeilen.",
        "Status akzeptierter Einsendungen. Fehlerstatus werden im Statistikbestand nicht erfasst.",
        "Statistik des ausdrücklich angegebenen Formulars.",
        "Statistikereignisse ohne Personenbezug; höchstens 100 Einträge, keine Besucherkennungen.",
        "Aggregierte Ads-Verteilung und Conversion; kleine Gruppen werden ausgeblendet."
    ]
    struct Input {
        let tenant: UUID, form: UUID
        let days: Int, limit: Int
        init(_ args: [String: JSONValue]) throws {
            guard Set(args.keys).isSubset(of: ["tenantId", "formId", "days", "limit"]),
                  let tenant = args["tenantId"]?.string.flatMap(UUID.init(uuidString:)),
                  let form = args["formId"]?.string.flatMap(UUID.init(uuidString:)),
                  args["days"] == nil || args["days"]?.int != nil,
                  args["limit"] == nil || args["limit"]?.int != nil,
                  (1...366).contains(args["days"]?.int ?? 30), (1...100).contains(args["limit"]?.int ?? 50) else { throw Abort(.badRequest) }
            self.tenant = tenant; self.form = form
            days = Int(args["days"]?.int ?? 30); limit = Int(args["limit"]?.int ?? 50)
        }
    }
    static func tools(token: TokenIdentity, perms: PermissionService) async throws -> [[String: Any]] {
        guard token.permits("statistics.read", on: token.boundary.target) else { return [] }
        // A customer-bound token may have only individual form grants. Do not require a customer-wide grant.
        let accessible = try await perms.grants(account: token.accountID).contains { grant in
            guard grant.permission == "statistics.read" else { return false }
            switch grant.scope {
            case .system: return true
            case .customer(let c): return c == token.boundary.tenantId
            case .form(let c, let f): return c == token.boundary.tenantId && (token.boundary.formId == nil || f == token.boundary.formId)
            }
        }
        guard accessible else { return [] }
        return zip(names, descriptions).map { name, description -> [String: Any] in
            ["name": name, "description": description,
             "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
             "inputSchema": ["type": "object", "required": ["tenantId", "formId"], "additionalProperties": false,
                "properties": ["tenantId": ["type": "string", "format": "uuid"], "formId": ["type": "string", "format": "uuid"],
                    "days": ["type": "integer", "minimum": 1, "maximum": 366, "default": 30],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 50]]]]
        }
    }
    static func window(days: Int, now: Date) -> (String, String) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: calendar.date(byAdding: .day, value: -(days - 1), to: now)!), formatter.string(from: now))
    }
    /// Shared reader entry point for REST integration once its file ownership is released.
    static func eventStream(tenant: UUID, form: UUID, from: String, to: String, now: Date) -> SQLQueryString {
        let end = now
        // Same production event/fallback contract as StatisticsRoutes: pre-introduction accepted
        // submissions only, no duplicate submits, no resurrection after explicit statistics erasure.
        return """

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
            """
    }
    struct Day: Decodable { let d: String; let visits: Int, begins: Int, submits: Int, abandons: Int }
    struct Event: Decodable { let occurred_at: Date; let event_kind: String }
    static func call(_ name: String, input: Input, token: TokenIdentity, db: Database, now: Date) async throws -> [String: Any] {
        guard names.contains(name) || name == "statistik_ads" else { throw Abort(.badRequest) }
        let sql = db as! SQLDatabase
        let tenant = input.tenant, form = input.form
        let target = PermissionTarget.form(customer: tenant, form: form)
        guard token.permits("statistics.read", on: target) else { throw Abort(.forbidden) }
        let exists = try await sql.raw("SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id=f.customer_id WHERE f.id=\(bind: DB.bin(form)) AND f.customer_id=\(bind: DB.bin(tenant)) AND c.state='active'").first(decoding: FormAdmin.CountRow.self)?.c == 1
        try await token.authorize(PermissionService(sql: sql), "statistics.read", on: target, exists: exists)
        let (from, to) = window(days: input.days, now: now)
        let stream = eventStream(tenant: tenant, form: form, from: from, to: to, now: now)
        var result: [String: Any] = ["contractVersion": "1.0", "from": from, "to": to, "environment": "production", "formId": form.uuidString.lowercased()]
        if name == "ads_statistics" || name == "statistik_ads" {
            let body = try await AdsStatistics.read(sql: sql, tenant: tenant, form: form, days: input.days, now: now)
            let projection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
            result.merge(projection) { _, new in new }
        } else if name == "statistik_eintraege" {
            let rows = try await sql.raw("SELECT occurred_at,event_kind FROM (\(stream)) AS counted ORDER BY occurred_at DESC,event_kind LIMIT \(bind: input.limit + 1)").all(decoding: Event.self)
            let formatter = ISO8601DateFormatter()
            result["events"] = rows.prefix(input.limit).map { ["occurredAt": formatter.string(from: $0.occurred_at), "kind": $0.event_kind] }
            result["truncated"] = rows.count > input.limit
        } else {
            let rows = try await sql.raw("""
                SELECT DATE_FORMAT(occurred_at,'%Y-%m-%d') AS d,
                  CAST(SUM(event_kind='visit') AS SIGNED) AS visits,
                  CAST(SUM(event_kind='begin') AS SIGNED) AS begins,
                  CAST(SUM(event_kind='submit') AS SIGNED) AS submits,
                  CAST(SUM(event_kind='abandon') AS SIGNED) AS abandons
                FROM (\(stream)) AS counted GROUP BY d ORDER BY d LIMIT 366
                """).all(decoding: Day.self)
            let body = StatisticsRoutes.Body(from: from, to: to, days: rows.map { .init(date: $0.d, visits: $0.visits, begins: $0.begins, submits: $0.submits, abandons: $0.abandons) })
            switch name {
            case "statistik_zeitreihe":
                result["days"] = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])?["days"]
            case "statistik_statusverteilung":
                result["statuses"] = [["status": "accepted", "count": body.submits]]
                result["errorStatusesAvailable"] = false
            default:
                result["kpi"] = ["visits": body.visits, "begins": body.begins, "submits": body.submits, "abandons": body.abandons, "conversion": body.conversion.map { $0 as Any } ?? NSNull()]
            }
        }
        // Never include arguments, visitor identifiers, tokens, labels, client names or result data.
        try await sql.raw("""
            INSERT INTO audit_events (id,customer_id,form_id,actor_kind,category,action_code,occurred_at,safe_details_json)
            VALUES (\(bind: DB.bin(UUID())),\(bind: DB.bin(tenant)),\(bind: DB.bin(form)),'service','statistics',\(bind: "mcp." + name),\(bind: DB.time(now)),'{}')
            """).run()
        return result
    }
}
