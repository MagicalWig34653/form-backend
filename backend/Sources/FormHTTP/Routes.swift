// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormPersistence
import Vapor

struct ProblemMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let rid = UUID().uuidString.lowercased()
        let res: Response
        do {
            res = try await next.respond(to: req)
        } catch {
            let status: HTTPResponseStatus
            let code: String
            let message: String
            if let known = error as? PublicProblemError {
                if let reason = known.auditReason {
                    req.logger.info("request rejected", metadata: ["code": "\(known.code)", "reason": "\(reason)", "requestId": "\(rid)"])
                }
                let res = try Self.problem(HTTPResponseStatus(statusCode: Int(known.statusCode)),
                                           Problem(code: known.code, message: known.message, requestId: rid))
                for h in known.extraHeaders { res.headers.replaceOrAdd(name: h.name, value: h.value) }
                return res
            }
            if let abort = error as? AbortError, abort.status.code < 500 {
                status = abort.status
                (code, message) = Self.clientError(status)
            } else {
                status = .internalServerError; code = "internal_error"; message = "Interner Fehler."
                // Only the error type: descriptions may contain request data or SQL values.
                req.logger.error("unhandled error", metadata: ["type": "\(type(of: error))", "requestId": "\(rid)"])
            }
            return try Self.problem(status, Problem(code: code, message: message, requestId: rid))
        }
        res.headers.replaceOrAdd(name: "X-Request-Id", value: rid)
        // Static assets choose their own cache policy; every other response (API, auth) is never cached.
        let ownCachePolicy = res.headers.first(name: .cacheControl) != nil
        Self.harden(res, keepCachePolicy: ownCachePolicy)
        return res
    }

    /// Stable machine code and fixed German text per client-error status (status itself is preserved).
    static func clientError(_ status: HTTPResponseStatus) -> (String, String) {
        switch status.code {
        case 401: return ("unauthenticated", "Nicht angemeldet.")
        case 403: return ("forbidden", "Zugriff verweigert.")
        case 404: return ("not_found", "Nicht gefunden.")
        case 405: return ("method_not_allowed", "Methode nicht erlaubt.")
        case 409: return ("conflict", "Konflikt.")
        case 410: return ("confirmation_expired", "Bestätigung abgelaufen.")
        case 412: return ("precondition_failed", "Vorbedingung nicht erfüllt.")
        case 428: return ("precondition_required", "Vorbedingung erforderlich.")
        case 413: return ("payload_too_large", "Anfrage zu groß.")
        case 415: return ("unsupported_media_type", "Medientyp nicht unterstützt.")
        case 422: return ("validation_failed", "Anfrage nicht verarbeitbar.")
        case 429: return ("rate_limited", "Zu viele Anfragen.")
        default: return ("bad_request", "Ungültige Anfrage.")
        }
    }

    static func harden(_ res: Response, keepCachePolicy: Bool = false) {
        if !keepCachePolicy { res.headers.replaceOrAdd(name: "Cache-Control", value: "no-store") }
        res.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
    }

    static func problem(_ status: HTTPResponseStatus, _ p: Problem) throws -> Response {
        let res = Response(status: status)
        res.body = .init(data: try JSONEncoder().encode(p))
        res.headers.contentType = .jsonProblem
        res.headers.replaceOrAdd(name: "X-Request-Id", value: p.requestId)
        harden(res)
        return res
    }
}

extension HTTPMediaType {
    static let jsonProblem = HTTPMediaType(type: "application", subType: "problem+json")
}

public enum HTTPSetup {
    /// - Parameter publicDirectory: built PWA to serve (nil = API only).
    public static func configure(_ app: Application, publicDirectory: String? = nil, requireSchema: Bool = false, internalRoutes: Bool = true) throws {
        app.middleware = .init()
        app.middleware.use(ProblemMiddleware())
        if let dir = publicDirectory {
            guard let site = StaticSiteMiddleware(publicDirectory: dir) else { throw Abort(.internalServerError, reason: "public directory has no index.html") }
            app.middleware.use(site)
        }
        // Liveness: process is up. No dependencies.
        app.get("healthz") { _ in ["status": "ok"] }
        guard internalRoutes else { return }
        app.get("health") { _ in ["status": "ok"] }
        // Readiness: database answers SELECT 1.
        app.get("ready") { req async throws -> Response in
            var ok = await Persistence.ping(req.application)
            if ok && requireSchema { ok = await Persistence.schemaApplied(req.application) }
            if ok {
                let res = Response(status: .ok)
                try res.content.encode(["status": "ready"], as: .json)
                return res
            }
            return try ProblemMiddleware.problem(
                .serviceUnavailable,
                Problem(code: "not_ready", message: "Dienst nicht bereit.", requestId: UUID().uuidString.lowercased()))
        }
    }
}
