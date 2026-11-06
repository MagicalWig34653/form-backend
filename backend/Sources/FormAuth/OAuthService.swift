// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormPersistence
import Foundation
import SQLKit
import Vapor

public struct OAuthFailure: Error, Sendable {
    public let code: String
    public init(_ code: String = "invalid_grant") { self.code = code }
}

/// Opaque credentials; all state transitions serialize on the grant (also across replicas).
public struct OAuthService: Sendable {
    let db: Database
    let issuer: String
    let now: @Sendable () -> Date
    public init(db: Database, issuer: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.issuer = issuer; self.now = now
    }
    public static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    public static func validVerifier(_ value: String) -> Bool {
        (43...128).contains(value.utf8.count) && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95,126].contains($0) }
    }
    public static func validRedirect(_ raw: String) -> Bool {
        guard raw.utf8.count <= 512, !raw.contains("\\"), !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let u = URLComponents(string: raw), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil, u.fragment == nil else { return false }
        guard !(u.queryItems ?? []).contains(where: { ["code", "state", "iss", "error"].contains($0.name) }) else { return false }
        return u.scheme == "https" || (u.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
    }
    public static func secret(_ prefix: String) -> String { prefix + Data.random(32).base64URL }
    public struct Pair: Content, Sendable {
        public let access_token: String; public let refresh_token: String
        public let token_type = "Bearer"; public let expires_in = 900
        public let scope: String
    }
    struct GrantRow: Decodable {
        let id: Blob; let account_id: Blob; let client_id: Blob; let scopes_json: String; let scope_json: String
        let resource: String; let expires_at: Date; let revoked_at: Date?
    }
    func lock(_ sql: SQLDatabase, _ id: Blob) async throws -> GrantRow {
        guard let g = try await sql.raw("SELECT id,account_id,client_id,scopes_json,scope_json,resource,expires_at,revoked_at FROM oauth_grants WHERE id = \(bind: id) FOR UPDATE").first(decoding: GrantRow.self) else { throw OAuthFailure() }
        return g
    }
    func live(_ sql: SQLDatabase, _ g: GrantRow) async throws -> (UUID, Set<String>, TokenBoundary) {
        guard g.revoked_at == nil, g.expires_at > now(), g.resource == issuer + "/mcp/", let a = DB.uuid(g.account_id.data),
              let scopes = try? JSONDecoder().decode(Set<String>.self, from: Data(g.scopes_json.utf8)), !scopes.isEmpty,
              scopes.isSubset(of: Set(TokenIdentity.scopeRights.keys)),
              let boundary = try? JSONDecoder().decode(TokenBoundary.self, from: Data(g.scope_json.utf8)) else { throw OAuthFailure() }
        try await Self.checkRights(sql, account: a, scopes: scopes, boundary: boundary)
        return (a, scopes, boundary)
    }
    public static func checkRights(_ sql: SQLDatabase, account: UUID, scopes: Set<String>, boundary: TokenBoundary) async throws {
        struct C: Decodable { let c: Int }
        guard !scopes.isEmpty, scopes.isSubset(of: Set(TokenIdentity.scopeRights.keys)),
              try await sql.raw("SELECT COUNT(*) AS c FROM accounts WHERE id = \(bind: DB.bin(account)) AND active = 1 AND mcp_allowed = 1").first(decoding: C.self)?.c == 1 else { throw OAuthFailure("access_denied") }
        let exists: Bool
        if let f = boundary.formId {
            exists = try await sql.raw("SELECT COUNT(*) AS c FROM forms WHERE id = \(bind: DB.bin(f)) AND customer_id = \(bind: DB.bin(boundary.tenantId))").first(decoding: C.self)?.c == 1
        } else {
            exists = try await sql.raw("SELECT COUNT(*) AS c FROM customers WHERE id = \(bind: DB.bin(boundary.tenantId)) AND state = 'active'").first(decoding: C.self)?.c == 1
        }
        guard exists else { throw OAuthFailure("access_denied") }
        let perms = PermissionService(sql: sql)
        for scope in scopes { for right in TokenIdentity.scopeRights[scope]! {
            guard try await perms.can(account: account, right, on: boundary.target) else { throw OAuthFailure("access_denied") }
        } }
    }
    func issue(_ sql: SQLDatabase, _ g: GrantRow, family: UUID) async throws -> (Pair, UUID) {
        let (_, scopes, _) = try await live(sql, g)
        let access = Self.secret("ofa_"), refresh = Self.secret("ofr_"), rid = UUID()
        try await sql.raw("""
            INSERT INTO mcp_tokens (id,account_id,grant_id,token_hash,hash_format,scopes_json,scope_json,created_at,expires_at,origin)
            VALUES (\(bind: DB.bin(UUID())),\(bind: g.account_id),\(bind: g.id),\(bind: Blob(TokenService.digest(access))),'sha256-oauth-v1',\(bind: g.scopes_json),\(bind: g.scope_json),\(bind: DB.time(now())),\(bind: DB.time(now().addingTimeInterval(900))),'native')
            """).run()
        try await sql.raw("""
            INSERT INTO oauth_refresh_tokens (id,grant_id,refresh_hash,hash_format,family_id,created_at,expires_at,origin)
            VALUES (\(bind: DB.bin(rid)),\(bind: g.id),\(bind: Blob(TokenService.digest(refresh))),'sha256-oauth-v1',\(bind: DB.bin(family)),\(bind: DB.time(now())),\(bind: DB.time(g.expires_at)),'native')
            """).run()
        try await TokenService.audit(sql, account: DB.uuid(g.account_id.data)!, id: DB.uuid(g.id.data)!, action: "oauth.token.issue", at: now(), actorKind: "service")
        return (Pair(access_token: access, refresh_token: refresh, scope: scopes.sorted().joined(separator: " ")), rid)
    }
    public func exchange(_ input: [String: String]) async throws -> Pair {
        guard let client = input["client_id"], client.count <= 255, input["client_secret"] == nil,
              input["resource"] == issuer + "/mcp/" else { throw OAuthFailure("invalid_target") }
        let refresh = input["grant_type"] == "refresh_token"
        guard refresh || input["grant_type"] == "authorization_code" else { throw OAuthFailure("unsupported_grant_type") }
        let raw = input[refresh ? "refresh_token" : "code"] ?? ""
        guard raw.count == 47, raw.hasPrefix(refresh ? "ofr_" : "ofc_") else { throw OAuthFailure() }
        // Lookup only finds the grant; row state is always reread after acquiring its lock.
        struct Ref: Decodable { let grant_id: Blob }
        let sql = db as! SQLDatabase
        let ref: Ref?
        if refresh { ref = try await sql.raw("SELECT grant_id FROM oauth_refresh_tokens WHERE refresh_hash = \(bind: Blob(TokenService.digest(raw))) AND hash_format = 'sha256-oauth-v1'").first(decoding: Ref.self) }
        else { ref = try await sql.raw("SELECT grant_id FROM oauth_codes WHERE code_hash = \(bind: Blob(TokenService.digest(raw))) AND hash_format = 'sha256-oauth-v1'").first(decoding: Ref.self) }
        guard let ref else { throw OAuthFailure() }
        let result: Pair? = try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            let g = try await lock(tx, ref.grant_id)
            struct Client: Decodable { let client_identifier: String }
            guard try await tx.raw("SELECT client_identifier FROM oauth_clients WHERE id = \(bind: g.client_id)").first(decoding: Client.self)?.client_identifier == client else { throw OAuthFailure("invalid_client") }
            if refresh {
                struct R: Decodable { let id: Blob; let family_id: Blob; let replaced_at: Date?; let revoked_at: Date?; let expires_at: Date }
                guard let r = try await tx.raw("SELECT id,family_id,replaced_at,revoked_at,expires_at FROM oauth_refresh_tokens WHERE grant_id = \(bind: g.id) AND refresh_hash = \(bind: Blob(TokenService.digest(raw))) FOR UPDATE").first(decoding: R.self) else { throw OAuthFailure() }
                if r.replaced_at != nil {
                    // Return a sentinel so replay revocation COMMITs before returning invalid_grant.
                    try await revoke(tx, g, action: "oauth.refresh.replay")
                    return nil
                }
                let originalScope = try JSONDecoder().decode(Set<String>.self, from: Data(g.scopes_json.utf8)).sorted().joined(separator: " ")
                guard r.revoked_at == nil, r.expires_at > now(), input["scope"] == nil || input["scope"] == originalScope else { throw OAuthFailure() }
                let (pair, next) = try await issue(tx, g, family: DB.uuid(r.family_id.data)!)
                try await tx.raw("UPDATE oauth_refresh_tokens SET replaced_at = \(bind: DB.time(now())), replaced_by = \(bind: DB.bin(next)) WHERE id = \(bind: r.id)").run()
                return pair
            } else {
                struct R: Decodable { let id: Blob; let redirect_uri: String; let code_challenge: String; let challenge_method: String; let expires_at: Date; let consumed_at: Date?; let revoked_at: Date? }
                guard let r = try await tx.raw("SELECT id,redirect_uri,code_challenge,challenge_method,expires_at,consumed_at,revoked_at FROM oauth_codes WHERE grant_id = \(bind: g.id) AND code_hash = \(bind: Blob(TokenService.digest(raw))) FOR UPDATE").first(decoding: R.self),
                      r.consumed_at == nil, r.revoked_at == nil, r.expires_at > now(), r.redirect_uri == input["redirect_uri"], r.challenge_method == "S256",
                      let verifier = input["code_verifier"], Self.validVerifier(verifier), constantTimeEqual(Data(Self.challenge(verifier).utf8), Data(r.code_challenge.utf8)) else { throw OAuthFailure() }
                try await tx.raw("UPDATE oauth_codes SET consumed_at = \(bind: DB.time(now())) WHERE id = \(bind: r.id)").run()
                return try await issue(tx, g, family: UUID()).0
            }
        }
        guard let result else { throw OAuthFailure() }
        return result
    }
    func revoke(_ sql: SQLDatabase, _ g: GrantRow, action: String) async throws {
        try await sql.raw("UPDATE oauth_grants SET revoked_at = COALESCE(revoked_at, \(bind: DB.time(now()))) WHERE id = \(bind: g.id)").run()
        try await sql.raw("UPDATE oauth_refresh_tokens SET revoked_at = COALESCE(revoked_at, \(bind: DB.time(now()))) WHERE grant_id = \(bind: g.id)").run()
        try await TokenService.audit(sql, account: DB.uuid(g.account_id.data)!, id: DB.uuid(g.id.data)!, action: action, at: now(), actorKind: action == "oauth.grant.revoke" ? "human" : "service")
    }
    public func revokeGrant(account: UUID, id: UUID) async throws {
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            let g: GrantRow
            do { g = try await lock(tx, DB.bin(id)) } catch is OAuthFailure { throw Abort(.notFound) }
            guard g.account_id.data == DB.bin(account).data else { throw Abort(.notFound) }
            try await revoke(tx, g, action: "oauth.grant.revoke")
        }
    }
    public func disconnectClient(account: UUID, client: String) async throws {
        struct R: Decodable { let id: Blob }
        let rows = try await (db as! SQLDatabase).raw("SELECT g.id FROM oauth_grants g JOIN oauth_clients c ON c.id = g.client_id WHERE g.account_id = \(bind: DB.bin(account)) AND c.client_identifier = \(bind: client) ORDER BY g.id").all(decoding: R.self)
        for r in rows { try await revokeGrant(account: account, id: DB.uuid(r.id.data)!) }
    }
    public func revokeToken(_ raw: String, client: String) async throws {
        guard raw.count == 47 else { return }
        struct R: Decodable { let grant_id: Blob }
        let sql = db as! SQLDatabase
        let r: R?
        if raw.hasPrefix("ofr_") { r = try await sql.raw("SELECT grant_id FROM oauth_refresh_tokens WHERE refresh_hash = \(bind: Blob(TokenService.digest(raw)))").first(decoding: R.self) }
        else { r = try await sql.raw("SELECT grant_id FROM mcp_tokens WHERE token_hash = \(bind: Blob(TokenService.digest(raw))) AND grant_id IS NOT NULL").first(decoding: R.self) }
        guard let r else { return }
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase, g = try await lock(tx, r.grant_id)
            struct C: Decodable { let client_identifier: String }
            guard try await tx.raw("SELECT client_identifier FROM oauth_clients WHERE id = \(bind: g.client_id)").first(decoding: C.self)?.client_identifier == client else { return }
            try await revoke(tx, g, action: "oauth.token.revoke")
        }
    }
    public func resolve(_ raw: String) async throws -> TokenIdentity {
        guard raw.hasPrefix("ofa_"), raw.count == 47 else { throw TokenService.Invalid() }
        let sql = db as! SQLDatabase
        struct R: Decodable { let id: Blob; let grant_id: Blob }
        guard let r = try await sql.raw("SELECT id,grant_id FROM mcp_tokens WHERE token_hash = \(bind: Blob(TokenService.digest(raw))) AND hash_format = 'sha256-oauth-v1' AND revoked_at IS NULL AND expires_at > \(bind: DB.time(now()))").first(decoding: R.self) else { throw TokenService.Invalid() }
        // Every request checks account, resource, revocation and *all* scope rights live.
        return try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            let g = try await lock(tx, r.grant_id)
            struct Current: Decodable { let id: Blob }
            guard try await tx.raw("SELECT id FROM mcp_tokens WHERE id = \(bind: r.id) AND revoked_at IS NULL AND expires_at > \(bind: DB.time(now()))").first(decoding: Current.self) != nil else { throw TokenService.Invalid() }
            let a: UUID, scopes: Set<String>, boundary: TokenBoundary
            do { (a, scopes, boundary) = try await live(tx, g) } catch { throw TokenService.Invalid() }
            try await tx.raw("UPDATE mcp_tokens SET last_used_at = \(bind: DB.time(now())) WHERE id = \(bind: r.id)").run()
            try await TokenService.audit(tx, account: a, id: DB.uuid(r.id.data)!, action: "oauth.token.use", at: now(), actorKind: "service")
            return TokenIdentity(id: DB.uuid(r.id.data)!, accountID: a, scopes: scopes, boundary: boundary)
        }
    }
}
