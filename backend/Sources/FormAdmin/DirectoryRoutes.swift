// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// What an administration UI needs to start (VORGESCHLAGEN, not yet in the OpenAPI contract):
/// `GET /me`, `GET/POST /tenants`, `GET /tenants/{t}/connections`. Everything is authorised like every other operation
/// (live rights, 404 for what the caller may not see); the permission lists returned here are hints for the UI only.
enum DirectoryRoutes {
    static func register(root: RoutesBuilder, tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase

        root.get("me") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            struct R: Decodable { let username: String }
            let account = s.accountID!
            guard let r = try await sql.raw("SELECT username FROM accounts WHERE id = \(bind: DB.bin(account)) AND active = 1").first(decoding: R.self) else { throw Abort(.unauthorized) }
            let system = try await perms.can(account: account, "system.manage", on: .system)
            return try MailRoutes.anyJSON(["id": account.uuidString.lowercased(), "username": r.username, "systemAdministrator": system])
        }

        root.get("tenants") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let grants = try await perms.grants(account: s.accountID!)
            struct R: Decodable { let id: Blob; let name: String }
            var rows: [R]
            if grants.contains(where: { $0.scope == .system }) {
                rows = try await sql.raw("SELECT id, name FROM customers WHERE state = 'active' ORDER BY name, id LIMIT 200").all(decoding: R.self)
            } else {
                var ids = Set<UUID>()
                for g in grants { switch g.scope { case .customer(let c): ids.insert(c); case .form(let c, _): ids.insert(c); case .system: break } }
                guard !ids.isEmpty else { return try MailRoutes.anyJSON(["items": [Any]()]) }
                rows = try await sql.raw("SELECT id, name FROM customers WHERE state = 'active' AND id IN (\(binds: ids.map(DB.bin))) ORDER BY name, id LIMIT 200").all(decoding: R.self)
            }
            let items: [[String: Any]] = rows.compactMap { r in
                guard let id = DB.uuid(r.id.data) else { return nil }
                // Hints for the UI: rights that hold for the whole customer (customer-wide or system grants).
                let hints = Set(grants.filter { $0.scope.covers(.customer(id)) }.map(\.permission)).sorted()
                return ["id": id.uuidString.lowercased(), "name": r.name, "permissions": hints]
            }
            return try MailRoutes.anyJSON(["items": items])
        }

        root.post("tenants") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let account = s.accountID!
            try await perms.authorize(account: account, "system.manage", on: .system)
            try await guardian.requireFreshAuthentication(s, now: now())
            let obj = try MailRoutes.jsonObject(req, allowed: ["name"])
            guard let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespaces), (1...255).contains(name.count),
                  !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { throw ValidationFailed(detail: "name: 1–255 Zeichen ohne Steuerzeichen") }
            let id = UUID(), ts = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await tx.raw("INSERT INTO customers (id, name, state, created_at) VALUES (\(bind: DB.bin(id)), \(bind: name), 'active', \(bind: ts))").run()
                try await MailRoutes.audit(tx, actor: account, action: "customer.create", subject: id, at: ts, customer: id)
            }
            return try FormAdmin.json(.created, ["id": id.uuidString.lowercased(), "status": "created"])
        }

        tenants.get("connections") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId")
            let exists = try await FormAdmin.CountRow.count(sql, "SELECT COUNT(*) AS c FROM customers WHERE id = \(bind: DB.bin(tenant)) AND state = 'active'") == 1
            try await perms.authorize(account: s.accountID!, "form.read", on: .customer(tenant), exists: exists)
            struct R: Decodable { let id: Blob; let kind: String; let name: String }
            let rows = try await sql.raw("""
                SELECT c.id AS id, c.kind AS kind, c.name AS name FROM customer_connections cc JOIN connections c ON c.id = cc.connection_id
                WHERE cc.customer_id = \(bind: DB.bin(tenant)) AND c.enabled = 1 AND c.kind IN ('smtp','mail-proxy') ORDER BY c.name, c.id LIMIT 100
                """).all(decoding: R.self)
            return try MailRoutes.anyJSON(["items": rows.map { ["id": DB.uuid($0.id.data)?.uuidString.lowercased() ?? "", "kind": $0.kind, "name": $0.name] as [String: Any] }])
        }
    }
}
