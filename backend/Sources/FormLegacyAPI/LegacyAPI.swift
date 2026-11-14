// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormIngest
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Legacy API module (ADR 0047): a thin translation of the OLD backend's public paths, request/response formats and
/// status codes (form-backend_bvk) onto the NEW ingest services. It owns no validation, storage or limit logic: every
/// call goes through `LegacyIngestBackend`, so form lookup, per-(form, client) budget, concurrency and body budget gates,
/// body limit, parsers, Origin/host rules, abuse policy, field validation, sealing and storage are the new ones.
/// Register it only on the public listener. Switch: setting `compat.legacy` / `FORM_COMPAT_LEGACY` (default on); off = every
/// legacy path answers 404 like an unknown route.
///
/// The single deliberate relaxation (inherent to the old protocol, whose keys are not imported): on the legacy paths a form
/// with NO registered signature key accepts an unsigned request. A form with a key still needs a valid signature.
public enum LegacyAPI {
    enum Style { case v1, v2 }

    /// Config calls carry (almost) no body; their signature covers an empty or tiny form.
    static let configBodyLimit = 64 * 1024

    public static func register(_ app: Application, backend: LegacyIngestBackend) {
        app.middleware.use(LegacySubmitMiddleware())

        func group(_ style: Style) -> RoutesBuilder { app.grouped(LegacyTranslation(style: style)) }
        func methodsRefused(_ g: RoutesBuilder, _ components: [PathComponent]) {
            for method in [HTTPMethod.GET, .PUT, .PATCH, .DELETE] { g.on(method, components) { _ -> Response in throw Abort(.methodNotAllowed) } }
        }

        // v1 submit: plain-text "<code> - <text>" answers; same gates and pipeline as /api/v2/submit/.
        let v1 = group(.v1)
        for path in [["endpoint"], ["endpoint", "index.php"]] {
            let c = path.map { PathComponent(stringLiteral: $0) }
            backend.submitRoutes(v1).on(.POST, c, body: .collect(maxSize: ByteCount(value: backend.maxBodyBytes))) { try await backend.submit($0) }
            methodsRefused(v1, c)
        }
        // v1 config: `{"cf-sitekey", "mode"}`, never signed.
        let cfg1: [PathComponent] = ["api", "getFormData.php"]
        v1.on(.POST, cfg1, body: .collect(maxSize: ByteCount(value: configBodyLimit))) { req in
            let c = try await backend.config(req, parameter: "z", requireSignatureIfKeyed: false)
            return json(["cf-sitekey": c.siteKey ?? NSNull(), "mode": c.testMode ? "testing" : "production"])
        }
        methodsRefused(v1, cfg1)

        let v2 = group(.v2)
        // v2 config: `{"configuration": {...}, "fields": [...]}`.
        for path in [["api", "v2", "form"], ["api", "v2", "form", "index.php"]] {
            let c = path.map { PathComponent(stringLiteral: $0) }
            v2.on(.POST, c, body: .collect(maxSize: ByteCount(value: configBodyLimit))) { req in
                let cfg = try await backend.config(req, parameter: "f", requireSignatureIfKeyed: true)
                let fields: [[String: Any]] = cfg.fields.map { ["name": $0.name, "type": $0.type, "required": $0.required, "rule": $0.rule ?? NSNull()] }
                return json(["configuration": ["cfSitekey": cfg.siteKey ?? NSNull(), "mode": cfg.testMode ? "testing" : "production",
                                               "signaturschluesselHinterlegt": cfg.hasSignatureKey] as [String: Any], "fields": fields])
            }
            methodsRefused(v2, c)
        }
        // v2 key registration cannot be honoured (the old symmetric client keys are not imported). Constant 403, no form lookup.
        for path in [["api", "v2", "key"], ["api", "v2", "key", "index.php"]] {
            let c = path.map { PathComponent(stringLiteral: $0) }
            v2.on(.POST, c) { _ -> Response in throw Abort(.forbidden) }
            methodsRefused(v2, c)
        }
    }

