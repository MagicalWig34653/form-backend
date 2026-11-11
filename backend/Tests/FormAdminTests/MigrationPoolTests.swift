// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin

import FluentMySQLDriver
import FormAuth
import FormCore
import FormMail
import FormMigration
import FormPersistence
import FormWebhooks
import FormFlow
import Foundation
import NIOPosix
import SQLKit
import XCTest
import XCTVapor

/// Connection demand of a real migration job (tick -> execute -> importer) against a real MariaDB, with the source
/// reached through `withSource` (read-only user, allowlisted loopback). Synthetic data only.
final class MigrationPoolTests: XCTestCase {
    static let form = "11111111-1111-4111-8111-111111111111"
    static let customer = "33333333-3333-4333-8333-333333333333"

    struct JobEnv {
        let app: Application
        let service: MigrationService
        let job: UUID
        let target: String
        let observer: SQLDatabase
        /// Open server connections of the job application to the target schema. The pool opens connections lazily and keeps
        /// them, so after a run this equals the peak number of connections checked out at the same time.
        func openTargetConnections() async throws -> Int {
            struct N: Decodable { let n: Int }
            return try await observer.raw("SELECT COUNT(*) AS n FROM information_schema.processlist WHERE db=\(bind: target)").first(decoding: N.self)?.n ?? -1
        }
        func job() async throws -> MigrationJob? {
            try await Persistence.sql(app).raw("SELECT * FROM migration_jobs WHERE id=\(bind: DB.bin(job))").first(decoding: MigrationJob.self)
        }
    }

