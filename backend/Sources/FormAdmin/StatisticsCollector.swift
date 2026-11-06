// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Public, bounded collector. Request metadata is used for authorization only, never stored in events.
public enum StatisticsCollector {
    public typealias HostResolver = @Sendable (Request) throws -> String

    public static func proxyHost(_ req: Request, trusted: [CIDR]) throws -> String {
        guard let text = req.remoteAddress?.ipAddress, let peer = IPAddr(text), trusted.contains(where: { $0.contains(peer) }) else { throw Abort(.forbidden) }
        guard req.headers["X-Forwarded-Proto"] == ["https"], req.headers["X-Forwarded-Host"].count == 1, req.headers["X-Real-IP"].count == 1,
              let client = req.headers.first(name: "X-Real-IP"), IPAddr(client) != nil,
              let host = req.headers.first(name: "X-Forwarded-Host") else { throw Abort(.badRequest) }
        do { return try DomainRoutes.host(host, adminHost: "") } catch { throw Abort(.badRequest) }
    }

    /// Syntax/proxy checks do not touch the database or any legitimate request budget.
    static func origin(_ req: Request) throws -> String {
        guard req.headers["Origin"].count == 1, let value = req.headers.first(name: "Origin"),
              value.hasPrefix("https://") else { throw Abort(.forbidden) }
        let host = String(value.dropFirst(8))
        guard (try? DomainRoutes.host(host, adminHost: "")) == host else { throw Abort(.forbidden) }
        return value
    }

    static func validBudget(_ guardian: AuthGuard, host: String) async throws {
        // Consume host first: an exhausted host cannot drain the shared budget.
        try await guardian.throttles.consume(.adminRoute, "statistics|host|\(host)", limit: 600, window: 60)
        try await guardian.throttles.consume(.adminRoute, "statistics|global", limit: 6000, window: 60)
    }

    static func invalidBudget(_ guardian: AuthGuard, req: Request, error: Error) async throws {
        guard let abort = error as? AbortError, (400..<500).contains(Int(abort.status.code)),
              abort.status != .tooManyRequests else { return }
        // Socket peer only; spoofed forwarded IPs never create budget identities.
        try await guardian.throttles.consume(.adminRoute, "statistics|invalid|\(req.remoteAddress?.ipAddress ?? "unknown")", limit: 30, window: 60)
    }

