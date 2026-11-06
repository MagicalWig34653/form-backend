// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

public struct TokenBoundary: Codable, Sendable {
    public let tenantId: UUID
    public let formId: UUID?
    public init(tenantId: UUID, formId: UUID? = nil) { self.tenantId = tenantId; self.formId = formId }
    public var target: PermissionTarget { formId.map { .form(customer: tenantId, form: $0) } ?? .customer(tenantId) }
    public func covers(_ target: PermissionTarget) -> Bool {
        (formId.map { GrantScope.form(customer: tenantId, form: $0) } ?? .customer(tenantId)).covers(target)
    }
}

public struct TokenIdentity: Sendable {
    public let id: UUID
    public let accountID: UUID
    public let scopes: Set<String>
    public let boundary: TokenBoundary
    public static let scopeRights: [String: Set<String>] = [
        "konfiguration.lesen": ["form.read"], "entwurf.schreiben": ["draft.write", "draft.export"],
        "statistik.lesen": ["statistics.read"]
    ]
    public func permits(_ permission: String, on target: PermissionTarget) -> Bool {
        boundary.covers(target) && scopes.contains { Self.scopeRights[$0]?.contains(permission) == true }
    }
    public func authorize(_ perms: PermissionService, _ permission: String, on target: PermissionTarget, exists: Bool = true) async throws {
        guard permits(permission, on: target) else { throw Abort(.forbidden) }
        try await perms.authorize(account: accountID, permission, on: target, exists: exists)
    }
}

