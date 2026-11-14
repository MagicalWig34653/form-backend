// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Public protocol endpoints and human authorization are registered on separate listeners.
enum OAuthRoutes {
    static func failure(_ error: OAuthFailure) throws -> Response {
        let r = try MCPRoutes.response(["error": error.code]); r.status = .badRequest; return r
    }
    static func form(_ req: Request) throws -> [String: String] {
        guard req.headers.contentType == .urlEncodedForm, let body = req.body.string, body.utf8.count <= 8192 else { throw OAuthFailure("invalid_request") }
        return try parameters(body)
    }
    static func parameters(_ raw: String) throws -> [String: String] {
        guard raw.utf8.count <= 8192 else { throw OAuthFailure("invalid_request") }
        var result: [String: String] = [:]
        for part in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let key = String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding, result[key] == nil else { throw OAuthFailure("invalid_request") }
            result[key] = value
        }
        return result
    }
    static func metadata(_ config: AuthConfig) -> [String: Any] {
        let base = config.issuer
        return ["issuer": base, "authorization_endpoint": config.authorizeBaseURL + "/oauth/authorize",
                "token_endpoint": base + "/oauth/token", "registration_endpoint": base + "/oauth/register",
                "revocation_endpoint": config.authorizeBaseURL + "/oauth/revoke",
                "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
                "token_endpoint_auth_methods_supported": ["none"], "revocation_endpoint_auth_methods_supported": ["none"],
                "code_challenge_methods_supported": ["S256"], "scopes_supported": TokenIdentity.scopeRights.keys.sorted(),
                "authorization_response_iss_parameter_supported": true]
    }
    static func registerPublic(_ app: Application, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        let service = OAuthService(db: db, issuer: guardian.config.issuer, now: now)
        app.get(".well-known", "oauth-authorization-server") { req async throws -> Response in
            try await guardian.budget(req)
            return try MCPRoutes.response(metadata(guardian.config))
        }
        app.on(.POST, "oauth", "token", body: .collect(maxSize: "8kb")) { req async throws -> Response in
            try await guardian.budget(req)
            do {
                guard !req.headers.contains(name: .authorization) else { throw OAuthFailure("invalid_client") }
                let r = try FormAdmin.json(.ok, await service.exchange(form(req))); r.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return r }
            catch let e as OAuthFailure { return try failure(e) }
        }
        app.on(.POST, "oauth", "register", body: .collect(maxSize: "8kb")) { req async throws -> Response in
            try await guardian.throttles.consume(.adminRoute, "oauth-register|" + IPAddr.quotaKey(guardian.config.clientIP(req)), limit: OAuthService.registrationsPerIPPerHour, window: 3600)
            do {
                struct Input: Decodable { let client_name: String?; let redirect_uris: [String]; let token_endpoint_auth_method: String?; let grant_types: [String]?; let response_types: [String]? }
                guard req.headers.contentType == .json else { throw OAuthFailure("invalid_client_metadata") }
                // RFC 7591: unknown registration metadata is ignored, never fetched or trusted.
                let i: Input
                do { i = try req.content.decode(Input.self) } catch { throw OAuthFailure("invalid_client_metadata") }
                let name = i.client_name ?? "MCP-Client"
                guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      (1...10).contains(i.redirect_uris.count), i.redirect_uris.allSatisfy(OAuthService.validRedirect), Set(i.redirect_uris).count == i.redirect_uris.count,
                      i.token_endpoint_auth_method == nil || i.token_endpoint_auth_method == "none",
                      i.grant_types == nil || (!i.grant_types!.isEmpty && Set(i.grant_types!).isSubset(of: ["authorization_code", "refresh_token"])),
                      i.response_types == nil || i.response_types == ["code"] else { throw OAuthFailure("invalid_client_metadata") }
                let id = UUID(), client = UUID().uuidString.lowercased(), redirects = String(decoding: try JSONEncoder().encode(i.redirect_uris), as: UTF8.self)
                try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    // Shared row lock serializes the count and insert across replicas (also consent/cleanup).
                    _ = try await SystemSettings.lock(tx, at: DB.time(now()))
                    let hourly = Int(try await SystemSettings.value("oauth.registrationsPerHour", sql: tx))!
                    let unused = Int(try await SystemSettings.value("oauth.maxUnusedClients", sql: tx))!
                    struct Count: Decodable { let n: Int }
                    let recent = try await tx.raw("SELECT COUNT(*) AS n FROM oauth_clients WHERE created_at > \(bind: DB.time(now().addingTimeInterval(-3600)))").first(decoding: Count.self)!.n
                    let pending = try await tx.raw("SELECT COUNT(*) AS n FROM oauth_clients c WHERE NOT EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id = c.id)").first(decoding: Count.self)!.n
                    guard recent < hourly, pending < unused else { throw Abort(.tooManyRequests) }
                    try await tx.raw("INSERT INTO oauth_clients (id,client_identifier,name,redirect_uris_json,created_at,origin) VALUES (\(bind: DB.bin(id)),\(bind: client),\(bind: name),\(bind: redirects),\(bind: DB.time(now())),'native')").run()
                    try await audit(tx, account: nil, id: id, action: "oauth.client.register", now: now())
                }
                let res = try MCPRoutes.response(["client_id": client, "client_name": name, "redirect_uris": i.redirect_uris, "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]]); res.status = .created; return res
            } catch let e as OAuthFailure { return try failure(e) }
        }
    }
    struct Client: Decodable { let id: Blob; let name: String; let redirect_uris_json: String }
    struct Pending: Decodable {
        let id: Blob; let session_id: Blob; let client_id: Blob; let redirect_uri: String; let code_challenge: String
        let scopes_json: String; let state_value: String; let resource: String; let expires_at: Date; let consumed_at: Date?
    }
    static func registerInternal(_ app: Application, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase, service = OAuthService(db: db, issuer: guardian.config.issuer, now: now)
        app.get("oauth", "authorize") { req async throws -> Response in
            try await guardian.budget(req)
            // Login's local return target is fixed to this endpoint; never forward an unvalidated redirect_uri.
            guard let session = try await guardian.currentSession(req), session.state == .authenticated else {
                let next = "/oauth/authorize?" + (req.url.query ?? "")
                var u = URLComponents(); u.path = "/login"; u.queryItems = [.init(name: "next", value: next)]
                return req.redirect(to: u.string!, redirectType: .normal)
            }
            do { try await guardian.requireFreshAuthentication(session, now: now()) }
            catch {
                var u = URLComponents(); u.path = "/login"
                u.queryItems = [.init(name: "next", value: "/oauth/authorize?" + (req.url.query ?? "")), .init(name: "fresh", value: "1")]
                return req.redirect(to: u.string!, redirectType: .normal)
            }
            do {
                let p = try parameters(req.url.query ?? "")
                guard p["response_type"] == "code", let client = p["client_id"], let redirect = p["redirect_uri"],
                      let challenge = p["code_challenge"], challenge.count == 43, challenge.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,95].contains($0) }),
                      p["code_challenge_method"] == "S256", p["resource"] == guardian.config.issuer + "/mcp/",
                      let r = try await sql.raw("SELECT id,name,redirect_uris_json FROM oauth_clients WHERE client_identifier = \(bind: client) AND (created_at > \(bind: DB.time(now().addingTimeInterval(-OAuthService.unusedClientTTL))) OR EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id = oauth_clients.id))").first(decoding: Client.self),
                      (try JSONDecoder().decode([String].self, from: Data(r.redirect_uris_json.utf8))).contains(redirect) else { throw OAuthFailure("invalid_request") }
                let scopes = Set((p["scope"] ?? "").split(separator: " ").map(String.init)), state = p["state"] ?? ""
                guard !scopes.isEmpty, scopes.isSubset(of: Set(TokenIdentity.scopeRights.keys)), state.utf8.count <= 1024 else { throw OAuthFailure("invalid_scope") }
                let id = UUID()
                try await sql.raw("""
                    INSERT INTO oauth_authorization_requests (id,session_id,client_id,redirect_uri,code_challenge,scopes_json,state_value,resource,expires_at)
                    VALUES (\(bind: DB.bin(id)),\(bind: DB.bin(session.id)),\(bind: r.id),\(bind: redirect),\(bind: challenge),\(bind: String(decoding: try JSONEncoder().encode(scopes), as: UTF8.self)),\(bind: state),\(bind: guardian.config.issuer + "/mcp/"),\(bind: DB.time(now().addingTimeInterval(300))))
                    """).run()
                let res = req.redirect(to: "/api-tokens?oauth_request=" + id.uuidString.lowercased(), redirectType: .normal)
                res.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); res.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer"); return res
            } catch let e as OAuthFailure { return try failure(e) }
        }
        let root = app.grouped("admin", "api", "v1", "account", "oauth")
        root.get("requests", ":id") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            let id = try FormAdmin.uuidParam(req, "id")
            guard let p = try await sql.raw("SELECT * FROM oauth_authorization_requests WHERE id = \(bind: DB.bin(id)) AND session_id = \(bind: DB.bin(s.id)) AND consumed_at IS NULL AND expires_at > \(bind: DB.time(now()))").first(decoding: Pending.self),
                  let c = try await sql.raw("SELECT id,name,redirect_uris_json FROM oauth_clients WHERE id = \(bind: p.client_id)").first(decoding: Client.self) else { throw Abort(.notFound) }
            return try MCPRoutes.response(["clientName": c.name, "redirectHost": URLComponents(string: p.redirect_uri)!.host!, "scopes": try JSONDecoder().decode([String].self, from: Data(p.scopes_json.utf8))])
        }
        // Same handler at the protocol URL and the PWA API URL; one human consent contract.
        let consent: @Sendable (Request) async throws -> Response = { req in
            try await guardian.budget(req)
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.requireFreshAuthentication(s, now: now())
            struct Input: Decodable { let requestId: UUID; let approve: Bool; let tenantId: UUID?; let formId: UUID? }
            let i: Input = try FormAdmin.decodeStrict(req, allowed: ["requestId", "approve", "tenantId", "formId"])
            let redirect: String = try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                _ = try await SystemSettings.lock(tx, at: DB.time(now()))
                guard let p = try await tx.raw("SELECT * FROM oauth_authorization_requests WHERE id = \(bind: DB.bin(i.requestId)) AND session_id = \(bind: DB.bin(s.id)) FOR UPDATE").first(decoding: Pending.self), p.consumed_at == nil, p.expires_at > now(), p.resource == guardian.config.issuer + "/mcp/" else { throw Abort(.badRequest) }
                struct Count: Decodable { let n: Int }
                guard try await tx.raw("SELECT COUNT(*) AS n FROM oauth_clients c WHERE c.id = \(bind: p.client_id) AND (c.created_at > \(bind: DB.time(now().addingTimeInterval(-OAuthService.unusedClientTTL))) OR EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id = c.id))").first(decoding: Count.self)!.n == 1 else { throw Abort(.badRequest) }
                try await tx.raw("UPDATE oauth_authorization_requests SET consumed_at = \(bind: DB.time(now())) WHERE id = \(bind: p.id)").run()
                var u = URLComponents(string: p.redirect_uri)!, values = [URLQueryItem(name: "iss", value: guardian.config.issuer), .init(name: "state", value: p.state_value)]
                if i.approve {
                    guard let tenant = i.tenantId else { throw Abort(.unprocessableEntity) }
                    let boundary = TokenBoundary(tenantId: tenant, formId: i.formId), scopes = try JSONDecoder().decode(Set<String>.self, from: Data(p.scopes_json.utf8))
                    do { try await OAuthService.checkRights(tx, account: s.accountID!, scopes: scopes, boundary: boundary) }
                    catch is OAuthFailure { throw Abort(.forbidden) }
                    let grant = UUID(), code = OAuthService.secret("ofc_")
                    try await tx.raw("""
                        INSERT INTO oauth_grants (id,client_id,account_id,scopes_json,scope_json,resource,created_at,expires_at,origin)
                        VALUES (\(bind: DB.bin(grant)),\(bind: p.client_id),\(bind: DB.bin(s.accountID!)),\(bind: p.scopes_json),\(bind: String(decoding: try JSONEncoder().encode(boundary), as: UTF8.self)),\(bind: p.resource),\(bind: DB.time(now())),\(bind: DB.time(now().addingTimeInterval(30 * 86400))),'native')
                        """).run()
                    try await tx.raw("""
                        INSERT INTO oauth_codes (id,code_hash,hash_format,grant_id,redirect_uri,code_challenge,challenge_method,resource,scopes_json,expires_at,origin)
                        VALUES (\(bind: DB.bin(UUID())),\(bind: Blob(TokenService.digest(code))),'sha256-oauth-v1',\(bind: DB.bin(grant)),\(bind: p.redirect_uri),\(bind: p.code_challenge),'S256',\(bind: p.resource),\(bind: p.scopes_json),\(bind: DB.time(now().addingTimeInterval(60))),'native')
                        """).run()
                    try await audit(tx, account: s.accountID!, id: grant, action: "oauth.consent.approve", now: now())
                    values.append(.init(name: "code", value: code))
                } else {
                    try await audit(tx, account: s.accountID!, id: i.requestId, action: "oauth.consent.deny", now: now())
                    values.append(.init(name: "error", value: "access_denied"))
                }
                u.queryItems = (u.queryItems ?? []) + values
                return u.string!
            }
            return try MCPRoutes.response(["redirect": redirect])
        }
        app.post("oauth", "authorize", use: consent)
        root.post("consent", use: consent)
        app.on(.POST, "oauth", "revoke", body: .collect(maxSize: "8kb")) { req async throws -> Response in
            try await guardian.budget(req)
            do {
                let p = try form(req)
                guard let token = p["token"], let client = p["client_id"] else { throw OAuthFailure("invalid_request") }
                try await service.revokeToken(token, client: client)
                return Response(status: .ok, headers: ["Cache-Control": "no-store"])
            } catch let e as OAuthFailure { return try failure(e) }
        }
        root.get { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            struct R: Decodable { let id: Blob; let name: String; let client_identifier: String; let redirect_uris_json: String; let scopes_json: String; let scope_json: String; let revoked_at: Date? }
            let rows = try await sql.raw("SELECT g.id,c.name,c.client_identifier,c.redirect_uris_json,g.scopes_json,g.scope_json,g.revoked_at FROM oauth_grants g JOIN oauth_clients c ON c.id = g.client_id WHERE g.account_id = \(bind: DB.bin(s.accountID!)) ORDER BY g.created_at DESC LIMIT 100").all(decoding: R.self)
            return try MCPRoutes.response(["items": rows.map { r -> [String: Any] in ["id": DB.uuid(r.id.data)!.uuidString.lowercased(), "clientName": r.name, "clientId": r.client_identifier, "redirects": r.redirect_uris_json, "scopes": r.scopes_json, "boundary": r.scope_json, "revoked": r.revoked_at != nil] }])
        }
        root.delete("clients", ":client") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.requireFreshAuthentication(s, now: now())
            guard let client = req.parameters.get("client"), client.count <= 255 else { throw Abort(.badRequest) }
            try await service.disconnectClient(account: s.accountID!, client: client)
            return Response(status: .noContent)
        }
        root.delete(":id") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.requireFreshAuthentication(s, now: now())
            try await service.revokeGrant(account: s.accountID!, id: FormAdmin.uuidParam(req, "id"))
            return Response(status: .noContent)
        }
    }
    static func audit(_ sql: SQLDatabase, account: UUID?, id: UUID, action: String, now: Date) async throws {
        try await sql.raw("INSERT INTO audit_events (id,actor_id,actor_kind,category,action_code,subject_id,occurred_at,safe_details_json) VALUES (\(bind: DB.bin(UUID())),\(bind: account.map(DB.bin)),\(bind: account == nil ? "service" : "human"),'auth',\(bind: action),\(bind: DB.bin(id)),\(bind: DB.time(now)),'{}')").run()
    }
}
