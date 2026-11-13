// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum DBTLSMode: String, Sendable { case verify, disable }

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public init(variable: String, reason: String) { self.variable = variable; self.reason = reason }
    public let variable: String
    public let reason: String
    public var description: String { "invalid configuration \(variable): \(reason)" }
}

/// Startup configuration from the effective environment (system settings merged below explicit ENV).
/// Bootstrap secrets and listener configuration remain ENV-only.
/// Listener ports: FORM_PUBLIC_PORT (8080), FORM_INTERNAL_PORT (8081).
/// FORM_PUBLIC_DASHBOARD=1 requires FORM_PUBLIC_DASHBOARD_HOSTS. Per-listener trusted proxies override FORM_TRUSTED_PROXIES.
/// Variables: FORM_HTTP_HOST, FORM_PUBLIC_PORT, FORM_INTERNAL_PORT, FORM_LOG_LEVEL, FORM_DB_HOST, FORM_DB_PORT, FORM_DB_USER,
/// FORM_DB_PASSWORD (required), FORM_DB_NAME, FORM_DB_TLS (verify|disable, default verify),
/// FORM_ADMIN_REQUEST_LIMIT_IP (default 600) / FORM_ADMIN_REQUEST_LIMIT_ACCOUNT (default 300): admin API requests per minute, 1...100000.
/// FORM_BODY_BUDGET_MB (default 128): memory reserved for request bodies in flight (ingest and large admin bodies), 64...8192.
/// FORM_TRUSTED_PROXIES (CIDR list), FORM_MAIL_ALLOWED_NETS (CIDR list of private networks mail targets may use).
/// FORM_ALLOW_INSECURE_DEV (must be exactly "1" to permit FORM_DB_TLS=disable; development only),
/// FORM_SCHEMA_FILE (default db/schema-p3.sql relative to the working directory), FORM_PUBLIC_DIR (built PWA to serve, optional).
/// Admin API (all three or none): FORM_SERVER_KEY_FILE (file with the 32-byte server key, 64 hex chars, mode 0600/0400),
/// FORM_ADMIN_ORIGIN (exact origin, https unless FORM_ALLOW_INSECURE_DEV=1), FORM_RP_ID (WebAuthn RP ID, bare lowercase host).
public struct AdminConfig: Sendable, Equatable {
    public let serverKeyFile: String
    public let origin: String
    public let rpID: String
}

public struct AppConfig: Sendable, CustomStringConvertible {
    public var oauthIssuer: String?
    public var oauthAuthorizeBaseURL: String?
    public var httpHost: String
    public var httpPort: Int
    public var publicPort: Int
    public var internalSecondFactor: Bool
    public var adminRequestLimitIP = 600
    public var adminRequestLimitAccount = 300
    /// FORM_BODY_BUDGET_MB (64...8192, default 128): reserved request-body memory in flight (see `BodyBudget`).
    public var bodyBudgetBytes = BodyBudget.defaultCapacity
    public var publicDashboard: Bool
    public var publicDashboardHosts: [String]
    public var publicTrustedProxies: [CIDR]
    public var internalTrustedProxies: [CIDR]
    public var logLevel: String
    public var dbHost: String
    public var dbPort: Int
    public var dbUser: String
    public var dbPassword: String
    public var dbName: String
    public var dbTLS: DBTLSMode
    public var schemaFile: String
    /// Built PWA directory served by the backend (FORM_PUBLIC_DIR); nil = API only.
    public var publicDir: String?
    /// nil = admin API not configured (not registered).
    public var admin: AdminConfig?
    /// Reverse proxies whose `X-Forwarded-For` is believed (FORM_TRUSTED_PROXIES, comma-separated CIDRs). Empty = never.
    public var trustedProxies: [CIDR]
    /// FORM_ALLOW_INSECURE_DEV=1 (development only): permits plain SMTP/HTTP mail targets.
    public var allowInsecureDev: Bool
    /// Networks mail connections may target although they are private/loopback (FORM_MAIL_ALLOWED_NETS, CIDR list). Empty = only public addresses.
    public var mailAllowedNets: [CIDR]

