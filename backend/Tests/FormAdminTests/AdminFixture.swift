// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormCore
import FormDeploy
import FormHTTP
import FormIngest
import FormStorage
import FormMail
import FormWebhooks
import FormPersistence
import Foundation
import NIOPosix
import SQLKit
import XCTest
import XCTVapor

/// Scratch MariaDB per test with the real schema, the auth routes and the admin routes. Needs P4A_DB_PORT/P4A_DB_PASSWORD
/// (backend/integration-test.sh), otherwise skipped. Synthetic data only.
struct AdminFixture {
    static let origin = "https://admin.example.test"
    let app: Application
    let guardian: AuthGuard
    let sessions: SessionService
    let deploy: DeployService
    var sql: SQLDatabase { Persistence.sql(app) }

    static func with(webhookLimits: WebhookLimits = WebhookLimits(), singleConnection: Bool = false, secondFactorRequired: Bool = true, _ body: (AdminFixture) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["P4A_DB_PORT"].flatMap(Int.init), let pw = env["P4A_DB_PASSWORD"] else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh")
        }
        func cfg(_ db: String) throws -> AppConfig {
            try AppConfig(env: ["FORM_DB_HOST": ProcessInfo.processInfo.environment["P4A_DB_HOST"] ?? "127.0.0.1", "FORM_DB_PASSWORD": pw, "FORM_DB_PORT": "\(port)", "FORM_DB_USER": "root", "FORM_DB_NAME": db,
                                "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1"])
        }
        let name = "p5c_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        // A single loop and connection make nested pool acquisition fail deterministically.
        let group = singleConnection ? MultiThreadedEventLoopGroup(numberOfThreads: 1) : nil
        let provider: Application.EventLoopGroupProvider = group.map { .shared($0) } ?? .singleton
        let admin = try await Application.make(.testing, provider)
        Persistence.configure(admin, try cfg("p4atest"))
        let adminSQL = Persistence.sql(admin)
        try await adminSQL.raw("CREATE DATABASE \(ident: name)").run()
        func cleanup() async { try? await adminSQL.raw("DROP DATABASE IF EXISTS \(ident: name)").run(); try? await admin.asyncShutdown(); try? await group?.shutdownGracefully() }
        let app: Application
        do { app = try await Application.make(.testing, provider) } catch { await cleanup(); throw error }
        do {
            Persistence.configure(app, try cfg(name), maxConnectionsPerEventLoop: singleConnection ? 1 : 2)
            let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
            _ = try await MigrationRunner(db: Persistence.sql(app)).run(schemaFile: schema)
            _ = try await MigrationRunner(db: Persistence.sql(app)).run(schemaFile: URL(fileURLWithPath: schema).deletingLastPathComponent().appendingPathComponent("upgrades/0027-account-recovery.sql").path, name: "0027-account-recovery")
            try HTTPSetup.configure(app)
            let key = try StaticServerKey(Data(repeating: 7, count: 32))
            var auth = AuthConfig(relyingParty: RelyingParty(rpID: "admin.example.test", origin: origin), clientIP: { _ in "203.0.113.9" })
            auth.secondFactorRequired = secondFactorRequired
            auth.requestBudget = (100_000, 60)
            let guardian = FormAuth.register(app, config: auth, keys: key)
            let secrets = SecretStore(db: app.db(.mysql), keys: key)
            let loopback = [CIDR("127.0.0.0/8")!]
            struct Digest: DigestSecretProvider { let store: SecretStore; func secret(ref: String) async throws -> Data? { try await store.get(ref) } }
            struct MailSecrets: MailSecretProvider { let store: SecretStore; func secret(ref: String) async throws -> String? { try await store.get(ref).map { String(decoding: $0, as: UTF8.self) } } }
            let dispatcher = MailDispatcher(db: app.db(.mysql), secrets: MailSecrets(store: secrets), allowedNets: loopback, allowInsecure: true, logger: app.logger)
            struct DeploySecrets: DeploySecretProvider { let store: SecretStore; func secret(ref: String, on session: SQLDatabase) async throws -> String? { try await store.get(ref, on: session).map { String(decoding: $0, as: UTF8.self) } } }
            let sdkDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("sdk/php")
            let deploy = DeployService(db: app.db(.mysql), secrets: DeploySecrets(store: secrets), bundle: { try SDKBundle.load(from: sdkDir) }, allowedNets: loopback, allowInsecure: true, logger: app.logger)
            app.storage[StorageServiceKey.self] = StorageService(db: app.db(.mysql), secrets: secrets, allowedNets: loopback)
            FormAdmin.register(app, guardian: guardian, secrets: secrets, mailAllowedNets: loopback, allowInsecure: true, mail: dispatcher, deploy: deploy, sdkVersion: { try? SDKBundle.load(from: sdkDir).version }, statisticsHostResolver: { req in
                try DomainRoutes.host(req.headers.first(name: "X-Forwarded-Host") ?? "", adminHost: "")
            })
            IngestSetup.register(app, config: IngestConfig(secrets: Digest(store: secrets), mail: dispatcher, webhookLimits: webhookLimits, externalHost: { $0.headers.first(name: "X-Forwarded-Host") }))
            try await body(AdminFixture(app: app, guardian: guardian, sessions: SessionService(db: app.db(.mysql), keys: key), deploy: deploy))
        } catch {
            try? await app.asyncShutdown(); await cleanup(); throw error
        }
        try await app.asyncShutdown(); await cleanup()
    }

    func account() async throws -> UUID {
        let id = UUID()
        try await sql.raw("""
            INSERT INTO accounts (id, username, password_hash, active, mcp_allowed, rights_version, created_at)
            VALUES (\(bind: DB.bin(id)), \(bind: "u-" + id.uuidString), 'x', 1, 0, 0, '2026-10-30 12:00:00.000000')
            """).run()
        return id
    }

    func customer(state: String = "active") async throws -> UUID {
        let id = UUID()
        try await sql.raw("INSERT INTO customers (id, name, state, created_at) VALUES (\(bind: DB.bin(id)), 'c', \(bind: state), '2026-10-30 12:00:00.000000')").run()
        return id
    }

    func form(customer: UUID, name: String = "f") async throws -> UUID {
        let id = UUID()
        try await sql.raw("INSERT INTO forms (id, customer_id, name, active, created_at) VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(customer)), \(bind: name), 0, '2026-10-30 12:00:00.000000')").run()
        return id
    }

    func grant(_ account: UUID, _ permission: String, system: Bool = false, customer: UUID? = nil, form: UUID? = nil, by: UUID) async throws {
        try await sql.raw("""
            INSERT INTO permission_assignments (id, account_id, permission, scope_kind, customer_id, form_id, revision, granted_by, granted_at)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), \(bind: permission), \(bind: system ? "system" : "customer"),
              \(bind: customer.map(DB.bin)), \(bind: form.map(DB.bin)), 1, \(bind: DB.bin(by)), '2026-10-30 12:00:00.000000')
            """).run()
    }

    /// A fully authenticated session for the account (both factors skipped; the rotation itself is tested in FormAuthTests).
    func login(_ account: UUID) async throws -> TestClient {
        let (_, anon) = try await sessions.createAnonymous()
        let (token, s) = try await sessions.rotate(from: anon, to: .authenticated, accountID: account, method: "passkey+password", rightsVersion: 0)
        let csrf = try await sessions.csrfToken(for: s)!
        return TestClient(app: app, cookie: "\(SessionService.cookieName)=\(token)", csrf: csrf)
    }
}

