// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormCore
import FormMail
import FormMigration
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
import FormHTTP

final class SetupMigrationTests: XCTestCase {
    func testMigrationSystemRightAndReadOnlyAllowlist() {
        XCTAssertTrue(PermissionCatalog.all.contains("migration.run"))
        XCTAssertFalse(GrantScope.customer(UUID()).covers(.system))
        XCTAssertFalse(TokenIdentity.scopeRights.values.contains { $0.contains("migration.run") })
        XCTAssertTrue(MigrationService.readOnlyGrant("GRANT SELECT, SHOW VIEW ON `old`.* TO `reader`@`%`"))
        for grant in ["GRANT ALL PRIVILEGES ON *.* TO x", "GRANT SELECT, INSERT ON old.* TO x", "GRANT SELECT ON old.* TO x WITH GRANT OPTION", "GRANT role TO x"] {
            XCTAssertFalse(MigrationService.readOnlyGrant(grant))
        }
    }
    func testHostRequiresExplicitNetworkAndSourceTLSValidation() throws {
        let ip = try XCTUnwrap(IPAddr("10.20.30.40"))
        XCTAssertFalse(HostGuard.isAllowed(ip, allowedNets: []))
        XCTAssertTrue(HostGuard.isAllowed(ip, allowedNets: [try XCTUnwrap(CIDR("10.20.30.0/24"))]))
        let source = MigrationSource(host: "db.example", database: "old", username: "reader", password: "synthetic", port: 3306, tls: "disable")
        XCTAssertThrowsError(try source.validate(allowInsecure: false))
        XCTAssertNoThrow(try source.validate(allowInsecure: true))
        let completed = try XCTUnwrap(SettingsRegistry.entries.first { $0.key == "setup.completed" })
        XCTAssertNoThrow(try completed.validate("false"))
        XCTAssertThrowsError(try completed.validate("1"))
    }
    func testMigrationNetworkAllowlistAndPinnedAnswers() async throws {
        let nets = [CIDR("10.20.30.0/24")!, CIDR("8.8.8.0/24")!, CIDR("2606:4700:4700::/48")!]
        for ip in ["10.20.30.40", "8.8.8.8", "2606:4700:4700::1111"] {
            let pinned = try await HostGuard.resolve(host: ip, allowedNets: nets, requireAllowedNetwork: true)
            XCTAssertEqual(pinned, [IPAddr(ip)!.text])
        }
        for (host, allowed) in [("8.8.8.8", []), ("10.20.30.40", []), ("1.1.1.1", nets), ("2606:4700:4701::1111", nets)] {
            do {
                _ = try await HostGuard.resolve(host: host, allowedNets: allowed, requireAllowedNetwork: true)
                XCTFail("Migration target outside explicit networks accepted")
            } catch { XCTAssertEqual(error as? HostGuard.Failure, .blocked) }
        }
        // The whole DNS answer must pass, including IPv6; never filter to the first allowed IP.
        for outside in ["1.1.1.1", "10.20.31.1", "2606:4700:4701::1111"] {
            let resolver = BoundedDNSResolver(lookup: { _ in [IPAddr("10.20.30.40")!, IPAddr(outside)!] })
            do {
                _ = try await HostGuard.resolve(host: "source.test", allowedNets: nets, resolver: resolver, requireAllowedNetwork: true)
                XCTFail("Mixed DNS answer accepted")
            } catch { XCTAssertEqual(error as? HostGuard.Failure, .blocked) }
        }
        let resolver = BoundedDNSResolver(lookup: { _ in [IPAddr("10.20.30.40")!, IPAddr("8.8.8.8")!] })
        let pinned = try await HostGuard.resolve(host: "source.test", allowedNets: nets, resolver: resolver, requireAllowedNetwork: true)
        XCTAssertEqual(pinned, ["10.20.30.40", "8.8.8.8"])
        // Default SMTP/webhook behaviour is intentionally different.
        let publicMail = try await HostGuard.resolve(host: "1.1.1.1", allowedNets: [])
        XCTAssertEqual(publicMail, ["1.1.1.1"])
    }

