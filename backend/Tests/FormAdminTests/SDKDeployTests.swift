// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormDeploy
import FormPersistence
import Foundation
import SQLKit
import TestSupport
import XCTest
import XCTVapor
@testable import FormAdmin

/// ADR 0011 through the admin API: FTP connection (system administrator) -> target (key.manage) -> manual install / rollback,
/// optional automatic update, history, rights, and the FTP password never leaving the secret store.
final class SDKDeployTests: XCTestCase {
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private struct C: Decodable { let c: Int }

    func testConnectionTargetInstallRollbackAndAutomaticUpdate() async throws {
        let ftp = FakeFTPServer(); ftp.seedDir("/web"); ftp.seedDir("/web/lib"); ftp.seedFile("/web/lib/credentials.json", Data("{\"keep\":1}".utf8))
        try await ftp.start()
        do {
            try await AdminFixture.with(singleConnection: true) { f in
                let root = try await f.account(), mgr = try await f.account(), reader = try await f.account(), sysAcc = try await f.account(), tenant = try await f.customer()
                for r in ["form.create", "form.read", "key.manage", "draft.write", "release.publish"] { try await f.grant(mgr, r, customer: tenant, by: root) }
                try await f.grant(reader, "form.read", customer: tenant, by: root)
                try await f.grant(sysAcc, "system.manage", system: true, by: root)
                let cm = try await f.login(mgr), cr = try await f.login(reader), sys = try await f.login(sysAcc)
                var form = ""
                try await cm.post("tenants/\(tenant)/forms", "{\"name\":\"Kontakt\"}") { form = obj($0)["id"] as? String ?? "" }
                let base = "tenants/\(tenant)/forms/\(form)/sdk-target"

                // the connection: system administrator only, password stored encrypted, plain FTP refused without the development switch is not needed here (TLS)
                let cfg = "{\"host\":\"127.0.0.1\",\"port\":\(ftp.port),\"security\":\"explicit-tls\",\"username\":\"ftpuser\",\"verifyCertificate\":false}"
                try await cm.send(.POST, "connections", body: "{\"kind\":\"ftp\",\"name\":\"Webspace\",\"config\":\(cfg),\"credential\":\"ftppass\"}") { XCTAssertNotEqual($0.status, .created) }
                try await sys.send(.POST, "connections", body: "{\"kind\":\"ftp\",\"name\":\"kaputt\",\"config\":{\"host\":\"\"},\"credential\":\"x\"}") { XCTAssertEqual($0.status.code, 422) }
                try await sys.send(.POST, "connections", body: "{\"kind\":\"ftp\",\"name\":\"ohne\",\"config\":\(cfg)}") { XCTAssertEqual($0.status.code, 422) }
                var conn = ""
                try await sys.send(.POST, "connections", body: "{\"kind\":\"ftp\",\"name\":\"Webspace\",\"config\":\(cfg),\"credential\":\"ftppass\"}") { res async throws in
                    XCTAssertEqual(res.status, .created, text(res)); conn = obj(res)["id"] as? String ?? ""
                }
                // SFTP connections: the pinned host key is mandatory and must look like ssh-keygen -l output; the probe is system-only
                let fp = "SHA256:" + String(repeating: "A", count: 43)
                try await sys.send(.POST, "connections", body: "{\"kind\":\"sftp\",\"name\":\"s1\",\"config\":{\"host\":\"127.0.0.1\",\"username\":\"u\"},\"credential\":\"pw\"}") { XCTAssertEqual($0.status.code, 422) }
                try await sys.send(.POST, "connections", body: "{\"kind\":\"sftp\",\"name\":\"s1\",\"config\":{\"host\":\"127.0.0.1\",\"username\":\"u\",\"hostKeySha256\":\"SHA256:short\"},\"credential\":\"pw\"}") { XCTAssertEqual($0.status.code, 422) }
                try await sys.send(.POST, "connections", body: "{\"kind\":\"sftp\",\"name\":\"s1\",\"config\":{\"host\":\"127.0.0.1\",\"username\":\"u\",\"hostKeySha256\":\"\(fp)\"},\"credential\":\"pw\"}") { XCTAssertEqual($0.status, .created, text($0)) }
                try await cm.send(.POST, "connections/probe-sftp", body: "{\"host\":\"127.0.0.1\"}") { XCTAssertNotEqual($0.status, .ok) }
                try await sys.send(.POST, "connections/probe-sftp", body: "{\"host\":\"10.0.0.1\",\"port\":22}") { XCTAssertEqual($0.status.code, 422) }   // blocked network
                let leaked = try await f.sql.raw("SELECT COUNT(*) AS c FROM connections WHERE safe_config_json LIKE '%ftppass%' OR credential_ref LIKE '%ftppass%'").first(decoding: C.self)?.c
                XCTAssertEqual(leaked, 0)
                try await cm.get(base) { res async throws in XCTAssertTrue(obj(res)["target"] is NSNull); XCTAssertNotNil(obj(res)["availableVersion"] as? String) }
                // not assigned to the customer yet -> refused
                let put = { (dir: String, auto: Bool) in "{\"connectionId\":\"\(conn)\",\"remoteDir\":\"\(dir)\",\"autoUpdate\":\(auto)}" }
                try await cm.send(.PUT, base, body: put("/web/lib/form-sdk", false)) { XCTAssertEqual($0.status.code, 422) }
                try await sys.send(.PUT, "tenants/\(tenant)/connections/\(conn)") { XCTAssertEqual($0.status, .noContent) }
                // invalid paths and rights
                for bad in ["/", "/web", "web/lib/sdk", "/web/../etc/x", "/web/lib/"] { try await cm.send(.PUT, base, body: put(bad, false)) { XCTAssertEqual($0.status.code, 422, bad) } }
                try await cr.send(.PUT, base, body: put("/web/lib/form-sdk", false)) { XCTAssertEqual($0.status, .forbidden) }
                try await cm.send(.PUT, base, body: put("/web/lib/form-sdk", false)) { XCTAssertEqual($0.status, .noContent, text($0)) }

                // manual install
                try await cr.send(.POST, base + "/install") { XCTAssertEqual($0.status, .forbidden) }
                var version = ""
                try await cm.send(.POST, base + "/install") { res async throws in
                    XCTAssertEqual(res.status, .ok, text(res)); version = obj(res)["to"] as? String ?? ""
                }
                XCTAssertFalse(version.isEmpty)
                XCTAssertEqual(ftp.files["/web/lib/form-sdk/VERSION"], Data("\(version)\n".utf8))
                XCTAssertNotNil(ftp.files["/web/lib/form-sdk/src/Client.php"]); XCTAssertNotNil(ftp.files["/web/lib/form-sdk/bin/submit.php"])
                XCTAssertNil(ftp.files.keys.first { $0.contains("/tests/") })
                XCTAssertEqual(ftp.files["/web/lib/credentials.json"], Data("{\"keep\":1}".utf8))
                XCTAssertFalse(ftp.log.contains { $0.contains("ftppass") })

                // an older version really is installed (server AND database) and auto-update is OFF: the scheduler leaves it alone
                ftp.seedFile("/web/lib/form-sdk/VERSION", Data("0.0.9\n".utf8))
                try await f.sql.raw("UPDATE sdk_targets SET installed_version = '0.0.9'").run()
                let svc = f.deploy
                let ranOff = try await DeployScheduler.runOnce(svc)
                XCTAssertEqual(ranOff, 0)
                // switch it on: updated once, history records trigger auto
                try await cm.send(.PUT, base, body: put("/web/lib/form-sdk", true)) { XCTAssertEqual($0.status, .noContent) }
                let ranOn = try await DeployScheduler.runOnce(svc)
                XCTAssertEqual(ranOn, 1)
                let again = try await DeployScheduler.runOnce(svc)
                XCTAssertEqual(again, 0, "the same version is not attempted twice")
                try await cm.get(base) { res async throws in
                    let t = obj(res)["target"] as? [String: Any]
                    XCTAssertEqual(t?["installedVersion"] as? String, version); XCTAssertEqual(t?["previousVersion"] as? String, "0.0.9", "the version that was live before the update"); XCTAssertEqual(t?["autoUpdate"] as? Bool, true)
                    let h = (obj(res)["history"] as? [[String: Any]]) ?? []
                    XCTAssertEqual(h.first?["trigger"] as? String, "auto"); XCTAssertEqual(h.first?["result"] as? String, "ok")
                }

                // a manual install of the version that is already live changes nothing and keeps .prev (gegenlesen Astra 2)
                try await cm.send(.POST, base + "/install") { res async throws in XCTAssertEqual(res.status, .ok, text(res)); XCTAssertEqual(obj(res)["to"] as? String, version) }
                XCTAssertEqual(ftp.files["/web/lib/form-sdk.prev/VERSION"], Data("0.0.9\n".utf8))
                // rollback and roll forward again
                try await cm.send(.POST, base + "/rollback") { XCTAssertEqual($0.status, .ok, text($0)) }
                XCTAssertEqual(ftp.files["/web/lib/form-sdk/VERSION"], Data("0.0.9\n".utf8))
                XCTAssertEqual(ftp.files["/web/lib/form-sdk.prev/VERSION"], Data("\(version)\n".utf8))
                try await cr.send(.POST, base + "/rollback") { XCTAssertEqual($0.status, .forbidden) }

                // a deliberate rollback is not undone by the automatic update (review M3)
                let afterRollback = try await DeployScheduler.runOnce(svc)
                XCTAssertEqual(afterRollback, 0, "auto update must not reinstall the version that was just rolled back")
                // a grant on one form only is not enough: connection and remote path reach beyond that form (review H2)
                let formOnly = try await f.account()
                try await f.grant(formOnly, "key.manage", customer: tenant, form: UUID(uuidString: form)!, by: root)
                try await f.grant(formOnly, "form.read", customer: tenant, by: root)
                let cf = try await f.login(formOnly)
                try await cf.send(.PUT, base, body: put("/web/lib/other-sdk", false)) { XCTAssertEqual($0.status, .forbidden) }
                try await cf.send(.POST, base + "/install") { XCTAssertEqual($0.status, .forbidden) }
                // secrets belong into `credential`, never into the clear-text config (review M7)
                try await sys.send(.POST, "connections", body: "{\"kind\":\"ftp\",\"name\":\"leak\",\"config\":{\"host\":\"127.0.0.1\",\"username\":\"u\",\"password\":\"geheim\"},\"credential\":\"x\"}") { XCTAssertEqual($0.status.code, 422) }
                try await sys.send(.POST, "connections", body: "{\"kind\":\"sftp\",\"name\":\"leak\",\"config\":{\"host\":\"127.0.0.1\",\"username\":\"u\",\"hostKeySha256\":\"\(fp)\",\"privateKey\":\"abc\"},\"credential\":\"x\"}") { XCTAssertEqual($0.status.code, 422) }

                // a failing server is recorded and not retried in a loop
                try await f.sql.raw("UPDATE sdk_targets SET installed_version = '0.0.8', last_attempt_version = NULL").run()
                await ftp.stop()
                let failed = try await DeployScheduler.runOnce(svc)
                XCTAssertEqual(failed, 1)
                let retry = try await DeployScheduler.runOnce(svc)
                XCTAssertEqual(retry, 0)
                struct H: Decodable { let result: String; let error_code: String? }
                let last = try await f.sql.raw("SELECT result, error_code FROM sdk_deployments ORDER BY started_at DESC, id LIMIT 1").first(decoding: H.self)
                XCTAssertEqual(last?.result, "failed"); XCTAssertEqual(last?.error_code, "connect_failed")
                // manual run on a dead server answers 502 with the code, without any free text from the server
                try await cm.send(.POST, base + "/install") { res async throws in XCTAssertEqual(res.status, .badGateway); XCTAssertEqual(obj(res)["errorCode"] as? String, "connect_failed") }
            }
        } catch { await ftp.stop(); throw error }
        await ftp.stop()
    }
    // MARK: review Astra 2 M1/M2

