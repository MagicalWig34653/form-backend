// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import Vapor

/// Gate for admin routes with large bodies (key-rotation replacement packages, hold with rewrap proof list). Authentication, Origin/CSRF
/// and the request budget run as route middleware BEFORE the body is collected (Vapor collects inside the route responder, after
/// route middleware): an anonymous request ends with 401 without a byte being buffered; an authenticated one needs a reservation in
/// the shared body budget first (413 / 503). The handler repeats the checks cheaply (session and budget are cached per request)
/// and adds permission and fresh-login checks.
enum AdminBodyGate {
    /// 32 MiB ingress packages plus Base64/JSON and the complete hold proof list.
    static let maxReplacementBytes = 64 << 20

    static func make(guardian: AuthGuard, maxBytes: Int, mutation: Bool = true) -> BodyBudgetGate {
        BodyBudgetGate(maxBytes: maxBytes) { req in
            _ = try await guardian.requireAuthenticated(req, mutation: mutation)
            try await guardian.budget(req)
        }
    }

    /// Gate for configuration routes that accept a session OR a bearer/OAuth token (drafts): the identity is resolved before the body is
    /// collected and handed to the handler through the request storage, so the token rate limit is charged once per request.
    static func make(guardian: AuthGuard, db: Database, maxBytes: Int, now: @escaping @Sendable () -> Date) -> BodyBudgetGate {
        BodyBudgetGate(maxBytes: maxBytes) { req in
            let identity = try await ConfigurationIdentity.require(req, guardian: guardian, db: db, mutation: true, now: now)
            if identity.token == nil { try await guardian.budget(req) }
            req.storage[ConfigurationIdentity.InternalKey.self] = identity
        }
    }
}
