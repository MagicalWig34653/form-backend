// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormAdmin
import FormAuth
import FormCore
import FormDeploy
import FormHTTP
import FormStorage
import FormIngest
import FormLegacyAPI
import FormMigration
import FormWebhooks
import FormMail
import FormFlow
import FormPersistence
import Foundation
import Vapor
import SQLKit

/// Adapts the encrypted secret store to the ingest's provider protocol.
struct StoreDigestSecrets: DigestSecretProvider {
    let store: SecretStore
    func secret(ref: String) async throws -> Data? { try await store.get(ref) }
}

/// Adapts the encrypted secret store to the mail dispatcher (SMTP password / proxy ACODE).
struct StoreMailSecrets: MailSecretProvider {
    let store: SecretStore
    func secret(ref: String) async throws -> String? { try await store.get(ref).map { String(decoding: $0, as: UTF8.self) } }
}

/// Adapts the encrypted secret store to the SDK deployer (FTP password).
struct StoreDeploySecrets: DeploySecretProvider {
    let store: SecretStore
    func secret(ref: String, on session: SQLDatabase) async throws -> String? { try await store.get(ref, on: session).map { String(decoding: $0, as: UTF8.self) } }
}

struct MigrateCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Applies the DDL schema (idempotent) and records it in schema_migrations." }
    let schemaFile: String
    func run(using context: CommandContext, signature: Signature) async throws {
        let outcome = try await MigrationRunner(db: Persistence.sql(context.application)).run(schemaFile: schemaFile)
        context.console.print("migration: \(outcome)")
        let missing = try await MigrationRunner(db: Persistence.sql(context.application)).missingTables(schemaFile: schemaFile)
        if !missing.isEmpty { throw MigrationError.missingTables(missing) }
        for name in MigrationRunner.upgrades {
            let r = try await MigrationRunner(db: Persistence.sql(context.application)).run(schemaFile: MigrationRunner.upgradeFile(name, schemaFile: schemaFile), name: name)
            context.console.print("upgrade \(name): \(r)")
        }
        // ADR 0046: report published patterns the linear dialect cannot evaluate (their forms reject non-empty values). Read-only, never fails the upgrade.
        if let findings = try? await PatternCompatibility.scan(sql: Persistence.sql(context.application)) {
            for f in findings { context.console.print("WARNING pattern-incompatible: form=\(f.form) field=\(f.field) reason=\(f.reason); adjust the pattern before rollout (docs/BETRIEB.md)") }
            context.console.print("pattern check: \(findings.isEmpty ? "all published patterns supported" : "\(findings.count) incompatible pattern(s)")")
        }
    }
}

/// Creates the very first administrator (refuses when any account exists) and prints a one-time passkey enrollment link.
/// Password: FORM_BOOTSTRAP_PASSWORD_FILE (a Docker secret) or generated and printed once.
struct BootstrapAdminCommand: AsyncCommand {
    struct Signature: CommandSignature { @Argument(name: "username") var username: String }
    var help: String { "Creates the first administrator account and a one-time enrollment link for its passkey." }
    let origin: String?
    let requiresPassword: Bool
    func run(using context: CommandContext, signature: Signature) async throws {
        var password = ""
        var generated = false
        if let file = ProcessInfo.processInfo.environment["FORM_BOOTSTRAP_PASSWORD_FILE"], !file.isEmpty {
            guard let d = FileManager.default.contents(atPath: file), let t = String(data: d, encoding: .utf8) else { throw Abort(.internalServerError, reason: "FORM_BOOTSTRAP_PASSWORD_FILE not readable") }
            password = t.trimmingCharacters(in: .newlines)
        } else if requiresPassword {
            password = Data((0..<18).map { _ in UInt8.random(in: 0...255) }).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: "x").replacingOccurrences(of: "+", with: "y")
            generated = true
        }
        guard !requiresPassword || !password.isEmpty else { throw Bootstrap.Failure.passwordTooShort }
        let r = try await Bootstrap.createFirstAdmin(db: context.application.db(.mysql), username: signature.username, password: password)
        context.console.print("account created: \(signature.username)")
        if generated { context.console.print("initial password (shown once, second factor after the passkey): \(password)") }
        context.console.print("passkey enrollment link (valid 24 h, single use): \(origin ?? "<FORM_ADMIN_ORIGIN>")/setup#\(r.token)")
    }
}

