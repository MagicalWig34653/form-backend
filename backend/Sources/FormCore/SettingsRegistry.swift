// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// System settings contract. Values use canonical text; integer text never accepts coercion.
public enum SettingsRegistry {
    public struct Entry: Sendable, Encodable {
        public let key: String, group: String, type: String, defaultValue: String, envName: String
        public let minimum: Int?, maximum: Int?
        public let restartRequired: Bool, sensitive: Bool
        public init(_ key: String, _ group: String, _ type: String, _ fallback: String, _ env: String,
                    min: Int? = nil, max: Int? = nil, restart: Bool = true, sensitive: Bool = false) {
            self.key = key; self.group = group; self.type = type; defaultValue = fallback; envName = env
            minimum = min; maximum = max; restartRequired = restart; self.sensitive = sensitive
        }
        public func validate(_ value: String) throws {
            guard value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Invalid() }
            switch type {
            case "boolean": guard ["true", "false"].contains(value) else { throw Invalid() }
            case "hashes", "patterns", "recipients":
                guard let data = value.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [String], list.count <= 200 else { throw Invalid() }
                for item in list {
                    guard !item.isEmpty, item.utf8.count <= 200 else { throw Invalid() }
                    if type == "hashes" { guard item.count == 64, item.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Invalid() } }
                    // UA patterns are literal, case-insensitive substrings, avoiding regex backtracking.
                    if type == "recipients" { guard item.contains("@"), !item.contains(where: { $0.isWhitespace }), !item.contains(",") else { throw Invalid() } }
                }
            case "integer":
                guard let n = Int(value), String(n) == value, n >= minimum!, n <= maximum! else { throw Invalid() }
            case "mailbox":
                if value.isEmpty { return }
                let parts = value.split(separator: "@", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0].count <= 64, !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains(".."),
                      parts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
                      value.range(of: "^[A-Za-z0-9._%+!-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}$", options: .regularExpression) != nil, value.count <= 254 else { throw Invalid() }
            case "uuid": guard value.isEmpty || UUID(uuidString: value) != nil else { throw Invalid() }
            case "cidrs":
                if !value.isEmpty { for item in value.split(separator: ",", omittingEmptySubsequences: false) {
                    guard CIDR(String(item)) != nil else { throw Invalid() }
                } }
            case "level": guard ["trace", "debug", "info", "notice", "warning", "error", "critical"].contains(value) else { throw Invalid() }
            case "origin":
                guard let u = URLComponents(string: value), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil,
                      u.path.isEmpty, u.query == nil, u.fragment == nil else { throw Invalid() }
            case "host":
                guard !value.isEmpty, value == value.lowercased(), value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { throw Invalid() }
            case "path": guard value.hasPrefix("/"), !value.contains("..") else { throw Invalid() }
            default: throw Invalid()
            }
        }
    }
    public struct Invalid: Error { public init() {} }
    public static let entries: [Entry] = [
        .init("ops.threshold", "Limits", "integer", "1", "FORM_OPS_THRESHOLD", min: 1, max: 2, restart: false),
        .init("ops.intervalSeconds", "Limits", "integer", "900", "FORM_OPS_INTERVAL_SECONDS", min: 60, max: 86400, restart: false),
        .init("ops.retentionDays", "Limits", "integer", "30", "FORM_OPS_RETENTION_DAYS", min: 1, max: 365, restart: false),
        .init("ops.recipient", "Limits", "mailbox", "", "FORM_OPS_RECIPIENT", restart: false),
        .init("ops.sender", "Limits", "mailbox", "", "FORM_OPS_SENDER", restart: false),
        .init("ops.connection", "Limits", "uuid", "", "FORM_OPS_CONNECTION", restart: false),
        .init("abuse.blockedNets", "Missbrauchsschutz", "cidrs", "", "FORM_ABUSE_BLOCKED_NETS", restart: false),
        .init("abuse.uaPatterns", "Missbrauchsschutz", "patterns", "[]", "FORM_ABUSE_UA_PATTERNS", restart: false),
        .init("abuse.hashes", "Missbrauchsschutz", "hashes", "[]", "FORM_ABUSE_HASHES", restart: false),
        .init("abuse.threshold", "Missbrauchsschutz", "integer", "5", "FORM_ABUSE_THRESHOLD", min: 1, max: 1000, restart: false),
        .init("abuse.windowSeconds", "Missbrauchsschutz", "integer", "600", "FORM_ABUSE_WINDOW_SECONDS", min: 1, max: 86400, restart: false),
        .init("abuse.banSeconds", "Missbrauchsschutz", "integer", "7200", "FORM_ABUSE_BAN_SECONDS", min: 1, max: 86400, restart: false),
        .init("mail.restricted", "Missbrauchsschutz", "boolean", "false", "FORM_MAIL_RESTRICTED", restart: false),
        .init("mail.allowedRecipients", "Missbrauchsschutz", "recipients", "[]", "FORM_MAIL_ALLOWED_RECIPIENTS", restart: false),
        .init("setup.step", "Einrichtung", "integer", "0", "", min: 0, max: 5, restart: false),
        .init("setup.mailPending", "Einrichtung", "boolean", "true", "", restart: false),
        .init("setup.completed", "Einrichtung", "boolean", "false", "", restart: false),
        .init("auth.freshLoginMinutes", "Anmeldung", "integer", "30", "", min: 1, max: 120, restart: false),
        .init("auth.sessionIdleMinutes", "Anmeldung", "integer", "120", "", min: 5, max: 720, restart: false),
        .init("migration.enabled", "Umstieg", "boolean", "true", "", restart: false),
        .init("compat.legacy", "Umstieg", "boolean", "true", "FORM_COMPAT_LEGACY", restart: false),
        .init("migration.allowedNets", "Umstieg", "cidrs", "", "FORM_MIGRATION_ALLOWED_NETS", restart: false),
        .init("mail.allowedNets", "Mail-Netze", "cidrs", "", "FORM_MAIL_ALLOWED_NETS"),
        .init("log.level", "Limits", "level", "info", "FORM_LOG_LEVEL"),
        .init("sdk.directory", "Speicher", "path", "/app/sdk", "FORM_SDK_DIR"),
        .init("webhook.perForm", "Webhook-Limits", "integer", "5", "FORM_WEBHOOK_MAX_PER_FORM", min: 0, max: 10000, restart: false),
        .init("webhook.perCustomer", "Webhook-Limits", "integer", "20", "FORM_WEBHOOK_MAX_PER_CUSTOMER", min: 0, max: 100000, restart: false),
        .init("webhook.backlog", "Webhook-Limits", "integer", "1000", "FORM_WEBHOOK_MAX_BACKLOG_PER_CUSTOMER", min: 0, max: 10000000, restart: false),
        .init("mcp.requestsPerMinute", "MCP-Token-Ratelimit", "integer", "60", "FORM_MCP_TOKEN_RATE_LIMIT", min: 1, max: 100000, restart: false),
        .init("ingest.requestsPerMinute", "Ingest-Ratelimit", "integer", "60", "FORM_INGEST_REQUESTS_PER_MINUTE", min: 0, max: 1000000, restart: false),
        .init("oauth.authorizeBaseURL", "MCP-OAuth", "origin", "", "FORM_OAUTH_AUTHORIZE_BASE_URL"),
        .init("oauth.registrationsPerHour", "MCP-OAuth", "integer", "200", "FORM_OAUTH_REGISTRATIONS_PER_HOUR", min: 1, max: 100000, restart: false),
        .init("oauth.maxUnusedClients", "MCP-OAuth", "integer", "1000", "FORM_OAUTH_MAX_UNUSED_CLIENTS", min: 1, max: 100000, restart: false),
        .init("oauth.issuer", "MCP-OAuth", "origin", "", "FORM_OAUTH_ISSUER"),
        .init("admin.origin", "Hosts", "origin", "", "FORM_ADMIN_ORIGIN"),
        .init("admin.rpID", "Hosts", "host", "", "FORM_RP_ID")
    ]
    public struct Resolved: Sendable, Encodable {
        public let definition: Entry
        public let value: String?, source: String, locked: Bool
    }
    public static func resolve(_ entry: Entry, env: [String: String], stored: [String: String]) throws -> Resolved {
        let source = env[entry.envName] != nil ? "env" : stored[entry.key] != nil ? "db" : "default"
        let value = env[entry.envName] ?? stored[entry.key] ?? entry.defaultValue
        // Bootstrap validation already handles development HTTP origins; never reinterpret ENV here.
        if !(source == "env" && entry.type == "origin") && !(value.isEmpty && entry.defaultValue.isEmpty) { try entry.validate(value) }
        return Resolved(definition: entry, value: entry.sensitive ? nil : value, source: source, locked: source == "env")
    }
    /// Deliberately contains keys only, including for future sensitive entries.
    public static func auditDetails(keys: [String]) -> String {
        String(data: JCS.canonicalize(.object(["keys": .array(keys.sorted().map(JSONValue.string))])), encoding: .utf8)!
    }
}
