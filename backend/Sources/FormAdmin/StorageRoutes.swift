// SPDX-License-Identifier: AGPL-3.0-only
import CoreFoundation
import Fluent
import FormAuth
import FormPersistence
import FormStorage
import Foundation
import SQLKit
import Vapor

enum StorageRoutes {
    static func register(root: RoutesBuilder, tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, storage: StorageService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        // Pass the scoped resource lookup into authorization, as in PrivacyRoutes/MailRoutes.
        func policyExists(_ sql: SQLDatabase, customer: UUID, form: UUID?) async throws -> Bool {
            if let form {
                return try await FormAdmin.CountRow.count(sql, "SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.id = \(bind: DB.bin(form)) AND f.customer_id = \(bind: DB.bin(customer)) AND c.state = 'active'") == 1
            }
            return try await FormAdmin.CountRow.count(sql, "SELECT COUNT(*) AS c FROM customers WHERE id = \(bind: DB.bin(customer)) AND state = 'active'") == 1
        }
        func connectionExists(customer: UUID, connection: UUID) async throws -> Bool {
            try await FormAdmin.CountRow.count(sql, "SELECT COUNT(*) AS c FROM customer_connections cc JOIN connections c ON c.id = cc.connection_id JOIN customers t ON t.id = cc.customer_id WHERE cc.customer_id = \(bind: DB.bin(customer)) AND cc.connection_id = \(bind: DB.bin(connection)) AND t.state = 'active' AND c.enabled = 1 AND c.kind IN ('s3','sftp')") == 1
        }
        // Synthetic probes use a unique key and always attempt cleanup, including after a failed PUT response.
        tenants.post("connections", ":connectionId", "probe") { req async throws -> Response in
            let session = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let account = session.accountID!, customer = try FormAdmin.uuidParam(req, "tenantId"), connection = try FormAdmin.uuidParam(req, "connectionId")
            try await perms.authorize(account: account, "system.manage", on: .system, exists: try await connectionExists(customer: customer, connection: connection))
            try await guardian.requireFreshAuthentication(session, now: now())
            try await guardian.throttles.consume(.adminRoute, "storageprobe|\(account)", limit: 10, window: 60)
            let adapter = try await storage.store(customer: customer, connection: connection, sql: sql).1
            let key = customer.uuidString.lowercased() + "/probe-" + UUID().uuidString.lowercased()
            let value = Data("FormBackend verschlüsselte Speicherprobe".utf8)
            // Probe bytes contain no content or credentials. A failed cleanup is reported, never a false success.
            var ok = false
            do { try await adapter.put(key, data: value); let read = try await adapter.get(key); let size = try await adapter.head(key); ok = read == value && size == value.count }
            catch { ok = false }
            var cleaned = true
            do { try await adapter.delete(key) } catch { cleaned = false }
            try await MailRoutes.audit(sql, actor: account, action: ok && cleaned ? "storage.probe.ok" : "storage.probe.failed", subject: connection, at: DB.time(now()), customer: customer)
            return try MailRoutes.anyJSON(["ok": ok && cleaned, "cleanupConfirmed": cleaned])
        }
        for formScoped in [false, true] {
            let path: [PathComponent] = formScoped ? ["forms", ":formId", "storage"] : ["storage"]
            tenants.on(.GET, path) { req async throws -> Response in
                let session = try await guardian.requireAuthenticated(req, mutation: false)
                try await guardian.budget(req)
                let customer = try FormAdmin.uuidParam(req, "tenantId")
                let form = formScoped ? try FormAdmin.uuidParam(req, "formId") : nil
                try await perms.authorize(account: session.accountID!, "system.manage", on: .system, exists: try await policyExists(sql, customer: customer, form: form))
                let value = try await storage.policy(customer: customer, form: form, sql: sql)
                let response = try FormAdmin.json(.ok, value)
                response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return response
            }
            tenants.on(.PUT, path) { req async throws -> Response in
                let session = try await guardian.requireAuthenticated(req, mutation: true)
                try await guardian.budget(req)
                let account = session.accountID!, customer = try FormAdmin.uuidParam(req, "tenantId")
                let form = formScoped ? try FormAdmin.uuidParam(req, "formId") : nil
                // Same system-level right as connection assignment. Rights are rechecked in the mutation transaction.
                try await perms.authorize(account: account, "system.manage", on: .system, exists: try await policyExists(sql, customer: customer, form: form))
                try await guardian.requireFreshAuthentication(session, now: now())
                let body = try MailRoutes.jsonObject(req, allowed: ["connectionId", "data", "attachmentThreshold"])
                let connection: UUID?
                if body["connectionId"] == nil || body["connectionId"] is NSNull { connection = nil }
                else { guard let text = body["connectionId"] as? String, let id = MailRoutes.lowerUUID(text) else { throw ValidationFailed(detail: "connectionId") }; connection = id }
                guard let data = body["data"] as? Bool else { throw ValidationFailed(detail: "data") }
                var threshold: Int?
                if let value = body["attachmentThreshold"], !(value is NSNull) {
                    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.rounded() == n.doubleValue, (0...64*1024*1024).contains(n.intValue) else { throw ValidationFailed(detail: "attachmentThreshold") }
                    threshold = n.intValue
                }
                guard connection != nil || (!data && threshold == nil) else { throw ValidationFailed(detail: "connectionId fehlt") }
                let policy = StorageService.Policy(connectionId: connection, data: data, attachmentThreshold: threshold)
                let encoded = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    try await PermissionService(sql: tx).authorize(account: account, "system.manage", on: .system, exists: try await policyExists(tx, customer: customer, form: form))
                    guard try await FormAdmin.CountRow.count(tx, "SELECT COUNT(*) AS c FROM customers WHERE id = \(bind: DB.bin(customer)) AND state = 'active' FOR UPDATE") == 1 else { throw Abort(.notFound) }
                    if let form { guard try await FormAdmin.CountRow.count(tx, "SELECT COUNT(*) AS c FROM forms WHERE id = \(bind: DB.bin(form)) AND customer_id = \(bind: DB.bin(customer))") == 1 else { throw Abort(.notFound) } }
                    if let connection { _ = try await storage.store(customer: customer, connection: connection, sql: tx) }
                    let scope = form.map { "form:\($0.uuidString.lowercased())" } ?? "customer:\(customer.uuidString.lowercased())"
                    try await tx.raw("INSERT INTO settings (scope_key, setting_key, safe_value_json, manageable, modified_at) VALUES (\(bind: scope), 'storage.policy', \(bind: encoded), 1, \(bind: DB.time(now()))) ON DUPLICATE KEY UPDATE safe_value_json = VALUES(safe_value_json), modified_at = VALUES(modified_at)").run()
                    try await MailRoutes.audit(tx, actor: account, action: "storage.policy.set", subject: form ?? customer, at: DB.time(now()), customer: customer, form: form)
                }
                return Response(status: .noContent)
            }
        }
    }
}
