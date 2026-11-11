// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormMigration
import FormPersistence
import Foundation
import SQLKit
import Vapor

public enum SetupMigrationRoutes {
    static func response(_ value: Any) throws -> Response {
        let result = try MailRoutes.anyJSON(value)
        result.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return result
    }
    static func decode<T: Decodable>(_ req: Request, allowed: Set<String>) throws -> T {
        guard let buffer = req.body.data else { throw Abort(.badRequest) }
        do { _ = try JCS.parse(Data(buffer: buffer)) } catch { throw Abort(.badRequest) }
        return try FormAdmin.decodeStrict(req, allowed: allowed)
    }
    /// Display labels by lowercased UUID, read only when the column exists. Values are trimmed, limited to 200 characters
    /// and must be valid UTF-8 without control characters; anything else is left out (never guessed).
    static func labels(_ source: SQLDatabase, table: String, idColumn: String, labelColumn: String, limit: Int) async throws -> [String: String] {
        struct C: Decodable { let n: Int }
        let present = try await source.raw("SELECT COUNT(*) AS n FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=\(bind: table) AND COLUMN_NAME IN (\(bind: idColumn), \(bind: labelColumn))").first(decoding: C.self)?.n ?? 0
        guard present == 2 else { return [:] }
        struct L: Decodable { let id: String; let label: String? }
        let rows = try await source.raw("SELECT CAST(\(ident: idColumn) AS CHAR) AS id, CAST(\(ident: labelColumn) AS CHAR) AS label FROM \(ident: table) ORDER BY ID LIMIT \(unsafeRaw: String(limit))").all(decoding: L.self)
        var result: [String: String] = [:]
        for row in rows {
            guard let id = UUID(uuidString: row.id)?.uuidString.lowercased(), let raw = row.label else { continue }
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            result[id] = String(label.prefix(200))
        }
        return result
    }
    public static func register(_ app: Application, guardian: AuthGuard, secrets: SecretStore, allowInsecure: Bool = false, startWorker: Bool = true) {
        guard guardian.config.listener == "internal" else { return }
        let service = MigrationService(app: app, secrets: secrets, allowInsecure: allowInsecure)
        let db = service.db, sql = service.sql
        if startWorker { app.lifecycle.use(MigrationScheduler(service: service)) }
        // Called only from the internal listener registration, never FormAdmin.register.
        app.get("admin", "api", "v1", "setup-state") { req async throws -> Response in
            let session = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let permissions = PermissionService(sql: sql)
            let allowed = try await permissions.can(account: session.accountID!, "system.settings", on: .system)
            let migration = try await permissions.can(account: session.accountID!, "migration.run", on: .system)
            let completed = try await SystemSettings.value("setup.completed", sql: sql) == "true"
            return try response(["required": allowed && !completed, "migrationAllowed": migration,
                "migrationEnabled": try await SystemSettings.value("migration.enabled", sql: sql) == "true"])
        }
        let root = app.grouped("admin", "api", "v1", "migration")
        // All controls share live permission checks and mutation protection. Fresh authentication (contracts/auth/anmeldung.md,
        // "Frische Authentifizierung") is required for every mutation and for the probe read (migrated ciphertext, audited);
        // only the plain status list GET /migration/jobs (explicit allowlist, no secrets) works without it.
        func authorize(_ req: Request, mutation: Bool, fresh: Bool) async throws -> UUID {
            let session = try await guardian.requireAuthenticated(req, mutation: mutation)
            try await guardian.budget(req)
            if fresh || mutation { try await guardian.requireFreshAuthentication(session, now: Date()) }
            try await PermissionService(sql: sql).authorize(account: session.accountID!, "migration.run", on: .system)
            guard try await SystemSettings.value("migration.enabled", sql: sql) == "true" else { throw Abort(.forbidden) }
            return session.accountID!
        }
        MigrationVerificationRoutes.register(root, service: service, authorize: { req, mutation in try await authorize(req, mutation: mutation, fresh: true) })
        root.post("test") { req async throws -> Response in
            let actor = try await authorize(req, mutation: true, fresh: true)
            let input: MigrationSource = try decode(req, allowed: ["host", "port", "database", "username", "password", "tls"])
            let key = try await service.key()
            // Shared with jobs: strict migration.allowedNets check and a pinned socket, even for source tests.
            let inventory: [String: Any] = try await service.withSource(input) { source in
                let hmac = try await LegacyImporter(source: source, target: sql, secrets: secrets, hmacKey: key).inspectSchema()
                struct F: Decodable { let id: String }
                let forms = try await source.raw("SELECT CAST(UUID AS CHAR) AS id FROM formulare ORDER BY ID LIMIT 1001").all(decoding: F.self)
                guard forms.count <= 1000, forms.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw Abort(.unprocessableEntity) }
                var counts: [String: Int] = [:]
                struct C: Decodable { let count: Int }
                for table in ["datenschluessel", "outgoingMailServer", "outgoingMailProxy", "formulare", "formularFelder", "anfragen", "anfrageIdempotenz", "formularWebhooks", "statistics"] {
                    counts[table] = try await source.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first(decoding: C.self)?.count ?? 0
                }
                // Mail connections the plan must assign to customers (connectionCustomers); ids only, never credentials.
                var connectionIds: [String] = []
                var connections: [[String: Any]] = []
                for table in ["outgoingMailServer", "outgoingMailProxy"] {
                    let rows = try await source.raw("SELECT CAST(UUID AS CHAR) AS id FROM \(ident: table) ORDER BY ID LIMIT 101").all(decoding: F.self)
                    guard rows.count <= 100, rows.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw Abort(.unprocessableEntity) }
                    connectionIds += rows.map { $0.id.lowercased() }
                    // Display name only (ADR 0040); host, user, password, proxy URL and auth stay in the source.
                    let names = try await Self.labels(source, table: table, idColumn: "UUID", labelColumn: "name", limit: 100)
                    connections += rows.map { ["id": $0.id.lowercased(), "kind": table == "outgoingMailServer" ? "smtp" : "mail-proxy", "name": names[$0.id.lowercased()].map { $0 as Any } ?? NSNull()] }
                }
                // Form display names and the referenced mail connections (only values that are UUIDs of a listed connection).
                let formNames = try await Self.labels(source, table: "formulare", idColumn: "UUID", labelColumn: "name", limit: 1000)
                let known = Set(connectionIds)
                var formConnections: [String: [String]] = [:]
                for column in ["outgoingProductionServer", "outgoingTestingServer"] {
                    for (id, value) in try await Self.labels(source, table: "formulare", idColumn: "UUID", labelColumn: column, limit: 1000) {
                        if let ref = UUID(uuidString: value)?.uuidString.lowercased(), known.contains(ref), !(formConnections[id] ?? []).contains(ref) { formConnections[id, default: []].append(ref) }
                    }
                }
                let formItems: [[String: Any]] = forms.map { form in
                    let id = form.id.lowercased()
                    return ["id": id, "name": formNames[id].map { $0 as Any } ?? NSNull(), "connectionIds": (formConnections[id] ?? []).sorted()]
                }
                let keys = try await LegacyKeyInventory.scan(source)
                return (["schemaHMAC": hmac, "readOnly": true, "formIds": forms.map { $0.id.lowercased() }, "connectionIds": connectionIds, "counts": counts,
                         "forms": formItems, "connections": connections] as [String: Any]).merging(keys.json) { current, _ in current }
            }
            try await service.audit(sql, actor: actor, action: "migration.source.test")
            return try response(inventory)
        }
        root.on(.POST, "jobs", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            let actor = try await authorize(req, mutation: true, fresh: true)
            struct Input: Decodable { let source: MigrationSource; let plan: ImportPlan; let expectedSchema: String; let dryRun: Bool }
            let input: Input = try decode(req, allowed: ["source", "plan", "expectedSchema", "dryRun"])
            guard input.dryRun else { throw Abort(.unprocessableEntity) }
            try input.source.validate(allowInsecure: allowInsecure)
            guard input.expectedSchema.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw Abort(.unprocessableEntity) }
            guard !input.plan.namespace.isEmpty, input.plan.namespace.utf8.count <= 64,
                  input.plan.namespace.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }),
                  input.plan.dumpSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  !input.plan.customers.isEmpty,
                  input.plan.customers.allSatisfy({ UUID(uuidString: $0.key) != nil && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  input.plan.formCustomers.values.allSatisfy({ input.plan.customers[$0] != nil }) else { throw Abort(.unprocessableEntity) }
            let hmac = try await service.key()
            try await service.withSource(input.source) { source in
                let actual = try await LegacyImporter(source: source, target: sql, secrets: secrets, hmacKey: hmac).inspectSchema()
                guard actual == input.expectedSchema else { throw Abort(.unprocessableEntity) }
                struct F: Decodable { let id: String }
                let ids = try await source.raw("SELECT CAST(UUID AS CHAR) AS id FROM formulare ORDER BY ID").all(decoding: F.self)
                guard Set(ids.map { $0.id.lowercased() }) == Set(input.plan.formCustomers.keys) else { throw Abort(.unprocessableEntity) }
            }
            let id = UUID(), at = DB.time(Date())
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                let refs = try await service.store(input.source, on: tx)
                try await tx.raw("""
                    INSERT INTO migration_jobs(id,actor_id,source_json,plan_json,expected_schema,state,phase,dry_run,report_json,created_at,updated_at)
                    VALUES(\(bind: DB.bin(id)),\(bind: DB.bin(actor)),\(bind: MigrationService.encode(refs)),\(bind: MigrationService.encode(input.plan)),\(bind: input.expectedSchema),'queued','source',\(bind: input.dryRun ? 1 : 0),'{}',\(bind: at),\(bind: at))
                    """).run()
                try await service.audit(tx, actor: actor, action: "migration.job.create")
            }
            return try response(["id": id.uuidString.lowercased()])
        }
        root.get("jobs") { req async throws -> Response in
            _ = try await authorize(req, mutation: false, fresh: false)
            let jobs = try await sql.raw("SELECT * FROM migration_jobs ORDER BY created_at DESC LIMIT 50").all(decoding: MigrationJob.self)
            // Explicit allowlist: no source refs, plan names, source keys or raw issues.
            let items: [[String: Any]] = try jobs.map { job in
                ["id": DB.uuid(job.id.data)!.uuidString.lowercased(), "state": job.state, "phase": job.phase,
                 "formIds": (try JSONDecoder().decode(ImportPlan.self, from: Data(job.plan_json.utf8))).formCustomers.keys.sorted(),
                 "probeConfirmed": job.probe_hash != nil, "testConfirmed": job.test_hash != nil,
                 "dryRun": job.dry_run == 1, "report": try JSONSerialization.jsonObject(with: Data(job.report_json.utf8)), "error": job.error_code ?? ""]
            }
            return try response(["items": items])
        }
        root.post("jobs", ":jobId", ":action") { req async throws -> Response in
            let actor = try await authorize(req, mutation: true, fresh: true)
            let id = try FormAdmin.uuidParam(req, "jobId"), action = req.parameters.get("action") ?? ""
            guard ["pause", "resume", "import", "delta", "remove-source"].contains(action) else { throw Abort(.notFound) }
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard let job = try await tx.raw("SELECT * FROM migration_jobs WHERE id=\(bind: DB.bin(id)) FOR UPDATE").first(decoding: MigrationJob.self) else { throw Abort(.notFound) }
                switch action {
                case "pause":
                    guard ["queued", "running"].contains(job.state) else { throw Abort(.conflict) }
                    try await tx.raw("UPDATE migration_jobs SET cancel_requested=1,state=IF(state='queued','paused',state) WHERE id=\(bind: DB.bin(id))").run()
                case "resume":
                    guard ["paused", "failed"].contains(job.state) else { throw Abort(.conflict) }
                    try await tx.raw("UPDATE migration_jobs SET state='queued',actor_id=\(bind: DB.bin(actor)),cancel_requested=0,error_code=NULL WHERE id=\(bind: DB.bin(id))").run()
                case "delta":
                    guard job.state == "review", job.dry_run == 0 else { throw Abort(.conflict) }
                    struct Delta: Decodable { let dumpSHA256: String }
                    let input: Delta = try decode(req, allowed: ["dumpSHA256"])
                    guard input.dumpSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw Abort(.unprocessableEntity) }
                    var plan = try JSONDecoder().decode(ImportPlan.self, from: Data(job.plan_json.utf8))
                    guard plan.dumpSHA256 != input.dumpSHA256 else { throw Abort(.conflict) }
                    plan.dumpSHA256 = input.dumpSHA256
                    try await tx.raw("UPDATE migration_jobs SET plan_json=\(bind: MigrationService.encode(plan)),state='queued',dry_run=1,actor_id=\(bind: DB.bin(actor)),cancel_requested=0,probe_hash=NULL,test_hash=NULL WHERE id=\(bind: DB.bin(id))").run()
                case "import":
                    guard job.state == "review", job.dry_run == 1 else { throw Abort(.conflict) }
                    try await tx.raw("UPDATE migration_jobs SET state='queued',dry_run=0,actor_id=\(bind: DB.bin(actor)),cancel_requested=0 WHERE id=\(bind: DB.bin(id))").run()
                default:
                    guard ["review", "paused", "failed"].contains(job.state) else { throw Abort(.conflict) }
                    // Removing the source after a real import requires both browser confirmations (probe decryption and test message);
                    // aborting a dry run, a paused or a failed job stays possible.
                    if job.state == "review", job.dry_run == 0, job.probe_hash == nil || job.test_hash == nil { throw Abort(.conflict) }
                    let refs = try JSONDecoder().decode(MigrationSourceRefs.self, from: Data(job.source_json.utf8))
                    for ref in [refs.host, refs.database, refs.username, refs.password] {
                        try await tx.raw("DELETE FROM managed_secrets WHERE ref=\(bind: ref)").run()
                    }
                    try await tx.raw("UPDATE migration_jobs SET state='closed',source_json='{}' WHERE id=\(bind: DB.bin(id))").run()
                }
                try await service.audit(tx, actor: actor, action: "migration.job." + action)
            }
            return try response(["status": "accepted"])
        }
    }
}
