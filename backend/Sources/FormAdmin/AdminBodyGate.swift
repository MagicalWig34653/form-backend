// SPDX-License-Identifier: AGPL-3.0-only
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

    static func make(guardian: AuthGuard, maxBytes: Int) -> BodyBudgetGate {
        BodyBudgetGate(maxBytes: maxBytes) { req in
            _ = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
        }
    }
}