    private struct Env { let f: AdminFixture; let cm: TestClient; let sys: TestClient; let tenant: UUID; let forms: [String] }
    /// Manager with key.manage at the customer, a system admin and `n` forms of one customer.
    private func env(_ f: AdminFixture, forms n: Int) async throws -> Env {
        let root = try await f.account(), mgr = try await f.account(), sysAcc = try await f.account(), tenant = try await f.customer()
        for r in ["form.create", "form.read", "key.manage"] { try await f.grant(mgr, r, customer: tenant, by: root) }
        try await f.grant(sysAcc, "system.manage", system: true, by: root)
        let cm = try await f.login(mgr), sys = try await f.login(sysAcc)
        var forms: [String] = []
        for i in 0..<n { try await cm.post("tenants/\(tenant)/forms", "{\"name\":\"F\(i)\"}") { forms.append(obj($0)["id"] as? String ?? "") } }
        return Env(f: f, cm: cm, sys: sys, tenant: tenant, forms: forms)
    }
    private func connection(_ e: Env, port: Int, name: String) async throws -> String {
        let cfg = "{\"host\":\"127.0.0.1\",\"port\":\(port),\"security\":\"explicit-tls\",\"username\":\"ftpuser\",\"verifyCertificate\":false}"
        var conn = ""
        try await e.sys.send(.POST, "connections", body: "{\"kind\":\"ftp\",\"name\":\"\(name)\",\"config\":\(cfg),\"credential\":\"ftppass\"}") { conn = obj($0)["id"] as? String ?? "" }
        try await e.sys.send(.PUT, "tenants/\(e.tenant)/connections/\(conn)") { XCTAssertEqual($0.status, .noContent) }
        return conn
    }
    private func put(_ e: Env, form: String, conn: String, dir: String, auto: Bool = false) async throws -> HTTPStatus {
        try await putProblem(e, form: form, conn: conn, dir: dir, auto: auto).0
    }
    /// Status and problem code (the reason of a 4xx must reach the client, gegenlesen Astra 2).
    private func putProblem(_ e: Env, form: String, conn: String, dir: String, auto: Bool = false) async throws -> (HTTPStatus, String?) {
        var st: HTTPStatus = .internalServerError, code: String? = nil
        try await e.cm.send(.PUT, "tenants/\(e.tenant)/forms/\(form)/sdk-target", body: "{\"connectionId\":\"\(conn)\",\"remoteDir\":\"\(dir)\",\"autoUpdate\":\(auto)}") { st = $0.status; code = obj($0)["code"] as? String }
        return (st, code)
    }
    private struct Rev: Decodable { let target_revision: Int; let run_phase: String?; let last_result: String?; let installed_version: String? }
    private func target(_ e: Env, _ form: String) async throws -> Rev? {
        try await e.f.sql.raw("SELECT target_revision, run_phase, last_result, installed_version FROM sdk_targets WHERE form_id = \(bind: DB.bin(UUID(uuidString: form)!))").first(decoding: Rev.self)
    }

