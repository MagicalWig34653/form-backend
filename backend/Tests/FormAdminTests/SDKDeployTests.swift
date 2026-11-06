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

                // pretend an older version is installed and auto-update is OFF: the scheduler leaves it alone
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
                    XCTAssertEqual(t?["installedVersion"] as? String, version); XCTAssertEqual(t?["previousVersion"] as? String, "0.0.9"); XCTAssertEqual(t?["autoUpdate"] as? Bool, true)
                    let h = (obj(res)["history"] as? [[String: Any]]) ?? []
                    XCTAssertEqual(h.first?["trigger"] as? String, "auto"); XCTAssertEqual(h.first?["result"] as? String, "ok")
                }

                // rollback and roll forward again
                try await cm.send(.POST, base + "/rollback") { XCTAssertEqual($0.status, .ok, text($0)) }
                XCTAssertNotNil(ftp.files["/web/lib/form-sdk.prev/VERSION"])
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
}