    static func register(_ app: Application, guardian: AuthGuard, trusted: [CIDR], resolver: HostResolver?, now: @escaping @Sendable () -> Date) {
        app.on(.OPTIONS, "api", "v2", "statistics", "events") { req async throws -> Response in
            do {
                let host = try resolver?(req) ?? proxyHost(req, trusted: trusted)
                let origin = try origin(req)
                guard req.headers["Access-Control-Request-Method"] == ["POST"],
                      req.headers["Access-Control-Request-Headers"].allSatisfy({ $0.lowercased().split(separator: ",").allSatisfy { $0.trimmingCharacters(in: .whitespaces) == "content-type" } }) else { throw Abort(.forbidden) }
                let allowed = try await (req.db(.mysql) as! SQLDatabase).raw("""
                    SELECT COUNT(*) AS c FROM domain_bindings d JOIN customers c ON c.id=d.customer_id
                    WHERE d.enabled=1 AND c.state='active' AND CONCAT('https://',d.host_ascii)=\(bind: origin)
                      AND (d.host_ascii=\(bind: host) OR EXISTS (
                        SELECT 1 FROM api_hosts h JOIN api_host_forms f ON f.api_host_id=h.id
                        WHERE h.enabled=1 AND h.host_ascii=\(bind: host) AND f.customer_id=d.customer_id AND f.form_id=d.form_id
                          AND (f.release_id IS NULL OR f.release_id=d.release_id)))
                    """).first(decoding: FormAdmin.CountRow.self)?.c ?? 0
                guard allowed > 0 else { throw Abort(.misdirectedRequest) }
                try await validBudget(guardian, host: host)
                let res = Response(status: .noContent)
                res.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: origin)
                res.headers.replaceOrAdd(name: "Access-Control-Allow-Methods", value: "POST")
                res.headers.replaceOrAdd(name: "Access-Control-Allow-Headers", value: "Content-Type")
                res.headers.replaceOrAdd(name: "Vary", value: "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")
                res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return res
            } catch {
                try await invalidBudget(guardian, req: req, error: error)
                throw error
            }
        }
        app.on(.POST, "api", "v2", "statistics", "events", body: .collect(maxSize: "8kb")) { req async throws -> Response in
            do {
                let host = try resolver?(req) ?? proxyHost(req, trusted: trusted)
                let origin = try origin(req)
                let obj = try MailRoutes.jsonObject(req, allowed: ["contractVersion", "proposalStatus", "eventId", "tenantId", "form", "view", "release", "domainAlias", "occurredAt", "visitPseudonym", "event", "source", "environment", "retentionMonths", "stepId", "abandonmentEvidence", "ads"])
                let ads: Bool?
                do { ads = try AdsIndicator.parse(obj["ads"]) } catch { throw Abort(.unprocessableEntity) }
                guard obj["ads"] == nil || obj["event"] as? String == "visit" else { throw Abort(.unprocessableEntity) }
                let required: Set<String> = ["contractVersion", "proposalStatus", "eventId", "tenantId", "form", "view", "release", "domainAlias", "occurredAt", "visitPseudonym", "event", "source", "environment", "retentionMonths"]
                guard required.isSubset(of: Set(obj.keys)), obj["contractVersion"] as? String == "0.1.0", obj["proposalStatus"] as? String == "VORGESCHLAGEN",
                      obj["source"] as? String == "client", let months = obj["retentionMonths"] as? Int, months == 13,
                      let kind = obj["event"] as? String, ["visit", "begin", "abandon"].contains(kind),
                      let environment = obj["environment"] as? String, ["production", "test"].contains(environment),
                      let pseudo = obj["visitPseudonym"] as? String, pseudo.range(of: "\\A[0-9a-f]{32}(?:[0-9a-f]{2}){0,16}\\z", options: .regularExpression) != nil,
                      let stamp = obj["occurredAt"] as? String,
                      let occurred = instant(stamp), abs(occurred.timeIntervalSince(now())) <= 300 else { throw Abort(.unprocessableEntity) }
                guard (kind == "abandon" && obj["abandonmentEvidence"] as? String == "client-signal") || (kind != "abandon" && obj["abandonmentEvidence"] == nil) else { throw Abort(.unprocessableEntity) }
                if let step = obj["stepId"] { guard let s = step as? String, s.range(of: "\\A[A-Za-z][A-Za-z0-9._-]{0,127}\\z", options: .regularExpression) != nil else { throw Abort(.unprocessableEntity) } }
                func uuid(_ value: Any?) throws -> UUID {
                    guard let s = value as? String, let u = UUID(uuidString: s), s == u.uuidString.lowercased() else { throw Abort(.unprocessableEntity) }; return u
                }
                let event = try uuid(obj["eventId"]), tenant = try uuid(obj["tenantId"]), alias = try uuid(obj["domainAlias"])
                func ref(_ key: String) throws -> (UUID, String, String) {
                    guard let r = obj[key] as? [String: Any], Set(r.keys) == ["id", "version", "sha256"],
                          let version = r["version"] as? String, version.range(of: "\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z", options: .regularExpression) != nil,
                          let hash = r["sha256"] as? String, hash.range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression) != nil else { throw Abort(.unprocessableEntity) }
                    return (try uuid(r["id"]), version, hash)
                }
                let form = try ref("form"), view = try ref("view"), release = try ref("release")
                let origins = [origin]
                // Exact HTTPS origin; no ports, paths, userinfo, suffix matching or forwarded Origin.
                let db = req.db(.mysql)
                try await db.transaction { conn in
                    let sql = conn as! SQLDatabase
                    struct Binding: Decodable { let host_ascii: String; let manifest: String; let hash: Blob; let version: Int }
                    guard let b = try await sql.raw("""
                        SELECT d.host_ascii, r.dependency_manifest_json AS manifest, r.manifest_sha256 AS hash, r.release_version_no AS version
                        FROM domain_bindings d JOIN customers c ON c.id = d.customer_id
                        JOIN releases r ON r.customer_id = d.customer_id AND r.form_id = d.form_id AND r.id = d.release_id
                        WHERE d.id = \(bind: DB.bin(alias)) AND d.customer_id = \(bind: DB.bin(tenant)) AND d.form_id = \(bind: DB.bin(form.0))
                          AND d.release_id = \(bind: DB.bin(release.0)) AND d.view_id = \(bind: DB.bin(view.0))
                          AND d.enabled = 1 AND d.environment = \(bind: environment) AND c.state = 'active' FOR UPDATE
                        """).first(decoding: Binding.self) else { throw Abort(.misdirectedRequest) }
                    guard origins[0] == "https://\(b.host_ascii)" else { throw Abort(.forbidden) }
                    if host != b.host_ascii {
                        let allowed = try await sql.raw("""
                            SELECT COUNT(*) AS c FROM api_hosts h JOIN api_host_forms f ON f.api_host_id = h.id
                            WHERE h.host_ascii = \(bind: host) AND h.enabled = 1 AND f.customer_id = \(bind: DB.bin(tenant)) AND f.form_id = \(bind: DB.bin(form.0))
                              AND (f.release_id IS NULL OR f.release_id = \(bind: DB.bin(release.0)))
                            """).first(decoding: FormAdmin.CountRow.self)?.c == 1
                        guard allowed else { throw Abort(.misdirectedRequest) }
                    }
                    guard let manifest = try JSONSerialization.jsonObject(with: Data(b.manifest.utf8)) as? [String: Any] else { throw Abort(.internalServerError) }
                    func matches(_ value: Any?, _ r: (UUID, String, String)) -> Bool {
                        guard let v = value as? [String: Any] else { return false }
                        return v["id"] as? String == r.0.uuidString.lowercased() && v["version"] as? String == r.1 && v["sha256"] as? String == r.2
                    }
                    guard matches(manifest["form"], form), (manifest["views"] as? [Any] ?? []).contains(where: { matches($0, view) }),
                          release.1 == "\(b.version).0.0", release.2 == b.hash.data.map({ String(format: "%02x", $0) }).joined() else { throw Abort(.unprocessableEntity) }
                    let bytes = stride(from: 0, to: pseudo.count, by: 2).map { i -> UInt8 in
                        let start = pseudo.index(pseudo.startIndex, offsetBy: i); return UInt8(pseudo[start..<pseudo.index(start, offsetBy: 2)], radix: 16)!
                    }
                    let p = Blob(Data(bytes))
                    // Duplicate event IDs cannot be reused for another visit; visit+kind replay returns the original row unchanged.
                    struct ID: Decodable { let id: Blob }
                    let prior = try await sql.raw("""
                        SELECT id FROM statistics_events WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form.0))
                          AND release_id = \(bind: DB.bin(release.0)) AND view_id = \(bind: DB.bin(view.0)) AND domain_alias = \(bind: DB.bin(alias))
                          AND environment = \(bind: environment) AND visit_pseudonym = \(bind: p) AND event_kind = \(bind: kind)
                        """).first(decoding: ID.self)
                    if prior == nil {
                        do {
                            try await sql.raw("""
                                INSERT INTO statistics_events (id,customer_id,form_id,release_id,view_id,domain_alias,visit_pseudonym,event_kind,source,environment,abandonment_evidence,step_id,occurred_at,expires_at,ads_present)
                                VALUES (\(bind: DB.bin(event)),\(bind: DB.bin(tenant)),\(bind: DB.bin(form.0)),\(bind: DB.bin(release.0)),\(bind: DB.bin(view.0)),\(bind: DB.bin(alias)),\(bind: p),\(bind: kind),'client',\(bind: environment),\(bind: kind == "abandon" ? "client-signal" : nil),\(bind: obj["stepId"] as? String),\(bind: DB.time(occurred)), DATE_ADD(CAST(\(bind: DB.time(occurred)) AS DATETIME(6)), INTERVAL 13 MONTH),\(bind: ads))
                                """).run()
                        } catch { if DB.isDuplicateKey(error) { throw Abort(.conflict) }; throw error }
                    }
                    // Commit only after all validation succeeds; a budget rejection rolls the event back.
                    try await validBudget(guardian, host: host)
                }
                let response = Response(status: .noContent)
                response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                response.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: origins[0])
                response.headers.replaceOrAdd(name: "Vary", value: "Origin")
                return response
            } catch {
                try await invalidBudget(guardian, req: req, error: error)
                throw error
            }
        }
    }

    static func instant(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
