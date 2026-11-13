// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FluentMySQLDriver
import FormAuth
import FormCore
import FormMail
import FormMigration
import FormPersistence
import Foundation
import NIOCore
import SQLKit
import Vapor

/// Persistent control plane; source values never leave this service.
struct MigrationSource: Codable {
    let host: String, database: String, username: String, password: String
    let port: Int
    let tls: String
    func validate(allowInsecure: Bool) throws {
        guard (1...65535).contains(port), [host, database, username].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }),
              password.utf8.count <= 200, tls == "verify" || (tls == "disable" && allowInsecure) else { throw Abort(.unprocessableEntity) }
    }
}
struct SessionStatus: Decodable { let Value: String? }
struct MigrationSourceRefs: Codable { let host: String, database: String, username: String, password: String; let port: Int; let tls: String }
struct MigrationJob: Decodable {
    let id: Blob, actor_id: Blob
    let source_json: String, plan_json: String, expected_schema: String
    let state: String, phase: String, report_json: String
    let dry_run: Int, cancel_requested: Int
    let error_code: String?
    let probe_hash: String?, test_hash: String?
}
struct MigrationService {
    let app: Application
    let secrets: SecretStore
    let allowInsecure: Bool
    var db: Database { app.db(.mysql) }
    var sql: SQLDatabase { db as! SQLDatabase }
    static func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    func key() async throws -> Data {
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            _ = try await SystemSettings.lock(tx, at: DB.time(Date()))
            struct R: Decodable { let secret_ref: String? }
            if let ref = try await tx.raw("SELECT secret_ref FROM settings WHERE scope_key='system' AND setting_key='_migration.hmac'").first(decoding: R.self)?.secret_ref {
                guard let key = try await secrets.get(ref, on: tx), key.count == 32 else { throw Abort(.serviceUnavailable) }
                return key
            }
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let ref = try await secrets.put(bytes, on: tx)
            try await tx.raw("INSERT INTO settings(scope_key,setting_key,secret_ref,manageable,modified_at) VALUES ('system','_migration.hmac',\(bind: ref),0,\(bind: DB.time(Date())))").run()
            return bytes
        }
    }
    func store(_ source: MigrationSource, on tx: SQLDatabase) async throws -> MigrationSourceRefs {
        try await MigrationSourceRefs(host: secrets.put(Data(source.host.utf8), on: tx), database: secrets.put(Data(source.database.utf8), on: tx), username: secrets.put(Data(source.username.utf8), on: tx), password: secrets.put(Data(source.password.utf8), on: tx), port: source.port, tls: source.tls)
    }
    func open(_ refs: MigrationSourceRefs) async throws -> MigrationSource {
        func read(_ ref: String) async throws -> String {
            guard let data = try await secrets.get(ref), let text = String(data: data, encoding: .utf8) else { throw Abort(.serviceUnavailable) }; return text
        }
        return try await MigrationSource(host: read(refs.host), database: read(refs.database), username: read(refs.username), password: read(refs.password), port: refs.port, tls: refs.tls)
    }
    /// Shared by all source checks of the process (B6).
    static let sourceTests = SourceTestGate()
    func withSource<T>(_ source: MigrationSource, body: @escaping (SQLDatabase) async throws -> T) async throws -> T {
        try source.validate(allowInsecure: allowInsecure)
        let nets = try await SystemSettings.value("migration.allowedNets", sql: sql).split(separator: ",").compactMap { CIDR(String($0)) }
        let addresses: [String]
        do { addresses = try await HostGuard.resolve(host: source.host, allowedNets: nets, requireAllowedNetwork: true) }
        catch {
            // One answer for "not allowed" and "not resolvable": otherwise the check tells which internal names exist.
            // Configuration state only, nothing about the source; the allowlist is the usual first stumbling block.
            app.logger.info("migration source refused before connecting", metadata: ["reason": "\((error as? HostGuard.Failure) == .blocked ? "blocked" : "unresolvable")"])
            throw SourceFailure.notAllowed
        }
        let pinned = addresses[0], port = source.port
        if source.tls == "verify" {
            // Stock mysql-nio continued in plain text when the server did not offer TLS; the vendored driver (backend/Vendor)
            // now aborts before authentication. The probe stays for the named error (noTLS) before any credential is used.
            guard try await SourceTLSProbe.offersTLS(address: pinned, port: port, group: app.eventLoopGroup) else { throw SourceFailure.noTLS }
        } else {
            // Explicit, allowed only with FORM_ALLOW_INSECURE_DEV: loopback and throw-away sources without TLS.
            app.logger.warning("migration source used without TLS (tls=disable, insecure mode)")
        }
        var config = MySQLConfiguration(hostname: source.host, port: port, username: source.username, password: source.password, database: source.database)
        // Preserve the original TLS hostname while pinning the actual socket address.
        config.address = { try SocketAddress(ipAddress: pinned, port: port) }
        if source.tls == "disable" { config.tlsConfiguration = nil }
        let connectionApp = try await Application.make(.production)
        connectionApp.logger.logLevel = .critical
        connectionApp.databases.use(.mysql(configuration: config, maxConnectionsPerEventLoop: 1, sqlLogLevel: nil), as: .mysql)
        do {
            let sourceDB = connectionApp.db(.mysql) as! SQLDatabase
            let verify = source.tls == "verify"
            let result = try await sourceDB.withSession { session in
                try await session.raw("SELECT 1").run()
                if verify {
                    // Second line of defence (the probe cannot see a path attacker who only strips TLS on the real connection).
                    let cipher = try await session.raw("SHOW SESSION STATUS LIKE 'Ssl_cipher'").first(decoding: SessionStatus.self)?.Value ?? ""
                    guard !cipher.isEmpty else { throw SourceFailure.noTLS }
                }
                // Strict allowlist: roles, global write rights and GRANT OPTION are rejected.
                let grants = try await session.raw("SHOW GRANTS FOR CURRENT_USER").all()
                guard !grants.isEmpty else { throw SourceFailure.rights }
                for row in grants {
                    guard let column = row.allColumns.first else { throw SourceFailure.rights }
                    let grant = try row.decode(column: column, as: String.self)
                    guard Self.readOnlyGrant(grant) else { throw SourceFailure.rights }
                }
                return try await body(session)
            }
            try await connectionApp.asyncShutdown(); return result
        } catch {
            try? await connectionApp.asyncShutdown()
            // Neither driver nor source diagnostics can cross this boundary: only the classified cause.
            var failure = SourceFailure.classify(error)
            if failure == .certUntrusted {
                // Unknown CA and expired look the same in the handshake error. A separate, credential-free connection reads the certificate.
                if let notAfter = await SourceTLSProbe.leafNotValidAfter(address: pinned, port: port, group: app.eventLoopGroup), Double(notAfter) < Date().timeIntervalSince1970 { failure = .certExpired }
            }
            throw failure
        }
    }
    static func readOnlyGrant(_ grant: String) -> Bool {
        guard grant.hasPrefix("GRANT "), let range = grant.range(of: " ON "), !grant.contains("WITH GRANT OPTION") else { return false }
        return grant[grant.index(grant.startIndex, offsetBy: 6)..<range.lowerBound].split(separator: ",").allSatisfy {
            ["SELECT", "SHOW VIEW", "USAGE"].contains($0.trimmingCharacters(in: .whitespaces))
        }
    }
    func audit(_ tx: SQLDatabase, actor: UUID, action: String, details: String = "{}") async throws {
        try await tx.raw("INSERT INTO audit_events(id,actor_id,actor_kind,category,action_code,occurred_at,safe_details_json) VALUES(\(bind: DB.bin(UUID())),\(bind: DB.bin(actor)),'human','system',\(bind: action),\(bind: DB.time(Date())),\(bind: details))").run()
    }
    func tick(recover: Bool = false) async throws {
        struct L: Decodable { let acquired: Int? }
        try await sql.withSession { lock in
            guard try await lock.raw("SELECT GET_LOCK('form_migration_jobs',0) AS acquired").first(decoding: L.self)?.acquired == 1 else { return }
            do {
                // Crash recovery requires explicit human resume; never silently restart an import.
                if recover { try await lock.raw("UPDATE migration_jobs SET state='paused',phase='approval',updated_at=UTC_TIMESTAMP(6) WHERE state='running'").run() }
                guard try await SystemSettings.value("migration.enabled", sql: sql) == "true" else {
                    try await lock.raw("SELECT RELEASE_LOCK('form_migration_jobs')").run(); return
                }
                if let job = try await lock.raw("SELECT * FROM migration_jobs WHERE state='queued' ORDER BY created_at LIMIT 1").first(decoding: MigrationJob.self) {
                    try await execute(job, session: lock)
                }
                try await lock.raw("SELECT RELEASE_LOCK('form_migration_jobs')").run()
            } catch { try? await lock.raw("SELECT RELEASE_LOCK('form_migration_jobs')").run(); throw error }
        }
    }
    /// Short, stable, secret-free cause for the job list (column error_code is VARCHAR(40)). The phase already names the table.
    static func errorCode(for error: Error) -> String {
        if let failure = error as? SourceFailure { return failure.jobCode }
        guard let failure = error as? ImportFailure else { return "migration_failed" }
        switch failure {
        case let .invalidSourceAt(_, column, reason):
            let safe = column.utf8.count <= 20 && column.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 }) ? column : "column"
            return String("\(reason.rawValue)@\(safe)".prefix(40))
        case .invalidSource: return "invalid_source"
        case .snapshotChanged: return "snapshot_changed"
        case .sourceChanged: return "source_changed"
        case .sourceNotQuiesced: return "source_not_quiesced"
        case .invalidPlan, .invalidPlanField: return "invalid_plan"
        case .statisticsReviewMissing: return "statistics_review_missing"
        case .statisticsKeyUnknown: return "statistics_key_unknown"
        case .conflict: return "conflict"
        case .missingTarget: return "missing_target"
        case .database: return "database"
        // Server error number and index/column name (never the message): "database@1062:uq_customer_active_key".
        case let .databaseAt(_, code, _, object): return String("database@\(code)\(object.isEmpty ? "" : ":" + object)".prefix(40))
        case let .keyConflict(reason): return "key_conflict_" + reason.rawValue.lowercased()
        case .targetFormsLive: return "target_forms_live"
        case .customerNameMismatch: return "customer_name_mismatch"
        case let .targetPacketTooSmall(limit, largest): return PacketRequirement.jobCode(limit: limit, largest: largest)
        case .lock: return "lock"
        case .interrupted: return "interrupted"
        }
    }
    /// `session` is the connection that holds the job lock. The importer runs its target work on that same connection, so a
    /// running job holds one pooled connection (plus short single queries) instead of two long-lived ones; holding two while
    /// requesting a third from the same event-loop pool deadlocked the pool together with the maintenance schedulers.
    func execute(_ job: MigrationJob, session: SQLDatabase? = nil) async throws {
        let target = session ?? sql
        let id = job.id
        try await sql.raw("UPDATE migration_jobs SET state='running',phase='source',updated_at=UTC_TIMESTAMP(6) WHERE id=\(bind: id)").run()
        do {
            guard let actor = DB.uuid(job.actor_id.data) else { throw Abort(.forbidden) }
            try await PermissionService(sql: sql).authorize(account: actor, "migration.run", on: .system)
            let refs = try JSONDecoder().decode(MigrationSourceRefs.self, from: Data(job.source_json.utf8))
            let source = try await open(refs), hmac = try await key()
            let plan = try JSONDecoder().decode(ImportPlan.self, from: Data(job.plan_json.utf8))
            // The rehearsal's fingerprint (report_json) is what a real run expects; progress writes keep it so that a resume still has it.
            let storedFingerprint = (try? JSONSerialization.jsonObject(with: Data(job.report_json.utf8)) as? [String: Any])?["sourceFingerprint"] as? String
            let expectedFingerprint = job.dry_run == 0 ? storedFingerprint : nil
            // withSource replaces every error by one generic answer. The importer's own failures carry a safe description
            // (table, column, reason; never a source value), so they travel out as a value and keep the real cause.
            let outcome = try await withSource(source) { src -> Result<ImportReport, ImportFailure> in
              do {
                let importer = try LegacyImporter(source: src, target: target, secrets: secrets, hmacKey: hmac)
                return .success(try await importer.run(plan: plan, dryRun: job.dry_run == 1, expectedSchema: job.expected_schema, expectedSourceFingerprint: expectedFingerprint) { phase, processed in
                    struct C: Decodable { let cancel_requested: Int }
                    let cancel = try await sql.raw("SELECT cancel_requested FROM migration_jobs WHERE id=\(bind: id)").first(decoding: C.self)?.cancel_requested
                    let enabled = try await SystemSettings.value("migration.enabled", sql: sql) == "true"
                    if Task.isCancelled || cancel != 0 || !enabled { throw ImportFailure.interrupted }
                    try await PermissionService(sql: sql).authorize(account: actor, "migration.run", on: .system)
                    let progress = expectedFingerprint.map { "{\"processed\":\(processed),\"sourceFingerprint\":\"\($0)\"}" } ?? "{\"processed\":\(processed)}"
                    try await sql.raw("UPDATE migration_jobs SET phase=\(bind: phase),report_json=\(bind: progress),updated_at=UTC_TIMESTAMP(6) WHERE id=\(bind: id)").run()
                })
              } catch let failure as ImportFailure { return .failure(failure) }
            }
            var report = try outcome.get()
            let knownTables: Set<String> = ["datenschluessel", "datenschluesselRecovery", "outgoingMailServer", "outgoingMailProxy", "formulare", "formularFelder", "anfragen", "anfrageIdempotenz", "formularWebhooks", "statistics"]
            let other = report.inventory.filter { !knownTables.contains($0.key) }.values.reduce(0, +)
            report.inventory = report.inventory.filter { knownTables.contains($0.key) }
            if other > 0 { report.inventory["otherTables"] = other }
            var safeReport = try JCS.parse(Data(try Self.encode(report).utf8))
            if job.dry_run == 0 {
                struct Issue: Decodable { let issue_code: String; let count: Int }
                // All runs of the namespace: a repeated run (new snapshot id) resumes ledger entries and does not report their cases again.
                let issues = try await sql.raw("SELECT i.issue_code, COUNT(DISTINCT i.source_table, i.source_key) AS count FROM migration_issues i JOIN migration_runs r ON r.id=i.run_id WHERE r.source_namespace=\(bind: plan.namespace) AND i.state='open' GROUP BY i.issue_code").all(decoding: Issue.self)
                let codes = Set(["migration-review", "unmapped-table", "unmapped-column", "source-deletion-review", "unsupported-content", "statistics-review-missing", "statistics-key-unknown"])
                // One entry per code (unknown codes are folded into migration-review and summed).
                var totals: [String: Int] = [:]
                for issue in issues { totals[codes.contains(issue.issue_code) ? issue.issue_code : "migration-review", default: 0] += issue.count }
                let summary: [JSONValue] = totals.sorted { $0.key < $1.key }.map { .object(["code": .string($0.key), "count": .int(Int64($0.value))]) }
                if case .object(var fields) = safeReport { fields["issues"] = .array(summary); safeReport = .object(fields) }
                try await sql.raw("UPDATE migration_jobs SET phase='conversion',updated_at=UTC_TIMESTAMP(6) WHERE id=\(bind: id)").run()
                var conversions: [JSONValue] = []
                try await sql.raw("UPDATE migration_jobs SET report_json=\(bind: String(decoding: JCS.canonicalize(safeReport), as: UTF8.self)) WHERE id=\(bind: id)").run()
                for formID in plan.formCustomers.keys.sorted() {
                    guard let form = UUID(uuidString: formID) else { throw ImportFailure.invalidPlan }
                    let result = try await db.transaction { conn in
                        try await LegacyConversionRoutes.perform(conn as! SQLDatabase, form: form, account: actor, method: .POST, now: Date(), includeDocument: false, permission: "migration.run")
                    }
                    conversions.append(result)
                    struct C: Decodable { let cancel_requested: Int }
                    let cancel = try await sql.raw("SELECT cancel_requested FROM migration_jobs WHERE id=\(bind: id)").first(decoding: C.self)?.cancel_requested
                    if Task.isCancelled || cancel != 0 { throw ImportFailure.interrupted }
                }
                if case .object(var fields) = safeReport { fields["conversions"] = .array(conversions); safeReport = .object(fields) }
            }
            let encoded = String(decoding: JCS.canonicalize(safeReport), as: UTF8.self)
            // A completed importer with review cases is awaiting review, never cutover-ready.
            try await sql.raw("UPDATE migration_jobs SET state='review',phase='verification',report_json=\(bind: encoded),updated_at=UTC_TIMESTAMP(6) WHERE id=\(bind: id)").run()
        } catch {
            let paused = (error as? ImportFailure).map { if case .interrupted = $0 { return true }; return false } ?? false
            let code = paused ? "interrupted" : Self.errorCode(for: error)
            // Importer failures describe themselves safely (no source values); anything else only by type (may contain SQL values).
            if let failure = error as? ImportFailure { app.logger.error("migration job failed", metadata: ["jobId": "\(DB.uuid(id.data)?.uuidString.lowercased() ?? "?")", "failure": "\(failure)"]) }
            else if let failure = error as? SourceFailure { app.logger.error("migration job failed", metadata: ["jobId": "\(DB.uuid(id.data)?.uuidString.lowercased() ?? "?")", "source": "\(failure.jobCode)"]) }
            else { app.logger.error("migration job failed", metadata: ["jobId": "\(DB.uuid(id.data)?.uuidString.lowercased() ?? "?")", "type": "\(type(of: error))"]) }
            try await sql.raw("UPDATE migration_jobs SET state=\(bind: paused ? "paused" : "failed"),error_code=\(bind: code),updated_at=UTC_TIMESTAMP(6) WHERE id=\(bind: id)").run()
        }
    }
}
struct MigrationScheduler: LifecycleHandler {
    let service: MigrationService
    func didBoot(_ app: Application) throws {
        app.storage[MigrationTask.self] = Task {
            var recover = true
            while !Task.isCancelled {
                do { try await service.tick(recover: recover); recover = false } catch { /* No raw driver diagnostics. */ }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    func shutdown(_ app: Application) { app.storage[MigrationTask.self]?.cancel() }
}
private struct MigrationTask: StorageKey { typealias Value = Task<Void, Never> }