    /// M1: the physical target (account + path) is coordinated: no two forms on overlapping paths of one FTP account (also not through a
    /// second connection record), runs on one account are serialised, target changes wait for a running deployment, and every
    /// change of connection/path is a new target revision.
    func testPhysicalTargetsAreExclusiveAndTargetChangesRespectRunningDeployments() async throws {
        let ftp = FakeFTPServer(); ftp.seedDir("/web"); ftp.seedDir("/web/lib")
        try await ftp.start()
        do {
            try await AdminFixture.with { f in
                let e = try await env(f, forms: 2)
                let (a, b) = (e.forms[0], e.forms[1])
                let conn = try await connection(e, port: ftp.port, name: "Webspace")
                let mirror = try await connection(e, port: ftp.port, name: "derselbe Webspace")   // same host, port and user
                var st = try await put(e, form: a, conn: conn, dir: "/web/lib/form-sdk"); XCTAssertEqual(st, .noContent)
                for dir in ["/web/lib/form-sdk", "/web/lib/form-sdk/inner", "/web/lib/form-sdk.prev", "/web/lib/.form-sdk.staging", "/web/lib", "/web/lib/FORM-SDK"] {
                    let (s, code) = try await putProblem(e, form: b, conn: conn, dir: dir); XCTAssertEqual(s, .conflict, dir); XCTAssertEqual(code, "sdk_target_overlap", dir)
                }
                st = try await put(e, form: b, conn: mirror, dir: "/web/lib/form-sdk"); XCTAssertEqual(st, .conflict, "a second connection record to the same account")
                st = try await put(e, form: b, conn: conn, dir: "/web/lib/form-sdk-b"); XCTAssertEqual(st, .noContent)
                st = try await put(e, form: a, conn: conn, dir: "/web/lib/form-sdk", auto: true); XCTAssertEqual(st, .noContent, "a target never conflicts with itself")

                // revision: only a change of connection or path is a new target
                let r1 = try await target(e, a)?.target_revision
                st = try await put(e, form: a, conn: conn, dir: "/web/lib/form-sdk", auto: false); XCTAssertEqual(st, .noContent)
                let r2 = try await target(e, a)?.target_revision
                st = try await put(e, form: a, conn: conn, dir: "/web/lib/form-sdk-a"); XCTAssertEqual(st, .noContent)
                let r3 = try await target(e, a)?.target_revision
                XCTAssertEqual(r1, r2); XCTAssertEqual(r3, (r2 ?? 0) + 1)

                // a running deployment of form A (its form lock is held) blocks a target change of A
                let formLock = "form_sdk_deploy_" + a.lowercased().prefix(30)
                struct L: Decodable { let l: Int? }
                try await (f.sql).withSession { s in
                    let got = try await s.raw("SELECT GET_LOCK(\(literal: String(formLock)), 0) AS l").first(decoding: L.self)?.l; XCTAssertEqual(got, 1)
                    let (s2, code) = try await self.putProblem(e, form: a, conn: conn, dir: "/web/lib/form-sdk-x"); XCTAssertEqual(s2, .conflict, "target change during a run"); XCTAssertEqual(code, "sdk_deploy_busy")
                    _ = try await s.raw("SELECT RELEASE_LOCK(\(literal: String(formLock)))").run()
                }
                // a running deployment on the same ACCOUNT (another form, even through the mirror record) makes a second run wait: 409 busy
                struct C: Decodable { let safe_config_json: String }
                let cfg = try await f.sql.raw("SELECT safe_config_json FROM connections WHERE id = \(bind: DB.bin(UUID(uuidString: mirror)!))").first(decoding: C.self)!.safe_config_json
                let accountLock = DeployService.accountLockName(configJSON: cfg)
                try await (f.sql).withSession { s in
                    let got = try await s.raw("SELECT GET_LOCK(\(literal: accountLock), 0) AS l").first(decoding: L.self)?.l; XCTAssertEqual(got, 1)
                    try await e.cm.send(.POST, "tenants/\(e.tenant)/forms/\(b)/sdk-target/install") { XCTAssertEqual($0.status, .conflict); XCTAssertEqual(self.obj($0)["code"] as? String, "sdk_deploy_busy") }
                    _ = try await s.raw("SELECT RELEASE_LOCK(\(literal: accountLock))").run()
                }
                try await e.cm.send(.POST, "tenants/\(e.tenant)/forms/\(b)/sdk-target/install") { XCTAssertEqual($0.status, .ok, text($0)) }
                XCTAssertNotNil(ftp.files["/web/lib/form-sdk-b/VERSION"])
                let tb = try await target(e, b); XCTAssertNil(tb?.run_phase, "no run left open after a normal run")
            }
        } catch { await ftp.stop(); throw error }
        await ftp.stop()
    }

