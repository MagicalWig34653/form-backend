// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormCore
import FormMail
import FormPersistence
import FormWebhooks
import Foundation
import SQLKit
import Vapor

/// Webhook administration shares the customer-level key management permission (ADR 0013).
/// Signing keys are returned once on creation and subsequently accessible only through SecretStore.
enum WebhookRoutes {
    struct Create: Decodable { let targetURL: String; let active: Bool? }
    struct Toggle: Decodable { let active: Bool }
    struct Item: Encodable {
        let id: String, targetURL: String, publicKey: String, createdAt: String
        let active: Bool
        let privateKey: String?
    }
    struct List: Encodable { let items: [Item] }
    struct Row: Decodable {
        let id: Blob; let target_url: String; let public_key: Blob; let active: Int; let created_at: Date
    }

    static func validateTarget(_ url: String, resolver: BoundedDNSResolver = .shared) async throws {
        do { _ = try await WebhookTarget.validate(url, resolver: resolver) }
        catch HostGuard.Failure.timeout { throw ValidationFailed(detail: "DNS-Auflösung des Webhook-Ziels hat das Zeitlimit überschritten") }
        catch { throw ValidationFailed(detail: "Webhook-Ziel muss eine öffentliche HTTPS-Adresse sein") }
    }

    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService,
                         secrets: SecretStore, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase
        func noStore(_ res: Response) -> Response {
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
        func exists(_ tenant: UUID, _ form: UUID) async throws -> Bool {
            try await FormAdmin.CountRow.count(sql, "SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.customer_id = \(bind: DB.bin(tenant)) AND f.id = \(bind: DB.bin(form)) AND c.state = 'active'") == 1
        }
        func authorize(_ req: Request, mutation: Bool) async throws -> (UUID, UUID, UUID) {
            let s = try await guardian.requireAuthenticated(req, mutation: mutation)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            try await perms.authorize(account: s.accountID!, "key.manage", on: .customer(tenant), exists: try await exists(tenant, form))
            try await guardian.requireFreshAuthentication(s, now: now())
            return (tenant, form, s.accountID!)
        }

        tenants.get("forms", ":formId", "webhooks") { req async throws -> Response in
            let (tenant, form, actor) = try await authorize(req, mutation: false)
            let rows = try await sql.raw("SELECT id, target_url, public_key, active, created_at FROM webhook_endpoints WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) ORDER BY created_at, id").all(decoding: Row.self)
            try await ReleaseRoutes.audit(sql, tenant: tenant, form: form, actor: actor, action: "webhook.list", subject: form, at: DB.time(now()), category: "webhook").run()
            return noStore(try FormAdmin.json(.ok, List(items: rows.map {
                Item(id: DB.uuid($0.id.data)!.uuidString.lowercased(), targetURL: $0.target_url, publicKey: $0.public_key.data.base64EncodedString(),
                     createdAt: ReleaseRoutes.iso($0.created_at), active: $0.active == 1, privateKey: nil)
            })))
        }

        tenants.post("forms", ":formId", "webhooks") { req async throws -> Response in
            let (tenant, form, actor) = try await authorize(req, mutation: true)
            let input: Create = try FormAdmin.decodeStrict(req, allowed: ["targetURL", "active"])
            try await validateTarget(input.targetURL)
            let key = Curve25519.Signing.PrivateKey(), id = UUID(), at = now()
            let active = input.active ?? true
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: actor, "key.manage", on: .customer(tenant))
                try await WebhookLimits.lockCustomer(tx, customer: DB.bin(tenant))
                if active { try await WebhookLimits.current(tx).checkActivation(tx, customer: DB.bin(tenant), form: DB.bin(form), excluding: DB.bin(id)) }
                let ref = try await secrets.put(key.rawRepresentation, on: tx)
                try await tx.raw("""
                    INSERT INTO webhook_endpoints (id, customer_id, form_id, target_url, signing_secret_ref, public_key, active, created_by, created_at)
                    VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: input.targetURL), \(bind: ref),
                      \(bind: Blob(key.publicKey.rawRepresentation)), \(literal: active ? 1 : 0), \(bind: DB.bin(actor)), \(bind: DB.time(at)))
                    """).run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: actor, action: "webhook.create", subject: id, at: DB.time(at), category: "webhook").run()
            }
            return noStore(try FormAdmin.json(.created, Item(id: id.uuidString.lowercased(), targetURL: input.targetURL,
                publicKey: key.publicKey.rawRepresentation.base64EncodedString(), createdAt: ReleaseRoutes.iso(at), active: active,
                privateKey: key.rawRepresentation.base64EncodedString())))
        }

        tenants.put("forms", ":formId", "webhooks", ":webhookId") { req async throws -> Response in
            let (tenant, form, actor) = try await authorize(req, mutation: true)
            let id = try FormAdmin.uuidParam(req, "webhookId")
            let input: Toggle = try FormAdmin.decodeStrict(req, allowed: ["active"])
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: actor, "key.manage", on: .customer(tenant))
                try await WebhookLimits.lockCustomer(tx, customer: DB.bin(tenant))
                if input.active { try await WebhookLimits.current(tx).checkActivation(tx, customer: DB.bin(tenant), form: DB.bin(form), excluding: DB.bin(id)) }
                guard try await tx.raw("SELECT id, target_url, public_key, active, created_at FROM webhook_endpoints WHERE id = \(bind: DB.bin(id)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) FOR UPDATE").first(decoding: Row.self) != nil else { throw Abort(.notFound) }
                try await tx.raw("UPDATE webhook_endpoints SET active = \(literal: input.active ? 1 : 0) WHERE id = \(bind: DB.bin(id)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: actor, action: input.active ? "webhook.enable" : "webhook.disable", subject: id, at: DB.time(now()), category: "webhook").run()
            }
            return noStore(Response(status: .noContent))
        }

        tenants.delete("forms", ":formId", "webhooks", ":webhookId") { req async throws -> Response in
            let (tenant, form, actor) = try await authorize(req, mutation: true)
            let id = try FormAdmin.uuidParam(req, "webhookId")
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await PermissionService(sql: tx).authorize(account: actor, "key.manage", on: .customer(tenant))
                try await WebhookLimits.lockCustomer(tx, customer: DB.bin(tenant))
                struct Secret: Decodable { let signing_secret_ref: String }
                guard let endpoint = try await tx.raw("SELECT signing_secret_ref FROM webhook_endpoints WHERE id = \(bind: DB.bin(id)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) FOR UPDATE").first(decoding: Secret.self) else { throw Abort(.notFound) }
                try await tx.raw("DELETE FROM webhook_outbox WHERE webhook_id = \(bind: DB.bin(id)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").run()
                try await tx.raw("DELETE FROM webhook_endpoints WHERE id = \(bind: DB.bin(id)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").run()
                try await tx.raw("DELETE FROM managed_secrets WHERE ref = \(bind: endpoint.signing_secret_ref)").run()
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: actor, action: "webhook.delete", subject: id, at: DB.time(now()), category: "webhook").run()
            }
            return noStore(Response(status: .noContent))
        }
    }
}
