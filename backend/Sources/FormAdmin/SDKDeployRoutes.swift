// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormDeploy
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// SDK self-update targets (ADR 0011, VORGESCHLAGEN): `PUT/GET /tenants/{t}/forms/{f}/sdk-target`, `POST …/sdk-target/install|rollback`.
/// Right: `key.manage` at the customer (like the SDK credentials), fresh login for every change and every run.
enum SDKDeployRoutes {
    static func register(tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, deploy: DeployService?, bundleVersion: @escaping @Sendable () -> String?,
                         now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase

        func scope(_ req: Request, mutation: Bool, fresh: Bool) async throws -> (UUID, UUID, UUID) {
            let s = try await guardian.requireAuthenticated(req, mutation: mutation)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), form = try FormAdmin.uuidParam(req, "formId")
            let exists = try await FormAdmin.CountRow.count(sql, "SELECT COUNT(*) AS c FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.id = \(bind: DB.bin(form)) AND f.customer_id = \(bind: DB.bin(tenant)) AND c.state = 'active'") == 1
            // the connection and the remote path reach beyond one form, so changes and runs need key.manage at the customer (ADR 0011, decision 6)
            try await perms.authorize(account: s.accountID!, mutation || fresh ? "key.manage" : "form.read", on: mutation || fresh ? .customer(tenant) : .form(customer: tenant, form: form), exists: exists)
            if fresh { try await guardian.requireFreshAuthentication(s, now: now()) }
            return (tenant, form, s.accountID!)
        }

        tenants.get("forms", ":formId", "sdk-target") { req async throws -> Response in
            let (tenant, form, _) = try await scope(req, mutation: false, fresh: false)
            struct T: Decodable { let connection_id: Blob; let remote_dir: String; let auto_update: Int; let installed_version: String?; let previous_version: String?; let last_result: String?; let run_phase: String? }
            struct H: Decodable { let action: String; let trigger_kind: String; let from_version: String?; let to_version: String?; let result: String; let error_code: String?; let started_at: Date }
            guard let t = try await sql.raw("SELECT connection_id, remote_dir, auto_update, installed_version, previous_version, last_result, run_phase FROM sdk_targets WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").first(decoding: T.self)
            else { return try MailRoutes.anyJSON(["target": NSNull(), "availableVersion": bundleVersion() as Any? ?? NSNull()] as [String: Any]) }
            let rows = try await sql.raw("SELECT action, trigger_kind, from_version, to_version, result, error_code, started_at FROM sdk_deployments WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) ORDER BY started_at DESC LIMIT 10").all(decoding: H.self)
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var target: [String: Any] = ["connectionId": DB.uuid(t.connection_id.data)?.uuidString.lowercased() ?? "", "remoteDir": t.remote_dir, "autoUpdate": t.auto_update == 1]
            if let v = t.installed_version { target["installedVersion"] = v }
            if let v = t.previous_version { target["previousVersion"] = v }
            if let v = t.last_result { target["lastResult"] = v }
            if let v = t.run_phase { target["runPhase"] = v }   // a running (or not yet closed, crashed) run
            let res = try MailRoutes.anyJSON(["target": target, "availableVersion": bundleVersion() as Any? ?? NSNull(),
                "history": rows.map { r -> [String: Any] in
                    var o: [String: Any] = ["action": r.action, "trigger": r.trigger_kind, "result": r.result, "at": iso.string(from: r.started_at)]
                    if let v = r.from_version { o["from"] = v }; if let v = r.to_version { o["to"] = v }; if let v = r.error_code { o["errorCode"] = v }
                    return o
                }] as [String: Any])
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }

