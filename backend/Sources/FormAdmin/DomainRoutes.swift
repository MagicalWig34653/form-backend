// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Manually confirmed host assignments. All writers serialize the two hostname namespaces with one DB lock.
enum DomainRoutes {
    struct Input: Decodable {
        let hostname: String, tenantId: UUID, formId: UUID, viewId: UUID
        let releaseId: UUID?
        let mode: String
        let enabled: Bool
        let confirm: Bool
    }
    struct Item: Codable {
        let id: String, tenantId: String, formId: String, hostname: String, viewId: String?
        let releaseId: String?
        let mode: String
        let enabled: Bool
        let revision: UInt64
    }
    struct Row: Decodable {
        let id: Blob, customer_id: Blob, form_id: Blob, host_ascii: String
        let release_id: Blob?, view_id: Blob?
        let environment: String
        let enabled: Int
        let revision: UInt64
        var item: Item { Item(id: lower(id), tenantId: lower(customer_id), formId: lower(form_id), hostname: host_ascii,
                             viewId: view_id.map(lower), releaseId: release_id.map(lower), mode: environment == "test" ? "testing" : "production", enabled: enabled == 1, revision: revision) }
    }
    struct Binding: Codable { let formId: UUID; let releaseId: UUID?; let expectedBindingRevision: UInt64 }
    struct APIInput: Codable {
        let hostname: String, formIds: [UUID], enabled: Bool, expectedRevision: UInt64
        let releaseBindings: [Binding]?
        let confirm: Bool?
    }
    struct APIResult: Encodable { let id: String; let revision: UInt64 }
    static func lower(_ b: Blob) -> String { DB.uuid(b.data)!.uuidString.lowercased() }

