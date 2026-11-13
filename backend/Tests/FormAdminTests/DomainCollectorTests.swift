// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

final class DomainCollectorTests: XCTestCase {
    struct Fixture { let payload: [String: Any]; let domain: UUID; let tenant: UUID; let form: UUID }
    struct C: Decodable { let c: Int }

    private func world(_ f: AdminFixture) async throws -> Fixture {
        let root = try await f.account(), account = try await f.account(), tenant = try await f.customer()
        for right in ["form.create", "form.read", "draft.write", "release.publish"] { try await f.grant(account, right, customer: tenant, by: root) }
        let client = try await f.login(account)
        var formText = "", draft = "", hash = "", confirmation = ""
        try await client.post("tenants/\(tenant)/forms", "{\"name\":\"Besuche\"}") { formText = jsonObject($0)["id"] as? String ?? "" }
        try await client.get("tenants/\(tenant)/forms/\(formText)") { draft = (jsonObject($0)["draftIds"] as? [String])?.first ?? "" }
        try await client.get("tenants/\(tenant)/forms/\(formText)/drafts/\(draft)") { hash = jsonObject($0)["hash"] as? String ?? "" }
        try await client.post("tenants/\(tenant)/forms/\(formText)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") { confirmation = jsonObject($0)["confirmationId"] as? String ?? "" }
        try await client.send(.POST, "tenants/\(tenant)/forms/\(formText)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key":"publish"]) { XCTAssertEqual($0.status, .created) }
        let form = UUID(uuidString: formText)!
        struct R: Decodable { let id: Blob; let manifest: String; let hash: Blob; let view: Blob }
        let r = try await f.sql.raw("""
            SELECT r.id, r.dependency_manifest_json AS manifest, r.manifest_sha256 AS hash, v.view_id AS view
            FROM releases r JOIN release_views v ON v.release_id = r.id WHERE r.customer_id = \(bind: DB.bin(tenant)) AND r.form_id = \(bind: DB.bin(form))
            """).first(decoding: R.self)!
        let manifest = try JSONSerialization.jsonObject(with: Data(r.manifest.utf8)) as! [String: Any]
        let domain = UUID()
        try await f.sql.raw("""
            INSERT INTO domain_bindings (id,customer_id,form_id,host_ascii,environment,release_id,view_id,enabled,revision,changed_by,changed_at,confirmation_audit_id)
            VALUES (\(bind: DB.bin(domain)),\(bind: DB.bin(tenant)),\(bind: DB.bin(form)),'visit.example.test','production',\(bind: r.id),\(bind: r.view),1,1,\(bind: DB.bin(account)),NOW(),\(bind: DB.bin(UUID())))
            """).run()
        let payload: [String: Any] = [
            "contractVersion":"0.1.0", "proposalStatus":"VORGESCHLAGEN", "eventId":UUID().uuidString.lowercased(),
            "tenantId":tenant.uuidString.lowercased(), "form":manifest["form"]!, "view":(manifest["views"] as! [[String:Any]])[0],
            "release":["id":DB.uuid(r.id.data)!.uuidString.lowercased(),"version":"1.0.0","sha256":r.hash.data.map { String(format:"%02x",$0) }.joined()],
            "domainAlias":domain.uuidString.lowercased(), "occurredAt":ISO8601DateFormatter().string(from:Date()),
            "visitPseudonym":String(repeating:"ab",count:16), "event":"visit", "source":"client", "environment":"production", "retentionMonths":13
        ]
        return Fixture(payload: payload, domain: domain, tenant: tenant, form: form)
    }

    private func send(_ f: AdminFixture, _ obj: [String:Any], host: String = "visit.example.test", origin: String? = "https://visit.example.test", expected: HTTPResponseStatus) async throws {
        var h = HTTPHeaders(); h.contentType = .json
        h.add(name:"X-Forwarded-Host",value:host)
        if let origin { h.add(name:"Origin",value:origin) }
        try await f.app.test(.POST,"api/v2/statistics/events",headers:h,body:ByteBuffer(data:try JSONSerialization.data(withJSONObject:obj))) { r in
            XCTAssertEqual(r.status,expected,String(decoding:Data(buffer:r.body),as:UTF8.self))
            if expected == .noContent { XCTAssertEqual(r.headers.first(name:"Access-Control-Allow-Origin"),origin) }
        }
    }

    func testOriginHostTenantAndReleaseAreCheckedBeforeAnEventIsStored() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            try await send(f,w.payload,origin:"https://evil.example.test",expected:.forbidden)
            try await send(f,w.payload,origin:"https://visit.example.test.evil.test",expected:.forbidden)
            try await send(f,w.payload,origin:nil,expected:.forbidden)
            try await send(f,w.payload,host:"unassigned.example.test",expected:.misdirectedRequest)
            var foreign = w.payload; foreign["tenantId"] = UUID().uuidString.lowercased()
            try await send(f,foreign,expected:.misdirectedRequest)
            var release = w.payload; var ref = release["release"] as! [String:Any]; ref["sha256"] = String(repeating:"0",count:64); release["release"] = ref
            try await send(f,release,expected:.unprocessableEntity)
            try await f.sql.raw("UPDATE domain_bindings SET enabled = 0 WHERE id = \(bind: DB.bin(w.domain))").run()
            try await send(f,w.payload,expected:.misdirectedRequest)
            let count = try await f.sql.raw("SELECT COUNT(*) AS c FROM statistics_events").first(decoding:C.self)?.c
            XCTAssertEqual(count,0)
        }
    }

    func testOnlyPseudonymousClientEventsAreAcceptedAndVisitEventIsIdempotent() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            for field in ["ip","ua","userAgent","url","submissionId"] {
                var obj = w.payload; obj[field] = "must-not-be-stored"
                try await send(f,obj,expected:.badRequest)
            }
            var submit = w.payload; submit["event"] = "submit"; submit["source"] = "ingest"
            try await send(f,submit,expected:.unprocessableEntity)
            var inferred = w.payload; inferred["event"] = "abandon"; inferred["abandonmentEvidence"] = "inactivity-inferred"
            try await send(f,inferred,expected:.unprocessableEntity)
            try await send(f,w.payload,expected:.noContent)
            var duplicate = w.payload; duplicate["eventId"] = UUID().uuidString.lowercased()
            try await send(f,duplicate,expected:.noContent)
            var begin = w.payload; begin["eventId"] = UUID().uuidString.lowercased(); begin["event"] = "begin"
            try await send(f,begin,expected:.noContent)
            var abandon = w.payload; abandon["eventId"] = UUID().uuidString.lowercased(); abandon["event"] = "abandon"; abandon["abandonmentEvidence"] = "client-signal"
            try await send(f,abandon,expected:.noContent)
            let count = try await f.sql.raw("SELECT COUNT(*) AS c FROM statistics_events").first(decoding:C.self)?.c
            XCTAssertEqual(count,3)
            // Reusing an event ID for another visit cannot overwrite or silently merge a different event.
            var reused = w.payload; reused["visitPseudonym"] = String(repeating:"cd",count:16)
            try await send(f,reused,expected:.conflict)
        }
    }

    func testAdsIndicatorIsStrictAndReplaysNeverChangeAttribution() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            let invalidValues: [Any] = [["gclid": "synthetic"], ["gclidPresent": 1], ["gclidPresent": true, "ip": "synthetic"]]
            for invalid in invalidValues {
                var obj = w.payload; obj["ads"] = invalid
                try await send(f, obj, expected: .unprocessableEntity)
            }
            var visit = w.payload; visit["ads"] = ["gclidPresent": true]
            try await send(f, visit, expected: .noContent)
            visit["ads"] = ["gclidPresent": false]
            try await send(f, visit, expected: .noContent)
            struct Ads: Decodable { let ads_present: Bool? }
            let recorded = try await f.sql.raw("SELECT ads_present FROM statistics_events WHERE event_kind='visit'").first(decoding: Ads.self)
            XCTAssertEqual(recorded?.ads_present, true)
            var begin = w.payload; begin["event"] = "begin"; begin["ads"] = ["gclidPresent": true]
            try await send(f, begin, expected: .unprocessableEntity)
        }
    }

    func testDomainCollectorCorsPreflightAllowsOnlyAssignedExactOriginAndPost() async throws {
        try await AdminFixture.with { f in
            _ = try await world(f)
            var h = HTTPHeaders()
            h.add(name: "X-Forwarded-Host", value: "visit.example.test")
            h.add(name: "Origin", value: "https://visit.example.test")
            h.add(name: "Access-Control-Request-Method", value: "POST")
            h.add(name: "Access-Control-Request-Headers", value: "content-type")
            try await f.app.test(.OPTIONS, "api/v2/statistics/events", headers: h) { r in
                XCTAssertEqual(r.status, .noContent)
                XCTAssertEqual(r.headers.first(name: "Access-Control-Allow-Origin"), "https://visit.example.test")
                XCTAssertEqual(r.headers.first(name: "Access-Control-Allow-Methods"), "POST")
                XCTAssertEqual(r.headers.first(name: "Access-Control-Allow-Headers"), "Content-Type")
                XCTAssertNil(r.headers.first(name: "Access-Control-Allow-Credentials"))
            }
            h.replaceOrAdd(name: "Origin", value: "https://visit.example.test.evil.test")
            try await f.app.test(.OPTIONS, "api/v2/statistics/events", headers: h) { r in
                XCTAssertEqual(r.status, .misdirectedRequest)
                XCTAssertNil(r.headers.first(name: "Access-Control-Allow-Origin"))
            }
            h.replaceOrAdd(name: "Origin", value: "https://visit.example.test")
            h.replaceOrAdd(name: "Access-Control-Request-Method", value: "DELETE")
            try await f.app.test(.OPTIONS, "api/v2/statistics/events", headers: h) { r in
                XCTAssertEqual(r.status, .forbidden)
                XCTAssertNil(r.headers.first(name: "Access-Control-Allow-Origin"))
            }
        }
    }

    func testHostRateBudgetCannotBeBypassedByNewVisitPseudonyms() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            try await send(f,w.payload,expected:.noContent)
            // The successful request initialized the global and host buckets. Set both to 600;
            // global remains below 6000 while the next host request exceeds the configured 600.
            try await f.sql.raw("UPDATE auth_throttles SET failures = 600 WHERE scope = 'admin-route'").run()
            var obj = w.payload; obj["eventId"] = UUID().uuidString.lowercased(); obj["visitPseudonym"] = String(repeating:"cd",count:16)
            try await send(f,obj,expected:.tooManyRequests)
            let count = try await f.sql.raw("SELECT COUNT(*) AS c FROM statistics_events").first(decoding:C.self)?.c
            XCTAssertEqual(count,1)
        }
    }
    func testDomainInvalidBudgetCannotExhaustLegitimatePostOrOptionsBudgets() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            // The budgets count in fixed 60 s wall-clock windows: start well inside one, so the 31st request and the checks
            // below cannot fall into a fresh window (that turned the expected 429 into 403).
            let left = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
            if left < 15 { try await Task.sleep(nanoseconds: UInt64((left + 0.2) * 1_000_000_000)) }
            // Syntactically invalid requests create only the peer-invalid bucket.
            for _ in 0..<30 {
                try await send(f, w.payload, origin: nil, expected: .forbidden)
            }
            try await send(f, w.payload, origin: nil, expected: .tooManyRequests)
            let buckets = try await f.sql.raw("SELECT COUNT(*) AS c FROM auth_throttles WHERE scope = 'admin-route'").first(decoding: C.self)?.c
            // Login/admin fixture calls also have their own bucket; capture rather than assume its count.
            try await send(f, w.payload, expected: .noContent)
            var h = HTTPHeaders()
            h.add(name: "X-Forwarded-Host", value: "visit.example.test")
            h.add(name: "Origin", value: "https://visit.example.test")
            h.add(name: "Access-Control-Request-Method", value: "POST")
            try await f.app.test(.OPTIONS, "api/v2/statistics/events", headers: h) { XCTAssertEqual($0.status, .noContent) }
            let after = try await f.sql.raw("SELECT COUNT(*) AS c FROM auth_throttles WHERE scope = 'admin-route'").first(decoding: C.self)?.c
            XCTAssertEqual(after, (buckets ?? 0) + 2, "Only valid traffic creates host/global buckets")
            // An unknown but well-formed host must not consume the valid buckets either.
            let before = try await f.sql.raw("SELECT CAST(SUM(failures) AS SIGNED) AS c FROM auth_throttles WHERE scope = 'admin-route'").first(decoding: C.self)!.c
            try await send(f, w.payload, host: "unknown.example.test", expected: .tooManyRequests)
            h.replaceOrAdd(name: "Origin", value: "https://evil.example.test")
            try await f.app.test(.OPTIONS, "api/v2/statistics/events", headers: h) { XCTAssertEqual($0.status, .tooManyRequests) }
            let final = try await f.sql.raw("SELECT CAST(SUM(failures) AS SIGNED) AS c FROM auth_throttles WHERE scope = 'admin-route'").first(decoding: C.self)!.c
            XCTAssertEqual(final, before + 2, "Rejected POST/OPTIONS only consume the invalid peer budget")
            try await send(f, w.payload, expected: .noContent)
        }
    }

}
