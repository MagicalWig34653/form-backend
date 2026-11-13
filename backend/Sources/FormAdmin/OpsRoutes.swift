// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

enum OpsRoutes {
    static let events = ["pending", "sending", "accepted", "failed", "uncertain", "recovered"]
    static let operations = ["mail", "webhook", "scanner", "storage", "sdk"]
    struct Item: Codable {
        let id: UInt64
        let customer: String, form: String
        let submission: String?, target: String?
        let event: String, operation: String, priority: Int, occurredAt: String
    }
    struct Page: Encodable { let items: [Item]; let next: UInt64? }
    struct Form: Encodable { let customer: String, id: String, name: String }
    struct Access: Encodable { let forms: [Form]; let system: Bool; let cleanup: Bool; let alarm: Alarm? }
    struct Alarm: Codable { let outcome: String; let suppressed: UInt64 }
    struct F: Decodable { let customer_id: Blob, id: Blob; let name: String }
    static func permitted(_ grants: [Grant], customer: UUID, form: UUID) -> Bool {
        grants.contains { $0.permission == "audit.read" && $0.scope.covers(.form(customer: customer, form: form)) }
    }
    static func register(_ app: Application, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        let root = app.grouped("admin", "api", "v1", "ops")
        let sql = db as! SQLDatabase
        root.get("access") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let grants = try await PermissionService(sql: sql).grants(account: s.accountID!)
            let rows = try await sql.raw("SELECT f.customer_id,f.id,f.name FROM forms f JOIN customers c ON c.id=f.customer_id WHERE c.state='active' ORDER BY f.id").all(decoding: F.self)
            let forms = rows.compactMap { r -> Form? in
                guard let c = DB.uuid(r.customer_id.data), let f = DB.uuid(r.id.data), permitted(grants, customer: c, form: f) else { return nil }
                return Form(customer: c.uuidString.lowercased(), id: f.uuidString.lowercased(), name: r.name)
            }
            let system = grants.contains { $0.permission == "audit.read" && $0.scope == .system }
            let alarm = system ? try await sql.raw("SELECT outcome,suppressed FROM ops_alarm_state WHERE singleton=1").first(decoding: Alarm.self) : nil
            return try response(Access(forms: forms, system: grants.contains { $0.permission == "audit.read" && $0.scope == .system }, cleanup: grants.contains { $0.permission == "system.manage" && $0.scope == .system }, alarm: alarm))
        }
        root.get { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            // One explicit form per query keeps paging scoped before LIMIT, even with form-only grants.
            guard let raw: String = req.query["form"], let form = UUID(uuidString: raw) else { throw Abort(.badRequest) }
            let row = try await sql.raw("SELECT f.customer_id,f.id,f.name FROM forms f JOIN customers c ON c.id=f.customer_id WHERE f.id=\(bind: DB.bin(form)) AND c.state='active'").first(decoding: F.self)
            guard let row, let customer = DB.uuid(row.customer_id.data) else { throw Abort(.notFound) }
            try await PermissionService(sql: sql).authorize(account: s.accountID!, "audit.read", on: .form(customer: customer, form: form))
            let event: String? = req.query["event"], operation: String? = req.query["operation"]
            if let event, !events.contains(event) { throw Abort(.badRequest) }
            if let operation, !operations.contains(operation) { throw Abort(.badRequest) }
            func number(_ key: String, fallback: UInt64) throws -> UInt64 {
                guard let raw: String = req.query[key] else { return fallback }
                guard let n = UInt64(raw), n > 0, n <= UInt64(Int64.max) else { throw Abort(.badRequest) }; return n
            }
            let limit = try number("limit", fallback: 50), before = try number("before", fallback: UInt64(Int64.max))
            guard limit <= 100 else { throw Abort(.badRequest) }
            func date(_ key: String, fallback: Date) throws -> Date {
                guard let raw: String = req.query[key] else { return fallback }
                guard let d = ISO8601DateFormatter().date(from: raw) else { throw Abort(.badRequest) }; return d
            }
            let alarmFilter: String? = req.query["alarms"]
            let from = try date("from", fallback: now().addingTimeInterval(alarmFilter == "1" ? -365 * 86400 : -86400)), to = try date("to", fallback: now())
            guard from <= to, to.timeIntervalSince(from) <= 366 * 86400 else { throw Abort(.badRequest) }
            // Triggers stamp events with the database clock; without an explicit "to" a database clock running ahead of the
            // app clock must not hide the newest events, so the default window has no upper bound.
            let upper: String? = (req.query["to"] as String?) == nil ? nil : DB.time(to)
            let subRaw: String? = req.query["submission"]
            let submission = subRaw.flatMap(UUID.init(uuidString:))
            if subRaw != nil && submission == nil { throw Abort(.badRequest) }
            // Chronology also requires content.read; audit access alone does not confer submission access.
            if submission != nil { try await PermissionService(sql: sql).authorize(account: s.accountID!, "content.read", on: .form(customer: customer, form: form)) }
            let alarms: String? = req.query["alarms"]
            guard alarms == nil || alarms == "1" else { throw Abort(.badRequest) }
            let rows = try await sql.raw("""
                SELECT e.id, LOWER(CONCAT(SUBSTR(HEX(e.customer_id),1,8),'-',SUBSTR(HEX(e.customer_id),9,4),'-',SUBSTR(HEX(e.customer_id),13,4),'-',SUBSTR(HEX(e.customer_id),17,4),'-',SUBSTR(HEX(e.customer_id),21))) AS customer,
                  e.form_id,e.submission_id,e.target_id,e.event,e.operation,e.priority,DATE_FORMAT(e.occurred_at,'%Y-%m-%dT%H:%i:%sZ') AS occurredAt
                FROM ops_events e WHERE e.customer_id=\(bind: DB.bin(customer)) AND e.form_id=\(bind: DB.bin(form))
                  AND e.id < \(bind: before) AND e.occurred_at >= \(bind: DB.time(from)) AND (\(bind: upper) IS NULL OR e.occurred_at <= \(bind: upper))
                  AND (\(bind: event) IS NULL OR e.event=\(bind: event)) AND (\(bind: operation) IS NULL OR e.operation=\(bind: operation))
                  AND (\(bind: submission.map(DB.bin)) IS NULL OR e.submission_id=\(bind: submission.map(DB.bin)))
                  AND (\(bind: alarms) IS NULL OR (e.priority > 0 AND NOT EXISTS (SELECT 1 FROM ops_events n WHERE n.source_id=e.source_id AND n.operation=e.operation AND n.id>e.id)))
                ORDER BY e.id DESC LIMIT \(literal: limit + 1)
                """).all(decoding: EventRow.self)
            let items = rows.prefix(Int(limit)).map { $0.item(form: form) }
            return try response(Page(items: items, next: rows.count > limit ? items.last?.id : nil))
        }
        root.post("cleanup") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            try await guardian.requireFreshAuthentication(s, now: now())
            let result = try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: s.accountID!, "system.manage", on: .system)
                let result = try await OpsMaintenance.purge(tx, now: now())
                let data = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
                try await tx.raw("INSERT INTO audit_events (id,actor_id,actor_kind,category,action_code,occurred_at,safe_details_json) VALUES (\(bind: DB.bin(UUID())),\(bind: DB.bin(s.accountID!)),'human','system','ops.cleanup',\(bind: DB.time(now())),\(bind: data))").run()
                return result
            }
            return try response(result)
        }
    }
    struct EventRow: Decodable {
        let id: UInt64, customer: String, form_id: Blob, submission_id: Blob?, target_id: Blob?
        let event: String, operation: String, priority: Int, occurredAt: String
        func item(form: UUID) -> Item { Item(id: id, customer: customer, form: form.uuidString.lowercased(), submission: submission_id.flatMap { DB.uuid($0.data)?.uuidString.lowercased() }, target: target_id.flatMap { DB.uuid($0.data)?.uuidString.lowercased() }, event: event, operation: operation, priority: priority, occurredAt: occurredAt) }
    }
    static func response<T: Encodable>(_ data: T) throws -> Response {
        let r = try FormAdmin.json(.ok, data); r.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return r
    }
}