public struct TokenService: Sendable {
    public static let prefix = "kfm_"
    public static let format = "sha256-personal-v1"
    let db: Database
    var sql: SQLDatabase { db as! SQLDatabase }
    let now: @Sendable () -> Date
    public init(db: Database, now: @escaping @Sendable () -> Date = { Date() }) { self.db = db; self.now = now }
    public static func digest(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }
    public struct Invalid: PublicProblemError {
        let resource: String
        public var statusCode: UInt { 401 }
        public var code: String { "invalid_token" }
        public var message: String { "Token ungültig." }
        public var headers: HTTPHeaders { ["WWW-Authenticate": "Bearer realm=\"mcp\", error=\"invalid_token\"" + (resource.isEmpty ? "" : ", resource_metadata=\"\(resource)/.well-known/oauth-protected-resource\""), "Cache-Control": "no-store"] }
        public var extraHeaders: [(name: String, value: String)] { headers.map { ($0.name, $0.value) } }
        public init(resource: String = "") { self.resource = resource }
    }
    struct Row: Decodable { let id: Blob; let account_id: Blob; let token_hash: Blob; let scopes_json: String; let scope_json: String }
    public func resolve(_ raw: String) async throws -> TokenIdentity {
        guard raw.hasPrefix(Self.prefix), raw.count == 68, raw.dropFirst(4).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Invalid() }
        let hash = Self.digest(raw)
        guard let r = try await sql.raw("""
            SELECT t.id, t.account_id, t.token_hash, t.scopes_json, t.scope_json FROM mcp_tokens t
            JOIN accounts a ON a.id = t.account_id AND a.active = 1 AND a.mcp_allowed = 1
            WHERE t.hash_format = \(bind: Self.format) AND t.token_hash = \(bind: Blob(hash))
              AND t.grant_id IS NULL AND t.revoked_at IS NULL AND t.expires_at > \(bind: DB.time(now()))
            """).first(decoding: Row.self), constantTimeEqual(hash, r.token_hash.data),
              let id = DB.uuid(r.id.data), let account = DB.uuid(r.account_id.data),
              let scopes = try? JSONDecoder().decode(Set<String>.self, from: Data(r.scopes_json.utf8)),
              let boundary = try? JSONDecoder().decode(TokenBoundary.self, from: Data(r.scope_json.utf8)),
              scopes.isSubset(of: Set(TokenIdentity.scopeRights.keys)) else { throw Invalid() }
        try await sql.raw("UPDATE mcp_tokens SET last_used_at = \(bind: DB.time(now())) WHERE id = \(bind: r.id)").run()
        try await sql.raw("""
            INSERT INTO audit_events (id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), 'service', 'auth', 'token.use', \(bind: DB.bin(id)), \(bind: DB.time(now())), '{}')
            """).run()
        return TokenIdentity(id: id, accountID: account, scopes: scopes, boundary: boundary)
    }
    public func create(account: UUID, label: String, scopes: Set<String>, boundary: TokenBoundary, expiresAt: Date) async throws -> (id: UUID, token: String) {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 120,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !scopes.isEmpty, scopes.isSubset(of: Set(TokenIdentity.scopeRights.keys)),
              expiresAt >= now().addingTimeInterval(86400 - 60), expiresAt <= now().addingTimeInterval(90 * 86400) else { throw Abort(.unprocessableEntity) }
        let token = Self.prefix + Data.random(32).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), t = now()
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            struct A: Decodable { let active: Int; let mcp_allowed: Int }
            guard let a = try await tx.raw("SELECT active, mcp_allowed FROM accounts WHERE id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: A.self), a.active == 1, a.mcp_allowed == 1 else { throw Abort(.forbidden) }
            let perms = PermissionService(sql: tx)
            try await perms.authorize(account: account, "token.manage", on: boundary.target)
            for scope in scopes { for right in TokenIdentity.scopeRights[scope]! { try await perms.authorize(account: account, right, on: boundary.target) } }
            struct C: Decodable { let c: Int }
            guard try await tx.raw("SELECT COUNT(*) AS c FROM mcp_tokens WHERE account_id = \(bind: DB.bin(account)) AND revoked_at IS NULL AND expires_at > \(bind: DB.time(t)) AND grant_id IS NULL").first(decoding: C.self)!.c < 5 else { throw Abort(.conflict) }
            // Verify the ownership chain, including customer-wide credentials.
            let count: Int
            if let f = boundary.formId {
                count = try await tx.raw("SELECT COUNT(*) AS c FROM forms WHERE id = \(bind: DB.bin(f)) AND customer_id = \(bind: DB.bin(boundary.tenantId))").first(decoding: C.self)!.c
            } else {
                count = try await tx.raw("SELECT COUNT(*) AS c FROM customers WHERE id = \(bind: DB.bin(boundary.tenantId))").first(decoding: C.self)!.c
            }
            guard count == 1 else { throw Abort(.notFound) }
            try await tx.raw("""
                INSERT INTO mcp_tokens (id, account_id, token_hash, hash_format, label, scopes_json, scope_json, created_at, expires_at, origin)
                VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(account)), \(bind: Blob(Self.digest(token))), \(bind: Self.format), \(bind: label),
                \(bind: String(decoding: try JSONEncoder().encode(scopes), as: UTF8.self)), \(bind: String(decoding: try JSONEncoder().encode(boundary), as: UTF8.self)), \(bind: DB.time(t)), \(bind: DB.time(expiresAt)), 'native')
                """).run()
            try await Self.audit(tx, account: account, id: id, action: "token.create", at: t)
        }
        return (id, token)
    }
    public struct Item: Codable, Sendable { public let id: UUID; public let label: String?; public let scopes_json: String; public let scope_json: String; public let created_at: Date?; public let expires_at: Date; public let last_used_at: Date?; public let revoked_at: Date? }
    public func list(account: UUID) async throws -> [Item] {
        struct R: Decodable { let id: Blob; let label: String?; let scopes_json: String; let scope_json: String; let created_at: Date?; let expires_at: Date; let last_used_at: Date?; let revoked_at: Date? }
        return try await sql.raw("SELECT id,label,scopes_json,scope_json,created_at,expires_at,last_used_at,revoked_at FROM mcp_tokens WHERE account_id = \(bind: DB.bin(account)) AND hash_format = \(bind: Self.format) ORDER BY created_at DESC LIMIT 100").all(decoding: R.self).compactMap { r in
            guard let id = DB.uuid(r.id.data) else { return nil }
            return Item(id: id, label: r.label, scopes_json: r.scopes_json, scope_json: r.scope_json, created_at: r.created_at, expires_at: r.expires_at, last_used_at: r.last_used_at, revoked_at: r.revoked_at)
        }
    }
    public func revoke(account: UUID, id: UUID) async throws {
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            struct R: Decodable { let id: Blob }
            guard try await tx.raw("SELECT id FROM mcp_tokens WHERE id = \(bind: DB.bin(id)) AND account_id = \(bind: DB.bin(account)) AND hash_format = \(bind: Self.format) FOR UPDATE").first(decoding: R.self) != nil else { throw Abort(.notFound) }
            // Ownership is sufficient for self-revocation; the HTTP route requires fresh human authentication.
            try await tx.raw("UPDATE mcp_tokens SET revoked_at = COALESCE(revoked_at, \(bind: DB.time(now()))) WHERE id = \(bind: DB.bin(id))").run()
            try await Self.audit(tx, account: account, id: id, action: "token.revoke", at: now())
        }
    }
    /// Successful calls belong to the mutation transaction. Failed attempts are written after rollback.
    public static func auditDraft(_ sql: SQLDatabase, token: TokenIdentity, tenant: UUID, form: UUID, draft: UUID,
                                  revision: UInt64?, outcome: String, action: String = "draft.update", at: Date) async throws {
        struct Details: Encodable {
            let token_id: UUID; let revision: UInt64?; let outcome: String
        }
        let details = String(decoding: try JSONEncoder().encode(Details(token_id: token.id, revision: revision, outcome: outcome)), as: UTF8.self)
        try await sql.raw("""
            INSERT INTO audit_events (id, customer_id, form_id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: DB.bin(token.accountID)), 'service', 'form',
              \(bind: outcome == "success" ? action : action + ".failed"), \(bind: DB.bin(draft)), \(bind: DB.time(at)), \(bind: details))
            """).run()
    }
    static func audit(_ sql: SQLDatabase, account: UUID, id: UUID, action: String, at: Date, actorKind: String = "human") async throws {
        try await sql.raw("""
            INSERT INTO audit_events (id, actor_id, actor_kind, category, action_code, subject_id, occurred_at, safe_details_json)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), \(bind: actorKind), 'auth', \(bind: action), \(bind: DB.bin(id)), \(bind: DB.time(at)), '{}')
            """).run()
    }
}
