// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import Crypto
import FormAuth
import FormCore
import FormCrypto
@testable import FormMigration
import FormPersistence
import Foundation
import NIOCore
import NIOPosix
import SQLKit
import XCTest
import XCTVapor

/// Import rehearsal: the whole path as in operation, against the real legacy schema (legacy-real.sql), real :2 packages
/// made with the legacy crypto and the admin HTTP routes. Needs P4A_DB_PORT/P4A_DB_PASSWORD (backend/integration-test.sh).
final class ImportRehearsalTests: XCTestCase {
    struct Harness {
        let fx: AdminFixture
        let source: RehearsalSource
        let service: MigrationService
        let user: TestClient
        let actor: UUID
        let log: LogCapture
        let secrets: SecretStore
        var host: String { ProcessInfo.processInfo.environment["P4A_DB_HOST"] ?? "127.0.0.1" }
        var port: Int { Int(ProcessInfo.processInfo.environment["P4A_DB_PORT"]!)! }
        /// `host` is the database host of the environment; a fake server in the test process listens on loopback (`host: "127.0.0.1"`).
        func sourceBody(user: String? = nil, password: String? = nil, database: String? = nil, port: Int? = nil, host overrideHost: String? = nil) -> [String: Any] {
            ["host": overrideHost ?? host, "port": port ?? self.port, "database": database ?? source.name, "username": user ?? source.reader, "password": password ?? source.password, "tls": "disable"]
        }
        func json(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        func test(_ body: [String: Any]? = nil) async throws -> (HTTPStatus, [String: Any], String) {
            var out: (HTTPStatus, [String: Any], String) = (.ok, [:], "")
            try await user.send(.POST, "migration/test", body: json(body ?? sourceBody())) { res in out = (res.status, jsonObject(res), res.body.string) }
            return out
        }
        func createJob(plan: [String: Any], schema: String, body: [String: Any]? = nil, dryRun: Bool = true) async throws -> (HTTPStatus, String) {
            var out: (HTTPStatus, String) = (.ok, "")
            let payload: [String: Any] = ["source": body ?? sourceBody(), "plan": plan, "expectedSchema": schema, "dryRun": dryRun]
            try await user.send(.POST, "migration/jobs", body: json(payload)) { res in out = (res.status, res.body.string) }
            return out
        }
        func jobs() async throws -> [[String: Any]] {
            var items: [[String: Any]] = []
            try await user.get("migration/jobs") { res in items = jsonObject(res)["items"] as? [[String: Any]] ?? [] }
            return items
        }
        func action(_ id: String, _ name: String, body: String = "{}") async throws -> HTTPStatus {
            var status = HTTPStatus.ok
            try await user.send(.POST, "migration/jobs/\(id)/\(name)", body: body) { status = $0.status }
            return status
        }
        func scalar(_ sql: String) async throws -> String? {
            struct V: Decodable { let v: String? }
            return try await fx.sql.raw(SQLQueryString(sql)).first(decoding: V.self)?.v
        }
        func count(_ table: String, _ condition: String = "1=1") async throws -> Int { Int(try await scalar("SELECT CAST(COUNT(*) AS CHAR) AS v FROM \(table) WHERE \(condition)") ?? "-1") ?? -1 }
        func blob(_ sql: String) async throws -> Data? {
            struct B: Decodable { let v: Blob? }
            return try await fx.sql.raw(SQLQueryString(sql)).first(decoding: B.self)?.v?.data
        }
    }

    // MARK: golden file shared with the PWA (contracts/migration/rehearsal-golden.json)