    /// M2: the run and its phase are persisted before any remote change; a run that never finished (process died) is detected,
    /// recorded as `interrupted`, marks the target `repair_required` and stops the automatic until a manual run succeeded.
    func testInterruptedRunIsDetectedAndStopsTheAutomaticUntilRepaired() async throws {
        var o = FakeFTPServer.Options(); o.slowCommands = ["MKD": 0.05, "RNFR": 0.1]   // slow enough to watch the phases
        let ftp = FakeFTPServer(o); ftp.seedDir("/web"); ftp.seedDir("/web/lib")
        try await ftp.start()
        do {
            try await AdminFixture.with { f in
                let e = try await env(f, forms: 1)
                let form = e.forms[0], base = "tenants/\(e.tenant)/forms/\(form)/sdk-target"
                let conn = try await connection(e, port: ftp.port, name: "Webspace")
                let st0 = try await put(e, form: form, conn: conn, dir: "/web/lib/form-sdk", auto: true); XCTAssertEqual(st0, .noContent)

                // phases become visible in the database while the run is working
                let run = Task { try await f.deploy.run(customer: e.tenant, form: UUID(uuidString: form)!, action: .install, trigger: .manual, actor: nil) }
                var seen = Set<String>()
                for _ in 0..<400 { if let p = try await target(e, form)?.run_phase { seen.insert(p) }; if seen.contains("swap") { break }; try await Task.sleep(nanoseconds: 10_000_000) }
                let result = try await run.value
                XCTAssertTrue(result.ok)
                XCTAssertTrue(seen.isSuperset(of: ["upload", "swap"]), "\(seen)")
                let t0 = try await target(e, form); XCTAssertNil(t0?.run_phase)

                // simulate a process that died in the middle of an automatic run
                try await f.sql.raw("UPDATE sdk_targets SET installed_version = '0.0.9', run_phase = 'swap', run_action = 'install', run_trigger = 'auto', run_started_at = UTC_TIMESTAMP(6)").run()
                let before = ftp.files["/web/lib/form-sdk/VERSION"]
                _ = try await DeployScheduler.runOnce(f.deploy)
                XCTAssertEqual(ftp.files["/web/lib/form-sdk/VERSION"], before, "the automatic does not touch an unclear target")
                let t = try await target(e, form)
                XCTAssertEqual(t?.last_result, "repair_required"); XCTAssertNil(t?.run_phase)
                XCTAssertNil(t?.installed_version, "after a crash in the swap no version is claimed (codex gegenlesen 4)")
                struct H: Decodable { let action: String; let trigger_kind: String; let result: String; let error_code: String? }
                let hist = try await f.sql.raw("SELECT action, trigger_kind, result, error_code FROM sdk_deployments ORDER BY started_at DESC LIMIT 1").first(decoding: H.self)
                XCTAssertEqual(hist?.error_code, "interrupted"); XCTAssertEqual(hist?.trigger_kind, "auto"); XCTAssertEqual(hist?.result, "failed")
                try await f.sql.raw("UPDATE sdk_targets SET installed_version = '0.0.9'").run()
                let again = try await DeployScheduler.runOnce(f.deploy)
                XCTAssertEqual(again, 0, "repair_required stops the automatic")
                try await e.cm.get(base) { res async throws in XCTAssertEqual((obj(res)["target"] as? [String: Any])?["lastResult"] as? String, "repair_required") }

                // a manual run is the repair: it succeeds (the remote state is consistent) and clears the flag
                try await e.cm.send(.POST, base + "/install") { XCTAssertEqual($0.status, .ok, text($0)) }
                let t2 = try await target(e, form); XCTAssertEqual(t2?.last_result, "ok"); XCTAssertNotNil(t2?.installed_version)

                // a crash while uploading only touched .staging: interrupted, but no repair; the scheduler closes it even with auto-update
                // OFF (codex gegenlesen 3)
                let st1 = try await put(e, form: form, conn: conn, dir: "/web/lib/form-sdk", auto: false); XCTAssertEqual(st1, .noContent)
                try await f.sql.raw("UPDATE sdk_targets SET run_phase = 'upload', run_action = 'install', run_trigger = 'manual', run_started_at = UTC_TIMESTAMP(6)").run()
                try await e.cm.get(base) { res async throws in XCTAssertEqual((obj(res)["target"] as? [String: Any])?["runPhase"] as? String, "upload") }
                _ = try await DeployScheduler.runOnce(f.deploy)
                let t3 = try await target(e, form)
                XCTAssertNil(t3?.run_phase); XCTAssertEqual(t3?.last_result, "interrupted"); XCTAssertNotNil(t3?.installed_version)
                // a target change never drops an open run silently: it is recorded first
                try await f.sql.raw("UPDATE sdk_targets SET run_phase = 'swap', run_action = 'rollback', run_trigger = 'manual', run_started_at = UTC_TIMESTAMP(6)").run()
                let st2 = try await put(e, form: form, conn: conn, dir: "/web/lib/form-sdk-neu"); XCTAssertEqual(st2, .noContent)
                struct N: Decodable { let c: Int }
                let interrupted = try await f.sql.raw("SELECT COUNT(*) AS c FROM sdk_deployments WHERE error_code = 'interrupted' AND action = 'rollback'").first(decoding: N.self)?.c
                XCTAssertEqual(interrupted, 1)
                let t4 = try await target(e, form); XCTAssertNil(t4?.run_phase); XCTAssertNil(t4?.last_result, "the new path is a new target")
            }
        } catch { await ftp.stop(); throw error }
        await ftp.stop()
    }

