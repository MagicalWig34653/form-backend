// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormCore
@testable import FormAdmin
@testable import FormCrypto
@testable import FormIngest
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

final class DomainIngestStatisticsTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private func object(_ r: XCTHTTPResponse) -> [String: Any] { jsonObject(r) }

    func testSignedSubmitContextDeduplicatesAndCannotCrossDomains() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), account = try await f.account(), tenant = try await f.customer()
            for right in ["form.create", "form.read", "draft.write", "release.publish", "key.manage", "statistics.read"] {
                try await f.grant(account, right, customer: tenant, by: root)
            }
            let client = try await f.login(account)
            var form = "", draft = "", hash = "", confirmation = "", seed = Data()
            try await client.post("tenants/\(tenant)/forms", "{\"name\":\"Statistik\"}") { form = object($0)["id"] as? String ?? "" }
            try await client.get("tenants/\(tenant)/forms/\(form)") { draft = (object($0)["draftIds"] as? [String])?.first ?? "" }
            try await client.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { hash = object($0)["hash"] as? String ?? "" }
            try await client.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { confirmation = object($0)["confirmationId"] as? String ?? "" }
            try await client.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key":"publish"]) { XCTAssertEqual($0.status, .created) }
            let sk = Curve25519.KeyAgreement.PrivateKey()
            try await client.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            try await client.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: object($0)["signingSeed"] as? String ?? "") ?? Data() }
            struct V: Decodable { let release_id: Blob; let view_id: Blob }
            let binding = try await f.sql.raw("SELECT release_id, view_id FROM release_views WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(UUID(uuidString: form)!))").first(decoding: V.self)!
            let domain = UUID()
            try await f.sql.raw("""
                INSERT INTO domain_bindings (id,customer_id,form_id,host_ascii,environment,release_id,view_id,enabled,revision,changed_by,changed_at,confirmation_audit_id)
                VALUES (\(bind: DB.bin(domain)),\(bind: DB.bin(tenant)),\(bind: DB.bin(UUID(uuidString: form)!)),'stats.example.test','production',\(bind: binding.release_id),\(bind: binding.view_id),1,1,\(bind: DB.bin(account)),NOW(),\(bind: DB.bin(UUID())))
                """).run()
            let pseudo = String(repeating: "ab", count: 16)
            func submit(domain: UUID, key: String, host: String? = nil, origin: String? = nil, expected: HTTPResponseStatus) async throws {
                let ctx = "{\"domainAlias\":\"\(domain.uuidString.lowercased())\",\"viewId\":\"\(DB.uuid(binding.view_id.data)!.uuidString.lowercased())\",\"visitPseudonym\":\"\(pseudo)\",\"ads\":{\"gclidPresent\":true}}"
                let pairs = [("nachricht", "Statistik"), ("_statistics", ctx)]
                let canonical = try RequestSignature.canonical(fields: .array(pairs.map { ($0.0, .string($0.1)) }))
                let stamp = String(Int64(Date().timeIntervalSince1970))
                let signature = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: form, timestamp: stamp, canonical: canonical), seed: seed)
                var headers = HTTPHeaders(); headers.contentType = .urlEncodedForm
                headers.add(name: "X-Kubus-Timestamp", value: stamp); headers.add(name: "X-Kubus-Signature", value: signature.base64EncodedString()); headers.add(name: "Idempotency-Key", value: key)
                if let host { headers.add(name: "X-Forwarded-Host", value: host) }
                if let origin { headers.add(name: "Origin", value: origin) }
                let body = pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" }.joined(separator: "&")
                try await f.app.test(.POST, "api/v2/submit/?f=\(form)", headers: headers, body: ByteBuffer(string: body)) { XCTAssertEqual($0.status, expected, String(decoding: Data(buffer: $0.body), as: UTF8.self)) }
            }
            // Pre-existing inferred abandonment disappears when the signed acceptance arrives.
            try await f.sql.raw("""
                INSERT INTO statistics_events (id,customer_id,form_id,release_id,view_id,domain_alias,visit_pseudonym,event_kind,source,environment,abandonment_evidence,occurred_at,expires_at)
                VALUES (\(bind: DB.bin(UUID())),\(bind: DB.bin(tenant)),\(bind: DB.bin(UUID(uuidString: form)!)),\(bind: binding.release_id),\(bind: binding.view_id),\(bind: DB.bin(domain)),\(bind: Blob(Data(repeating: 0xab,count:16))),'abandon','collector','production','inactivity-inferred',NOW(),DATE_ADD(NOW(),INTERVAL 13 MONTH))
                """).run()
            try await submit(domain: domain, key: "a", expected: .ok)
            try await submit(domain: domain, key: "a", expected: .ok)
            try await submit(domain: domain, key: "b", expected: .ok)
            let count = try await f.sql.raw("SELECT COUNT(*) AS c FROM statistics_events WHERE event_kind = 'submit' AND source = 'ingest'").first(decoding: C.self)?.c
            XCTAssertEqual(count, 1)
            let abandoned = try await f.sql.raw("SELECT COUNT(*) AS c FROM statistics_events WHERE event_kind = 'abandon'").first(decoding: C.self)?.c
            XCTAssertEqual(abandoned, 0)
            try await f.sql.raw("""
                INSERT INTO statistics_events (id,customer_id,form_id,release_id,view_id,domain_alias,visit_pseudonym,event_kind,source,environment,occurred_at,expires_at)
                SELECT \(bind: DB.bin(UUID())),customer_id,form_id,release_id,view_id,domain_alias,visit_pseudonym,'visit','client',environment,occurred_at,expires_at
                FROM statistics_events WHERE event_kind='submit'
                """).run()
            struct Ads: Decodable { let ads_present: Bool? }
            let recordedAds = try await f.sql.raw("SELECT ads_present FROM statistics_events WHERE event_kind='submit'").first(decoding: Ads.self)
            XCTAssertEqual(recordedAds?.ads_present, true)
            let statistics = "tenants/\(tenant)/forms/\(form)/statistics"
            try await client.get(statistics) {
                XCTAssertEqual(jsonObject($0)["submits"] as? Int, 1)
                XCTAssertEqual(jsonObject($0)["conversion"] as? Double, 1)
            }
            try await submit(domain: UUID(), key: "foreign", expected: .unprocessableEntity)
            let submissions = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions").first(decoding: C.self)?.c
            XCTAssertEqual(submissions, 2, "Foreign context must roll the entire acceptance back")
            // Pin API host to release A while current_release_id advances to B: acceptance must stay on A.
            let laterRelease = UUID(), hostID = UUID()
            try await f.sql.raw("""
                INSERT INTO releases (id, customer_id, form_id, form_version_no, workflow_id, workflow_version_no, release_version_no,
                  dependency_manifest_json, manifest_sha256, confirmed_by, confirmed_at, confirmation_audit_id)
                SELECT \(bind: DB.bin(laterRelease)), customer_id, form_id, form_version_no, workflow_id, workflow_version_no, release_version_no + 1,
                  dependency_manifest_json, manifest_sha256, confirmed_by, confirmed_at, confirmation_audit_id FROM releases WHERE id = \(bind: binding.release_id)
                """).run()
            try await f.sql.raw("UPDATE forms SET current_release_id = \(bind: DB.bin(laterRelease)) WHERE id = \(bind: DB.bin(UUID(uuidString: form)!))").run()
            try await f.sql.raw("INSERT INTO api_hosts (id, host_ascii, enabled, revision) VALUES (\(bind: DB.bin(hostID)), 'api.example.test', 1, 1)").run()
            try await f.sql.raw("""
                INSERT INTO api_host_forms (api_host_id, customer_id, form_id, release_id, binding_revision, changed_by, changed_at, confirmation_audit_id)
                VALUES (\(bind: DB.bin(hostID)), \(bind: DB.bin(tenant)), \(bind: DB.bin(UUID(uuidString: form)!)), \(bind: binding.release_id), 1, \(bind: DB.bin(account)), NOW(), \(bind: DB.bin(UUID())))
                """).run()
            try await submit(domain: domain, key: "missing-host", expected: .misdirectedRequest)
            try await submit(domain: domain, key: "unknown-host", host: "unknown.example.test", expected: .misdirectedRequest)
            try await submit(domain: domain, key: "bad-origin", host: "api.example.test", origin: "https://stats.example.test.evil.test", expected: .forbidden)
            try await submit(domain: domain, key: "bound", host: "api.example.test", origin: "https://stats.example.test", expected: .ok)
            // A second authorized host accepts the same request/key without another submission or event.
            let backupID = UUID()
            try await f.sql.raw("INSERT INTO api_hosts (id, host_ascii, enabled, revision) VALUES (\(bind: DB.bin(backupID)), 'backup.example.test', 1, 1)").run()
            try await f.sql.raw("""
                INSERT INTO api_host_forms (api_host_id, customer_id, form_id, release_id, binding_revision, changed_by, changed_at, confirmation_audit_id)
                VALUES (\(bind: DB.bin(backupID)), \(bind: DB.bin(tenant)), \(bind: DB.bin(UUID(uuidString: form)!)), \(bind: binding.release_id), 1, \(bind: DB.bin(account)), NOW(), \(bind: DB.bin(UUID())))
                """).run()
            try await submit(domain: domain, key: "bound", host: "backup.example.test", origin: "https://stats.example.test", expected: .ok)
            try await client.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials",
                body: "{\"endpoints\":[\"https://api.example.test\",\"https://unknown.example.test\"]}") { XCTAssertEqual($0.status, .unprocessableEntity) }
            try await client.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials",
                body: "{\"endpoints\":[\"https://api.example.test\",\"https://backup.example.test\"]}") { response in
                XCTAssertEqual(response.status, .created)
                let cfg = object(response)
                XCTAssertEqual(cfg["endpoints"] as? [String], ["https://api.example.test", "https://backup.example.test"])
                let pub = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64URLString: cfg["signingPublicKey"] as? String ?? "")!)
                let signature = Data(base64URLString: cfg["endpointSignature"] as? String ?? "")!
                let text = "KUBUS-SDK-CONFIG-V1\n\(form)\nhttps://api.example.test\nhttps://backup.example.test"
                XCTAssertTrue(pub.isValidSignature(signature, for: Data(text.utf8)))
                XCTAssertFalse(pub.isValidSignature(signature, for: Data((text + "x").utf8)))
            }
            let onA = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions WHERE release_id = \(bind: binding.release_id)").first(decoding: C.self)?.c
            XCTAssertEqual(onA, 3, "API-host binding must override forms.current_release_id")
            // Content erasure must preserve the event count, including the visit submitted multiple times.
            struct Submission: Decodable { let id: Blob }
            let contents = try await f.sql.raw("SELECT id FROM submissions WHERE customer_id = \(bind: DB.bin(tenant))").all(decoding: Submission.self)
            let removed = try await f.app.db(.mysql).transaction { conn in
                try await SubmissionEraser.erase(conn as! SQLDatabase, tenant: tenant, form: UUID(uuidString: form)!,
                    ids: contents.compactMap { DB.uuid($0.id.data) }, reason: "request", actor: account, now: Date())
            }
            XCTAssertEqual(removed.deleted.count, 3)
            try await client.get(statistics) {
                XCTAssertEqual(jsonObject($0)["submits"] as? Int, 1)
                XCTAssertEqual(jsonObject($0)["conversion"] as? Double, 1)
            }

            try await f.sql.raw("UPDATE api_hosts SET enabled = 0 WHERE id = \(bind: DB.bin(hostID))").run()
            try await submit(domain: domain, key: "disabled-host", host: "api.example.test", expected: .misdirectedRequest)
            // Five synthetic visits/conversions, no customer data or content required.
            try await f.sql.raw("UPDATE statistics_events SET ads_present=1").run()
            for _ in 0..<4 {
                for kind in ["visit", "submit"] {
                    try await f.sql.raw("""
                        INSERT INTO statistics_events (id,customer_id,form_id,release_id,view_id,domain_alias,visit_pseudonym,event_kind,source,environment,submission_id,occurred_at,expires_at,ads_present)
                        SELECT \(bind: DB.bin(UUID())),customer_id,form_id,release_id,view_id,domain_alias,\(bind: DB.bin(UUID())),event_kind,source,environment,
                          \(bind: kind == "submit" ? DB.bin(UUID()) : nil),occurred_at,expires_at,1
                        FROM statistics_events WHERE event_kind=\(bind: kind) LIMIT 1
                        """).run()
                }
            }
            try await client.get(statistics + "/ads") {
                let groups = jsonObject($0)["groups"] as? [[String: Any]]
                XCTAssertEqual(groups?.first?["visits"] as? Int, 5)
                XCTAssertEqual(groups?.first?["submits"] as? Int, 5)
                XCTAssertEqual(groups?.first?["conversion"] as? Double, 1)
            }
            _ = try await f.app.db(.mysql).transaction { conn in
                try await StatisticsEraser.erase(conn as! SQLDatabase, tenant: tenant, form: UUID(uuidString: form)!, reason: "request", actor: account, now: Date())
            }
            try await client.get(statistics + "/ads") {
                XCTAssertEqual((jsonObject($0)["groups"] as? [Any])?.count, 0)
            }


        }
    }

    func testSignedEndpointSyntax() throws {
        XCTAssertNoThrow(try KeyRoutes.validateEndpoints(["https://primary.example.test", "https://backup.example.test"]))
        for invalid in [[], ["http://api.example.test"], ["https://api.example.test/path"],
                        ["https://api.example.test:443"], ["https://API.example.test"],
                        ["https://api.example.test", "https://api.example.test"], ["https://api.example.test\nevil"]] {
            XCTAssertThrowsError(try KeyRoutes.validateEndpoints(invalid))
        }
    }

    func testMalformedSignedContextIsRejectedRatherThanSilentlyIgnored() throws {
        let malformed = try RequestSignature.canonical(fields: .array([("_statistics", .string("{}"))]))
        XCTAssertThrowsError(try IngestStatistics.context(canonical: malformed))
        let absent = try RequestSignature.canonical(fields: .array([("message", .string("x"))]))
        XCTAssertNil(try IngestStatistics.context(canonical: absent))
    }
}