    // MARK: Switch

    static func enabled(_ req: Request) async throws -> Bool {
        let sql = req.db(.mysql) as! SQLDatabase
        return try await SystemSettings.value("compat.legacy", sql: sql) == "true"
    }

    /// The old SDK's encrypted client-signal headers; the new SDK never sends them.
    static func isLegacyClient(_ req: Request) -> Bool {
        req.headers.contains(name: "CLIENTUA-ENCRYPT") || req.headers.contains(name: "CLIENTIP-ENCRYPT")
    }

    // MARK: Rendering

    /// Old status code for a thrown error. Anything unexpected is a plain 500 and only its type is logged.
    static func status(of error: Error, req: Request) -> (code: Int, headers: [(name: String, value: String)]) {
        switch error {
        case let e as LegacyStatus: return (e.code, [])
        case is SubmissionInvalid: return (412, [])
        case let e as PublicProblemError: return (Int(e.statusCode), e.extraHeaders)
        case let e as AbortError where e.status.code < 500: return (Int(e.status.code), [])
        case let e as AbortError where e.status == .serviceUnavailable: return (503, [])
        default:
            req.logger.error("unhandled error", metadata: ["type": "\(type(of: error))"])
            return (500, [])
        }
    }

    static func render(_ error: Error, style: Style, req: Request) -> Response {
        let (code, headers) = status(of: error, req: req)
        let res: Response
        let reason = HTTPResponseStatus(statusCode: code).reasonPhrase
        switch style {
        case .v1:
            res = text(code, "\(code) - \(reason)")
        case .v2:
            res = Response(status: HTTPResponseStatus(statusCode: code))
            res.headers.contentType = .json
            res.body = .init(string: "{\"error\":{\"code\":\(code),\"status\":\"\(reason)\"}}")
        }
        for h in headers { res.headers.replaceOrAdd(name: h.name, value: h.value) }
        return res
    }

    static func text(_ code: Int, _ body: String) -> Response {
        let res = Response(status: HTTPResponseStatus(statusCode: code))
        res.headers.replaceOrAdd(name: .contentType, value: "text/plain; charset=utf-8")
        res.body = .init(string: body)
        return res
    }

    static func json(_ object: [String: Any]) -> Response {
        let res = Response(status: .ok)
        res.headers.contentType = .json
        res.body = .init(data: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8))
        return res
    }
}

/// Outermost middleware of every legacy route: switch (off = 404), then everything below it (gates, handler) answers in the
/// old format. Gate rejections (body budget, concurrency) are translated too.
struct LegacyTranslation: AsyncMiddleware {
    let style: LegacyAPI.Style
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard try await LegacyAPI.enabled(req) else { throw Abort(.notFound) }
        return await LegacyAPI.translate(req, style: style, next)
    }
}

extension LegacyAPI {
    static func translate(_ req: Request, style: Style, _ next: AsyncResponder) async -> Response {
        do {
            let res = try await next.respond(to: req)
            guard style == .v1, res.headers.contentType == .json, res.body.string?.hasPrefix("{\"submission\"") == true else { return res }
            return text(200, "200 - OK")
        } catch {
            return render(error, style: style, req: req)
        }
    }
}

/// Old v2 SDKs post to the NEW path `/api/v2/submit/`; they are recognised by their client-signal headers and get the old
/// error format and the unsigned-for-keyless-forms rule. Everything else (the new SDK) passes through untouched. The request
/// is only marked here; the regular gates and handler of `/api/v2/submit/` run unchanged.
struct LegacySubmitMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard req.method == .POST, ["/api/v2/submit", "/api/v2/submit/", "/api/v2/submit/index.php"].contains(req.url.path),
              LegacyAPI.isLegacyClient(req), try await LegacyAPI.enabled(req) else { return try await next.respond(to: req) }
        LegacyIngestBackend.markLegacy(req)
        return await LegacyAPI.translate(req, style: .v2, next)
    }
}