    static var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/migration/rehearsal-golden.json")
    }
    static func golden() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL)) as! [String: Any]
    }

    /// The plan exactly as the PWA builds it from the source check (golden), with the two values that are per run.
    func plan(_ source: [String: Any], namespace: String = "legacy-altsystem") throws -> [String: Any] {
        var plan = try XCTUnwrap(Self.golden()["plan"] as? [String: Any])
        plan["namespace"] = namespace
        plan["dumpSHA256"] = String(repeating: "ab", count: 32)
        return plan
    }

    func withHarness(perForm: Int = 8, statistics: Int = 6, nets: String = "127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16", _ body: (Harness) async throws -> Void) async throws {
        try await AdminFixture.with { fx in
            let log = LogCapture()
            let source = try await RehearsalSource.create(fx, perForm: perForm, statistics: statistics)
            // Captured from here on (trace level, stricter than production): the seeding itself is test setup, not the system.
            fx.app.logger = log.logger
            do {
                let secrets = SecretStore(db: fx.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 31, count: 32)))
                SetupMigrationRoutes.register(fx.app, guardian: fx.guardian, secrets: secrets, allowInsecure: true, startWorker: false)
                let actor = try await fx.account(), user = try await fx.login(actor)
                try await fx.grant(actor, "migration.run", system: true, by: actor)
                let at = DB.time(Date())
                try await SystemSettings.write(fx.sql, key: "migration.enabled", value: "true", at: at)
                try await SystemSettings.write(fx.sql, key: "migration.allowedNets", value: nets, at: at)
                try await body(Harness(fx: fx, source: source, service: MigrationService(app: fx.app, secrets: secrets, allowInsecure: true), user: user, actor: actor, log: log, secrets: secrets))
            } catch { await source.drop(fx); throw error }
            await source.drop(fx)
        }
    }

    // MARK: the whole path

    /// Source check, plan from the golden file, dry run, import, phases, and all proofs.
    func testFullRehearsalThroughAdminRoutes() async throws {
        try await withHarness { h in
            // 1. Source check through the real route; the answer equals the golden inventory the PWA builds its plan from.
            let (status, inventory, text) = try await h.test()
            XCTAssertEqual(status, .ok, text)
            if let path = ProcessInfo.processInfo.environment["REHEARSAL_WRITE_INVENTORY"] {
                var masked = inventory; masked["schemaHMAC"] = String(repeating: "0", count: 64)
                try JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: path))
            }
            let golden = try Self.golden()
            var masked = inventory; masked["schemaHMAC"] = String(repeating: "0", count: 64)
            XCTAssertEqual(masked as NSDictionary, try XCTUnwrap(golden["inventory"] as? [String: Any]) as NSDictionary, "backend answer and PWA golden inventory diverged")
            let schema = try XCTUnwrap(inventory["schemaHMAC"] as? String)
            for secret in [h.source.password, RehearsalSource.smtpPassword, "smtp.example.invalid", RehearsalSource.proxyURL, "proxy-secret-99", RehearsalSource.cloudflare, "KLARTEXT-MARKER", "KUBUS-AEAD"] {
                XCTAssertFalse(text.contains(secret), "source check leaked \(secret)")
            }

            // 2. Dry run job (the only way to start one) -> phases -> review.
            let plan = try plan(inventory)
            let (createStatus, created) = try await h.createJob(plan: plan, schema: schema)
            XCTAssertEqual(createStatus, .ok, created)
            let jobID = try XCTUnwrap(jsonObjectFrom(created)["id"] as? String)
            var started = Date()
            try await h.service.tick()
            var job = try await h.jobs().first!
            XCTAssertEqual(job["state"] as? String, "review", "error=\(job["error"] ?? "-") report=\(job["report"] ?? "-")")
            XCTAssertEqual(job["dryRun"] as? Bool, true)
            print("MEASURE rehearsal dry-run seconds=\(Date().timeIntervalSince(started)) rows=\(h.source.submissionCount)")
            // A dry run leaves nothing behind.
            for table in ["customers", "forms", "submissions", "stored_objects", "connections", "customer_key_generations", "migration_runs", "migration_objects"] {
                let n = try await h.count(table)
                XCTAssertEqual(n, 0, "dry run left rows in \(table)")
            }

            // 3. Real import through the route; counts per table.
            let importStatus = try await h.action(jobID, "import")
            XCTAssertEqual(importStatus, .ok)
            started = Date()
            try await h.service.tick()
            job = try await h.jobs().first!
            XCTAssertEqual(job["state"] as? String, "review", "error=\(job["error"] ?? "-")")
            XCTAssertEqual(job["dryRun"] as? Bool, false)
            XCTAssertEqual(job["phase"] as? String, "verification")
            print("MEASURE rehearsal import seconds=\(Date().timeIntervalSince(started))")
            try await assertImported(h, job: job)
        }
    }

    func assertImported(_ h: Harness, job: [String: Any]) async throws {
        let expected = h.source.expected
        // Row counts per table.
        let report = try XCTUnwrap(job["report"] as? [String: Any])
        let tables = try XCTUnwrap(report["tables"] as? [String: Any])
        func parity(_ t: String) -> (Int, Int, Int) {
            let p = tables[t] as? [String: Any] ?? [:]
            return (p["sourceCount"] as? Int ?? -1, p["importedCount"] as? Int ?? -1, p["reviewCount"] as? Int ?? -1)
        }
        let n = h.source.submissionCount
        XCTAssertEqual(parity("datenschluessel").0, 2); XCTAssertEqual(parity("datenschluessel").1, 2)
        XCTAssertEqual(parity("datenschluesselRecovery").1, 1)
        XCTAssertEqual(parity("formulare").1, 3)
        XCTAssertEqual(parity("formularFelder").1, 7)
        XCTAssertEqual(parity("outgoingMailServer").1, 2); XCTAssertEqual(parity("outgoingMailProxy").1, 1)
        XCTAssertEqual(parity("formularWebhooks").1, 1)
        XCTAssertEqual(parity("anfrageIdempotenz").1, 3)
        XCTAssertEqual(parity("anfragen").0, n)
        XCTAssertEqual(parity("anfragen").1, n, "every submission is taken over, defective ones as examination cases")
        // Target rows.
        let c1 = try await h.count("customers"), c2 = try await h.count("customer_key_generations"), c3 = try await h.count("data_key_recovery")
        XCTAssertEqual([c1, c2, c3], [1, 2, 1])
        let c4 = try await h.count("forms"), c5 = try await h.count("form_versions"), c6 = try await h.count("connections"), c7 = try await h.count("customer_connections")
        XCTAssertEqual([c4, c5, c6, c7], [3, 3, 3, 3])
        let c8 = try await h.count("submissions"), c9 = try await h.count("ingest_idempotency"), c10 = try await h.count("webhook_endpoints")
        XCTAssertEqual([c8, c9, c10], [n, 3, 1])
        let packageCount = expected.values.reduce(0) { $0 + $1.packages.count }
        let objects = try await h.count("stored_objects", "object_role<>'statistics-metadata'")
        XCTAssertEqual(objects, packageCount)
        // Everything is inactive until the human cutover.
        let active = try await h.count("forms", "active=1")
        XCTAssertEqual(active, 0)
        // Byte-for-byte packages and round trip with the legacy private key.
        var opened = 0
        for (uuid, item) in expected {
            for (role, package) in item.packages {
                let stored = try await h.blob("SELECT ciphertext AS v FROM stored_objects WHERE submission_id=\(unhexUUID(uuid)) AND object_role='\(role)'")
                XCTAssertEqual(stored, Data(package.wire.utf8), "\(uuid) \(role) is not byte-identical")
                if let key = package.key, let plain = package.plain {
                    let wire = try XCTUnwrap(String(data: try XCTUnwrap(stored), encoding: .utf8))
                    XCTAssertEqual(try PackageV2(wire).open(recipient: key), plain, "\(uuid) \(role) does not decrypt with the legacy key")
                    opened += 1
                }
            }
            if item.packages.isEmpty || item.reviewCause != nil {
                // Preserved even without importable packages.
                let present = try await h.count("submissions", "id=\(unhexUUID(uuid))")
                XCTAssertEqual(present, 1)
            }
        }
        XCTAssertGreaterThan(opened, 30)
        // Recovery envelope bytes unchanged; generation numbers as planned.
        let wrapped = try await h.blob("SELECT wrapped_key AS v FROM data_key_recovery WHERE kid='\(RehearsalSource.kid(RehearsalSource.alphaActive))'")
        XCTAssertEqual(wrapped, Data((0..<48).map { UInt8(($0 &* 5 &+ 1) & 0xff) }))
        let numbers = try await h.scalar("SELECT GROUP_CONCAT(CONCAT(generation_no,state) ORDER BY generation_no SEPARATOR ',') AS v FROM customer_key_generations WHERE customer_id=\(unhexUUID(RehearsalSource.alpha))")
        XCTAssertEqual(numbers, "1retiring,2active")
        // Review cases: issues reported by kind, mapped to the job report.
        let issues = try await h.scalar("SELECT GROUP_CONCAT(CONCAT(issue_code,':',c) ORDER BY issue_code) AS v FROM (SELECT issue_code, COUNT(*) AS c FROM migration_issues GROUP BY issue_code) x")
        print("MEASURE issues=\(issues ?? "-")")
        // Review cases are exactly the rows with unsupported content, not every row that has a sent mail server (the legacy
        // ingest writes sentServer on every submission, and the contract maps it to submissions.legacy_sent_server).
        let reviewed = expected.values.filter { $0.reviewCause != nil }.count
        let flagged = try await h.count("migration_issues", "issue_code='unsupported-content'")
        XCTAssertEqual(flagged, reviewed, "unsupported-content must flag only rows with a defective package, plaintext blob, errors or file name")
        let transport = try await h.count("submissions", "legacy_sent_server='\(RehearsalSource.smtpA)'")
        XCTAssertEqual(transport, expected.count - 1, "sentServer (a mail server id) is taken over for every row except the one with a free-text value")
        // Secrets and plaintext never in logs, job rows, issues, audit or the readable target columns.
        let leaks = [RehearsalSource.smtpPassword, "proxy-secret-99", RehearsalSource.proxyURL, RehearsalSource.cloudflare, h.source.password, "KLARTEXT-MARKER", "proxy-token-xyz"]
        let logText = h.log.text
        let rows = try await h.scalar("SELECT CONCAT_WS('|', (SELECT GROUP_CONCAT(report_json,error_code,source_json,plan_json) FROM migration_jobs), (SELECT GROUP_CONCAT(safe_config_json) FROM connections), (SELECT IFNULL(GROUP_CONCAT(safe_details_json),'') FROM audit_events), (SELECT IFNULL(GROUP_CONCAT(issue_code,source_table),'') FROM migration_issues)) AS v") ?? ""
        for secret in leaks {
            if logText.contains(secret) { let line = logText.split(separator: "\n").first { $0.contains(secret) }; print("LEAKLINE", String((line ?? "").prefix(300))) }
            XCTAssertFalse(logText.contains(secret), "log contains \(secret)")
            XCTAssertFalse(rows.contains(secret), "job/connection/audit/issue rows contain \(secret)")
        }
        let encrypted = try await h.scalar("SELECT COUNT(*) AS v FROM managed_secrets WHERE ciphertext IS NOT NULL")
        XCTAssertNotNil(encrypted)
    }

    // MARK: failures explain themselves

    /// MariaDB-like greeting (protocol 10) with or without CLIENT_SSL; what a server sends before any credentials.
    static func greeting(ssl: Bool) -> [UInt8] {
        var payload: [UInt8] = [10] + Array("10.11.0-MariaDB".utf8) + [0, 1, 0, 0, 0] + Array("abcdefgh".utf8) + [0]
        var lower: UInt16 = 0xFFFF; if !ssl { lower &= ~0x0800 }
        payload += [UInt8(lower & 0xff), UInt8(lower >> 8), 45, 2, 0, 0xff, 0x81, 21] + [UInt8](repeating: 0, count: 10)
        payload += Array("ijklmnopqrst".utf8) + [0] + Array("mysql_native_password".utf8) + [0]
        return [UInt8(payload.count & 0xff), UInt8((payload.count >> 8) & 0xff), 0, 0] + payload
    }

    /// Listens on loopback, sends the greeting and counts every byte the client sends back.
    final class FakeServer: @unchecked Sendable {
        let group: MultiThreadedEventLoopGroup, channel: Channel
        private let lock = NSLock(); private var received = 0
        var receivedBytes: Int { lock.lock(); defer { lock.unlock() }; return received }
        var port: Int { channel.localAddress!.port! }
        init(ssl: Bool) async throws {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let box = Box()
            channel = try await ServerBootstrap(group: group).childChannelInitializer { ch in
                ch.pipeline.addHandler(Counter(count: { n in box.owner?.add(n) }, greeting: ImportRehearsalTests.greeting(ssl: ssl)))
            }.bind(host: "127.0.0.1", port: 0).get()
            box.owner = self
            self.boxKeep = box
        }
        private var boxKeep: Box?
        final class Box: @unchecked Sendable { var owner: FakeServer? }
        func add(_ n: Int) { lock.lock(); received += n; lock.unlock() }
        func stop() async { try? await channel.close().get(); try? await group.shutdownGracefully() }
        final class Counter: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer; typealias OutboundOut = ByteBuffer
            let count: (Int) -> Void, greeting: [UInt8]
            init(count: @escaping (Int) -> Void, greeting: [UInt8]) { self.count = count; self.greeting = greeting }
            func channelActive(context: ChannelHandlerContext) { context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: greeting)), promise: nil) }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) { count(unwrapInboundIn(data).readableBytes) }
        }
    }

    /// B1 of the security review: tls "verify" must never fall back to plain text. A server that does not offer TLS is refused
    /// before the client sends anything (user name and password scramble are part of the first reply).
    func testSourceWithoutTLSIsRefusedBeforeAnyCredentialIsSent() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            let fake = try await FakeServer(ssl: false)
            do {
                var body = h.sourceBody(user: "srcuser-geheim", password: "pw-geheim", database: "alt", port: fake.port, host: "127.0.0.1")
                body["tls"] = "verify"
                let (status, _, text) = try await h.test(body)
                try await Task.sleep(nanoseconds: 300_000_000)
                XCTAssertEqual(fake.receivedBytes, 0, "credentials were sent to a server without TLS")
                XCTAssertEqual(status, .unprocessableEntity, text)
                XCTAssertTrue(text.contains("TLS"), text)
                XCTAssertFalse(text.contains("pw-geheim") || text.contains("srcuser-geheim"))
            } catch { await fake.stop(); throw error }
            await fake.stop()
        }
    }

    func testGreetingParserFindsTLSOffer() {
        XCTAssertEqual(SourceTLSProbe.offersTLS(greeting: Self.greeting(ssl: true)), true)
        XCTAssertEqual(SourceTLSProbe.offersTLS(greeting: Self.greeting(ssl: false)), false)
        XCTAssertNil(SourceTLSProbe.offersTLS(greeting: [1, 2, 3]))
        XCTAssertNil(SourceTLSProbe.offersTLS(greeting: [255, 0, 0, 0, 0xff, 0x15, 4] + Array("Host not allowed".utf8)))
    }

    func testSourceCheckFailuresNameTheCause() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            let writer = "reh_w_" + String(h.source.name.suffix(12))
            try await h.fx.sql.raw(SQLQueryString("CREATE USER '\(writer)'@'%' IDENTIFIED BY 'writer-pw'")).run()
            try await h.fx.sql.raw(SQLQueryString("GRANT SELECT, INSERT ON `\(h.source.name)`.* TO '\(writer)'@'%'")).run()
            do {
                let cases: [(String, [String: Any], String)] = [
                    ("falsches Passwort", h.sourceBody(password: "falsch"), "Anmeldung an der Quelle abgelehnt"),
                    ("Quelle nicht erreichbar", h.sourceBody(port: 1), "nicht erreichbar"),
                    ("Datenbank fehlt", h.sourceBody(database: "gibt_es_nicht"), "Quelldatenbank"),
                    ("zu viele Rechte", h.sourceBody(user: writer, password: "writer-pw"), "Leserechte"),
                ]
                for (label, body, expected) in cases {
                    let (status, _, text) = try await h.test(body)
                    XCTAssertEqual(status, .unprocessableEntity, label)
                    XCTAssertTrue(text.contains(expected), "\(label): \(text)")
                    for secret in ["falsch", "writer-pw", h.source.password, "gibt_es_nicht"] { XCTAssertFalse(text.contains(secret), "\(label) echoes \(secret)") }
                    XCTAssertFalse(text.contains("Quelle konnte nicht sicher geprüft werden"), "\(label) is still the generic text")
                }
                // The same causes become short codes on a job (error column), never source values.
                XCTAssertEqual(MigrationService.errorCode(for: SourceFailure.authentication), "source_auth")
                XCTAssertEqual(MigrationService.errorCode(for: SourceFailure.unreachable), "source_unreachable")
                XCTAssertEqual(MigrationService.errorCode(for: SourceFailure.noTLS), "source_no_tls")
            } catch { try? await h.fx.sql.raw(SQLQueryString("DROP USER IF EXISTS '\(writer)'@'%'")).run(); throw error }
            try await h.fx.sql.raw(SQLQueryString("DROP USER IF EXISTS '\(writer)'@'%'")).run()
        }
    }

    /// B2: an unresolvable host and a host outside the allowlist look the same (no DNS oracle).
    func testUnresolvableAndNotAllowedHostsAnswerIdentically() async throws {
        try await withHarness(perForm: 1, statistics: 0, nets: "10.0.0.0/8") { h in
            let (s1, j1, _) = try await h.test(h.sourceBody().merging(["host": "gibt-es-nicht.invalid"]) { $1 })
            let (s2, j2, outside) = try await h.test(h.sourceBody().merging(["host": "8.8.8.8"]) { $1 })
            XCTAssertEqual(s1, .unprocessableEntity); XCTAssertEqual(s2, .unprocessableEntity)
            XCTAssertEqual(j1["message"] as? String, j2["message"] as? String)
            XCTAssertEqual(j1["code"] as? String, j2["code"] as? String)
            XCTAssertTrue(outside.contains("migration.allowedNets"))
        }
    }

    /// B6: parallel source checks are limited (one per account, two overall) and failures are audited without secrets.
    func testSourceChecksAreLimitedAndFailuresAudited() async throws {
        try await withHarness(perForm: 1, statistics: 0) { h in
            let entered = await MigrationService.sourceTests.enter(h.actor)
            XCTAssertTrue(entered)
            let second = await MigrationService.sourceTests.enter(h.actor)
            XCTAssertFalse(second, "one running check per account")
            var status = HTTPStatus.ok
            try await h.user.send(.POST, "migration/test", body: h.json(h.sourceBody())) { status = $0.status }
            XCTAssertEqual(status, .tooManyRequests)
            await MigrationService.sourceTests.leave(h.actor)
            let (code, _, _) = try await h.test(h.sourceBody(password: "falsch-geheim"))
            XCTAssertEqual(code, .unprocessableEntity)
            let failures = try await h.count("audit_events", "action_code='migration.source.test.failed'")
            XCTAssertEqual(failures, 1)
            let details = try await h.scalar("SELECT GROUP_CONCAT(safe_details_json) AS v FROM audit_events") ?? ""
            XCTAssertFalse(details.contains("falsch-geheim") || details.contains(h.source.password))
            // The gate is free again after the failed check.
            let (again, _, _) = try await h.test()
            XCTAssertEqual(again, .ok)
        }
    }

    func unhexUUID(_ s: String) -> String { "X'" + s.replacingOccurrences(of: "-", with: "") + "'" }
    func jsonObjectFrom(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
}