    /// Accept already converted IDNA A-labels only: no implicit platform-dependent Unicode mapping.
    static func host(_ raw: String, adminHost: String) throws -> String {
        let h = raw.lowercased(), labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard raw.utf8.count == raw.count, (1...253).contains(h.utf8.count), labels.count >= 2,
              h != adminHost.lowercased(), !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw ValidationFailed(detail: "Ungültiger Hostname (ASCII/IDNA-A-Label ohne Port erforderlich; Adminhost ausgeschlossen)") }
        return h
    }
    private struct LockResult: Decodable { let l: Int? }
    static func serialize<T>(sql: SQLDatabase, _ body: @escaping () async throws -> T) async throws -> T {
        return try await sql.withSession { session in
            guard try await session.raw("SELECT GET_LOCK('form_domain_namespace', 5) AS l").first(decoding: LockResult.self)?.l == 1 else { throw Abort(.conflict) }
            do { let result = try await body(); try await session.raw("DO RELEASE_LOCK('form_domain_namespace')").run(); return result }
            catch { try? await session.raw("DO RELEASE_LOCK('form_domain_namespace')").run(); throw error }
        }
    }
    static func formExists(_ sql: SQLDatabase, tenant: UUID, form: UUID) async throws -> Bool {
        try await sql.raw("SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id=f.customer_id WHERE f.id=\(bind: DB.bin(form)) AND f.customer_id=\(bind: DB.bin(tenant)) AND c.state='active'").first(decoding: FormAdmin.CountRow.self)?.c == 1
    }
    static func validateTarget(_ sql: SQLDatabase, input: Input) async throws {
        guard ["testing", "production"].contains(input.mode), input.confirm, !input.enabled || input.releaseId != nil else { throw ValidationFailed(detail: "Bestätigung oder Release fehlt") }
        if let release = input.releaseId {
            guard try await sql.raw("SELECT COUNT(*) AS c FROM release_views v JOIN releases r ON r.id=v.release_id AND r.customer_id=v.customer_id AND r.form_id=v.form_id WHERE v.customer_id=\(bind: DB.bin(input.tenantId)) AND v.form_id=\(bind: DB.bin(input.formId)) AND v.release_id=\(bind: DB.bin(release)) AND v.view_id=\(bind: DB.bin(input.viewId))").first(decoding: FormAdmin.CountRow.self)?.c == 1 else { throw ValidationFailed(detail: "Release/Ansicht gehört nicht zum Formular") }
        } else {
            guard try await sql.raw("SELECT COUNT(*) AS c FROM view_versions WHERE customer_id=\(bind: DB.bin(input.tenantId)) AND form_id=\(bind: DB.bin(input.formId)) AND view_id=\(bind: DB.bin(input.viewId))").first(decoding: FormAdmin.CountRow.self)?.c ?? 0 > 0 else { throw ValidationFailed(detail: "Ansicht gehört nicht zum Formular") }
        }
    }
    static func noStore(_ response: Response) -> Response { response.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return response }

    static func register(root: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase, adminHost = URLComponents(string: guardian.config.adminOrigin)!.host!
        let allowed: Set<String> = ["hostname", "tenantId", "formId", "viewId", "releaseId", "mode", "enabled", "confirm"]
        root.get("domains") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false); try await guardian.budget(req)
            guard let raw: String = req.query["tenantId"], let tenant = UUID(uuidString: raw) else { throw Abort(.badRequest) }
            try await perms.authorize(account: s.accountID!, "domain.manage", on: .customer(tenant))
            let rows = try await sql.raw("SELECT * FROM domain_bindings WHERE customer_id=\(bind: DB.bin(tenant)) ORDER BY id LIMIT 100").all(decoding: Row.self)
            struct List: Encodable { let items: [Item] }
            return noStore(try FormAdmin.json(.ok, List(items: rows.map(\.item))))
        }
        root.post("domains") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true); try await guardian.budget(req)
            let b: Input = try FormAdmin.decodeStrict(req, allowed: allowed)
            let hostname = try host(b.hostname, adminHost: adminHost), account = s.accountID!, id = UUID()
            try await perms.authorize(account: account, "domain.manage", on: .customer(b.tenantId), exists: try await formExists(sql, tenant: b.tenantId, form: b.formId))
            try await guardian.requireFreshAuthentication(s, now: now())
            guard b.mode == "testing", !b.enabled else { throw ValidationFailed(detail: "Neue Domain muss inaktiv/testing sein") }
            try await serialize(sql: sql) {
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    try await PermissionService(sql: tx).authorize(account: account, "domain.manage", on: .customer(b.tenantId))
                    try await validateTarget(tx, input: b)
                    try await available(tx, hostname: hostname)
                    let aid = UUID(), time = DB.time(now())
                    try await ReleaseRoutes.audit(tx, tenant: b.tenantId, form: b.formId, actor: account, action: "domain.create", subject: id, at: time, id: aid, category: "domain").run()
                    try await confirmationDetails(tx, audit: aid, input: b, hostname: hostname, revision: 1)
                    try await tx.raw("""
                        INSERT INTO domain_bindings (id,customer_id,form_id,host_ascii,environment,release_id,view_id,enabled,revision,changed_by,changed_at,confirmation_audit_id)
                        VALUES (\(bind: DB.bin(id)),\(bind: DB.bin(b.tenantId)),\(bind: DB.bin(b.formId)),\(bind: hostname),'test',\(bind: b.releaseId.map(DB.bin)),\(bind: DB.bin(b.viewId)),0,1,\(bind: DB.bin(account)),\(bind: time),\(bind: DB.bin(aid)))
                        """).run()
                }
            }
            return noStore(try FormAdmin.json(.created, APIResult(id: id.uuidString.lowercased(), revision: 1)))
        }
        root.patch("domains", ":domainId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true); try await guardian.budget(req)
            let id = try FormAdmin.uuidParam(req, "domainId"), account = s.accountID!
            guard let old = try await sql.raw("SELECT * FROM domain_bindings WHERE id=\(bind: DB.bin(id))").first(decoding: Row.self) else { throw Abort(.notFound) }
            let tenant = DB.uuid(old.customer_id.data)!
            try await perms.authorize(account: account, "domain.manage", on: .customer(tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            guard let match = req.headers.first(name: .ifMatch) else { throw Abort(.preconditionRequired) }
            guard let expected = DraftRoutes.parseETag(match) else { throw Abort(.preconditionFailed) }
            let b: Input = try FormAdmin.decodeStrict(req, allowed: allowed)
            guard b.tenantId == tenant, b.formId == DB.uuid(old.form_id.data)! else { throw ValidationFailed(detail: "Formular/Kunde einer Bindung sind unveränderlich; alte Bindung zuerst löschen") }
            let hostname = try host(b.hostname, adminHost: adminHost)
            try await serialize(sql: sql) {
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    guard let locked = try await tx.raw("SELECT * FROM domain_bindings WHERE id=\(bind: DB.bin(id)) FOR UPDATE").first(decoding: Row.self), locked.revision == expected else { throw Abort(.preconditionFailed) }
                    try await PermissionService(sql: tx).authorize(account: account, "domain.manage", on: .customer(tenant))
                    try await validateTarget(tx, input: b)
                    try await available(tx, hostname: hostname, excluding: id)
                    let aid = UUID(), time = DB.time(now())
                    try await ReleaseRoutes.audit(tx, tenant: tenant, form: b.formId, actor: account, action: "domain.update", subject: id, at: time, id: aid, category: "domain").run()
                    try await confirmationDetails(tx, audit: aid, input: b, hostname: hostname, revision: expected + 1)
                    try await tx.raw("UPDATE domain_bindings SET host_ascii=\(bind: hostname),environment=\(bind: b.mode == "testing" ? "test" : "production"),release_id=\(bind: b.releaseId.map(DB.bin)),view_id=\(bind: DB.bin(b.viewId)),enabled=\(bind: b.enabled ? 1 : 0),revision=revision+1,changed_by=\(bind: DB.bin(account)),changed_at=\(bind: time),confirmation_audit_id=\(bind: DB.bin(aid)) WHERE id=\(bind: DB.bin(id))").run()
                }
            }
            return noStore(try FormAdmin.json(.ok, APIResult(id: id.uuidString.lowercased(), revision: expected + 1)))
        }
        root.delete("domains", ":domainId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true); try await guardian.budget(req)
            let id = try FormAdmin.uuidParam(req, "domainId"), account = s.accountID!
            guard let row = try await sql.raw("SELECT * FROM domain_bindings WHERE id=\(bind: DB.bin(id))").first(decoding: Row.self) else { throw Abort(.notFound) }
            let tenant = DB.uuid(row.customer_id.data)!, form = DB.uuid(row.form_id.data)!
            try await perms.authorize(account: account, "domain.manage", on: .customer(tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            struct B: Decodable { let confirm: Bool }
            let b: B = try FormAdmin.decodeStrict(req, allowed: ["confirm"])
            guard b.confirm else { throw ValidationFailed(detail: "Bestätigung fehlt") }
            guard let match = req.headers.first(name: .ifMatch) else { throw Abort(.preconditionRequired) }
            guard let expected = DraftRoutes.parseETag(match) else { throw Abort(.preconditionFailed) }
            try await serialize(sql: sql) {
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    guard let locked = try await tx.raw("SELECT * FROM domain_bindings WHERE id=\(bind: DB.bin(id)) FOR UPDATE").first(decoding: Row.self), locked.revision == expected else { throw Abort(.preconditionFailed) }
                    try await PermissionService(sql: tx).authorize(account: account, "domain.manage", on: .customer(tenant))
                    guard locked.enabled == 0 else { throw Abort(.conflict) }
                    try await tx.raw("DELETE FROM domain_bindings WHERE id=\(bind: DB.bin(id))").run()
                    try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: account, action: "domain.delete", subject: id, at: DB.time(now()), category: "domain").run()
                }
            }
            return noStore(Response(status: .noContent))
        }
        registerAPI(root: root, guardian: guardian, db: db, perms: perms, now: now, adminHost: adminHost)
    }
    static func confirmationDetails(_ tx: SQLDatabase, audit: UUID, input: Input, hostname: String, revision: UInt64) async throws {
        try await tx.raw("UPDATE audit_events SET safe_details_json=JSON_OBJECT('hostname',\(bind: hostname),'releaseId',\(bind: input.releaseId?.uuidString.lowercased()),'viewId',\(bind: input.viewId.uuidString.lowercased()),'revision',\(bind: revision),'mode',\(bind: input.mode),'enabled',\(bind: input.enabled ? 1 : 0)) WHERE id=\(bind: DB.bin(audit))").run()
    }
    static func available(_ tx: SQLDatabase, hostname: String, excluding: UUID? = nil) async throws {
        let a = try await tx.raw("SELECT COUNT(*) AS c FROM api_hosts WHERE host_ascii=\(bind: hostname)").first(decoding: FormAdmin.CountRow.self)?.c ?? 0
        let d = try await tx.raw("SELECT COUNT(*) AS c FROM domain_bindings WHERE host_ascii=\(bind: hostname) AND id<>\(bind: DB.bin(excluding ?? UUID()))").first(decoding: FormAdmin.CountRow.self)?.c ?? 0
        guard a == 0, d == 0 else { throw Abort(.conflict) }
    }
    static func registerAPI(root: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, now: @escaping @Sendable () -> Date, adminHost: String) {
        let sql = db as! SQLDatabase
        root.get("api-hosts") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false); try await guardian.budget(req)
            guard let raw: String = req.query["tenantId"], let tenant = UUID(uuidString: raw) else { throw Abort(.badRequest) }
            try await perms.authorize(account: s.accountID!, "domain.manage", on: .customer(tenant))
            struct R: Decodable { let id: Blob; let host_ascii: String; let enabled: Int; let revision: UInt64; let form_id: Blob; let release_id: Blob?; let binding_revision: UInt64 }
            struct I: Encodable { let id: String; let hostname: String; let enabled: Bool; let revision: UInt64; let formId: String; let releaseId: String?; let bindingRevision: UInt64 }
            struct L: Encodable { let items: [I] }
            let rows = try await sql.raw("SELECT h.id,h.host_ascii,h.enabled,h.revision,f.form_id,f.release_id,f.binding_revision FROM api_hosts h JOIN api_host_forms f ON f.api_host_id=h.id WHERE f.customer_id=\(bind: DB.bin(tenant)) ORDER BY h.id,f.form_id LIMIT 100").all(decoding: R.self)
            return noStore(try FormAdmin.json(.ok, L(items: rows.map { I(id: lower($0.id), hostname: $0.host_ascii, enabled: $0.enabled == 1, revision: $0.revision, formId: lower($0.form_id), releaseId: $0.release_id.map(lower), bindingRevision: $0.binding_revision) })))
        }
        root.post("api-hosts") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true); try await guardian.budget(req)
            guard let raw: String = req.query["tenantId"], let tenant = UUID(uuidString: raw) else { throw Abort(.badRequest) }
            let account = s.accountID!
            try await perms.authorize(account: account, "domain.manage", on: .customer(tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let b: APIInput = try FormAdmin.decodeStrict(req, allowed: ["hostname", "formIds", "enabled", "expectedRevision", "releaseBindings", "confirm"])
            let hostname = try host(b.hostname, adminHost: adminHost)
            guard b.confirm == true, (1...100).contains(b.formIds.count), Set(b.formIds).count == b.formIds.count else { throw ValidationFailed(detail: "Formularliste/Bestätigung ungültig") }
            let bindings = b.releaseBindings ?? []
            guard Set(bindings.map(\.formId)).count == bindings.count, bindings.allSatisfy({ b.formIds.contains($0.formId) }) else { throw ValidationFailed(detail: "Releasebindungen müssen zur Formularliste gehören") }
            let result: APIResult = try await serialize(sql: sql) {
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    struct H: Decodable { let id: Blob; let enabled: Int; let revision: UInt64 }
                    let old = try await tx.raw("SELECT id,enabled,revision FROM api_hosts WHERE host_ascii=\(bind: hostname) FOR UPDATE").first(decoding: H.self)
                    guard (old?.revision ?? 0) == b.expectedRevision else { throw Abort(.preconditionFailed) }
                    try await PermissionService(sql: tx).authorize(account: account, "domain.manage", on: .customer(tenant))
                    for form in b.formIds {
                        guard try await formExists(tx, tenant: tenant, form: form) else { throw ValidationFailed(detail: "Formular gehört nicht zum Kunden") }
                    }
                    let id = old.flatMap { DB.uuid($0.id.data) } ?? UUID()
                    if let old {
                        // A customer can append its own forms; it cannot disable a host used by another customer.
                        if (old.enabled == 1) != b.enabled {
                            let foreign = try await tx.raw("SELECT COUNT(*) AS c FROM api_host_forms WHERE api_host_id=\(bind: DB.bin(id)) AND customer_id<>\(bind: DB.bin(tenant))").first(decoding: FormAdmin.CountRow.self)?.c ?? 0
                            guard foreign == 0 else { throw Abort(.forbidden) }
                        }
                        try await tx.raw("UPDATE api_hosts SET enabled=\(bind: b.enabled ? 1 : 0),revision=revision+1 WHERE id=\(bind: DB.bin(id))").run()
                    } else {
                        try await available(tx, hostname: hostname)
                        guard !b.enabled, bindings.isEmpty else { throw ValidationFailed(detail: "Neuer API-Host muss inaktiv und ungebunden sein") }
                        try await tx.raw("INSERT INTO api_hosts (id,host_ascii,enabled,revision) VALUES (\(bind: DB.bin(id)),\(bind: hostname),0,1)").run()
                    }
                    let aid = UUID(), time = DB.time(now())
                    try await ReleaseRoutes.audit(tx, tenant: tenant, form: nil, actor: account, action: "domain.api.configure", subject: id, at: time, id: aid, category: "domain").run()
                    let details = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
                    try await tx.raw("UPDATE audit_events SET safe_details_json=\(bind: details) WHERE id=\(bind: DB.bin(aid))").run()
                    for form in b.formIds {
                        struct F: Decodable { let binding_revision: UInt64 }
                        let row = try await tx.raw("SELECT binding_revision FROM api_host_forms WHERE api_host_id=\(bind: DB.bin(id)) AND customer_id=\(bind: DB.bin(tenant)) AND form_id=\(bind: DB.bin(form)) FOR UPDATE").first(decoding: F.self)
                        let binding = bindings.first { $0.formId == form }
                        if let binding {
                            guard binding.expectedBindingRevision == (row?.binding_revision ?? 0) else { throw Abort(.preconditionFailed) }
                            if let release = binding.releaseId {
                                guard try await tx.raw("SELECT COUNT(*) AS c FROM releases WHERE id=\(bind: DB.bin(release)) AND customer_id=\(bind: DB.bin(tenant)) AND form_id=\(bind: DB.bin(form))").first(decoding: FormAdmin.CountRow.self)?.c == 1 else { throw ValidationFailed(detail: "Release gehört nicht zum Formular") }
                            }
                        }
                        if row == nil {
                            // Host revision never resets and advances on removal, so recreated bindings cannot reuse an old ETag.
                            try await tx.raw("INSERT INTO api_host_forms (api_host_id,customer_id,form_id,release_id,binding_revision,changed_by,changed_at,confirmation_audit_id) VALUES (\(bind: DB.bin(id)),\(bind: DB.bin(tenant)),\(bind: DB.bin(form)),\(bind: binding?.releaseId.map(DB.bin)),\(bind: (old?.revision ?? 0) + 1),\(bind: DB.bin(account)),\(bind: time),\(bind: DB.bin(aid)))").run()
                        } else if let binding {
                            try await tx.raw("UPDATE api_host_forms SET release_id=\(bind: binding.releaseId.map(DB.bin)),binding_revision=binding_revision+1,changed_by=\(bind: DB.bin(account)),changed_at=\(bind: time),confirmation_audit_id=\(bind: DB.bin(aid)) WHERE api_host_id=\(bind: DB.bin(id)) AND customer_id=\(bind: DB.bin(tenant)) AND form_id=\(bind: DB.bin(form))").run()
                        }
                    }
                    return APIResult(id: id.uuidString.lowercased(), revision: (old?.revision ?? 0) + 1)
                }
            }
            return noStore(try FormAdmin.json(.ok, result))
        }
        // Removing a customer's allowlist entry never changes any other customer's rows or global host state.
        root.delete("api-hosts", ":hostId", "forms", ":formId") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true); try await guardian.budget(req)
            let id = try FormAdmin.uuidParam(req, "hostId"), form = try FormAdmin.uuidParam(req, "formId"), account = s.accountID!
            struct R: Decodable { let customer_id: Blob; let binding_revision: UInt64 }
            guard let row = try await sql.raw("SELECT customer_id,binding_revision FROM api_host_forms WHERE api_host_id=\(bind: DB.bin(id)) AND form_id=\(bind: DB.bin(form))").first(decoding: R.self) else { throw Abort(.notFound) }
            let tenant = DB.uuid(row.customer_id.data)!
            try await perms.authorize(account: account, "domain.manage", on: .customer(tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            struct B: Decodable { let confirm: Bool }
            let b: B = try FormAdmin.decodeStrict(req, allowed: ["confirm"])
            guard b.confirm else { throw ValidationFailed(detail: "Bestätigung fehlt") }
            guard let match = req.headers.first(name: .ifMatch) else { throw Abort(.preconditionRequired) }
            guard let expected = DraftRoutes.parseETag(match) else { throw Abort(.preconditionFailed) }
            try await serialize(sql: sql) {
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    guard let locked = try await tx.raw("SELECT customer_id,binding_revision FROM api_host_forms WHERE api_host_id=\(bind: DB.bin(id)) AND form_id=\(bind: DB.bin(form)) FOR UPDATE").first(decoding: R.self), locked.binding_revision == expected else { throw Abort(.preconditionFailed) }
                    try await PermissionService(sql: tx).authorize(account: account, "domain.manage", on: .customer(tenant))
                    try await tx.raw("DELETE FROM api_host_forms WHERE api_host_id=\(bind: DB.bin(id)) AND form_id=\(bind: DB.bin(form)) AND customer_id=\(bind: DB.bin(tenant))").run()
                    try await tx.raw("UPDATE api_hosts SET revision=revision+1 WHERE id=\(bind: DB.bin(id))").run()
                    try await ReleaseRoutes.audit(tx, tenant: tenant, form: form, actor: account, action: "domain.api.remove", subject: id, at: DB.time(now()), category: "domain").run()
                }
            }
            return noStore(Response(status: .noContent))
        }
    }
}