        tenants.put("forms", ":formId", "sdk-target") { req async throws -> Response in
            let (tenant, form, account) = try await scope(req, mutation: true, fresh: true)
            let obj = try MailRoutes.jsonObject(req, allowed: ["connectionId", "remoteDir", "autoUpdate"])
            guard let cid = (obj["connectionId"] as? String).flatMap(MailRoutes.lowerUUID), let dir = obj["remoteDir"] as? String, (try? SDKDeployer.split(dir)) != nil,
                  let auto = obj["autoUpdate"] as? Bool else { throw ValidationFailed(detail: "connectionId, remoteDir (absoluter Pfad, mind. 2 Ebenen, nur a-z A-Z 0-9 . _ - Leerzeichen), autoUpdate") }
            let ts = DB.time(now())
            struct L: Decodable { let l: Int? }
            struct C: Decodable { let kind: String; let safe_config_json: String }
            struct O: Decodable { let remote_dir: String; let kind: String; let safe_config_json: String }
            // Review Astra 2 M1: a target change waits for no run (409 while one runs for this form) and is serialised per physical account,
            // so no two targets on one account can claim overlapping paths (live, .prev, staging, swap).
            try await sql.withSession { session in
                let formLock = DeployService.formLockName(form)
                guard try await session.raw("SELECT GET_LOCK(\(literal: formLock), 0) AS l").first(decoding: L.self)?.l == 1 else { throw SDKDeployProblem.busy }
                var accountLock: String? = nil
                do {
                    guard let c = try await session.raw("""
                        SELECT c.kind AS kind, c.safe_config_json AS safe_config_json FROM customer_connections cc JOIN connections c ON c.id = cc.connection_id
                        WHERE cc.customer_id = \(bind: DB.bin(tenant)) AND cc.connection_id = \(bind: DB.bin(cid)) AND c.kind IN ('ftp','sftp') AND c.enabled = 1
                        """).first(decoding: C.self) else { throw ValidationFailed(detail: "Die Verbindung ist keine dem Kunden zugeordnete FTP-/SFTP-Verbindung") }
                    let identity = DeployService.accountIdentity(configJSON: c.safe_config_json)
                    let lock = DeployService.targetChangeLockName(configJSON: c.safe_config_json)
                    guard try await session.raw("SELECT GET_LOCK(\(literal: lock), 5) AS l").first(decoding: L.self)?.l == 1 else { throw SDKDeployProblem.targetChangeBusy }
                    accountLock = lock
                    // a run that died on the old target is recorded first (interrupted / repair_required), never silently reset (gegenlesen Astra 2)
                    try await DeployService.closeOpenRun(session, customer: tenant, form: form, now: now(), logger: req.logger)
                    try await session.raw("START TRANSACTION").run()   // after the locks: this snapshot sees every earlier committed change
                    do {
                        try await PermissionService(sql: session).authorize(account: account, "key.manage", on: .customer(tenant))
                        let others = try await session.raw("""
                            SELECT t.remote_dir AS remote_dir, c.kind AS kind, c.safe_config_json AS safe_config_json
                            FROM sdk_targets t JOIN connections c ON c.id = t.connection_id
                            WHERE NOT (t.customer_id = \(bind: DB.bin(tenant)) AND t.form_id = \(bind: DB.bin(form)))
                            """).all(decoding: O.self)
                        if others.contains(where: { DeployService.accountIdentity(configJSON: $0.safe_config_json) == identity && SDKDeployer.overlaps(dir, $0.remote_dir) }) {
                            throw SDKDeployProblem.overlap
                        }
                        // Every IF(...) must compare the OLD values. MariaDB's default evaluates the assignments left to right, so they come
                        // before the assignments of connection_id/remote_dir; under SIMULTANEOUS_ASSIGNMENT every expression sees the old row
                        // anyway. Both modes give the same result.
                        try await session.raw("""
                            INSERT INTO sdk_targets (customer_id, form_id, connection_id, remote_dir, auto_update, updated_at)
                            VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: DB.bin(cid)), \(bind: dir), \(bind: auto ? 1 : 0), \(bind: ts))
                            ON DUPLICATE KEY UPDATE
                              installed_version = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), NULL, installed_version),
                              previous_version = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), NULL, previous_version),
                              last_result = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), NULL, last_result),
                              last_attempt_version = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), NULL, last_attempt_version),
                              run_phase = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), NULL, run_phase),
                              run_action = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), NULL, run_action),
                              run_trigger = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), NULL, run_trigger),
                              run_started_at = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), NULL, run_started_at),
                              target_revision = IF(remote_dir <> VALUES(remote_dir) OR connection_id <> VALUES(connection_id), target_revision + 1, target_revision),
                              connection_id = VALUES(connection_id), remote_dir = VALUES(remote_dir), auto_update = VALUES(auto_update),
                              updated_at = VALUES(updated_at)
                            """).run()
                        try await ReleaseRoutes.audit(session, tenant: tenant, form: form, actor: account, action: "sdk.target.set", subject: form, at: ts, category: "sdk").run()
                        try await session.raw("COMMIT").run()
                    } catch { try? await session.raw("ROLLBACK").run(); throw error }
                    // the change is committed: a failing release must not turn it into a 500 (the lock ends with the session anyway)
                    _ = try? await session.raw("DO RELEASE_LOCK(\(literal: lock))").run()
                    _ = try? await session.raw("DO RELEASE_LOCK(\(literal: formLock))").run()
                } catch {
                    if let l = accountLock { try? await session.raw("DO RELEASE_LOCK(\(literal: l))").run() }
                    try? await session.raw("DO RELEASE_LOCK(\(literal: formLock))").run()
                    throw error
                }
            }
            return Response(status: .noContent)
        }