/// Issues a new one-time enrollment link for an existing account (replacement device, lost key).
struct EnrollPasskeyCommand: AsyncCommand {
    struct Signature: CommandSignature { @Argument(name: "username") var username: String }
    var help: String { "Prints a new one-time passkey enrollment link for an existing account." }
    let origin: String?
    func run(using context: CommandContext, signature: Signature) async throws {
        let token = try await Bootstrap.issueEnrollment(db: context.application.db(.mysql), username: signature.username)
        context.console.print("passkey enrollment link (valid 24 h, single use): \(origin ?? "<FORM_ADMIN_ORIGIN>")/setup#\(token)")
    }
}

// Connect to the DB with ENV-only bootstrap values before resolving optional admin settings.
let processEnvironment = ProcessInfo.processInfo.environment
var bootstrapEnvironment = processEnvironment
if processEnvironment["FORM_SERVER_KEY_FILE"] != nil {
    for key in ["FORM_SERVER_KEY_FILE", "FORM_ADMIN_ORIGIN", "FORM_RP_ID"] { bootstrapEnvironment.removeValue(forKey: key) }
}
var dashboardRegistration: (() throws -> Void)?
var publicRegistration: (() throws -> Void)?
let config: AppConfig
do { config = try AppConfig(env: bootstrapEnvironment) } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))  // names the variable, never a value
    exit(64)
}
var env = try Environment.detect()
// Vapor's logger bootstrap reads LOG_LEVEL; honour FORM_LOG_LEVEL via the application logger below.
let app = try await Application.make(env)
app.logger.logLevel = Logger.Level(rawValue: config.logLevel) ?? .info
app.bodyBudget = BodyBudget(capacity: config.bodyBudgetBytes)   // shared by ingest and the large admin bodies on both listeners
app.http.server.configuration.hostname = config.httpHost
app.http.server.configuration.port = config.httpPort
Persistence.configure(app, config)
do { try HTTPSetup.configure(app, publicDirectory: config.publicDir, requireSchema: true) } catch {
    FileHandle.standardError.write(Data("FORM_PUBLIC_DIR is set but has no index.html\n".utf8))
    exit(78)
}
// The migrate command needs neither routes nor the key; and the catalog check needs the migrated schema.
let isMigrate = ["migrate", "migrate-legacy", "bootstrap-admin", "enroll-passkey"].contains(CommandLine.arguments.dropFirst().first ?? "")
if ProcessInfo.processInfo.environment["FORM_SERVER_KEY_FILE"] != nil, !isMigrate {
    // Admin API: server key from the operating environment (ADR 0008 F5). Fail closed on any problem.
    do {
        let effectiveEnvironment = try await SystemSettings.environment(Persistence.sql(app), env: ProcessInfo.processInfo.environment)
        let storedSettings = try await SystemSettings.read(Persistence.sql(app))
        for entry in SettingsRegistry.entries { _ = try SettingsRegistry.resolve(entry, env: ProcessInfo.processInfo.environment, stored: storedSettings) }
        let config = try AppConfig(env: effectiveEnvironment)
        guard let admin = config.admin else { throw Abort(.internalServerError) }
        app.logger.logLevel = Logger.Level(rawValue: config.logLevel) ?? .info
        let keys = try FileServerKey(path: admin.serverKeyFile)
        try await PermissionCatalog.verify(Persistence.sql(app))
        var internalAuth = AuthConfig(relyingParty: RelyingParty(rpID: admin.rpID, origin: admin.origin), trustedProxies: config.internalTrustedProxies)
        let issuer = try await SystemSettings.value("oauth.issuer", sql: Persistence.sql(app))
        let authorizeBase = try await SystemSettings.value("oauth.authorizeBaseURL", sql: Persistence.sql(app))
        internalAuth.oauthIssuer = issuer.isEmpty ? nil : issuer
        internalAuth.oauthAuthorizeBaseURL = authorizeBase.isEmpty ? nil : authorizeBase
        if let base = internalAuth.oauthAuthorizeBaseURL, base != admin.origin {
            guard config.publicDashboard, let host = URLComponents(string: base)?.host, config.publicDashboardHosts.contains(host) else {
                throw ConfigError(variable: "FORM_OAUTH_AUTHORIZE_BASE_URL", reason: "must be admin origin or an enabled public dashboard origin")
            }
        }
        internalAuth.secondFactorRequired = config.internalSecondFactor
        internalAuth.requestBudget = (config.adminRequestLimitIP, 60)
        internalAuth.accountRequestBudget = (config.adminRequestLimitAccount, 60)
        let guardian = FormAuth.register(app, config: internalAuth, keys: keys)
        let secrets = SecretStore(db: app.db(.mysql), keys: keys)
        let storage = StorageService(db: app.db(.mysql), secrets: secrets, allowedNets: config.mailAllowedNets)
        app.storage[StorageServiceKey.self] = storage
        app.lifecycle.use(StorageScheduler(service: storage))
        let mail = MailDispatcher(db: app.db(.mysql), secrets: StoreMailSecrets(store: secrets), allowedNets: config.mailAllowedNets,
                                  allowInsecure: config.allowInsecureDev, logger: app.logger, adminOrigin: guardian.config.adminOrigin)
        // The SDK shipped with this server (ADR 0011): FORM_SDK_DIR, default /app/sdk.
        let sdkDir = URL(fileURLWithPath: effectiveEnvironment["FORM_SDK_DIR"] ?? "/app/sdk")
        let deploy = DeployService(db: app.db(.mysql), secrets: StoreDeploySecrets(store: secrets), bundle: { try SDKBundle.load(from: sdkDir) },
                                   allowedNets: config.mailAllowedNets, allowInsecure: config.allowInsecureDev, logger: app.logger)
        FormAdmin.register(app, guardian: guardian, secrets: secrets, mailAllowedNets: config.mailAllowedNets, allowInsecure: config.allowInsecureDev, mail: mail,
                           deploy: deploy, sdkVersion: { try? SDKBundle.load(from: sdkDir).version }, includePublicRoutes: false, statisticsTrustedProxies: config.internalTrustedProxies)
        SetupMigrationRoutes.register(app, guardian: guardian, secrets: secrets, allowInsecure: config.allowInsecureDev)
        dashboardRegistration = {
            var authConfig = AuthConfig(relyingParty: guardian.config.relyingParty, trustedProxies: config.publicTrustedProxies)
            authConfig.oauthIssuer = guardian.config.oauthIssuer
            authConfig.oauthAuthorizeBaseURL = guardian.config.oauthAuthorizeBaseURL
            authConfig.listener = "public"
            authConfig.secondFactorRequired = true
            authConfig.requestBudget = (config.adminRequestLimitIP, 60)
            authConfig.accountRequestBudget = (config.adminRequestLimitAccount, 60)
            authConfig.csrfHosts = Set(config.publicDashboardHosts)
            let dashboardGuard = FormAuth.register(app, config: authConfig, keys: keys)
            FormAdmin.register(app, guardian: dashboardGuard, secrets: secrets, mailAllowedNets: config.mailAllowedNets,
                allowInsecure: config.allowInsecureDev, mail: mail, deploy: deploy,
                sdkVersion: { try? SDKBundle.load(from: sdkDir).version }, includePublicRoutes: false)
        }
        // Automatic SDK updates only run for targets that opted in (default off); one replica per round.
        app.lifecycle.use(DeployScheduler(service: deploy))
        // The ingest resolves `digest-hmac` secrets through the same encrypted store (ADR 0006 Nr. 6).
        let abuseKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: try await keys.serverKey(), info: Data("form-ingest-abuse-v1".utf8), outputByteCount: 32)
        publicRegistration = {
            var publicAuth = AuthConfig(relyingParty: guardian.config.relyingParty, trustedProxies: config.publicTrustedProxies)
            publicAuth.oauthIssuer = guardian.config.oauthIssuer
            publicAuth.oauthAuthorizeBaseURL = guardian.config.oauthAuthorizeBaseURL
            publicAuth.requestBudget = (config.adminRequestLimitIP, 60)
            publicAuth.accountRequestBudget = (config.adminRequestLimitAccount, 60)
            let publicGuardian = AuthGuard(sessions: guardian.sessions, throttles: guardian.throttles,
                config: publicAuth)
            try FormAdmin.registerPublic(app, guardian: publicGuardian, trustedProxies: config.publicTrustedProxies, adminResponder: app.responder.current)
            var ingest = IngestConfig(secrets: StoreDigestSecrets(store: secrets), mail: mail, externalHost: { req in try StatisticsCollector.proxyHost(req, trusted: config.publicTrustedProxies) })
            ingest.throttle = guardian.throttles
            ingest.abuseKey = abuseKey.withUnsafeBytes { Data($0) }
            ingest.clientIP = IngestConfig.proxiedClientIP(trusted: config.publicTrustedProxies)
            let backend = IngestSetup.register(app, config: ingest)
            LegacyAPI.register(app, backend: backend)
        }
        app.lifecycle.use(FlowMaintenance())
        app.lifecycle.use(MailMaintenanceScheduler())
        app.lifecycle.use(AuthMaintenanceScheduler())
        // FORM_RETENTION_INTERVAL_SECONDS (1...3600, test/real-run knob): how often the retention pass runs; default hourly.
        app.lifecycle.use(RetentionScheduler(interval: ProcessInfo.processInfo.environment["FORM_RETENTION_INTERVAL_SECONDS"].flatMap(TimeInterval.init).map { min(3600, max(1, $0)) } ?? 3600))
        app.lifecycle.use(WebhookScheduler(service: WebhookDispatcher(db: app.db(.mysql), secrets: secrets)))
        app.logger.info("admin API enabled")
    } catch {
        FileHandle.standardError.write(Data("admin API configuration failed: \(type(of: error))\n".utf8))  // never the key or its path content
        exit(78)
    }
} else if config.admin == nil, !isMigrate {
    app.logger.notice("admin API not configured (FORM_SERVER_KEY_FILE/FORM_ADMIN_ORIGIN/FORM_RP_ID unset)")
}
// Freeze the internal router before registering the strictly separate public surface.
let internalResponder = app.responder.default
app.responder.use { _ in internalResponder }
let publicResponder = try ListenerRoutes.publicSurface(app, config: config,
    dashboard: { try dashboardRegistration?() }, protocols: { try publicRegistration?() })
let servers = DualHTTPServer(app: app, config: config, internalResponder: internalResponder, publicResponder: publicResponder)
app.servers.use { _ in servers }
app.asyncCommands.use(MigrateLegacyCommand(), as: "migrate-legacy")
app.asyncCommands.use(MigrateCommand(schemaFile: config.schemaFile), as: "migrate")
app.asyncCommands.use(BootstrapAdminCommand(origin: ProcessInfo.processInfo.environment["FORM_ADMIN_ORIGIN"], requiresPassword: config.publicDashboard || config.internalSecondFactor), as: "bootstrap-admin")
app.asyncCommands.use(EnrollPasskeyCommand(origin: ProcessInfo.processInfo.environment["FORM_ADMIN_ORIGIN"]), as: "enroll-passkey")
do { try await app.execute() } catch let end as MigrateLegacyExit {
    // migrate-legacy already printed its message; the exit code separates input errors, failures, open review cases and signals.
    try? await app.asyncShutdown()
    exit(end.code)
} catch {
    app.logger.critical("fatal", metadata: ["type": "\(type(of: error))"])
    try? await app.asyncShutdown()
    exit(1)
}
try await app.asyncShutdown()
