// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormAuth
import FormCrypto
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Narrow facade for the legacy API module (FormLegacyAPI, ADR 0047). It only hands out what the translation needs;
/// there is no second validation or storage path: `submit` IS the new ingest pipeline, `config` reads the published form.
public struct LegacyIngestBackend: Sendable {
    let handler: SubmitHandler

    public struct Field: Sendable { public let name: String, type: String, required: Bool, rule: String? }
    public struct FormConfig: Sendable {
        public let siteKey: String?, testMode: Bool, fields: [Field], hasSignatureKey: Bool
    }

    /// The new submit pipeline. A form WITHOUT a registered signature key accepts an unsigned request (old behaviour);
    /// a form with a key still needs a valid signature. Throws exactly what the new API throws, except abuse outcomes
    /// that carry the old status as `LegacyStatus`.
    public func submit(_ req: Request) async throws -> Response { try await handler.submit(req) }

    private struct LegacyKey: StorageKey { typealias Value = Bool }
    /// Marks the request as a legacy request (set only by FormLegacyAPI, before the gates run).
    public static func markLegacy(_ req: Request) { req.storage[LegacyKey.self] = true }
    static func isLegacy(_ req: Request) -> Bool { req.storage[LegacyKey.self] == true }

    /// Route builder for legacy submit routes: marks the request, then runs the SAME concurrency gate and body budget gate
    /// (with the same pre-check) as `/api/v2/submit/`. `outer` wraps everything (the module's error translation).
    public func submitRoutes(_ builder: RoutesBuilder) -> RoutesBuilder {
        builder.grouped(LegacyMarker()).grouped(IngestGate(maxConcurrent: handler.config.maxConcurrent))
            .grouped(BodyBudgetGate(maxBytes: handler.config.maxBodyBytes) { [handler] req in try await handler.preflight(req) })
    }
    public var maxBodyBytes: Int { handler.config.maxBodyBytes }

    /// Published configuration for the old config call. Unknown/inactive/disabled forms are all 404, own budget bucket,
    /// and with `requireSignatureIfKeyed` a registered key demands a valid `/api/v2/form` signature (old v2 behaviour).
    public func config(_ req: Request, parameter: String, requireSignatureIfKeyed: Bool) async throws -> FormConfig {
        try await handler.legacyConfig(req, parameter: parameter, requireSignatureIfKeyed: requireSignatureIfKeyed)
    }
}

/// An error carrying the OLD backend's status code (the new API uses a different one for the same case).
public struct LegacyStatus: Error {
    public let code: Int
    /// Missing Turnstile token 412, failed check 406, malware 451, everything else unchanged.
    static func fromAbuse(_ abort: Abort, canonical: Data) -> Error {
        switch abort.status {
        case .preconditionFailed:
            let root = (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any]
            let token = (root?["fields"] as? [String: Any])?["cf-turnstile-response"] as? String ?? ""
            return LegacyStatus(code: token.isEmpty ? 412 : 406)
        case .unsupportedMediaType: return LegacyStatus(code: 451)
        default: return abort
        }
    }
}

extension SubmitHandler {
    /// Old config call. Unknown, inactive or disabled forms are all 404 (no enumeration signal); a form with a registered key
    /// needs a valid `/api/v2/form` signature on the v2 route, exactly like the old backend; the budget has its own bucket
    /// (`ingestcfg`) with the same limit so page renders cannot exhaust the submit budget.
    func legacyConfig(_ req: Request, parameter: String, requireSignatureIfKeyed: Bool) async throws -> LegacyIngestBackend.FormConfig {
        guard let value = try? req.query.get(String?.self, at: parameter), !value.isEmpty else { throw Abort(.unauthorized) }
        guard let formUUID = Self.canonicalUUID(value) else { throw Abort(.notFound) }
        let sql = req.db(.mysql) as! SQLDatabase
        let now = config.now()
        guard let form = try await sql.raw("""
            SELECT f.customer_id, f.active, f.current_release_id, c.state AS cstate
            FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.id = \(bind: Self.bin(formUUID))
            """).first(decoding: FormRow.self), form.active == 1, form.cstate == "active" else { throw Abort(.notFound) }
        try await enforceBudget(req, sql: sql, form: formUUID, scope: "ingestcfg")

        let keyed = try await !Self.hasNoSignatureKey(sql: sql, form: form, formUUID: formUUID, now: now)
        if requireSignatureIfKeyed, keyed {
            let body = req.body.data.map { Array($0.readableBytesView) } ?? []
            let fields: PHPValue
            var fileFields: [(String, FileField)] = []
            if let ct = req.headers.contentType, let boundary = MultipartParser.boundary(of: ct) {
                let m = try MultipartParser.parse(body, boundary: boundary)
                fields = try FormEncodedParser.parse(m.urlencoded)
                (_, fileFields) = try Uploads.prepare(m.files)
            } else { fields = try FormEncodedParser.parse(body) }
            let canonical: Data
            do { canonical = try RequestSignature.canonical(fields: fields, files: fileFields) } catch { throw Abort(.forbidden) }
            try await verifySignature(req, sql: sql, form: form, formID: value, formUUID: formUUID, canonical: canonical, now: now, route: .form)
        }

        struct HostCount: Decodable { let c: Int }
        let hostRequired = try await sql.raw("SELECT COUNT(*) AS c FROM api_host_forms WHERE customer_id = \(bind: form.customer_id) AND form_id = \(bind: Self.bin(formUUID))").first(decoding: HostCount.self)?.c ?? 0
        let externalHost = hostRequired > 0 ? try config.externalHost(req) : nil
        let releaseID = try await IngestStatistics.resolveRelease(sql: sql, customer: form.customer_id, form: formUUID, current: form.current_release_id, host: externalHost)
        let policy = try await AbuseProtection.policy(sql: sql, form: formUUID, customer: form.customer_id, release: releaseID)
        let definition = try await definitionOf(sql: sql, customer: form.customer_id, form: formUUID, release: releaseID)
        let specs = (definition?["fields"] as? [String: Any]) ?? [:]
        let fields: [LegacyIngestBackend.Field] = specs.keys.sorted().compactMap { key in
            guard let spec = specs[key] as? [String: Any], let name = spec["name"] as? String else { return nil }
            let rules = spec["validation"] as? [String: Any] ?? [:]
            return .init(name: name, type: spec["kind"] as? String ?? "text", required: (spec["required"] as? Bool) == true,
                         rule: (rules["pattern"] ?? rules["muster"]) as? String)
        }
        return .init(siteKey: policy.siteKey, testMode: policy.testMode, fields: fields, hasSignatureKey: keyed)
    }
}

struct LegacyMarker: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        LegacyIngestBackend.markLegacy(req)
        return try await next.respond(to: req)
    }
}
