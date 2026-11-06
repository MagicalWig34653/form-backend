// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import Vapor

/// `csrf_invalid` (403): missing/wrong CSRF token or Origin. Never counts as a failed password/factor attempt.
public struct CSRFInvalid: PublicProblemError {
    public init() {}
    public var statusCode: UInt { 403 }
    public var code: String { "csrf_invalid" }
    public var message: String { "Anfrage abgelehnt." }
}

public struct AuthConfig: Sendable {
    public var listener = "internal"
    private var internalSecondFactor = false
    /// Public dashboard authentication cannot opt out of the password factor.
    public var secondFactorRequired: Bool {
        get { listener == "public" || internalSecondFactor }
        set { internalSecondFactor = newValue }
    }
    public var relyingParty: RelyingParty
    /// Exact admin origin (scheme://host[:port]); `Origin` of every cookie-based mutation must equal it.
    public var csrfHosts: Set<String> = []
    public var adminOrigin: String { relyingParty.origin }
    /// Client address used for throttles. Default: the TCP peer. `X-Forwarded-For` is deliberately NOT read
    /// unless the explicit trusted-proxy initializer is used.
    public var clientIP: @Sendable (Request) -> String
    public var requestBudget: (limit: Int, window: TimeInterval) = (120, 60)
    public var oauthIssuer: String?
    public var oauthAuthorizeBaseURL: String?
    public var issuer: String { oauthIssuer ?? adminOrigin }
    public var authorizeBaseURL: String { oauthAuthorizeBaseURL ?? adminOrigin }
    public var loginBudget: (limit: Int, window: TimeInterval) = (10, 60)

    public init(relyingParty: RelyingParty, clientIP: @escaping @Sendable (Request) -> String = { $0.remoteAddress?.ipAddress ?? "unknown" }) {
        self.relyingParty = relyingParty; self.clientIP = clientIP
    }

    /// Client address behind trusted reverse proxies (see `ClientIPResolver`).
    public init(relyingParty: RelyingParty, trustedProxies: [CIDR]) {
        let resolver = ClientIPResolver(trusted: trustedProxies)
        self.init(relyingParty: relyingParty, clientIP: { req in
            resolver.resolve(peer: req.remoteAddress?.ipAddress, forwardedFor: Self.forwardedFor(req.headers))
        })
    }

    /// ALL `X-Forwarded-For` lines joined in order: a proxy that appends a second header line must not let the client's own line win (review M1).
    static func forwardedFor(_ headers: HTTPHeaders) -> String? {
        let lines = headers[canonicalForm: "x-forwarded-for"]
        return lines.isEmpty ? nil : lines.joined(separator: ", ")
    }
}

/// Session/CSRF/Origin handling shared by the auth routes and (via `AuthGuard.requireAuthenticated`) every later
/// admin route. Rights are checked separately with `PermissionService`.
public struct AuthGuard: Sendable {
    public let sessions: SessionService
    public let throttles: ThrottleService
    public let config: AuthConfig

    public init(sessions: SessionService, throttles: ThrottleService, config: AuthConfig) {
        self.sessions = sessions; self.throttles = throttles; self.config = config
    }

    static func cookieHeader(token: String) -> String {
        "\(SessionService.cookieName)=\(token); Path=/; Secure; HttpOnly; SameSite=Lax"
    }
    static let clearCookieHeader = "\(SessionService.cookieName)=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0"

    public func setCookie(_ res: Response, token: String) { res.headers.replaceOrAdd(name: .setCookie, value: Self.cookieHeader(token: token)) }

    /// Counts the request once per applicable budget (general; login endpoints additionally).
    public func budget(_ req: Request, login: Bool = false) async throws {
        let ip = config.clientIP(req)
        try await throttles.consume(.adminRoute, "ip|\(ip)", limit: config.requestBudget.limit, window: config.requestBudget.window)
        if login { try await throttles.consume(.adminRoute, "login|\(ip)", limit: config.loginBudget.limit, window: config.loginBudget.window) }
    }

    /// The session of the request cookie, if valid.
    public func currentSession(_ req: Request) async throws -> SessionRecord? {
        guard let token = req.cookies[SessionService.cookieName]?.string else { return nil }
        guard let session = try await sessions.resolve(token: token) else { return nil }
        guard session.state != .authenticated || !config.secondFactorRequired || (session.authMethod == "passkey+password" || (config.listener == "public" && ["passkey+totp", "password+totp"].contains(session.authMethod ?? ""))) else { return nil }
        return session
    }

    /// For cookie-based mutations: exact Origin and a valid CSRF token for this session.
    public func requireCSRF(_ req: Request, session: SessionRecord) async throws {
        let origins = req.headers["Origin"]
        let origin = origins.first ?? ""
        let parts = URLComponents(string: origin)
        let permitted = config.csrfHosts.isEmpty ? origin == config.adminOrigin :
            (parts?.scheme == "https" && parts?.host.map { config.csrfHosts.contains($0) } == true && parts?.user == nil && parts?.password == nil && parts?.path == "" && parts?.query == nil && parts?.fragment == nil)
        guard origins.count == 1, permitted,
              try await sessions.verifyCSRF(req.headers.first(name: "X-CSRF-Token"), for: session) else { throw CSRFInvalid() }
    }

    /// Sensitive actions need a recent login (`maxAge`, default 5 min, anmeldung.md); otherwise `reauthentication_required`.
    public func requireFreshAuthentication(_ session: SessionRecord, maxAge: TimeInterval = 300, now: Date) async throws {
        guard let at = try await sessions.authenticatedAt(session), now.timeIntervalSince(at) <= maxAge else { throw ReauthenticationRequired() }
    }

    /// A fully authenticated session (both factors); for mutations also Origin + CSRF. 401 otherwise.
    public func requireAuthenticated(_ req: Request, mutation: Bool) async throws -> SessionRecord {
        guard !req.headers.contains(name: .authorization), let s = try await currentSession(req), s.state == .authenticated, s.accountID != nil else { throw Abort(.unauthorized) }
        if mutation { try await requireCSRF(req, session: s) }
        return s
    }
}
