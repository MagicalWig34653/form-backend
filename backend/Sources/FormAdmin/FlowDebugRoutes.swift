// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormFlow
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Masked tracing only. No arbitrary endpoint, plaintext or CEK is accepted by these operations.
enum FlowDebugRoutes {
    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        registerTargets(tenants, guardian: guardian, db: db, perms: perms, now: now)
        let sql = db as! SQLDatabase, store = FlowDebugStore(db: db)
        func noStore(_ response: Response) -> Response { response.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return response }
        func exists(_ tenant: UUID, _ form: UUID) async throws -> Bool {
            try await sql.raw("SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.id = \(bind: DB.bin(form)) AND f.customer_id = \(bind: DB.bin(tenant)) AND c.state = 'active'").first(decoding: FormAdmin.CountRow.self)?.c == 1
        }
        func projection(_ tenant: UUID, _ form: UUID, _ id: UUID) async throws -> Response {
            do { return noStore(try FormAdmin.json(.ok, await store.snapshot(tenant: tenant, form: form, id: id, now: now()))) }
            catch FlowDebugError.missing { throw Abort(.notFound) }
            catch FlowDebugError.expired { throw Abort(.gone) }
        }
        tenants.post("forms", ":formId", "debug-jobs") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), account = s.accountID!
            let scope = PermissionTarget.form(customer: tenant, form: form)
            try await perms.authorize(account: account, "debug.read", on: scope, exists: try await exists(tenant, form))
            let o = try MailRoutes.jsonObject(req, allowed: ["releaseId", "mode", "correlationId"])
            guard let raw = o["releaseId"] as? String, let release = UUID(uuidString: raw), let mode = o["mode"] as? String, ["observe", "test"].contains(mode) else { throw ValidationFailed(detail: "releaseId, mode") }
            // Correlation tokens must never be persisted in clear. Matching by arbitrary correlation is unsupported in P6.
            if let correlation = o["correlationId"] { guard let c = correlation as? String, c.count <= 190 else { throw ValidationFailed(detail: "correlationId") }; throw ValidationFailed(detail: "correlationId wird in P6 nicht unterstützt") }
            if mode == "test" { try await perms.authorize(account: account, "test.run", on: scope); throw Abort(.conflict, reason: "Testläufe werden separat und ohne Produktionseffekte gestartet.") }
            let id = UUID(), at = now()
            try await store.purge(now: at)
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: account, "debug.read", on: scope)
                guard try await tx.raw("SELECT COUNT(*) AS c FROM releases WHERE id = \(bind: DB.bin(release)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) FOR UPDATE").first(decoding: FormAdmin.CountRow.self)?.c == 1 else { throw Abort(.notFound) }
                guard (try await tx.raw("SELECT COUNT(*) AS c FROM debug_requests WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND state IN ('waiting','recording') AND expires_at > \(bind: DB.time(at))").first(decoding: FormAdmin.CountRow.self)?.c ?? 0) < 20 else { throw Abort(.tooManyRequests) }
                try await tx.raw("INSERT INTO debug_requests (id, customer_id, form_id, release_id, requested_by, mode, environment, state, expires_at) VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: DB.bin(release)), \(bind: DB.bin(account)), 'observe', 'production', 'waiting', \(bind: DB.time(at.addingTimeInterval(900))))").run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: account, action: "debug.start", subject: id, at: DB.time(at)).run()
            }
            let response = try await projection(tenant, form, id); response.status = .created; return response
        }
        tenants.get("forms", ":formId", "debug-jobs", ":debugId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), id = try FormAdmin.uuidParam(req, "debugId")
            try await perms.authorize(account: s.accountID!, "debug.read", on: .form(customer: tenant, form: form), exists: try await exists(tenant, form))
            try await store.purge(now: now())
            return try await projection(tenant, form, id)
        }
        tenants.delete("forms", ":formId", "debug-jobs", ":debugId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId"), id = try FormAdmin.uuidParam(req, "debugId"), account = s.accountID!
            let scope = PermissionTarget.form(customer: tenant, form: form)
            try await perms.authorize(account: account, "debug.read", on: scope, exists: try await exists(tenant, form))
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: account, "debug.read", on: scope)
                struct Owner: Decodable { let requested_by: Blob }
                guard let row = try await tx.raw("SELECT requested_by FROM debug_requests WHERE id = \(bind: DB.bin(id)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) FOR UPDATE").first(decoding: Owner.self) else { throw Abort(.notFound) }
                guard DB.uuid(row.requested_by.data) == account else { throw Abort(.forbidden) }
                try await tx.raw("DELETE FROM debug_objects WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND debug_request_id = \(bind: DB.bin(id))").run()
                try await tx.raw("DELETE FROM debug_events WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND debug_request_id = \(bind: DB.bin(id))").run()
                try await tx.raw("UPDATE debug_requests SET state = 'cancelled', lease_token = NULL, lease_until = NULL WHERE id = \(bind: DB.bin(id))").run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: account, action: "debug.cancel", subject: id, at: DB.time(now())).run()
            }
            return noStore(Response(status: .noContent))
        }
    }
}

