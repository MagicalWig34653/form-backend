// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import Vapor

/// Captures independent route tables and middleware during startup, before any socket is opened.
public enum ListenerRoutes {
    public static func publicSurface(_ app: Application, config: AppConfig, dashboard: () throws -> Void, protocols: () throws -> Void) throws -> any Responder {
        try capture(app) {
            try HTTPSetup.configure(app, requireSchema: true, internalRoutes: false)
            if config.publicDashboard {
                app.middleware.use(DashboardHostMiddleware(hosts: config.publicDashboardHosts, trusted: config.publicTrustedProxies))
                if let dir = config.publicDir {
                    guard let site = StaticSiteMiddleware(publicDirectory: dir) else { throw Abort(.internalServerError) }
                    app.middleware.use(site)
                }
                try dashboard()
            }
            try protocols()
        }
    }
    public static func capture(_ app: Application, register: () throws -> Void) rethrows -> any Responder {
        let savedRoutes = app.routes.all
        let savedMiddleware = app.middleware
        app.routes.all = []
        defer { app.routes.all = savedRoutes; app.middleware = savedMiddleware }
        try register()
        return app.responder.default
    }
}

/// Restricts the optional public dashboard. Proxy headers are used only from explicitly trusted peers.
public struct DashboardHostMiddleware: AsyncMiddleware {
    let hosts: Set<String>
    let trusted: [CIDR]
    public init(hosts: [String], trusted: [CIDR]) { self.hosts = Set(hosts); self.trusted = trusted }
    public func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let path = req.url.path
        if ["/api", "/mcp", "/.well-known", "/oauth", "/healthz", "/health"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return try await next.respond(to: req)
        }
        try Self.validate(req, hosts: hosts, trusted: trusted)
        return try await next.respond(to: req)
    }
    public static func validate(_ req: Request, hosts: Set<String>, trusted: [CIDR]) throws {
        var authority = req.headers["Host"]
        if let ip = req.remoteAddress?.ipAddress, let peer = IPAddr(ip), trusted.contains(where: { $0.contains(peer) }) {
            authority = req.headers["X-Forwarded-Host"]
            guard req.headers["X-Forwarded-Proto"] == ["https"] else { throw Abort(.forbidden) }
        }
        guard authority.count == 1, let value = authority.first,
              let url = URLComponents(string: "https://" + value), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              let host = url.host, hosts.contains(host), value == host + (url.port.map { ":\($0)" } ?? "") else { throw Abort(.forbidden) }
        if req.headers.contains(name: .origin) {
            guard req.headers["Origin"] == ["https://" + value] else { throw Abort(.forbidden) }
        }
    }
}

/// Both listeners use the same Application, event loops, database pool and lifecycle.
public final class DualHTTPServer: Server, @unchecked Sendable {
    private let internalServer: HTTPServer
    private let publicServer: HTTPServer
    public var onShutdown: EventLoopFuture<Void> { internalServer.onShutdown }
    public init(app: Application, config: AppConfig, internalResponder: any Responder, publicResponder: any Responder) {
        var internalConfig = app.http.server.configuration
        internalConfig.hostname = config.httpHost; internalConfig.port = config.httpPort
        var publicConfig = internalConfig; publicConfig.port = config.publicPort
        internalServer = HTTPServer(application: app, responder: internalResponder, configuration: internalConfig, on: app.eventLoopGroup)
        publicServer = HTTPServer(application: app, responder: publicResponder, configuration: publicConfig, on: app.eventLoopGroup)
    }
    public func start(address: BindAddress?) throws { throw Abort(.internalServerError, reason: "Use async server startup") }
    public func start(address: BindAddress?) async throws {
        // CLI bind overrides must not collapse or redirect the listener contract.
        guard address == nil else { throw Abort(.badRequest, reason: "Configure listener addresses using FORM_* variables") }
        try await internalServer.start(address: nil)
        do { try await publicServer.start(address: nil) }
        catch { await internalServer.shutdown(); throw error }
    }
    public func shutdown() { publicServer.shutdown(); internalServer.shutdown() }
    public func shutdown() async { await publicServer.shutdown(); await internalServer.shutdown() }
}
