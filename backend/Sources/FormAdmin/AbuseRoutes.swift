// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Form-owned credentials: callers cannot select another form's SecretStore reference.
enum AbuseRoutes {
    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, secrets: SecretStore, now: @escaping @Sendable () -> Date) {
        for method in [HTTPMethod.GET, .PUT] {
            tenants.on(method, "forms", ":formId", "abuse-secret", body: .collect(maxSize: "1kb")) { req async throws -> Response in
                let session = try await guardian.requireAuthenticated(req, mutation: method == .PUT)
                try await guardian.budget(req)
                try await guardian.requireFreshAuthentication(session, now: now())
                let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
                let configured = try await db.transaction { conn -> Bool in
                    let sql = conn as! SQLDatabase
                    let exists = try await sql.raw("SELECT COUNT(*) AS c FROM forms WHERE customer_id=\(bind: DB.bin(tenant)) AND id=\(bind: DB.bin(form))").first(decoding: FormAdmin.CountRow.self)?.c == 1
                    try await PermissionService(sql: sql).authorize(account: session.accountID!, "draft.write", on: .form(customer: tenant, form: form), exists: exists)
                    if method == .PUT {
                        struct Input: Decodable { let secret: String }
                        let input: Input = try FormAdmin.decodeStrict(req, allowed: ["secret"])
                        guard (1...200).contains(input.secret.utf8.count), input.secret.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw Abort(.unprocessableEntity) }
                        struct Locked: Decodable { let id: Blob }
                        _ = try await sql.raw("SELECT id FROM forms WHERE customer_id=\(bind: DB.bin(tenant)) AND id=\(bind: DB.bin(form)) FOR UPDATE").first(decoding: Locked.self)
                        let ref = try await secrets.put(Data(input.secret.utf8), on: sql)
                        struct Old: Decodable { let secret_ref: String }
                        let old = try await sql.raw("SELECT secret_ref FROM form_abuse_secrets WHERE form_id=\(bind: DB.bin(form)) FOR UPDATE").first(decoding: Old.self)
                        try await sql.raw("INSERT INTO form_abuse_secrets (customer_id,form_id,secret_ref) VALUES (\(bind: DB.bin(tenant)),\(bind: DB.bin(form)),\(bind: ref)) ON DUPLICATE KEY UPDATE secret_ref=VALUES(secret_ref)").run()
                        if let old { try await sql.raw("DELETE FROM managed_secrets WHERE ref=\(bind: old.secret_ref)").run() }
                        try await ReleaseRoutes.audit(sql, tenant: tenant, form: form, actor: session.accountID!, action: "form.abuse.secret.update", subject: form, at: DB.time(now())).run()
                    }
                    return try await sql.raw("SELECT COUNT(*) AS c FROM form_abuse_secrets WHERE customer_id=\(bind: DB.bin(tenant)) AND form_id=\(bind: DB.bin(form))").first(decoding: FormAdmin.CountRow.self)?.c == 1
                }
                struct Status: Encodable { let configured: Bool }
                let response = try FormAdmin.json(.ok, Status(configured: configured))
                response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return response
            }
        }
    }
}
