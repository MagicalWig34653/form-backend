// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import CoreFoundation
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

public enum CaptchaResult: String, Sendable { case passed, rejected, unavailable, disabled }
public protocol CaptchaVerifier: Sendable {
    func verify(token: String, secret: String, client: Client) async -> CaptchaResult
}
public struct TurnstileVerifier: CaptchaVerifier {
    public init() {}
    public static func classify(status: Int, body: Data) -> CaptchaResult {
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let flag = obj["success"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let success = obj["success"] as? Bool, obj["error-codes"] == nil || obj["error-codes"] is [String] else { return .unavailable }
        let codes = obj["error-codes"] as? [String] ?? []
        if !Set(codes).isDisjoint(with: ["internal-error", "missing-input-secret", "invalid-input-secret", "bad-request"]) { return .unavailable }
        return success ? .passed : .rejected
    }
    public func verify(token: String, secret: String, client: Client) async -> CaptchaResult {
        struct Input: Content { let secret: String; let response: String }
        do {
            // Fixed endpoint only. No configurable URL, redirects or list downloads.
            let result = try await client.post("https://challenges.cloudflare.com/turnstile/v0/siteverify") { req in
                req.timeout = .seconds(10)
                try req.content.encode(Input(secret: secret, response: token), as: .json)
            }
            return Self.classify(status: Int(result.status.code), body: result.body.map { Data(buffer: $0) } ?? Data())
        } catch { return .unavailable }
    }
}
public enum MalwareResult: String, Sendable { case clear = "hash_clear", hit = "treffer", unchecked = "nicht_geprueft", none }
/// Optional service boundary: only a SHA-256 digest leaves the ingest, never file contents.
public protocol MalwareHashScanner: Sendable { func check(sha256: String) async throws -> MalwareResult }

enum AbuseProtection {
    struct Result { let captcha: CaptchaResult; let malware: MalwareResult; let test: Bool }
    static func captchaAllowed(_ result: CaptchaResult, policy: AbusePolicy) -> Bool {
        policy.testMode || result == .passed || result == .disabled || (result == .unavailable && !policy.failClosed)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func list(_ text: String) -> [String] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]) ?? [] }
    static func blocked(ip: String, ua: String, nets: String, patterns: [String]) -> Bool {
        (IPAddr(ip).map { address in nets.split(separator: ",").contains { CIDR(String($0))?.contains(address) == true } } ?? false)
        || patterns.contains { ua.lowercased().contains($0.lowercased()) }
    }
    static func scan(_ files: [Data], hashes: Set<String>, scanner: (any MalwareHashScanner)?) async -> MalwareResult {
        if files.isEmpty { return .none }
        var unchecked = hashes.isEmpty && scanner == nil
        for file in files {
            let digest = hash(file)
            if hashes.contains(digest) { return .hit }
            if let scanner {
                let result = (try? await scanner.check(sha256: digest)) ?? .unchecked
                if result == .hit { return .hit }
                if result != .clear { unchecked = true }
            }
        }
        return unchecked ? .unchecked : .clear
    }
    static func policy(sql: SQLDatabase, form: UUID, customer: Blob, release: Blob) async throws -> AbusePolicy {
        struct Definition: Decodable { let definition_json: String }
        guard let row = try await sql.raw("SELECT fv.definition_json FROM releases r JOIN form_versions fv ON fv.customer_id=r.customer_id AND fv.form_id=r.form_id AND fv.version_no=r.form_version_no WHERE r.id=\(bind: release) AND r.customer_id=\(bind: customer) AND r.form_id=\(bind: DB.bin(form))").first(decoding: Definition.self),
              let definition = try JSONSerialization.jsonObject(with: Data(row.definition_json.utf8)) as? [String: Any] else { throw Abort(.serviceUnavailable) }
        let security = definition["security"] as? [String: Any] ?? [:]
        return try AbusePolicy(security["abuse"] as? [String: Any] ?? [:])
    }
    static func check(req: Request, config: IngestConfig, form: UUID, customer: Blob, release: Blob, canonical: Data, uploads: [Upload], now: Date, policy: AbusePolicy) async throws -> Result {
        let sql = req.db(.mysql) as! SQLDatabase
        let stored = try await SystemSettings.read(sql)
        func setting(_ key: String) throws -> String { try SettingsRegistry.resolve(SettingsRegistry.entries.first { $0.key == key }!, env: ProcessInfo.processInfo.environment, stored: stored).value! }
        let ip = config.visitorIP(req)   // verified visitor (ADR 0047) or the peer
        // Separate purpose and form scope; no raw addresses, UAs or hashes in audit.
        let identity = IPAddr(ip).map { _ in config.visitorKey(req) }.flatMap { subject in config.abuseKey.map { key in Blob(Data(HMAC<SHA256>.authenticationCode(for: Data("abuse-ip-v1|\(form.uuidString)|\(subject)".utf8), using: SymmetricKey(data: key)))) } }
        if let identity, !policy.testMode {
            struct Ban: Decodable { let c: Int }
            if try await sql.raw("SELECT COUNT(*) AS c FROM ingest_abuse_ips WHERE form_id=\(bind: DB.bin(form)) AND ip_digest=\(bind: identity) AND blocked_until>\(bind: DB.time(now))").first(decoding: Ban.self)?.c == 1 { throw Abort(.tooManyRequests) }
        }
        let listed = try blocked(ip: ip, ua: String((req.headers.first(name: .userAgent) ?? "").prefix(1024)), nets: setting("abuse.blockedNets"), patterns: list(setting("abuse.uaPatterns")))
        var captcha: CaptchaResult = .disabled
        if policy.siteKey != nil && !listed {
            let root = try JSONSerialization.jsonObject(with: canonical) as? [String: Any]
            let token = (root?["fields"] as? [String: Any])?["cf-turnstile-response"] as? String ?? ""
            if token.isEmpty || token.utf8.count > 2048 { captcha = .rejected }
            else {
                struct Secret: Decodable { let secret_ref: String }
                do {
                    if let ref = try await sql.raw("SELECT secret_ref FROM form_abuse_secrets WHERE customer_id=\(bind: customer) AND form_id=\(bind: DB.bin(form))").first(decoding: Secret.self),
                       let data = try await config.secrets.secret(ref: ref.secret_ref), let secret = String(data: data, encoding: .utf8), !secret.isEmpty {
                        captcha = await config.captcha.verify(token: token, secret: secret, client: req.client)
                    } else { captcha = .unavailable }
                } catch { captcha = .unavailable }
            }
        }
        let malware = await scan(uploads.map(\.content), hashes: Set(try list(setting("abuse.hashes"))), scanner: config.malware)
        let abuse = listed || captcha == .rejected || malware == .hit
        if abuse && !policy.testMode, let identity {
            let threshold = Int(try setting("abuse.threshold"))!, window = Int(try setting("abuse.windowSeconds"))!, duration = Int(try setting("abuse.banSeconds"))!
            try await recordHit(sql: sql, form: form, identity: identity, now: now, threshold: threshold, window: window, duration: duration)
        }
        // Malware is never delivered, even in test mode. Test bypass applies to captcha/block rules.
        if malware == .hit { throw Abort(.unsupportedMediaType) }
        if listed && !policy.testMode { throw Abort(.forbidden) }
        guard captchaAllowed(captcha, policy: policy) else { if captcha == .unavailable { throw CaptchaUnavailable() }; throw Abort(.preconditionFailed) }
        return Result(captcha: captcha, malware: malware, test: policy.testMode)
    }
    static func recordHit(sql: SQLDatabase, form: UUID, identity: Blob, now: Date, threshold: Int, window: Int, duration: Int) async throws {
        // Single atomic upsert: no lost increments across replicas; expired bans reset the whole counter.
        let at = DB.time(now), cutoff = DB.time(now.addingTimeInterval(-Double(window)))
        try await sql.raw("""
            INSERT INTO ingest_abuse_ips (form_id, ip_digest, hits, window_start, blocked_until)
            VALUES (\(bind: DB.bin(form)), \(bind: identity), 1, \(bind: at), \(bind: threshold == 1 ? DB.time(now.addingTimeInterval(Double(duration))) : nil))
            ON DUPLICATE KEY UPDATE
              hits=IF(window_start<=\(bind: cutoff) OR (blocked_until IS NOT NULL AND blocked_until<=\(bind: at)),1,hits+1),
              window_start=IF(hits=1,VALUES(window_start),window_start),
              blocked_until=IF(hits>=\(bind: threshold),\(bind: DB.time(now.addingTimeInterval(Double(duration)))),NULL)
            """).run()
        try await sql.raw("DELETE FROM ingest_abuse_ips WHERE window_start<\(bind: cutoff) AND (blocked_until IS NULL OR blocked_until<=\(bind: at))").run()
    }
}

/// The captcha service could not be reached and the form is configured to fail closed.
/// A 5xx `Abort` would be rendered as an internal error, so this is a public problem with a fixed text.
public struct CaptchaUnavailable: PublicProblemError {
    public init() {}
    public var statusCode: UInt { 503 }
    public var code: String { "captcha_unavailable" }
    public var message: String { "Die Spam-Prüfung ist vorübergehend nicht erreichbar. Bitte später erneut versuchen." }
}
