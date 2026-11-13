// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Reading the audit log (FA-146, contracts/auth getAudit). Metadata only: `safe_details_json` and the migration
/// source columns are never part of the response. Rows are limited to the scopes of the caller's `audit.read` grants,
/// evaluated live: system sees everything (also rows without customer), a customer grant sees that customer's rows,
/// a form grant sees exactly that form's rows. No step-up: listing submissions does not require one either.
enum AuditRoutes {
    struct Item: Codable, Equatable {
        let id: String, occurredAt: String, category: String, action: String
        let actorId: String?, actorKind: String
        let customerId: String?, formId: String?, subjectId: String?
    }
    struct Page: Encodable { let items: [Item]; let nextCursor: String? }
    private struct Row: Decodable {
        let id: Blob, occurred_at: Date, category: String, action_code: String
        let actor_id: Blob?, actor_kind: String, customer_id: Blob?, form_id: Blob?, subject_id: Blob?
    }

    /// Identifiers such as `key.access.repair`; anything else cannot match a stored code and is rejected as 400.
    static func isCode(_ s: String, max: Int) -> Bool {
        !s.isEmpty && s.utf8.count <= max && s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e || $0 == 0x2d || $0 == 0x5f || $0 == 0x3a }
    }

    /// SQL condition over alias `e` for the audit.read grants; nil without any grant.
    static func scopeClause(_ grants: [Grant]) -> SQLQueryString? {
        var seen = Set<String>(), parts: [SQLQueryString] = []
        for g in grants where g.permission == "audit.read" {
            switch g.scope {
            case .system: return "1=1"
            case .customer(let c):
                if seen.insert("c\(c)").inserted { parts.append("e.customer_id = \(bind: DB.bin(c))") }
            case .form(let c, let f):
                if seen.insert("f\(c)\(f)").inserted { parts.append("(e.customer_id = \(bind: DB.bin(c)) AND e.form_id = \(bind: DB.bin(f)))") }
            }
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { "\($0) OR \($1)" }
    }

    static func register(_ app: Application, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        app.grouped("admin", "api", "v1", "audit").get { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let grants = try await PermissionService(sql: sql).grants(account: s.accountID!)
            guard let scope = scopeClause(grants) else { throw Abort(.forbidden) }
            let limit = try FormAdmin.limitParam(req)
            func uuid(_ key: String) throws -> UUID? {
                guard let raw: String = req.query[key] else { return nil }
                guard let u = UUID(uuidString: raw) else { throw Abort(.badRequest) }
                return u
            }
            func date(_ key: String) throws -> Date? {
                guard let raw: String = req.query[key] else { return nil }
                guard let d = ISO8601DateFormatter().date(from: raw) else { throw Abort(.badRequest) }
                return d
            }
            func code(_ key: String, max: Int) throws -> String? {
                guard let raw: String = req.query[key] else { return nil }
                guard isCode(raw, max: max) else { throw Abort(.badRequest) }
                return raw
            }
            let actor = try uuid("actor"), customer = try uuid("customer"), form = try uuid("form")
            let from = try date("from"), to = try date("to")
            if let from, let to, from > to { throw Abort(.badRequest) }
            let action = try code("action", max: 100), category = try code("category", max: 64)
            var filter: SQLQueryString = ""
            if let actor { filter = "\(filter) AND e.actor_id = \(bind: DB.bin(actor))" }
            if let customer { filter = "\(filter) AND e.customer_id = \(bind: DB.bin(customer))" }
            if let form { filter = "\(filter) AND e.form_id = \(bind: DB.bin(form))" }
            if let from { filter = "\(filter) AND e.occurred_at >= \(bind: DB.time(from))" }
            if let to { filter = "\(filter) AND e.occurred_at <= \(bind: DB.time(to))" }
            if let action { filter = "\(filter) AND e.action_code = \(bind: action)" }
            if let category { filter = "\(filter) AND e.category = \(bind: category)" }
            var cursor: SQLQueryString = ""
            if let after = try FormAdmin.cursorParam(req) {
                // The cursor row must itself be visible; otherwise the id would reveal nothing but still must not page.
                guard try await sql.raw("SELECT COUNT(*) AS c FROM audit_events e WHERE e.id = \(bind: Blob(after)) AND (\(scope))").first(decoding: FormAdmin.CountRow.self)?.c == 1 else { throw Abort(.badRequest) }
                cursor = "AND (e.occurred_at, e.id) < (SELECT c.occurred_at, c.id FROM audit_events c WHERE c.id = \(bind: Blob(after)))"
            }
            let rows = try await sql.raw("""
                SELECT e.id, e.occurred_at, e.category, e.action_code, e.actor_id, e.actor_kind, e.customer_id, e.form_id, e.subject_id
                FROM audit_events e
                WHERE (\(scope)) \(filter) \(cursor)
                ORDER BY e.occurred_at DESC, e.id DESC LIMIT \(literal: limit + 1)
                """).all(decoding: Row.self)
            func id(_ b: Blob?) -> String? { b.flatMap { DB.uuid($0.data) }?.uuidString.lowercased() }
            let page = rows.prefix(limit)
            let items = page.map { r in
                Item(id: id(r.id) ?? "", occurredAt: iso.string(from: r.occurred_at), category: r.category, action: r.action_code,
                     actorId: id(r.actor_id), actorKind: r.actor_kind, customerId: id(r.customer_id), formId: id(r.form_id), subjectId: id(r.subject_id))
            }
            let res = try FormAdmin.json(.ok, Page(items: items, nextCursor: rows.count > limit ? page.last.map { FormAdmin.cursor($0.id) } : nil))
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
    }
}