    func withJob(loops: Int, perLoop: Int, extraAnfragen: Int = 0, dryRun: Bool = false, _ body: (JobEnv) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["P4A_DB_PORT"].flatMap(Int.init), let pw = env["P4A_DB_PASSWORD"] else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh")
        }
        let host = env["P4A_DB_HOST"] ?? "127.0.0.1"
        func cfg(_ db: String) throws -> AppConfig {
            try AppConfig(env: ["FORM_DB_HOST": host, "FORM_DB_PASSWORD": pw, "FORM_DB_PORT": "\(port)", "FORM_DB_USER": "root", "FORM_DB_NAME": db,
                                "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1"])
        }
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let source = "pool_src_" + suffix, target = "pool_tgt_" + suffix, reader = "pool_r_" + suffix, readerPassword = "synthetic-" + suffix
        let group = MultiThreadedEventLoopGroup(numberOfThreads: loops)
        let admin = try await Application.make(.testing, .shared(group))
        admin.logger.logLevel = .critical
        Persistence.configure(admin, try cfg("p4atest"), maxConnectionsPerEventLoop: 2)
        let adminSQL = Persistence.sql(admin)
        func cleanup() async {
            for statement in ["DROP DATABASE IF EXISTS \(source)", "DROP DATABASE IF EXISTS \(target)", "DROP USER IF EXISTS '\(reader)'@'%'"] {
                try? await adminSQL.raw(SQLQueryString(statement)).run()
            }
            try? await admin.asyncShutdown(); try? await group.shutdownGracefully()
        }
        do {
            try await adminSQL.raw("CREATE DATABASE \(ident: source)").run()
            try await adminSQL.raw("CREATE DATABASE \(ident: target)").run()
            // Identifiers are generated above (hex suffix only).
            for statement in ["CREATE USER '\(reader)'@'%' IDENTIFIED BY '\(readerPassword)'", "GRANT SELECT ON `\(source)`.* TO '\(reader)'@'%'"] {
                try await adminSQL.raw(SQLQueryString(statement)).run()
            }
            let sourceID = DatabaseID(string: "pool-source")
            admin.databases.use(.mysql(configuration: MySQLConfiguration(hostname: host, port: port, username: "root", password: pw, database: source, tlsConfiguration: nil), maxConnectionsPerEventLoop: 1), as: sourceID)
            let sourceRoot = admin.db(sourceID) as! SQLDatabase
            let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let fixture = try String(contentsOf: tests.appendingPathComponent("FormMigrationTests/Fixtures/legacy.sql"), encoding: .utf8)
            for statement in try SQLStatementSplitter.split(fixture) { try await sourceRoot.raw(SQLQueryString(statement)).run() }
            if extraAnfragen > 0 {
                for n in 2...(extraAnfragen + 1) {
                    try await sourceRoot.raw("INSERT INTO anfragen (ID,UUID,formularUUID,time,data,removable) VALUES (\(bind: n),UUID(),\(bind: Self.form),\(bind: 1_700_000_000 + n),'unsupported-synthetic-packet',0)").run()
                }
            }
            let keys = try StaticServerKey(Data(repeating: 31, count: 32))
            // Setup on a throw-away application so that its connections never count towards the job's pool.
            let setup = try await Application.make(.testing, .shared(group))
            setup.logger.logLevel = .critical
            let job = UUID()
            do {
                Persistence.configure(setup, try cfg(target), maxConnectionsPerEventLoop: 4)
                let setupSQL = Persistence.sql(setup)
                let schema = tests.deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
                _ = try await MigrationRunner(db: setupSQL).run(schemaFile: schema)
                _ = try await MigrationRunner(db: setupSQL).run(schemaFile: URL(fileURLWithPath: schema).deletingLastPathComponent().appendingPathComponent("upgrades/0027-account-recovery.sql").path, name: "0027-account-recovery")
                let actor = UUID(), at = DB.time(Date())
                try await setupSQL.raw("INSERT INTO accounts (id, username, password_hash, active, mcp_allowed, rights_version, created_at) VALUES (\(bind: DB.bin(actor)), 'pool-actor', 'x', 1, 0, 0, \(bind: at))").run()
                try await setupSQL.raw("INSERT INTO permission_assignments (id, account_id, permission, scope_kind, revision, granted_by, granted_at) VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(actor)), 'migration.run', 'system', 1, \(bind: DB.bin(actor)), \(bind: at))").run()
                try await SystemSettings.write(setupSQL, key: "migration.enabled", value: "true", at: at)
                try await SystemSettings.write(setupSQL, key: "migration.allowedNets", value: "127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16", at: at)
                // The database host is loopback locally but a container address (private range) in the CI network.
                let secrets = SecretStore(db: setup.db(.mysql), keys: keys)
                let service = MigrationService(app: setup, secrets: secrets, allowInsecure: true)
                let hmac = try await service.key()
                let expected = try await LegacyImporter(source: sourceRoot, target: setupSQL, secrets: secrets, hmacKey: hmac).inspectSchema()
                let plan = ImportPlan(namespace: "pool-" + suffix, dumpSHA256: String(repeating: "0", count: 64), customers: [Self.customer: "Synthetisch"], formCustomers: [Self.form: Self.customer])
                let input = MigrationSource(host: host, database: source, username: reader, password: readerPassword, port: port, tls: "disable")
                try await setup.db(.mysql).transaction { conn in
                    let tx = conn as! SQLDatabase
                    let refs = try await service.store(input, on: tx)
                    try await tx.raw("""
                        INSERT INTO migration_jobs(id,actor_id,source_json,plan_json,expected_schema,state,phase,dry_run,report_json,created_at,updated_at)
                        VALUES(\(bind: DB.bin(job)),\(bind: DB.bin(actor)),\(bind: MigrationService.encode(refs)),\(bind: MigrationService.encode(plan)),\(bind: expected),'queued','source',\(bind: dryRun ? 1 : 0),'{}',\(bind: at),\(bind: at))
                        """).run()
                }
            } catch { try? await setup.asyncShutdown(); throw error }
            try await setup.asyncShutdown()
            let app = try await Application.make(.testing, .shared(group))
            app.logger.logLevel = .critical
            do {
                Persistence.configure(app, try cfg(target), maxConnectionsPerEventLoop: perLoop)
                let envelope = JobEnv(app: app, service: MigrationService(app: app, secrets: SecretStore(db: app.db(.mysql), keys: keys), allowInsecure: true),
                                      job: job, target: target, observer: adminSQL)
                // Connections of the setup application are closed asynchronously.
                var open = try await envelope.openTargetConnections()
                for _ in 0..<50 where open > 0 { try await Task.sleep(nanoseconds: 100_000_000); open = try await envelope.openTargetConnections() }
                XCTAssertEqual(open, 0)
                try await body(envelope)
            } catch { try? await app.asyncShutdown(); throw error }
            try await app.asyncShutdown()
        } catch { await cleanup(); throw error }
        await cleanup()
    }

    func testDefaultPoolSizeStaysAboveLockHoldersOnSmallHosts() {
        XCTAssertEqual(Persistence.defaultMaxConnectionsPerEventLoop(eventLoops: 1), 32)
        XCTAssertEqual(Persistence.defaultMaxConnectionsPerEventLoop(eventLoops: 2), 16)
        XCTAssertEqual(Persistence.defaultMaxConnectionsPerEventLoop(eventLoops: 8), 4)
        XCTAssertEqual(Persistence.defaultMaxConnectionsPerEventLoop(eventLoops: 64), 4)
        XCTAssertEqual(Persistence.defaultMaxConnectionsPerEventLoop(eventLoops: 0), 32)
    }

    /// Measurement: how many pool connections does one job run hold at the same time on a single event loop?
    func testJobPeakConnectionsOnOneEventLoop() async throws {
        for dryRun in [false, true] {
            try await withJob(loops: 1, perLoop: 16, extraAnfragen: 20, dryRun: dryRun) { env in
                let started = Date()
                try await env.service.tick()
                let row = try await env.job()
                let peak = try await env.openTargetConnections()
                print("MEASURE dryRun=\(dryRun) state=\(row?.state ?? "-") error=\(row?.error_code ?? "-") peak=\(peak) seconds=\(Date().timeIntervalSince(started))")
                XCTAssertEqual(row?.state, "review", "error=\(row?.error_code ?? "-")")
                // Lock session doubles as importer target: one long-lived connection plus one short query at a time (was 3).
                XCTAssertLessThanOrEqual(peak, 2)
            }
        }
    }

    /// With two connections per loop the job must still finish (it previously held two and needed a third: self-deadlock
    /// after the 10 s pool timeout, job failed with migration_failed).
    func testJobFinishesWithTwoConnectionsPerLoop() async throws {
        try await withJob(loops: 1, perLoop: 2, extraAnfragen: 5) { env in
            let started = Date()
            try await env.service.tick()
            let row = try await env.job()
            let open = try await env.openTargetConnections()
            print("MEASURE perLoop=2 state=\(row?.state ?? "-") error=\(row?.error_code ?? "-") seconds=\(Date().timeIntervalSince(started)) open=\(open)")
            XCTAssertEqual(row?.state, "review", "error=\(row?.error_code ?? "-")")
        }
    }

    /// The real maintenance services of the process (each holds a lock session and needs a second, nested connection),
    /// polled continuously on one event loop. Returns (rounds, failure kinds).
    static func background(_ app: Application, until stop: @escaping @Sendable () async -> Bool) async throws -> (Int, [String]) {
        let mailDB = app.db(.mysql), authDB = app.db(.mysql), flowDB = app.db(.mysql)
        let webhooks = WebhookDispatcher(db: app.db(.mysql), secrets: SecretStore(db: app.db(.mysql), keys: try StaticServerKey(Data(repeating: 31, count: 32))))
        let failures = PoolCounter(), rounds = PoolCounter()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<5 {
                group.addTask {
                    while await !stop(), !Task.isCancelled {
                        do {
                            switch worker {
                            case 0: _ = try await MailMaintenanceScheduler.runOnce(db: mailDB, now: Date())
                            case 1: _ = try await webhooks.run()
                            case 2: _ = try await AuthMaintenance.purgeIfLeader(db: authDB, now: Date())
                            case 3: try await FlowMaintenance.runOnce(db: flowDB)
                            default: _ = try await SystemSettings.value("migration.enabled", sql: Persistence.sql(app))
                            }
                            await rounds.add("\(worker)")
                        } catch { await failures.add("\(worker):\(type(of: error))") }
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                }
            }
        }
        return (await rounds.all.count, await failures.all)
    }

    /// Production default pool on one loop (container with one CPU): the maintenance services keep running alone and while
    /// the job imports. With the former fixed 4 per loop this deadlocked at once: tick and all services hit the pool timeout.
    func testBackgroundServicesKeepRunningDuringJob() async throws {
        try await withJob(loops: 1, perLoop: Persistence.defaultMaxConnectionsPerEventLoop(eventLoops: 1), extraAnfragen: 300) { env in
            let alone = Date()
            let (aloneRounds, aloneFailures) = try await Self.background(env.app) { Date().timeIntervalSince(alone) > 4 }
            print("MEASURE background-alone rounds=\(aloneRounds) failures=\(aloneFailures.count) kinds=\(Set(aloneFailures).sorted())")
            let done = Flag()
            let started = Date()
            async let services = Self.background(env.app) { await done.value }
            var tickError = "-"
            do { try await env.service.tick() } catch { tickError = "\(type(of: error))" }
            await done.set()
            let (jobRounds, jobFailures) = try await services
            let row = try await env.job()
            let open = try await env.openTargetConnections()
            print("MEASURE background-job tickError=\(tickError) state=\(row?.state ?? "-") error=\(row?.error_code ?? "-") seconds=\(Date().timeIntervalSince(started)) rounds=\(jobRounds) failures=\(jobFailures.count) kinds=\(Set(jobFailures).sorted()) open=\(open)")
            XCTAssertEqual(tickError, "-")
            XCTAssertTrue(aloneFailures.isEmpty, "background failures without job: \(Set(aloneFailures).sorted())")
            XCTAssertEqual(row?.state, "review", "error=\(row?.error_code ?? "-")")
            XCTAssertTrue(jobFailures.isEmpty, "background failures during job: \(Set(jobFailures).sorted())")
        }
    }
}

actor Flag {
    private(set) var value = false
    func set() { value = true }
}

actor PoolCounter {
    private(set) var all: [String] = []
    func add(_ value: String) { all.append(value) }
}
