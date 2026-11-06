// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation

/// Turns a stored connection (`connections` row: kind + safe JSON config + secret) into a transport, and validates configs
/// when an administrator creates one. The secret (SMTP password / proxy ACODE) comes from the SecretStore, never from the JSON.
public enum MailConnection {
    public struct Invalid: Error, Equatable { public let reason: String; public init(reason: String) { self.reason = reason } }

    /// Normalised safe config of an SMTP connection: host, port, security (`tls` | `starttls` | `plain`), optional username, verifyCertificate.
    public static func smtpConfig(_ json: [String: Any], password: String?, allowInsecure: Bool) throws -> SMTPConfig {
        let known: Set<String> = ["host", "port", "security", "username", "verifyCertificate", "clientName"]
        guard Set(json.keys).isSubset(of: known) else { throw Invalid(reason: "unknown member") }
        guard let host = json["host"] as? String, !host.isEmpty, host.utf8.count <= 253, host.range(of: "^[A-Za-z0-9.:-]+$", options: .regularExpression) != nil else { throw Invalid(reason: "host") }
        guard let port = json["port"] as? Int, (1...65535).contains(port) else { throw Invalid(reason: "port") }
        guard let sec = (json["security"] as? String).flatMap(SMTPConfig.Security.init(rawValue:)) else { throw Invalid(reason: "security") }
        if sec == .plain && !allowInsecure { throw Invalid(reason: "plain connections are not allowed") }
        let user = json["username"] as? String
        if let u = user, u.isEmpty || u.utf8.count > 255 || u.unicodeScalars.contains(where: { $0.value < 0x20 }) { throw Invalid(reason: "username") }
        if (user == nil) != (password == nil) { throw Invalid(reason: "username and password belong together") }
        let verify = (json["verifyCertificate"] as? Bool) ?? true
        if !verify && sec == .plain { throw Invalid(reason: "verifyCertificate") }
        let name = (json["clientName"] as? String) ?? "localhost"
        guard name.range(of: "^[A-Za-z0-9.-]{1,253}$", options: .regularExpression) != nil else { throw Invalid(reason: "clientName") }
        return SMTPConfig(host: host, port: port, security: sec, username: user, password: password, verifyCertificate: verify, clientName: name)
    }

    public static func proxyURL(_ json: [String: Any], allowInsecure: Bool) throws -> URL {
        guard Set(json.keys) == ["url"], let s = json["url"] as? String, s.utf8.count <= 2048, let u = URL(string: s) else { throw Invalid(reason: "url") }
        do { try MailProxyTransport.validate(url: u, allowInsecure: allowInsecure) } catch { throw Invalid(reason: "url must be https") }
        return u
    }

    public static func transport(kind: String, safeConfig: [String: Any], secret: String?, allowedNets: [CIDR], allowInsecure: Bool) throws -> any MailTransport {
        switch kind {
        case "smtp": return SMTPTransport(config: try smtpConfig(safeConfig, password: secret, allowInsecure: allowInsecure), allowedNets: allowedNets, allowInsecure: allowInsecure)
        case "mail-proxy":
            guard let acode = secret, !acode.isEmpty else { throw Invalid(reason: "ACODE missing") }
            return MailProxyTransport(url: try proxyURL(safeConfig, allowInsecure: allowInsecure), acode: acode, allowedNets: allowedNets, allowInsecure: allowInsecure)
        default: throw Invalid(reason: "unknown connection kind")
        }
    }
}