    func testConverterAbsentOnPublicDashboard() async throws {
        let app = try await Application.make(.testing)
        do {
            let config = try AppConfig(env: ["FORM_DB_PASSWORD": "synthetic-unused",
                "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1",
                "FORM_PUBLIC_DASHBOARD": "1", "FORM_PUBLIC_DASHBOARD_HOSTS": "admin.example.test"])
            XCTAssertTrue(config.publicDashboard)
            Persistence.configure(app, config)
            let key = try StaticServerKey(Data(repeating: 31, count: 32))
            let secrets = SecretStore(db: app.db(.mysql), keys: key)
            var auth = AuthConfig(relyingParty: RelyingParty(rpID: "admin.example.test", origin: "https://admin.example.test"))
            auth.listener = "internal"
            let internalGuard = FormAuth.register(app, config: auth, keys: key)
            FormAdmin.register(app, guardian: internalGuard, secrets: secrets, includePublicRoutes: false)
            let converters = app.routes.all.filter { $0.path.map(\.description).joined(separator: "/").contains("migration/legacy-forms") }
            XCTAssertEqual(converters.count, 2) // One GET and one POST, without duplicate registrations.
            let responder = try ListenerRoutes.publicSurface(app, config: config, dashboard: {
                auth.listener = "public"
                let guardian = FormAuth.register(app, config: auth, keys: key)
                FormAdmin.register(app, guardian: guardian, secrets: secrets, includePublicRoutes: false)
                SetupMigrationRoutes.register(app, guardian: guardian, secrets: secrets, startWorker: false)
            }, protocols: {})
            for method in [HTTPMethod.GET, .POST] {
                let req = Request(application: app, method: method,
                    url: URI(path: "/admin/api/v1/migration/legacy-forms/\(UUID().uuidString)/draft"),
                    headers: ["Host": "admin.example.test"], on: app.eventLoopGroup.next())
                let res = try await responder.respond(to: req).get()
                XCTAssertEqual(res.status, .notFound)
            }
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    func testSourceServiceRejectsPublicIPOutsideMigrationNetworks() async throws {
        try await AdminFixture.with { fx in
            let secrets = try SecretStore(db: fx.app.db(.mysql), keys: StaticServerKey(Data(repeating: 31, count: 32)))
            let service = MigrationService(app: fx.app, secrets: secrets, allowInsecure: true)
            let source = MigrationSource(host: "8.8.8.8", database: "old", username: "reader", password: "synthetic", port: 3306, tls: "disable")
            for nets in ["", "10.20.30.0/24"] {
                try await SystemSettings.write(fx.sql, key: "migration.allowedNets", value: nets, at: DB.time(Date()))
                do {
                    try await service.withSource(source) { _ in XCTFail("Disallowed source opened") }
                    XCTFail("Public migration source accepted")
                } catch {
                    // Still refused before any connection; the answer now names the setting to change instead of a bare 500.
                    let failure = try XCTUnwrap(error as? SourceFailure, "expected SourceFailure, got \(error)")
                    XCTAssertEqual(failure, .notAllowed)
                    XCTAssertTrue(failure.message.contains("migration.allowedNets"))
                }
            }
        }
    }

    // Written for MariaDB; not executed in the P11-CD environment.
    func testSecretEncryptionStableKeyAndCrashRecovery() async throws {
        try await AdminFixture.with { fx in
            let secrets = try SecretStore(db: fx.app.db(.mysql), keys: StaticServerKey(Data(repeating: 31, count: 32)))
            let service = MigrationService(app: fx.app, secrets: secrets, allowInsecure: true)
            let key = try await service.key(), again = try await service.key()
            XCTAssertEqual(key, again)
            XCTAssertEqual(key.count, 32)
            let source = MigrationSource(host: "synthetic.invalid", database: "old", username: "reader", password: "never-in-response", port: 3306, tls: "disable")
            let refs = try await fx.app.db(.mysql).transaction { conn in try await service.store(source, on: conn as! SQLDatabase) }
            let encoded = try MigrationService.encode(refs)
            XCTAssertFalse(encoded.contains(source.password))
            let opened = try await service.open(refs)
            XCTAssertEqual(opened.password, source.password)
            let id = UUID(), actor = try await fx.account()
            try await fx.sql.raw("INSERT INTO migration_jobs(id,actor_id,source_json,plan_json,expected_schema,state,phase,dry_run,report_json,created_at,updated_at) VALUES(\(bind: DB.bin(id)),\(bind: DB.bin(actor)),\(bind: encoded),'{}',\(bind: String(repeating: "a", count: 64)),'running','source',1,'{}',UTC_TIMESTAMP(6),UTC_TIMESTAMP(6))").run()
            try await SystemSettings.write(fx.sql, key: "migration.enabled", value: "false", at: DB.time(Date()))
            try await service.tick(recover: true)
            let row = try await fx.sql.raw("SELECT * FROM migration_jobs WHERE id=\(bind: DB.bin(id))").first(decoding: MigrationJob.self)
            XCTAssertEqual(row?.state, "paused")
        }
    }
    func testRoutesRequireExplicitRightFreshLoginAndCSRF() async throws {
        try await AdminFixture.with { fx in
            let secrets = try SecretStore(db: fx.app.db(.mysql), keys: StaticServerKey(Data(repeating: 31, count: 32)))
            SetupMigrationRoutes.register(fx.app, guardian: fx.guardian, secrets: secrets, startWorker: false)
            let actor = try await fx.account(), user = try await fx.login(actor)
            try await user.get("migration/jobs") { XCTAssertEqual($0.status, .notFound) }
            let missingJob = UUID().uuidString
            try await user.get("migration/jobs/\(missingJob)/probe") { XCTAssertEqual($0.status, .notFound) }
            try await fx.grant(actor, "migration.run", system: true, by: actor)
            try await user.get("migration/jobs") { XCTAssertEqual($0.status, .ok) }
            try await user.send(.POST, "migration/jobs/\(missingJob)/verify", body: "{\"hash\":\"abc\",\"success\":true,\"privateKey\":\"synthetic\"}") { XCTAssertEqual($0.status, .badRequest) }
            try await user.send(.POST, "migration/jobs/\(missingJob)/verify", body: "{}", csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await user.send(.POST, "migration/test", body: "{}", csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await fx.sql.raw("UPDATE sessions SET authenticated_at='2000-01-01' WHERE account_id=\(bind: DB.bin(actor))").run()
            // Status list is a plain read without secrets: no fresh login needed (contracts/auth/anmeldung.md, Frische-Liste).
            try await user.get("migration/jobs") { XCTAssertEqual($0.status, .ok) }
            // Everything that changes state, tests the source or reads migrated ciphertext still needs a fresh login.
            func reauth(_ res: XCTHTTPResponse) {
                XCTAssertEqual(res.status, .forbidden)
                XCTAssertTrue(res.body.string.contains("reauthentication_required"), res.body.string)
            }
            try await user.get("migration/jobs/\(missingJob)/probe") { reauth($0) }
            try await user.send(.POST, "migration/jobs/\(missingJob)/verify", body: "{\"hash\":\"abc\",\"success\":true}") { reauth($0) }
            try await user.send(.POST, "migration/jobs/\(missingJob)/pause", body: "{}") { reauth($0) }
            try await user.send(.POST, "migration/test", body: "{}") { reauth($0) }
            try await user.send(.POST, "migration/jobs", body: "{}") { reauth($0) }
        }
    }
    func testSourceOutsideAllowedNetworksIsRejectedWithExplanation() async throws {
        try await AdminFixture.with { fx in
            let secrets = try SecretStore(db: fx.app.db(.mysql), keys: StaticServerKey(Data(repeating: 31, count: 32)))
            SetupMigrationRoutes.register(fx.app, guardian: fx.guardian, secrets: secrets, startWorker: false)
            let actor = try await fx.account(), user = try await fx.login(actor)
            try await fx.grant(actor, "migration.run", system: true, by: actor)
            // Default: migration.allowedNets is empty, so every source is outside the allowlist. The answer must say so (not a bare 500).
            let body = "{\"host\":\"127.0.0.1\",\"port\":3306,\"database\":\"old\",\"username\":\"ro\",\"password\":\"x\",\"tls\":\"verify\"}"
            try await user.send(.POST, "migration/test", body: body) {
                XCTAssertEqual($0.status, .unprocessableEntity)
                XCTAssertTrue($0.body.string.contains("migration.allowedNets"), $0.body.string)
                XCTAssertFalse($0.body.string.contains("127.0.0.1"), "the answer must not echo the source")
            }
        }
    }
    func testJobErrorCodeKeepsTheCauseWithoutAnySourceValue() {
        // Before: every failure was stored as "migration_failed". Now the code names reason and column (VARCHAR(40), ascii).
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.invalidSourceAt(table: "anfragen", column: "time", reason: .invalidTimestamp)), "invalidTimestamp@time")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.invalidSourceAt(table: "stored_objects", column: "kid", reason: .unknownKeyGeneration)), "unknownKeyGeneration@kid")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.conflict), "conflict")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.invalidPlan), "invalid_plan")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.invalidSource), "invalid_source")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.snapshotChanged), "snapshot_changed")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.alreadyImported), "already_imported")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.sourceChanged), "source_changed")
        XCTAssertEqual(MigrationService.errorCode(for: ImportFailure.sourceNotQuiesced), "source_not_quiesced")
        // An unknown error (may carry SQL values) is never described, only generic.
        struct Foreign: Error, CustomStringConvertible { let description = "SELECT secret FROM x" }
        XCTAssertEqual(MigrationService.errorCode(for: Foreign()), "migration_failed")
        // A hostile column name cannot leak into the code or overflow the column.
        let hostile = MigrationService.errorCode(for: ImportFailure.invalidSourceAt(table: "t", column: "x'; DROP TABLE a;--", reason: .invalidInteger))
        XCTAssertEqual(hostile, "invalidInteger@column")
        let long = MigrationService.errorCode(for: ImportFailure.invalidSourceAt(table: "t", column: String(repeating: "a", count: 64), reason: .unknownKeyGeneration))
        XCTAssertLessThanOrEqual(long.utf8.count, 40)
    }
    func testFreshLoginWindowIsConfigurableAndDefaultsToThirtyMinutes() async throws {
        try await AdminFixture.with { fx in
            let secrets = try SecretStore(db: fx.app.db(.mysql), keys: StaticServerKey(Data(repeating: 31, count: 32)))
            SetupMigrationRoutes.register(fx.app, guardian: fx.guardian, secrets: secrets, startWorker: false)
            let actor = try await fx.account(), user = try await fx.login(actor)
            try await fx.grant(actor, "migration.run", system: true, by: actor)
            // GET jobs is readable without freshness since ADR 0037; the probe download still demands it (404 = passed the gate, job unknown).
            let missing = UUID().uuidString
            func age(_ minutes: Int) async throws {
                try await fx.sql.raw("UPDATE sessions SET authenticated_at = DATE_SUB(UTC_TIMESTAMP(6), INTERVAL \(unsafeRaw: String(minutes)) MINUTE) WHERE account_id=\(bind: DB.bin(actor))").run()
            }
            // Default 30 min: a 10 minute old login is still fresh (it was rejected under the former fixed 5 minutes), 40 minutes is not.
            try await age(10)
            try await user.get("migration/jobs/\(missing)/probe") { XCTAssertEqual($0.status, .notFound) }
            try await age(40)
            try await user.get("migration/jobs/\(missing)/probe") { XCTAssertEqual($0.status, .forbidden); XCTAssertTrue($0.body.string.contains("reauthentication_required")) }
            // Configurable: 5 minutes restores the old strictness, 60 minutes accepts the 40 minute old login.
            try await SystemSettings.write(fx.sql, key: "auth.freshLoginMinutes", value: "5", at: DB.time(Date()))
            try await age(10)
            try await user.get("migration/jobs/\(missing)/probe") { XCTAssertEqual($0.status, .forbidden) }
            try await SystemSettings.write(fx.sql, key: "auth.freshLoginMinutes", value: "60", at: DB.time(Date()))
            try await age(40)
            try await user.get("migration/jobs/\(missing)/probe") { XCTAssertEqual($0.status, .notFound) }
            // An invalid stored value never widens the window: back to 5 minutes.
            XCTAssertThrowsError(try SettingsRegistry.entries.first { $0.key == "auth.freshLoginMinutes" }!.validate("0"))
            XCTAssertThrowsError(try SettingsRegistry.entries.first { $0.key == "auth.freshLoginMinutes" }!.validate("121"))
        }
    }
}