extension FlowDebugRoutes {
    struct TargetConfig: Codable {
        let revision: Int, targetKind: String, recipientAllowlist: [String], endpointAlias: String?
    }
    struct Target: Encodable { let id: String, name: String, targetKind: String; let recipientAllowlistCount: Int, enabled: Bool, revision: Int }
    struct TargetRow: Decodable { let id: Blob; let name: String; let safe_config_json: String; let enabled: Int }
    static func targetProjection(_ r: TargetRow) throws -> Target {
        let c = try JSONDecoder().decode(TargetConfig.self, from: Data(r.safe_config_json.utf8))
        return Target(id: DB.uuid(r.id.data)!.uuidString.lowercased(), name: r.name, targetKind: c.targetKind, recipientAllowlistCount: c.recipientAllowlist.count, enabled: r.enabled == 1, revision: c.revision)
    }
    static func targetInput(_ req: Request, revision: Int) throws -> (String, Bool, TargetConfig) {
        let o = try MailRoutes.jsonObject(req, allowed: ["name", "targetKind", "recipientAllowlist", "endpointAlias", "enabled", "confirm"])
        guard let name = o["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 255,
              !name.unicodeScalars.contains(where: { $0.value < 32 }), let kind = o["targetKind"] as? String, ["mail-sink", "webhook-sink"].contains(kind),
              let enabled = o["enabled"] as? Bool, o["confirm"] as? Bool == true else { throw ValidationFailed(detail: "name, targetKind, enabled, confirm=true") }
        let recipients: [String]
        if let raw = o["recipientAllowlist"] { guard let a = raw as? [String], a.count <= 50, Set(a).count == a.count, a.allSatisfy({ $0.utf8.count <= 320 && $0.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", options: .regularExpression) != nil }) else { throw ValidationFailed(detail: "recipientAllowlist") }; recipients = a }
        else { recipients = [] }
        var alias: String? = nil
        if let raw = o["endpointAlias"] { guard let a = raw as? String, a.range(of: "^[A-Za-z][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else { throw ValidationFailed(detail: "endpointAlias ist ein provisionierter Alias, keine URL") }; alias = a }
        // This package provisions definitions only. Enabling a real sink requires a separately reviewed transport resolver.
        guard !enabled else { throw ValidationFailed(detail: "Testziele bleiben bis zur Transportfreigabe deaktiviert") }
        return (name, enabled, TargetConfig(revision: revision, targetKind: kind, recipientAllowlist: recipients, endpointAlias: alias))
    }
    static func registerTargets(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        func noStore(_ r: Response) -> Response { r.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return r }
        func exists(_ tenant: UUID) async throws -> Bool { try await sql.raw("SELECT COUNT(*) AS c FROM customers WHERE id = \(bind: DB.bin(tenant)) AND state = 'active'").first(decoding: FormAdmin.CountRow.self)?.c == 1 }
        tenants.get("test-targets") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false); try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId")
            try await perms.authorize(account: s.accountID!, "test.run", on: .customer(tenant), exists: try await exists(tenant))
            let limit = try FormAdmin.limitParam(req), cursor = try FormAdmin.cursorParam(req)
            let rows = try await sql.raw("SELECT c.id, c.name, c.safe_config_json, c.enabled FROM connections c JOIN customer_connections x ON x.connection_id = c.id WHERE x.customer_id = \(bind: DB.bin(tenant)) AND c.kind = 'test-target' AND (\(bind: cursor.map(Blob.init)) IS NULL OR c.id > \(bind: cursor.map(Blob.init))) ORDER BY c.id LIMIT \(literal: limit + 1)").all(decoding: TargetRow.self)
            struct Page: Encodable { let items: [Target]; let nextCursor: String? }
            let page = Array(rows.prefix(limit))
            return noStore(try FormAdmin.json(.ok, Page(items: page.map { try targetProjection($0) }, nextCursor: rows.count > limit ? page.last.map { FormAdmin.cursor($0.id) } : nil)))
        }
        tenants.post("test-targets") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true); try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), account = s.accountID!
            try await perms.authorize(account: account, "test-target.manage", on: .customer(tenant), exists: try await exists(tenant)); try await guardian.requireFreshAuthentication(s, now: now())
            let (name, enabled, config) = try targetInput(req, revision: 1), id = UUID()
            let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: account, "test-target.manage", on: .customer(tenant))
                try await tx.raw("INSERT INTO connections (id, kind, name, safe_config_json, enabled) VALUES (\(bind: DB.bin(id)), 'test-target', \(bind: name), \(bind: json), \(bind: enabled))").run()
                try await tx.raw("INSERT INTO customer_connections (customer_id, connection_id) VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(id)))").run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: nil, actor: account, action: "test-target.create", subject: id, at: DB.time(now())).run()
            }
            let r = noStore(try FormAdmin.json(.created, ResultBody(id: id.uuidString.lowercased(), status: "created", revision: 1))); r.headers.replaceOrAdd(name: .eTag, value: "\"1\""); return r
        }
        tenants.patch("test-targets", ":testTargetId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true); try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), id = try FormAdmin.uuidParam(req, "testTargetId"), account = s.accountID!
            try await perms.authorize(account: account, "test-target.manage", on: .customer(tenant), exists: try await exists(tenant)); try await guardian.requireFreshAuthentication(s, now: now())
            guard let match = req.headers.first(name: .ifMatch) else { throw Abort(.preconditionRequired) }
            let revision = try await db.transaction { conn -> Int in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: account, "test-target.manage", on: .customer(tenant))
                guard let row = try await tx.raw("SELECT c.id, c.name, c.safe_config_json, c.enabled FROM connections c JOIN customer_connections x ON x.connection_id = c.id WHERE x.customer_id = \(bind: DB.bin(tenant)) AND c.id = \(bind: DB.bin(id)) AND c.kind = 'test-target' FOR UPDATE").first(decoding: TargetRow.self) else { throw Abort(.notFound) }
                let old = try JSONDecoder().decode(TargetConfig.self, from: Data(row.safe_config_json.utf8))
                guard match == "\"\(old.revision)\"" else { throw Abort(.preconditionFailed) }
                let (name, enabled, config) = try targetInput(req, revision: old.revision + 1)
                let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
                try await tx.raw("UPDATE connections SET name = \(bind: name), safe_config_json = \(bind: json), enabled = \(bind: enabled) WHERE id = \(bind: DB.bin(id))").run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: nil, actor: account, action: "test-target.update", subject: id, at: DB.time(now())).run()
                return config.revision
            }
            let r = noStore(try FormAdmin.json(.ok, ResultBody(id: id.uuidString.lowercased(), status: "updated", revision: revision))); r.headers.replaceOrAdd(name: .eTag, value: "\"\(revision)\""); return r
        }
    }
}
