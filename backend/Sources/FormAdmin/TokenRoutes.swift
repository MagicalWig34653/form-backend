// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Only explicitly selected configuration routes use this identity. All other routes require a human session.
struct ConfigurationIdentity: Sendable {
    struct InternalKey: StorageKey { typealias Value = ConfigurationIdentity }
    let accountID: UUID?
    let token: TokenIdentity?
    func authorize(_ perms: PermissionService, _ permission: String, on target: PermissionTarget, exists: Bool = true) async throws {
        if let token { try await token.authorize(perms, permission, on: target, exists: exists) }
        else { try await perms.authorize(account: accountID!, permission, on: target, exists: exists) }
    }
    static func require(_ req: Request, guardian: AuthGuard, db: Database, mutation: Bool, now: @escaping @Sendable () -> Date) async throws -> Self {
        if let internalIdentity = req.storage[InternalKey.self] { return internalIdentity }
        if req.headers.contains(name: .authorization) {
            // Socket-backed requests consume the IP budget once, at the transport boundary.
            if req.remoteAddress != nil { try await guardian.budget(req) }
            guard req.headers[.authorization].count == 1, let bearer = req.headers.bearerAuthorization else {
                if req.remoteAddress == nil { try await guardian.budget(req) }
                throw TokenService.Invalid(resource: guardian.config.issuer)
            }
            let token: TokenIdentity
            do { token = try await (bearer.token.hasPrefix("ofa_") ? OAuthService(db: db, issuer: guardian.config.issuer, now: now).resolve(bearer.token) : TokenService(db: db, now: now).resolve(bearer.token)) }
            catch is TokenService.Invalid {
                if req.remoteAddress == nil { try await guardian.budget(req) }
                throw TokenService.Invalid(resource: guardian.config.issuer)
            }
            try await guardian.throttles.consume(.adminRoute, req.url.path.hasPrefix("/mcp") ? "mcp-token|\(token.id)" : "token|\(token.id)", limit: req.url.path.hasPrefix("/mcp") ? Int(try await SystemSettings.value("mcp.requestsPerMinute", sql: db as! SQLDatabase))! : 120, window: 60)
            return Self(accountID: token.accountID, token: token)
        }
        let s = try await guardian.requireAuthenticated(req, mutation: mutation)
        return Self(accountID: s.accountID, token: nil)
    }
}

enum TokenRoutes {
    static func register(_ app: Application, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        let routes = app.grouped("admin", "api", "v1", "account", "tokens")
        let service = TokenService(db: db, now: now)
        routes.get { req async throws -> Response in
            try await guardian.budget(req)
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            struct Body: Encodable { let items: [TokenService.Item] }
            let res = try FormAdmin.json(.ok, Body(items: try await service.list(account: s.accountID!)))
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
        routes.post { req async throws -> Response in
            try await guardian.budget(req)
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.requireFreshAuthentication(s, now: now())
            struct Input: Decodable { let label: String; let scopes: Set<String>; let tenantId: UUID; let formId: UUID?; let expiresAt: String }
            let i: Input = try FormAdmin.decodeStrict(req, allowed: ["label", "scopes", "tenantId", "formId", "expiresAt"])
            guard let expiry = ISO8601DateFormatter().date(from: i.expiresAt) else { throw Abort(.unprocessableEntity) }
            let result = try await service.create(account: s.accountID!, label: i.label, scopes: i.scopes, boundary: .init(tenantId: i.tenantId, formId: i.formId), expiresAt: expiry)
            struct Body: Encodable { let id: UUID; let token: String }
            let res = try FormAdmin.json(.created, Body(id: result.id, token: result.token))
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
        routes.delete(":tokenId") { req async throws -> Response in
            try await guardian.budget(req)
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.requireFreshAuthentication(s, now: now())
            try await service.revoke(account: s.accountID!, id: FormAdmin.uuidParam(req, "tokenId"))
            return Response(status: .noContent)
        }
    }
}