    /// Upgrade 0033 is applied like `migrate` does it (schema, then MigrationRunner.upgrades) and can run again (gegenlesen Astra 2).
    func testUpgrade0033IsAppliedByMigrateAndIdempotent() async throws {
        try await AdminFixture.with { f in
            struct N: Decodable { let c: Int }
            let name = "0033-sdk-deploy-recovery"
            XCTAssertTrue(MigrationRunner.upgrades.contains(name))
            let applied = try await f.sql.raw("SELECT COUNT(*) AS c FROM schema_migrations WHERE name = \(bind: name)").first(decoding: N.self)?.c
            XCTAssertEqual(applied, 1)
            // a manual run before (columns there, no bookkeeping row) must not break migrate
            try await f.sql.raw("DELETE FROM schema_migrations WHERE name = \(bind: name)").run()
            let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
            let again = try await MigrationRunner(db: f.sql).run(schemaFile: MigrationRunner.upgradeFile(name, schemaFile: schema), name: name)
            XCTAssertEqual(again, .applied(statements: 1))
            let cols = try await f.sql.raw("""
                SELECT COUNT(*) AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'sdk_targets'
                AND column_name IN ('target_revision','run_phase','run_action','run_trigger','run_started_at')
                """).first(decoding: N.self)?.c
            XCTAssertEqual(cols, 5)
        }
    }
}
