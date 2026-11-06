// SPDX-License-Identifier: AGPL-3.0-only
import FormStorage
import FormAuth
import FormCore
import FormDeploy
import FormFlow
import FormMail
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Admin API, forms part (contracts/auth/admin-api.openapi.yaml, base /admin/api/v1): listForms, createForm, getForm.
/// Every operation: session (+CSRF/Origin for mutations) via `AuthGuard`, then ONE rights check via `PermissionService`
/// against the DB ownership chain; the path IDs are never a credential.
public enum FormAdmin {
    /// Public protocol surface; future OAuth metadata/token/registration routes are added here.
    public static func registerPublic(_ app: Application, guardian: AuthGuard, trustedProxies: [CIDR], adminResponder: any Responder,
                                      oauth: (Application) throws -> Void = { _ in }) throws {
        MCPRoutes.register(app, guardian: guardian, db: app.db(.mysql), adminResponder: adminResponder, now: { Date() })
        StatisticsCollector.register(app, guardian: guardian, trusted: trustedProxies, resolver: nil, now: { Date() })
        OAuthRoutes.registerPublic(app, guardian: guardian, db: app.db(.mysql), now: { Date() })
        try oauth(app)
    }

    @discardableResult
    public static func register(_ app: Application, guardian: AuthGuard, secrets: SecretStore, mailAllowedNets: [CIDR] = [], allowInsecure: Bool = false, mail: MailDispatcher? = nil, deploy: DeployService? = nil, sdkVersion: @escaping @Sendable () -> String? = { nil },
                                includePublicRoutes: Bool = true, statisticsTrustedProxies: [CIDR] = [], statisticsHostResolver: StatisticsCollector.HostResolver? = nil,
                                now: @escaping @Sendable () -> Date = { Date() }) -> RouteCollectionBox {
        let db = app.db(.mysql)
        let sql = db as! SQLDatabase
        let perms = PermissionService(sql: sql)
        let tenants = app.grouped("admin", "api", "v1", "tenants", ":tenantId")

        // listForms
        tenants.get("forms") { req async throws -> Response in
            let s = try await ConfigurationIdentity.require(req, guardian: guardian, db: db, mutation: false, now: now)
            if s.token == nil { try await guardian.budget(req) }
            let tenant = try uuidParam(req, "tenantId")
            let account = s.accountID!
            var grants = try await perms.grants(account: account)
            if let token = s.token {
                guard token.scopes.contains("konfiguration.lesen"), token.boundary.tenantId == tenant else { throw Abort(.forbidden) }
                grants = grants.filter { $0.permission == "form.read" }
                if let form = token.boundary.formId {
                    grants = grants.filter { $0.scope.covers(.form(customer: tenant, form: form)) }.map { Grant(permission: $0.permission, scope: .form(customer: tenant, form: form)) }
                }
            }
            // The tenant is visible if any grant covers it or one of its forms; otherwise it does not exist for this caller.
            guard grants.contains(where: { touches($0.scope, tenant: tenant) }) else { throw Abort(.notFound) }
            let readable = grants.filter { $0.permission == "form.read" }.map(\.scope)
            let limit = try limitParam(req)
            let after = try cursorParam(req)
            let rows = try await readableForms(sql, tenant: tenant, scopes: readable, after: after, limit: limit + 1)
            let page = rows.prefix(limit)
            let next = rows.count > limit ? page.last.map { cursor($0.id) } : nil
            return try json(.ok, FormListBody(items: page.map(FormItem.init), nextCursor: next))
        }

        // createForm
        tenants.post("forms") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try uuidParam(req, "tenantId")
            let input: FormInputBody = try decodeStrict(req, allowed: ["name"])
            let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 190, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Abort(.unprocessableEntity) }
            let account = s.accountID!
            let customerActive = try await sql.raw("SELECT COUNT(*) AS c FROM customers WHERE id = \(bind: DB.bin(tenant)) AND state = 'active'").first(decoding: CountRow.self)?.c == 1
            try await perms.authorize(account: account, "form.create", on: .customer(tenant), exists: customerActive)
            let id = UUID()
            let t = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await tx.raw("""
                    INSERT INTO forms (id, customer_id, name, active, created_at)
                    VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(tenant)), \(bind: name), 0, \(bind: t))
                    """).run()
                // Standard draft (ADR 0009 F2): the form can be reviewed and published right away.
                let doc = DraftStore.standardDocument(tenant: tenant, form: id, name: name)
                _ = try await DraftStore.insert(tx, tenant: tenant, form: id, account: account, document: doc, base: nil, now: t)
                try await tx.raw("""
                    INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
                    VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(id)), \(bind: DB.bin(account)), 'human', 'form', 'form.create',
                      \(bind: DB.bin(id)), \(bind: t), '{}')
                    """).run()
            }
            return try json(.created, ResultBody(id: id.uuidString.lowercased(), status: "created", revision: 1))
        }

        // setFormActive (FA-021): switches ingest on/off. Uses the existing `release.publish` right (no catalog change); no fresh login.
        tenants.put("forms", ":formId", "active") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try uuidParam(req, "tenantId"), form = try uuidParam(req, "formId")
            let account = s.accountID!
            let obj: ActiveInputBody = try decodeStrict(req, allowed: ["active"])
            let exists = try await sql.raw("SELECT COUNT(*) AS c FROM forms WHERE id = \(bind: DB.bin(form)) AND customer_id = \(bind: DB.bin(tenant))").first(decoding: CountRow.self)?.c == 1
            try await perms.authorize(account: account, "release.publish", on: .form(customer: tenant, form: form), exists: exists)
            let t = DB.time(now())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await tx.raw("UPDATE forms SET active = \(bind: obj.active ? 1 : 0) WHERE id = \(bind: DB.bin(form)) AND customer_id = \(bind: DB.bin(tenant))").run()
                try await tx.raw("""
                    INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
                    VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: DB.bin(account)), 'human', 'form',
                      \(bind: obj.active ? "form.activate" : "form.deactivate"), \(bind: DB.bin(form)), \(bind: t), '{}')
                    """).run()
            }
            return Response(status: .noContent)
        }

        // getForm: own projection (ADR 0009 G1) instead of the contract's `Reference`.
        tenants.get("forms", ":formId") { req async throws -> Response in
            let s = try await ConfigurationIdentity.require(req, guardian: guardian, db: db, mutation: false, now: now)
            if s.token == nil { try await guardian.budget(req) }
            let tenant = try uuidParam(req, "tenantId"), form = try uuidParam(req, "formId")
            let row = try await sql.raw("""
                SELECT f.id AS id, f.name AS name, f.active AS active, f.current_release_id AS current_release_id, r.release_version_no AS release_version_no
                FROM forms f LEFT JOIN releases r ON r.id = f.current_release_id
                WHERE f.id = \(bind: DB.bin(form)) AND f.customer_id = \(bind: DB.bin(tenant))
                """).first(decoding: ReferenceRow.self)
            try await s.authorize(perms, "form.read", on: .form(customer: tenant, form: form), exists: row != nil)
            struct MC: Decodable { let connection_id: Blob }
            let mailConnection = try await sql.raw("SELECT connection_id FROM form_connections WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND environment = 'production' AND purpose = 'mail'").first(decoding: MC.self)
            struct D: Decodable { let id: Blob }
            let drafts = try await sql.raw("SELECT id FROM form_drafts WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) ORDER BY created_at DESC, id LIMIT 20").all(decoding: D.self)
            let r = row!
            return try json(.ok, FormDetailBody(id: form.uuidString.lowercased(), name: r.name ?? "", active: r.active == 1,
                currentReleaseId: r.current_release_id.flatMap { DB.uuid($0.data) }?.uuidString.lowercased(),
                currentReleaseVersion: r.release_version_no.map(Int.init),
                draftIds: drafts.compactMap { DB.uuid($0.id.data)?.uuidString.lowercased() },
                mailConnectionId: mailConnection.flatMap { DB.uuid($0.connection_id.data) }?.uuidString.lowercased()))
        }
        OpsRoutes.register(app, guardian: guardian, db: db, now: now)
        app.lifecycle.use(OpsScheduler(db: db, secrets: secrets, allowedNets: mailAllowedNets, allowInsecure: allowInsecure, now: now))
        AbuseRoutes.register(tenants, guardian: guardian, db: db, secrets: secrets, now: now)
        if guardian.config.listener == "internal" { LegacyConversionRoutes.register(app, guardian: guardian, db: db, now: now) }
        SettingsRoutes.register(app, guardian: guardian, db: db, now: now)
        OAuthRoutes.registerInternal(app, guardian: guardian, db: db, now: now)
        if includePublicRoutes { OAuthRoutes.registerPublic(app, guardian: guardian, db: db, now: now) }
        TokenRoutes.register(app, guardian: guardian, db: db, now: now)
        if includePublicRoutes { MCPRoutes.register(app, guardian: guardian, db: db, now: now) }
        FlowDebugRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now)
        FlowRunRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now, resume: { lease, state in try await FlowEngine(db: db, mail: mail).execute(lease: lease, state: state) })
        DraftRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now)
        ReleaseRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now)
        AccountRoutes.register(root: app.grouped("admin", "api", "v1"), tenants: tenants, guardian: guardian, db: db, perms: perms, now: now)
        KeyManagementRoutes.register(root: app.grouped("admin", "api", "v1"), tenants: tenants, guardian: guardian, db: db, perms: perms, now: now)
        if let storage = app.storage[StorageServiceKey.self] {
            StorageRoutes.register(root: app.grouped("admin", "api", "v1"), tenants: tenants, guardian: guardian, db: db, perms: perms, storage: storage, now: now)
        }
        EntryRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now)
        PrivacyRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now)
        DomainRoutes.register(root: app.grouped("admin", "api", "v1"), guardian: guardian, db: db, perms: perms, now: now)
        if includePublicRoutes { StatisticsCollector.register(app, guardian: guardian, trusted: statisticsTrustedProxies, resolver: statisticsHostResolver, now: now) }
        WebhookRoutes.register(tenants, guardian: guardian, db: db, perms: perms, secrets: secrets, now: now)
        StatisticsRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now)
        HoldRewrapRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now)
        RotationRoutes.register(tenants, guardian: guardian, db: db, perms: perms, now: now)
        KeyRoutes.register(tenants, guardian: guardian, db: db, perms: perms, secrets: secrets, now: now)
        DirectoryRoutes.register(root: app.grouped("admin", "api", "v1"), tenants: tenants, guardian: guardian, db: db, perms: perms, now: now)
        SDKDeployRoutes.register(tenants: tenants, guardian: guardian, db: db, perms: perms, deploy: deploy, bundleVersion: sdkVersion, now: now)
        MailRoutes.register(root: app.grouped("admin", "api", "v1"), tenants: tenants, guardian: guardian, db: db, perms: perms, secrets: secrets,
                            settings: .init(allowedNets: mailAllowedNets, allowInsecure: allowInsecure), dispatcher: mail, now: now)
        return RouteCollectionBox()
    }

    /// Placeholder return so later operations can be added without changing the call site.
    public struct RouteCollectionBox: Sendable { public init() {} }

    // MARK: queries

    struct FormRow: Decodable { let id: Blob; let name: String?; let active: Int; let current_release_id: Blob? }
    struct FormItem: Encodable {
        let id: String; let name: String; let active: Bool; let currentReleaseId: String?
        init(_ r: FormRow) {
            id = DB.uuid(r.id.data)?.uuidString.lowercased() ?? ""
            name = r.name ?? ""; active = r.active == 1
            currentReleaseId = r.current_release_id.flatMap { DB.uuid($0.data) }?.uuidString.lowercased()
        }
    }
    struct CountRow: Decodable { let c: Int }
    struct CountRowID: Decodable { let id: Blob }
    struct ReferenceRow: Decodable { let id: Blob; let name: String?; let active: Int; let current_release_id: Blob?; let release_version_no: UInt64? }

    static func touches(_ scope: GrantScope, tenant: UUID) -> Bool {
        switch scope {
        case .system: return true
        case .customer(let c): return c == tenant
        case .form(let c, _): return c == tenant
        }
    }

    /// Forms of the tenant the caller may read, ordered by id, keyset-paginated. Scope restriction happens in SQL before the page is cut.
    static func readableForms(_ sql: SQLDatabase, tenant: UUID, scopes: [GrantScope], after: Data?, limit: Int) async throws -> [FormRow] {
        let wide = scopes.contains { s in if case .form = s { return false } else { return s.covers(.customer(tenant)) } }
        let ids: [Blob] = scopes.compactMap { if case .form(let c, let f) = $0, c == tenant { return DB.bin(f) } else { return nil } }
        if !wide && ids.isEmpty { return [] }
        let afterBlob = Blob(after ?? Data(count: 16))
        if wide {
            return try await sql.raw("""
                SELECT id, name, active, current_release_id FROM forms
                WHERE customer_id = \(bind: DB.bin(tenant)) AND id > \(bind: afterBlob) ORDER BY id LIMIT \(literal: limit)
                """).all(decoding: FormRow.self)
        }
        return try await sql.raw("""
            SELECT id, name, active, current_release_id FROM forms
            WHERE customer_id = \(bind: DB.bin(tenant)) AND id IN (\(binds: ids)) AND id > \(bind: afterBlob) ORDER BY id LIMIT \(literal: limit)
            """).all(decoding: FormRow.self)
    }

    // MARK: helpers

    static func uuidParam(_ req: Request, _ name: String) throws -> UUID {
        guard let s = req.parameters.get(name), let u = UUID(uuidString: s) else { throw Abort(.badRequest) }
        return u
    }
    static func limitParam(_ req: Request) throws -> Int {
        guard let raw: String = req.query["limit"] else { return 50 }
        guard let n = Int(raw), (1...100).contains(n) else { throw Abort(.badRequest) }
        return n
    }
    static func cursor(_ id: Blob) -> String { id.data.base64URLString }
    static func cursorParam(_ req: Request) throws -> Data? {
        guard let raw: String = req.query["cursor"] else { return nil }
        guard let d = Data(base64URLString: raw), d.count == 16 else { throw Abort(.badRequest) }
        return d
    }
    static func json<T: Encodable>(_ status: HTTPResponseStatus, _ v: T) throws -> Response {
        let res = Response(status: status)
        res.body = .init(data: try JSONEncoder().encode(v))
        res.headers.contentType = .json
        return res
    }
    static func decode<T: Decodable>(_ req: Request) throws -> T {
        guard req.headers.contentType == .json else { throw Abort(.unsupportedMediaType) }
        guard var buf = req.body.data, let data = buf.readData(length: buf.readableBytes), let v = try? JSONDecoder().decode(T.self, from: data) else { throw Abort(.badRequest) }
        return v
    }

    /// Like `decode`, but rejects members outside `allowed` (the OpenAPI schemas use additionalProperties: false).
    static func decodeStrict<T: Decodable>(_ req: Request, allowed: Set<String>) throws -> T {
        if let buf = req.body.data, let obj = try? JSONSerialization.jsonObject(with: Data(buffer: buf)) as? [String: Any],
           !Set(obj.keys).isSubset(of: allowed) { throw Abort(.badRequest) }
        return try decode(req)
    }
}

struct FormListBody: Encodable { let items: [FormAdmin.FormItem]; let nextCursor: String? }
struct FormInputBody: Decodable { let name: String }
struct ActiveInputBody: Decodable { let active: Bool }
struct ResultBody: Encodable { let id: String; let status: String; let revision: Int }
struct FormDetailBody: Encodable { let id: String; let name: String; let active: Bool; let currentReleaseId: String?; let currentReleaseVersion: Int?; let draftIds: [String]; let mailConnectionId: String? }

extension Data {
    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLString s: String) {
        guard !s.isEmpty, s.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }) else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}
