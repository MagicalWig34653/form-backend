// SPDX-License-Identifier: AGPL-3.0-only
import FormAdmin
import FormAuth
import FormCore
import FormHTTP
import FormIngest
import FormPersistence
import XCTVapor
import NIOCore

/// Uses real registrations and XCTVapor's in-memory transport; never opens a database connection.
final class ListenerTests: XCTestCase {
    struct Secrets: DigestSecretProvider {
        func secret(ref: String) async throws -> Data? { nil }
    }
    func testStrictRouteSeparationAndDashboardSwitch() async throws {
        for enabled in [false, true] {
            let app = try await Application.make(.testing)
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                try Data("dashboard".utf8).write(to: dir.appendingPathComponent("index.html"))
                let config = try AppConfig(env: ["FORM_DB_PASSWORD": "unused", "FORM_PUBLIC_DASHBOARD": enabled ? "1" : "0",
                    "FORM_PUBLIC_DASHBOARD_HOSTS": enabled ? "admin.example.test" : "", "FORM_PUBLIC_DIR": dir.path])
                Persistence.configure(app, config)
                let key = try StaticServerKey(Data(repeating: 1, count: 32))
                let auth = AuthConfig(relyingParty: RelyingParty(rpID: "example.test", origin: "https://admin.example.test"))
                func dashboard() {
                    let guardian = FormAuth.register(app, config: auth, keys: key)
                    FormAdmin.register(app, guardian: guardian, secrets: SecretStore(db: app.db(.mysql), keys: key), includePublicRoutes: false)
                }
                try HTTPSetup.configure(app, publicDirectory: dir.path)
                dashboard()
                let internalResponder = app.responder.default
                app.responder.use { _ in internalResponder }
                let guardian = AuthGuard(sessions: SessionService(db: app.db(.mysql), keys: key),
                    throttles: ThrottleService(db: app.db(.mysql), keys: key), config: auth)
                let publicResponder = try ListenerRoutes.publicSurface(app, config: config, dashboard: dashboard) {
                    try FormAdmin.registerPublic(app, guardian: guardian, trustedProxies: [], adminResponder: internalResponder)
                    IngestSetup.register(app, config: IngestConfig(secrets: Secrets()))
                    let paths = app.routes.all.map { $0.path.map { $0.description }.joined(separator: "/") }
                    XCTAssertEqual(paths.contains { $0.hasPrefix("admin/api/") }, enabled)
                    XCTAssertTrue(paths.contains("api/v2/statistics/events"))
                    XCTAssertTrue(paths.contains("mcp"))
                    XCTAssertTrue(paths.contains(".well-known/oauth-protected-resource"))
                    XCTAssertTrue(paths.contains(".well-known/oauth-authorization-server"))
                    XCTAssertTrue(paths.contains("oauth/token"))
                    XCTAssertTrue(paths.contains("oauth/register"))
                    XCTAssertEqual(paths.contains("oauth/authorize"), enabled)
                    XCTAssertEqual(paths.contains("oauth/revoke"), enabled)
                }
                try await app.test(.POST, "/oauth/token", afterResponse: { response async in XCTAssertEqual(response.status, .notFound) })
                try await app.test(.POST, "/oauth/register", afterResponse: { response async in XCTAssertEqual(response.status, .notFound) })
                // Internal ingest and MCP must be absent, even with forged proxy/Host headers.
                try await app.test(.POST, "/api/v2/submit", afterResponse: { response async in XCTAssertEqual(response.status, .notFound) })
                try await app.test(.POST, "/mcp", afterResponse: { response async in XCTAssertEqual(response.status, .notFound) })
                try await app.test(.GET, "/healthz", afterResponse: { response async in XCTAssertEqual(response.status, .ok) })
                app.responder.use { _ in publicResponder }
                try await app.test(.GET, "/healthz", afterResponse: { response async in XCTAssertEqual(response.status, .ok) })
                try await app.test(.GET, "/api/v2/submit", afterResponse: { response async in XCTAssertNotEqual(response.status, .notFound) })
                // Wrong Host is rejected before authentication/DB access; off means a true router 404.
                try await app.test(.GET, "/admin/api/v1/auth/session", headers: ["Host": "evil.test", "X-Forwarded-Host": "admin.example.test"],
                    afterResponse: { response async in XCTAssertEqual(response.status, enabled ? .forbidden : .notFound) })
                try await app.test(.GET, "/", headers: ["Host": "admin.example.test"],
                    afterResponse: { response async in XCTAssertEqual(response.status, enabled ? .ok : .notFound) })
                try await app.test(.POST, "/admin/api/v1/auth/logout", headers: ["Host": "admin.example.test", "Origin": "https://evil.test"],
                    afterResponse: { response async in XCTAssertEqual(response.status, enabled ? .forbidden : .notFound) })
                // The public route table contains only protocol routes unless explicitly enabled.
                if !enabled {
                    try await app.test(.GET, "/admin/api/v1/tenants", headers: ["Host": "admin.example.test"], afterResponse: { response async in XCTAssertEqual(response.status, .notFound) })
                    try await app.test(.GET, "/ready", afterResponse: { response async in XCTAssertEqual(response.status, .notFound) })
                }
            } catch { try? await app.asyncShutdown(); throw error }
            try await app.asyncShutdown()
        }
    }
    func testDashboardHostAndProxyPolicy() async throws {
        let app = try await Application.make(.testing)
        do {
            let hosts: Set<String> = ["admin.example.test", "second.example.test"]
            let proxy = CIDR("10.0.0.0/8")!
            func request(_ headers: HTTPHeaders, peer: String = "192.0.2.1") throws -> Request {
                Request(application: app, method: .POST, url: "/admin/api/v1/auth/logout", headers: headers,
                    remoteAddress: try SocketAddress(ipAddress: peer, port: 1234), on: app.eventLoopGroup.any())
            }
            XCTAssertNoThrow(try DashboardHostMiddleware.validate(request(["Host": "admin.example.test", "Origin": "https://admin.example.test"]), hosts: hosts, trusted: [proxy]))
            XCTAssertNoThrow(try DashboardHostMiddleware.validate(request(["Host": "second.example.test:8443", "Origin": "https://second.example.test:8443"]), hosts: hosts, trusted: [proxy]))
            XCTAssertThrowsError(try DashboardHostMiddleware.validate(request(["Host": "admin.example.test", "Origin": "https://second.example.test"]), hosts: hosts, trusted: [proxy]))
            let forwarded: HTTPHeaders = ["Host": "container", "X-Forwarded-Host": "admin.example.test", "X-Forwarded-Proto": "https", "Origin": "https://admin.example.test"]
            XCTAssertThrowsError(try DashboardHostMiddleware.validate(request(forwarded), hosts: hosts, trusted: [proxy]))
            XCTAssertNoThrow(try DashboardHostMiddleware.validate(request(forwarded, peer: "10.1.2.3"), hosts: hosts, trusted: [proxy]))
            let invalidHeaders: [HTTPHeaders] = [["Host": "admin.example.test", "Origin": "null"], ["Host": "admin.example.test", "Origin": "http://admin.example.test"], HTTPHeaders([("Host", "admin.example.test"), ("Host", "evil.test")])]
            for headers in invalidHeaders {
                XCTAssertThrowsError(try DashboardHostMiddleware.validate(request(headers), hosts: hosts, trusted: []))
            }
        }
        try await app.asyncShutdown()
    }
    func testConfigurationFailsClosed() throws {
        let base = ["FORM_DB_PASSWORD": "unused"]
        XCTAssertThrowsError(try AppConfig(env: base.merging(["FORM_PUBLIC_DASHBOARD": "1"]) { _, b in b }))
        for host in ["", "*", "https://admin.test", "admin.test:443", ",admin.test", "admin.test,"] {
            XCTAssertThrowsError(try AppConfig(env: base.merging(["FORM_PUBLIC_DASHBOARD": "1", "FORM_PUBLIC_DASHBOARD_HOSTS": host]) { _, b in b }))
        }
        XCTAssertEqual(try AppConfig(env: base).httpPort, 8081)
        XCTAssertEqual(try AppConfig(env: base).publicPort, 8080)
        XCTAssertEqual(try AppConfig(env: base.merging(["FORM_HTTP_PORT": "9001"]) { _, b in b }).httpPort, 9001)
        XCTAssertEqual(try AppConfig(env: base.merging(["FORM_HTTP_PORT": "invalid", "FORM_INTERNAL_PORT": "9002"]) { _, b in b }).httpPort, 9002)
        XCTAssertThrowsError(try AppConfig(env: base.merging(["FORM_INTERNAL_PORT": "8080"]) { _, b in b }))
        let proxies = try AppConfig(env: base.merging(["FORM_TRUSTED_PROXIES": "10.0.0.0/8", "FORM_PUBLIC_TRUSTED_PROXIES": ""]) { _, b in b })
        XCTAssertTrue(proxies.publicTrustedProxies.isEmpty)
        XCTAssertEqual(proxies.internalTrustedProxies.count, 1)
    }
}