struct TestClient {
    let app: Application
    let cookie: String?
    let csrf: String?

    func headers(csrf useCSRF: Bool = true, origin: Bool = true, json: Bool = true) -> HTTPHeaders {
        var h = HTTPHeaders()
        if let cookie { h.add(name: .cookie, value: cookie) }
        if useCSRF, let csrf { h.add(name: "X-CSRF-Token", value: csrf) }
        if origin { h.add(name: "Origin", value: AdminFixture.origin) }
        if json { h.contentType = .json }
        return h
    }

    func get(_ path: String, _ check: (XCTHTTPResponse) async throws -> Void) async throws {
        try await app.test(.GET, "admin/api/v1/\(path)", headers: headers(json: false), afterResponse: check)
    }
    func post(_ path: String, _ body: String, csrf: Bool = true, origin: Bool = true, _ check: (XCTHTTPResponse) async throws -> Void) async throws {
        try await app.test(.POST, "admin/api/v1/\(path)", headers: headers(csrf: csrf, origin: origin), body: ByteBuffer(string: body), afterResponse: check)
    }
}

extension TestClient {
    func send(_ method: HTTPMethod, _ path: String, body: String? = nil, headers extra: [String: String] = [:], csrf: Bool = true, _ check: (XCTHTTPResponse) async throws -> Void) async throws {
        var h = headers(csrf: csrf, json: body != nil)
        for (k, v) in extra { h.replaceOrAdd(name: k, value: v) }
        try await app.test(method, "admin/api/v1/\(path)", headers: h, body: body.map { ByteBuffer(string: $0) }, afterResponse: check)
    }
}

func jsonObject(_ res: XCTHTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(buffer: res.body))) as? [String: Any] ?? [:]
}