        for (path, action) in [("install", DeployService.Action.install), ("rollback", .rollback)] {
            tenants.post("forms", ":formId", "sdk-target", .constant(path)) { req async throws -> Response in
                let (tenant, form, account) = try await scope(req, mutation: true, fresh: true)
                guard let deploy else { throw SDKDeployProblem.unavailable }
                do {
                    let r = try await deploy.run(customer: tenant, form: form, action: action, trigger: .manual, actor: account)
                    try await ReleaseRoutes.audit(sql, tenant: tenant, form: form, actor: account, action: "sdk.\(path)", subject: form, at: DB.time(now()), category: "sdk").run()
                    var o: [String: Any] = ["ok": r.ok]
                    if let v = r.from { o["from"] = v }; if let v = r.to { o["to"] = v }; if let v = r.errorCode { o["errorCode"] = v }
                    let res = try MailRoutes.anyJSON(o); res.status = r.ok ? .ok : .badGateway
                    return res
                } catch let e as DeployService.Failure {
                    if e.code == "no_target" { throw Abort(.notFound) }
                    throw e.code == "busy" ? SDKDeployProblem.busy : SDKDeployProblem(statusCode: 400, code: "sdk_" + e.code, message: "Der SDK-Lauf wurde nicht gestartet (\(e.code)).")
                }
            }
        }
    }
}

/// Answers of the SDK target routes with their own problem code (ProblemMiddleware drops the reason of a plain 4xx `Abort`).
struct SDKDeployProblem: PublicProblemError {
    let statusCode: UInt
    let code: String
    let message: String
    static let busy = SDKDeployProblem(statusCode: 409, code: "sdk_deploy_busy", message: "Für dieses Formular oder dieses Konto läuft gerade ein SDK-Lauf.")
    static let targetChangeBusy = SDKDeployProblem(statusCode: 409, code: "sdk_target_change_busy", message: "Auf diesem Konto wird gerade ein anderes SDK-Ziel geändert. Bitte erneut versuchen.")
    static let overlap = SDKDeployProblem(statusCode: 409, code: "sdk_target_overlap", message: "Der Zielpfad überschneidet sich mit einem anderen SDK-Ziel auf demselben Konto.")
    static let unavailable = SDKDeployProblem(statusCode: 503, code: "sdk_deploy_unavailable", message: "Das SDK-Selbstupdate ist auf diesem Server nicht eingerichtet.")
}