    public init(env: [String: String]) throws {
        func port(_ key: String, _ def: Int) throws -> Int {
            guard let raw = env[key] else { return def }
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let v = Int(raw), (1...65535).contains(v) else { throw ConfigError(variable: key, reason: "not a port") }
            return v
        }
        func oauthOrigin(_ key: String) throws -> String? {
            guard let raw = env[key] else { return nil }
            guard let u = URLComponents(string: raw), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil,
                  u.path.isEmpty, u.query == nil, u.fragment == nil else { throw ConfigError(variable: key, reason: "expected HTTPS origin") }
            return raw
        }
        oauthIssuer = try oauthOrigin("FORM_OAUTH_ISSUER")
        oauthAuthorizeBaseURL = try oauthOrigin("FORM_OAUTH_AUTHORIZE_BASE_URL")
        httpHost = env["FORM_HTTP_HOST"] ?? "127.0.0.1"
        if httpHost.isEmpty { throw ConfigError(variable: "FORM_HTTP_HOST", reason: "must not be empty") }
        httpPort = try port("FORM_INTERNAL_PORT", 8081)
        publicPort = try port("FORM_PUBLIC_PORT", 8080)
        guard httpPort != publicPort else { throw ConfigError(variable: "FORM_INTERNAL_PORT", reason: "listeners require different ports") }
        guard [nil, "0", "1"].contains(env["FORM_PUBLIC_DASHBOARD"]) else { throw ConfigError(variable: "FORM_PUBLIC_DASHBOARD", reason: "expected 0 or 1") }
        guard [nil, "0", "1"].contains(env["FORM_INTERNAL_SECOND_FACTOR"]) else { throw ConfigError(variable: "FORM_INTERNAL_SECOND_FACTOR", reason: "expected 0 or 1") }
        internalSecondFactor = env["FORM_INTERNAL_SECOND_FACTOR"] == "1"
        func perMinute(_ key: String, _ def: Int) throws -> Int {
            guard let raw = env[key] else { return def }
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let v = Int(raw), (1...100_000).contains(v) else { throw ConfigError(variable: key, reason: "expected integer 1...100000 (requests per minute)") }
            return v
        }
        adminRequestLimitIP = try perMinute("FORM_ADMIN_REQUEST_LIMIT_IP", 600)
        adminRequestLimitAccount = try perMinute("FORM_ADMIN_REQUEST_LIMIT_ACCOUNT", 300)
        if let raw = env["FORM_BODY_BUDGET_MB"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let mb = Int(raw), (64...8192).contains(mb) else { throw ConfigError(variable: "FORM_BODY_BUDGET_MB", reason: "expected integer 64...8192 (MiB)") }
            bodyBudgetBytes = mb << 20
        }
        publicDashboard = env["FORM_PUBLIC_DASHBOARD"] == "1"
        publicDashboardHosts = (env["FORM_PUBLIC_DASHBOARD_HOSTS"] ?? "").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if !publicDashboard && publicDashboardHosts == [""] { publicDashboardHosts = [] }
        if publicDashboard || !publicDashboardHosts.isEmpty {
            guard !publicDashboardHosts.isEmpty, publicDashboardHosts.allSatisfy({ host in
                !host.isEmpty && host == host.lowercased() && host.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 } && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..")
            }) else { throw ConfigError(variable: "FORM_PUBLIC_DASHBOARD_HOSTS", reason: "explicit lowercase hosts without scheme, port or wildcards required") }
        }
        logLevel = env["FORM_LOG_LEVEL"] ?? "info"
        if !["trace", "debug", "info", "notice", "warning", "error", "critical"].contains(logLevel) {
            throw ConfigError(variable: "FORM_LOG_LEVEL", reason: "unknown level")
        }
        dbHost = env["FORM_DB_HOST"] ?? "127.0.0.1"
        dbPort = try port("FORM_DB_PORT", 3306)
        dbUser = env["FORM_DB_USER"] ?? "form"
        // Docker/Swarm secrets arrive as files: FORM_DB_PASSWORD_FILE (one line, trailing newline ignored).
        var pw = env["FORM_DB_PASSWORD"] ?? ""
        if pw.isEmpty, let file = env["FORM_DB_PASSWORD_FILE"], !file.isEmpty {
            guard let data = FileManager.default.contents(atPath: file), let text = String(data: data, encoding: .utf8) else {
                throw ConfigError(variable: "FORM_DB_PASSWORD_FILE", reason: "not readable")
            }
            pw = text.trimmingCharacters(in: .newlines)
        }
        guard !pw.isEmpty else { throw ConfigError(variable: "FORM_DB_PASSWORD", reason: "required (or FORM_DB_PASSWORD_FILE)") }
        dbPassword = pw
        dbName = env["FORM_DB_NAME"] ?? "form"
        guard let tls = DBTLSMode(rawValue: env["FORM_DB_TLS"] ?? "verify") else {
            throw ConfigError(variable: "FORM_DB_TLS", reason: "expected verify or disable")
        }
        // Unverified/plain DB connections only with an explicit development opt-in, never by default.
        if tls == .disable && env["FORM_ALLOW_INSECURE_DEV"] != "1" {
            throw ConfigError(variable: "FORM_DB_TLS", reason: "disable requires FORM_ALLOW_INSECURE_DEV=1 (development only)")
        }
        dbTLS = tls
        schemaFile = env["FORM_SCHEMA_FILE"] ?? "db/schema-p3.sql"
        if let dir = env["FORM_PUBLIC_DIR"], !dir.isEmpty { publicDir = dir } else { publicDir = nil }
        var proxies: [CIDR] = []
        for item in (env["FORM_TRUSTED_PROXIES"] ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            guard let c = CIDR(item) else { throw ConfigError(variable: "FORM_TRUSTED_PROXIES", reason: "not a list of CIDRs") }
            proxies.append(c)
        }
        trustedProxies = proxies
        func listenerProxies(_ key: String) throws -> [CIDR] {
            guard let value = env[key] else { return proxies }
            return try value.split(separator: ",").map {
                guard let cidr = CIDR($0.trimmingCharacters(in: .whitespaces)) else { throw ConfigError(variable: key, reason: "not a list of CIDRs") }
                return cidr
            }
        }
        publicTrustedProxies = try listenerProxies("FORM_PUBLIC_TRUSTED_PROXIES")
        internalTrustedProxies = try listenerProxies("FORM_INTERNAL_TRUSTED_PROXIES")
        var mailNets: [CIDR] = []
        for item in (env["FORM_MAIL_ALLOWED_NETS"] ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            guard let c = CIDR(item) else { throw ConfigError(variable: "FORM_MAIL_ALLOWED_NETS", reason: "not a list of CIDRs") }
            mailNets.append(c)
        }
        mailAllowedNets = mailNets
        allowInsecureDev = env["FORM_ALLOW_INSECURE_DEV"] == "1"
        let adminVars = ["FORM_SERVER_KEY_FILE", "FORM_ADMIN_ORIGIN", "FORM_RP_ID"]
        let present = adminVars.filter { !(env[$0] ?? "").isEmpty }
        if present.isEmpty { admin = nil }
        else {
            if let missing = adminVars.first(where: { !present.contains($0) }) { throw ConfigError(variable: missing, reason: "required when the admin API is configured") }
            let origin = env["FORM_ADMIN_ORIGIN"]!, rp = env["FORM_RP_ID"]!
            guard let comps = URLComponents(string: origin), let scheme = comps.scheme, let host = comps.host, !host.isEmpty,
                  comps.path.isEmpty, comps.query == nil, comps.fragment == nil, comps.user == nil, comps.password == nil,
                  scheme == "https" || (scheme == "http" && env["FORM_ALLOW_INSECURE_DEV"] == "1") else {
                throw ConfigError(variable: "FORM_ADMIN_ORIGIN", reason: "expected scheme://host[:port] (https; http only with FORM_ALLOW_INSECURE_DEV=1)")
            }
            guard rp == rp.lowercased(), !rp.contains("/"), !rp.contains(":"), rp == host || host.hasSuffix("." + rp) else {
                throw ConfigError(variable: "FORM_RP_ID", reason: "must be a lowercase host equal to, or a registrable suffix of, the origin host")
            }
            admin = AdminConfig(serverKeyFile: env["FORM_SERVER_KEY_FILE"]!, origin: origin, rpID: rp)
        }
    }

    /// Never contains the password.
    public var description: String {
        "AppConfig(http=\(httpHost):\(httpPort), db=\(dbUser)@\(dbHost):\(dbPort)/\(dbName), tls=\(dbTLS.rawValue), password=<redacted>)"
    }
}
