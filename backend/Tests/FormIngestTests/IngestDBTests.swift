// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormAuth
import FormCore
@testable import FormCrypto
import FormHTTP
@testable import FormIngest
import FormLegacyAPI
import FormPersistence
import Foundation
import NIOCore
import SQLKit
import XCTest
import XCTVapor

/// DB integration for the v2 submit endpoint. Needs P4A_DB_PORT/P4A_DB_PASSWORD (backend/integration-test.sh),
/// otherwise skipped. Each test uses its own scratch database. Synthetic data only.
private extension Response { var text: String { body.string ?? "" } }

final class IngestDBTests: XCTestCase {
    private let formID = "0000000a-0000-4000-8000-0000000000fb"
    private let customerID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
    private let releaseID = UUID(uuidString: "00000000-0000-4000-8000-0000000000e1")!
    private let sigSeed = Data((0..<32).map { UInt8($0 + 1) })
    private let now = Date(timeIntervalSince1970: 1_793_012_400)
    private let digestSecret = Data(repeating: 0x42, count: 32)

    private struct C: Decodable { let c: Int }
    private struct Obj: Decodable { let ciphertext: Blob; let ciphertext_sha256: Blob; let byte_count: Int; let kid: String; let wrap_kind: String; let state: String; let content_encoding: String }

    struct Secrets: DigestSecretProvider {
        let table: [String: Data]
        func secret(ref: String) async throws -> Data? { table[ref] }
    }

    private func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
    private var schemaPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
    }
    private func appConfig(_ port: Int, _ pw: String, _ db: String) throws -> AppConfig {
        try AppConfig(env: ["FORM_DB_HOST": ProcessInfo.processInfo.environment["P4A_DB_HOST"] ?? "127.0.0.1", "FORM_DB_PASSWORD": pw, "FORM_DB_PORT": "\(port)", "FORM_DB_USER": "root", "FORM_DB_NAME": db,
                            "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1"])
    }

    struct Fixture {
        let app: Application
        let sql: SQLDatabase
        let recipient: Curve25519.KeyAgreement.PrivateKey
    }

    /// Scratch database with the real schema, synthetic seed and the ingest route registered.
    private final class Box: @unchecked Sendable { var ip = "192.0.2.4"; var t = Date(timeIntervalSince1970: 1_793_012_400) }
    private let box = Box()

    private func withFixture(seed: Bool = true, secrets: [String: Data]? = nil, rateLimited: Bool = false, clientIP: (@Sendable (Request) -> String)? = nil, _ body: (Fixture) async throws -> Void) async throws {
        guard let port = env("P4A_DB_PORT").flatMap(Int.init), let pw = env("P4A_DB_PASSWORD") else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh")
        }
        let name = "p5a_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let admin = try await Application.make(.testing)
        Persistence.configure(admin, try appConfig(port, pw, "p4atest"))
        let adminSQL = Persistence.sql(admin)
        try await adminSQL.raw("CREATE DATABASE \(ident: name)").run()
        func cleanup() async { try? await adminSQL.raw("DROP DATABASE IF EXISTS \(ident: name)").run(); try? await admin.asyncShutdown() }
        let app: Application
        do { app = try await Application.make(.testing) } catch { await cleanup(); throw error }
        do {
            Persistence.configure(app, try appConfig(port, pw, name))
            try HTTPSetup.configure(app)
            var config = IngestConfig(secrets: Secrets(table: secrets ?? ["ref-1": digestSecret]), now: { [now] in now })
            config.abuseKey = Data(repeating: 99, count: 32)
            config.clientIP = clientIP ?? { [box] _ in box.ip }
            if rateLimited { config.throttle = ThrottleService(db: app.db(.mysql), keys: try StaticServerKey(Data(repeating: 5, count: 32)), now: { [box] in box.t }) }
            LegacyAPI.register(app, backend: IngestSetup.register(app, config: config))
            let sql = Persistence.sql(app)
            _ = try await MigrationRunner(db: sql).run(schemaFile: schemaPath)
            let recipient = Curve25519.KeyAgreement.PrivateKey()
            if seed { try await seedData(sql, recipient: recipient) }
            try await body(Fixture(app: app, sql: sql, recipient: recipient))
        } catch {
            try? await app.asyncShutdown(); await cleanup(); throw error
        }
        try await app.asyncShutdown(); await cleanup()
    }

    private func eq<T: Equatable>(_ a: @autoclosure () async throws -> T, _ b: T, _ m: String = "", line: UInt = #line) async throws {
        let v = try await a()
        XCTAssertEqual(v, b, m, line: line)
    }
    private func bin(_ u: UUID) -> Blob { SubmitHandler.bin(u) }

    private func seedData(_ sql: SQLDatabase, recipient: Curve25519.KeyAgreement.PrivateKey, formActive: Bool = true) async throws {
        let f = UUID(uuidString: formID)!
        let pub = recipient.publicKey.rawRepresentation
        let sigPub = try Curve25519.Signing.PrivateKey(rawRepresentation: sigSeed).publicKey.rawRepresentation
        let t = "2026-10-30 00:00:00.000000"
        let cust = bin(customerID), rel = bin(releaseID), fb = bin(f)
        let workflowID = UUID()
        let gen = bin(workflowID), wf = bin(UUID()), acc = bin(UUID()), aud = bin(UUID())
        let pubB = Blob(pub), sigB = Blob(sigPub)
        // P6 resolves the pinned graph even for the legacy entry/end pipeline. Seed the same
        // valid standard graph as a real publication, with canonical graph/manifest digests.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts/flow/examples/subflow.json")
        guard case .object(var graph) = try JCS.parse(Data(contentsOf: fixture)) else { throw JCSError.invalidJSON }
        graph["id"] = .string(workflowID.uuidString.lowercased())
        let graphData = JCS.canonicalize(.object(graph)), graphHash = Data(SHA256.hash(data: graphData))
        let graphHex = graphHash.map { String(format: "%02x", $0) }.joined()
        let manifest = JSONValue.object([
            "flow": .object(["id": .string(workflowID.uuidString.lowercased()), "version": .string("1.0.0"), "sha256": .string(graphHex)]),
            "blocks": .array([]), "modules": .array([]), "scripts": .array([]), "sandboxProfiles": .array([]), "views": .array([])
        ])
        let manifestData = JCS.canonicalize(manifest), manifestHash = Blob(Data(SHA256.hash(data: manifestData)))
        let kidv = try keyID(pub), act = formActive ? 1 : 0
        // One pinned connection so FOREIGN_KEY_CHECKS=0 applies to all seed statements (account/version rows are out of scope here).
        try await sql.withSession { s in
            try await s.raw("SET FOREIGN_KEY_CHECKS=0").run()
            try await s.raw("INSERT INTO customers (id,name,state,created_at) VALUES (\(bind: cust),'synthetic','active',\(bind: t))").run()
            try await s.raw("""
                INSERT INTO forms (id,customer_id,name,active,current_release_id,created_at)
                VALUES (\(bind: fb),\(bind: cust),'synthetic',\(bind: act),\(bind: rel),\(bind: t))
                """).run()
            try await s.raw("""
                INSERT INTO workflow_versions (customer_id,workflow_id,version_no,contract_version,graph_json,graph_sha256,created_at)
                VALUES (\(bind: cust),\(bind: gen),1,'0.1.0',\(bind: String(decoding: graphData, as: UTF8.self)),\(bind: Blob(graphHash)),\(bind: t))
                """).run()
            try await s.raw("""
                INSERT INTO releases (id,customer_id,form_id,form_version_no,workflow_id,workflow_version_no,release_version_no,dependency_manifest_json,
                  manifest_sha256,confirmed_by,confirmed_at,confirmation_audit_id)
                VALUES (\(bind: rel),\(bind: cust),\(bind: fb),1,\(bind: gen),1,1,\(bind: String(decoding: manifestData, as: UTF8.self)),\(bind: manifestHash),
                  \(bind: wf),\(bind: t),\(bind: acc))
                """).run()
            try await s.raw("""
                INSERT INTO customer_key_generations (generation_id,customer_id,kid,generation_no,public_key,state,created_at)
                VALUES (\(bind: aud),\(bind: cust),\(bind: kidv),1,\(bind: pubB),'active',\(bind: t))
                """).run()
            try await s.raw("""
                INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,public_key,state,created_at)
                VALUES (\(bind: cust),\(bind: fb),'ed25519',1,\(bind: sigB),'current',\(bind: t))
                """).run()
            try await s.raw("""
                INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,secret_ref,state,created_at)
                VALUES (\(bind: cust),\(bind: fb),'digest-hmac',1,'ref-1','current',\(bind: t))
                """).run()
            try await s.raw("INSERT INTO form_versions (customer_id,form_id,version_no,contract_version,definition_json,definition_sha256,encryption_profile,validation_profile,special_categories,storage_backend,max_upload_bytes,created_at) VALUES (\(bind: cust),\(bind: fb),1,'0.1.0','{}',\(bind: Blob(Data(repeating: 0, count: 32))),'hpke-v2','typed-v1',0,'db',20000000,\(bind: t))").run()
            try await s.raw("SET FOREIGN_KEY_CHECKS=1").run()
        }
    }

    // MARK: request helpers

    private func enc(_ s: String) -> String {
        String(s.utf8.map { b -> String in
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 46 || b == 95 || b == 126
                ? String(UnicodeScalar(b)) : String(format: "%%%02X", b)
        }.joined())
    }
    private func body(_ pairs: [(String, String)]) -> String { pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&") }

    /// Signs the canonical structure of flat `pairs` exactly as a SDK would (PHP structure, sorted by key).
    private func sign(_ pairs: [(String, String)], form: String? = nil, ts: Int64? = nil, seed: Data? = nil) throws -> (ts: String, sig: String) {
        let canonical = try RequestSignature.canonical(fields: .array(pairs.map { ($0.0, PHPValue.string($0.1)) }))
        let t = String(ts ?? Int64(now.timeIntervalSince1970))
        let text = try RequestSignature.signingText(route: .submit, formID: form ?? formID, timestamp: t, canonical: canonical)
        return (t, try RequestSignature.sign(text, seed: seed ?? sigSeed).base64EncodedString())
    }

    private func send(_ app: Application, method: HTTPMethod = .POST, path: String = "/api/v2/submit/", query: String? = nil, headers: [String: String] = [:], peer: String? = nil,
                      body: String = "", contentType: String? = "application/x-www-form-urlencoded") async throws -> Response {
        var h = HTTPHeaders()
        for (k, v) in headers { h.add(name: k, value: v) }
        if let contentType { h.contentType = HTTPMediaType(type: contentType.split(separator: "/")[0].description, subType: contentType.split(separator: "/")[1].description) }
        var buf = ByteBufferAllocator().buffer(capacity: body.utf8.count)
        buf.writeString(body)
        let uri = URI(path: path + (query.map { "?\($0)" } ?? "?f=\(formID)"))
        let req = Request(application: app, method: method, url: uri, version: .http1_1, headers: h, collectedBody: buf, remoteAddress: try peer.map { try SocketAddress(ipAddress: $0, port: 4711) },
                          logger: app.logger, on: app.eventLoopGroup.next())
        return try await app.responder.respond(to: req).get()
    }

    private func signedHeaders(_ pairs: [(String, String)], key: String? = nil, ts: Int64? = nil) throws -> [String: String] {
        let s = try sign(pairs, ts: ts)
        var h = ["X-Kubus-Timestamp": s.ts, "X-Kubus-Signature": s.sig]
        if let key { h["Idempotency-Key"] = key }
        return h
    }
    /// Request headers plus the SDK's signed visitor claim (ADR 0047). `claimSeed`/`claimIP`/`bindTo` let tests forge it.
    private func visitorHeaders(_ pairs: [(String, String)], ip: String, key: String? = nil, ts: Int64? = nil, claimSeed: Data? = nil, claimIP: String? = nil, bindTo: String? = nil) throws -> [String: String] {
        var h = try signedHeaders(pairs, key: key, ts: ts)
        let sig = try ClientIPSignature.sign(formID: formID, ip: claimIP ?? ip, timestamp: h["X-Kubus-Timestamp"]!, requestSignature: bindTo ?? h["X-Kubus-Signature"]!, seed: claimSeed ?? sigSeed)
        h[ClientIPSignature.ipHeader] = ip
        h[ClientIPSignature.signatureHeader] = sig.base64EncodedString()
        return h
    }
    private func count(_ sql: SQLDatabase, _ table: String) async throws -> Int {
        try await sql.raw("SELECT COUNT(*) AS c FROM \(ident: table)").first(decoding: C.self)?.c ?? -1
    }
    private func submissionID(_ res: Response) throws -> String {
        struct R: Decodable { struct S: Decodable { let id: String }; let submission: S }
        return try JSONDecoder().decode(R.self, from: Data(res.text.utf8)).submission.id
    }

    private let pairs: [(String, String)] = [("nachricht", "Grüße / SYNTHETIC-MARKER-7731"), ("name", "Beispiel Test")]

    // MARK: tests

    func testAbuseFailOpenFailClosedAndTestMarkers() async throws {
        try await withFixture { fx in
            let pairs = [("cf-turnstile-response", "synthetic-token")]
            func policy(_ value: String) async throws {
                try await fx.sql.raw("UPDATE form_versions SET definition_json=\(bind: value) WHERE form_id=\(bind: bin(UUID(uuidString: formID)!))").run()
            }
            try await policy(#"{"security":{"abuse":{"siteKey":"synthetic"}}}"#)
            let headers = try signedHeaders(pairs, key: "abuse-replay")
            let accepted = try await send(fx.app, headers: headers, body: body(pairs))
            XCTAssertEqual(accepted.status, .ok)
            XCTAssertEqual(accepted.headers.first(name: "X-Form-Captcha"), "unavailable")
            try await policy(#"{"security":{"abuse":{"siteKey":"synthetic","failPolicy":"closed"}}}"#)
            let replay = try await send(fx.app, headers: headers, body: body(pairs))
            XCTAssertEqual(replay.status, .ok)
            XCTAssertEqual(replay.text, accepted.text)
            let failed = try await send(fx.app, headers: signedHeaders(pairs), body: body(pairs))
            XCTAssertEqual(failed.status, .serviceUnavailable)
            try await policy(#"{"security":{"abuse":{"siteKey":"synthetic","testMode":true}}}"#)
            let empty: [(String,String)] = [("a", "b")]
            let test = try await send(fx.app, headers: signedHeaders(empty), body: body(empty))
            XCTAssertEqual(test.status, .ok)
            XCTAssertEqual(test.headers.first(name: "X-Form-Captcha"), "rejected")
            XCTAssertEqual(test.headers.first(name: "X-Form-Mode"), "test")
        }
    }
    func testRepeatedNegativeCaptchaBansAndExpiredBanRestartsCounter() async throws {
        try await withFixture { fx in
            try await fx.sql.raw("UPDATE form_versions SET definition_json='{\"security\":{\"abuse\":{\"siteKey\":\"synthetic\"}}}'").run()
            try await SystemSettings.write(fx.sql, key: "abuse.threshold", value: "2", at: SubmitHandler.dbTime(now))
            let pairs = [("a", "b")]
            for expected in [HTTPResponseStatus.preconditionFailed, .preconditionFailed, .tooManyRequests] {
                let response = try await send(fx.app, headers: signedHeaders(pairs), body: body(pairs))
                XCTAssertEqual(response.status, expected)
            }
            try await eq(try await count(fx.sql, "submissions"), 0)
            let past = SubmitHandler.dbTime(now.addingTimeInterval(-1000))
            try await fx.sql.raw("UPDATE ingest_abuse_ips SET blocked_until=\(bind: past),window_start=\(bind: past)").run()
            let response = try await send(fx.app, headers: signedHeaders(pairs), body: body(pairs))
            XCTAssertEqual(response.status, .preconditionFailed)
        }
    }

    func testPerClientBudgetCountsReplaysIsolatesClientsExpiresAndCanBeSwitchedOff() async throws {
        try await withFixture(rateLimited: true) { fx in
            try await SystemSettings.write(fx.sql, key: "ingest.requestsPerMinute", value: "3", at: SubmitHandler.dbTime(now))
            func go(_ key: String) async throws -> Response { try await send(fx.app, headers: signedHeaders(pairs, key: key), body: body(pairs)) }
            let r1 = try await go("k1"); XCTAssertEqual(r1.status, .ok)
            let r2 = try await go("k1"); XCTAssertEqual(r2.status, .ok)   // idempotent replay is counted too
            let r3 = try await go("k2"); XCTAssertEqual(r3.status, .ok)
            let limited = try await go("k3")
            XCTAssertEqual(limited.status, .tooManyRequests)
            let r4 = try await go("k1"); XCTAssertEqual(r4.status, .tooManyRequests)   // replays are limited as well
            XCTAssertTrue((Int(limited.headers.first(name: "Retry-After") ?? "") ?? 0) >= 1)
            XCTAssertTrue(limited.text.contains("ingest_rate_limited"))
            try await eq(try await count(fx.sql, "submissions"), 2)
            // another client is independent; the stored counter is a hash, never the address
            box.ip = "198.51.100.9"
            let r5 = try await go("k4"); XCTAssertEqual(r5.status, .ok)
            struct H: Decodable { let c: Int }
            let clear = try await fx.sql.raw("SELECT COUNT(*) AS c FROM auth_throttles WHERE subject_hmac = \(bind: Blob(Data("198.51.100.9".utf8)))").first(decoding: H.self)?.c
            XCTAssertEqual(clear, 0)
            // the window ends
            box.ip = "192.0.2.4"; box.t = box.t.addingTimeInterval(61)
            let r6 = try await go("k5"); XCTAssertEqual(r6.status, .ok)
            // 0 switches the budget off
            try await SystemSettings.write(fx.sql, key: "ingest.requestsPerMinute", value: "0", at: SubmitHandler.dbTime(now))
            for i in 0..<6 { let r7 = try await go("off\(i)"); XCTAssertEqual(r7.status, .ok) }
        }
    }

    func testAbuseBanCountsClientsBehindTrustedProxySeparatelyAndIgnoresSpoofedHeaders() async throws {
        try await withFixture(clientIP: IngestConfig.proxiedClientIP(trusted: [CIDR("10.0.0.0/8")!])) { fx in
            try await fx.sql.raw("UPDATE form_versions SET definition_json='{\"security\":{\"abuse\":{\"siteKey\":\"synthetic\"}}}'").run()
            try await SystemSettings.write(fx.sql, key: "abuse.threshold", value: "2", at: SubmitHandler.dbTime(now))
            let pairs = [("a", "b")]
            func go(peer: String, xff: String?) async throws -> HTTPResponseStatus {
                var h = try signedHeaders(pairs)
                if let xff { h["X-Forwarded-For"] = xff }
                return try await send(fx.app, headers: h, peer: peer, body: body(pairs)).status
            }
            // bot behind the trusted proxy 10.0.0.5 is banned after the threshold
            for expected in [HTTPResponseStatus.preconditionFailed, .preconditionFailed, .tooManyRequests] {
                let s = try await go(peer: "10.0.0.5", xff: "203.0.113.50"); XCTAssertEqual(s, expected)
            }
            // a second visitor behind the SAME proxy is unaffected
            let other = try await go(peer: "10.0.0.5", xff: "203.0.113.51"); XCTAssertEqual(other, .preconditionFailed)
            // untrusted peer: X-Forwarded-For is ignored, the peer is the identity (cannot frame the bot's address)
            let spoof = try await go(peer: "198.51.100.7", xff: "203.0.113.50"); XCTAssertEqual(spoof, .preconditionFailed, "spoofed XFF from an untrusted peer must not inherit the ban")
            // a client's own (left) XFF entry is ignored, the proxy-appended hop counts
            let dodge = try await go(peer: "10.0.0.5", xff: "1.2.3.4, 203.0.113.50"); XCTAssertEqual(dodge, .tooManyRequests)
            // IPv6: all addresses of one /64 share the ban
            for _ in 0..<2 { _ = try await go(peer: "10.0.0.5", xff: "2001:db8:1:2::1") }
            let sameNet = try await go(peer: "10.0.0.5", xff: "2001:db8:1:2:ffff::9"); XCTAssertEqual(sameNet, .tooManyRequests)
            let otherNet = try await go(peer: "10.0.0.5", xff: "2001:db8:1:3::1"); XCTAssertEqual(otherNet, .preconditionFailed)
        }
    }

    func testRequestBudgetUsesResolvedClientNotTheProxyAndSharesAnIPv6Prefix() async throws {
        try await withFixture(rateLimited: true, clientIP: IngestConfig.proxiedClientIP(trusted: [CIDR("10.0.0.0/8")!])) { fx in
            try await SystemSettings.write(fx.sql, key: "ingest.requestsPerMinute", value: "2", at: SubmitHandler.dbTime(now))
            func go(_ key: String, peer: String = "10.0.0.5", xff: String?) async throws -> HTTPResponseStatus {
                var h = try signedHeaders(pairs, key: key)
                if let xff { h["X-Forwarded-For"] = xff }
                return try await send(fx.app, headers: h, peer: peer, body: body(pairs)).status
            }
            for i in 0..<2 { let s = try await go("a\(i)", xff: "203.0.113.50"); XCTAssertEqual(s, .ok) }
            let limited = try await go("a2", xff: "203.0.113.50"); XCTAssertEqual(limited, .tooManyRequests)
            // another visitor behind the same proxy is unaffected; so is a spoofed header from an untrusted peer
            let b = try await go("b0", xff: "203.0.113.51"); XCTAssertEqual(b, .ok)
            let spoof = try await go("s0", peer: "198.51.100.7", xff: "203.0.113.50"); XCTAssertEqual(spoof, .ok)
            // /64: rotating the host part does not buy a fresh budget
            for i in 0..<2 { let s = try await go("v\(i)", xff: "2001:db8:9:9::\(i + 1)"); XCTAssertEqual(s, .ok) }
            let rotated = try await go("v2", xff: "2001:db8:9:9:aaaa::1"); XCTAssertEqual(rotated, .tooManyRequests)
        }
    }

    // MARK: signed visitor address (ADR 0047, card 1BEEDE0F)

    private func abuseFixtureSetup(_ fx: Fixture, threshold: Int = 2) async throws {
        try await fx.sql.raw("UPDATE form_versions SET definition_json='{\"security\":{\"abuse\":{\"siteKey\":\"synthetic\"}}}'").run()
        try await SystemSettings.write(fx.sql, key: "abuse.threshold", value: "\(threshold)", at: SubmitHandler.dbTime(now))
    }
    private let badClaim = String(repeating: "A", count: 86) + "=="

    func testBotBehindOneWebServerIsBannedAloneAndOtherVisitorsAndTheServerKeepWorking() async throws {
        try await withFixture { fx in
            try await abuseFixtureSetup(fx)
            func go(_ ip: String?) async throws -> HTTPResponseStatus {
                let h = try ip.map { try visitorHeaders(pairs, ip: $0) } ?? signedHeaders(pairs)
                return try await send(fx.app, headers: h, body: body(pairs)).status
            }
            for expected in [HTTPResponseStatus.preconditionFailed, .preconditionFailed, .tooManyRequests] { let s = try await go("203.0.113.50"); XCTAssertEqual(s, expected) }
            // the same web server, another visitor, and an old SDK without a claim: not banned
            let other = try await go("203.0.113.51"); XCTAssertEqual(other, .preconditionFailed)
            let old = try await go(nil); XCTAssertEqual(old, .preconditionFailed, "peer identity is separate from the banned visitor")
            // IPv6: the whole /64 of the bot shares the ban, a neighbouring /64 does not
            for _ in 0..<2 { _ = try await go("2001:db8:1:2::1") }
            let same = try await go("2001:db8:1:2:ffff::9"); XCTAssertEqual(same, .tooManyRequests)
            let next = try await go("2001:db8:1:3::1"); XCTAssertEqual(next, .preconditionFailed)
            // no clear address in the ban table
            struct H: Decodable { let c: Int }
            let clear = try await fx.sql.raw("SELECT COUNT(*) AS c FROM ingest_abuse_ips WHERE ip_digest = \(bind: Blob(Data("203.0.113.50".utf8)))").first(decoding: H.self)?.c
            XCTAssertEqual(clear, 0)
        }
    }

    func testForgedOrUnboundVisitorClaimsFallBackToThePeerAndNeverFrameAnotherVisitor() async throws {
        try await withFixture { fx in
            try await abuseFixtureSetup(fx, threshold: 100)
            let other = Data((0..<32).map { UInt8($0 + 100) })
            var noSig = try signedHeaders(pairs); noSig[ClientIPSignature.ipHeader] = "203.0.113.60"
            var badSig = noSig; badSig[ClientIPSignature.signatureHeader] = badClaim
            let forgeries: [[String: String]] = [
                try visitorHeaders(pairs, ip: "203.0.113.60", claimSeed: other),            // wrong key
                try visitorHeaders(pairs, ip: "203.0.113.60", claimIP: "203.0.113.61"),     // signed for another address
                try visitorHeaders(pairs, ip: "203.0.113.60", bindTo: badClaim),            // bound to another request
                noSig, badSig,                                                              // claim without / with garbage signature
                try visitorHeaders(pairs, ip: "not-an-ip"),
            ]
            for h in forgeries { let r = try await send(fx.app, headers: h, body: body(pairs)); XCTAssertEqual(r.status, .preconditionFailed, "forged claim = peer behaviour, no error") }
            // a claim cannot be moved to another body: the request signature fails
            let moved = try await send(fx.app, headers: try visitorHeaders(pairs, ip: "203.0.113.70"), body: body([("a", "other")])); XCTAssertEqual(moved.status, .forbidden)
            struct H: Decodable { let c: Int }
            let rows = try await fx.sql.raw("SELECT COUNT(*) AS c FROM ingest_abuse_ips").first(decoding: H.self)?.c
            XCTAssertEqual(rows, 1, "all forgeries share the single peer identity; none created an identity for a claimed address")
        }
    }

    func testExpiredOrFutureRequestsDoNotCarryAnAcceptedClaim() async throws {
        try await withFixture(rateLimited: true) { fx in
            try await SystemSettings.write(fx.sql, key: "ingest.requestsPerMinute", value: "1", at: SubmitHandler.dbTime(now))
            let t = Int64(now.timeIntervalSince1970)
            // stale timestamp with a cryptographically valid claim: refused (403), and the claim is not believed (peer budget spent)
            let stale = try await send(fx.app, headers: try visitorHeaders(pairs, ip: "203.0.113.80", ts: t - 301), body: body(pairs)); XCTAssertEqual(stale.status, .forbidden)
            let fresh = try await send(fx.app, headers: try visitorHeaders(pairs, ip: "203.0.113.80", key: "f1"), body: body(pairs)); XCTAssertEqual(fresh.status, .ok)
            let peerOnly = try await send(fx.app, headers: try signedHeaders(pairs, key: "p1"), body: body(pairs)); XCTAssertEqual(peerOnly.status, .tooManyRequests)
            let future = try await send(fx.app, headers: try visitorHeaders(pairs, ip: "203.0.113.81", ts: t + 301), body: body(pairs)); XCTAssertEqual(future.status, .tooManyRequests, "claim not believed: counted against the exhausted peer")
        }
    }

    func testRequestBudgetIsPerVisitorBehindOneWebServerAndReplayCountsToo() async throws {
        try await withFixture(rateLimited: true) { fx in
            try await SystemSettings.write(fx.sql, key: "ingest.requestsPerMinute", value: "2", at: SubmitHandler.dbTime(now))
            func go(_ ip: String, _ key: String) async throws -> HTTPResponseStatus { try await send(fx.app, headers: visitorHeaders(pairs, ip: ip, key: key), body: body(pairs)).status }
            let a1 = try await go("203.0.113.10", "k1"); XCTAssertEqual(a1, .ok)
            let a2 = try await go("203.0.113.10", "k1"); XCTAssertEqual(a2, .ok)   // replay: same submission, still counted
            let a3 = try await go("203.0.113.10", "k2"); XCTAssertEqual(a3, .tooManyRequests)
            // two further visitors of the same server have their own budget
            for ip in ["203.0.113.11", "203.0.113.12"] { for i in 0..<2 { let s = try await go(ip, "\(ip)-\(i)"); XCTAssertEqual(s, .ok) } }
            // IPv6 /64: rotating the host part does not buy a fresh budget
            for i in 0..<2 { let s = try await go("2001:db8:5:5::\(i + 1)", "v6-\(i)"); XCTAssertEqual(s, .ok) }
            let rotated = try await go("2001:db8:5:5:aaaa::1", "v6-x"); XCTAssertEqual(rotated, .tooManyRequests)
            try await eq(try await count(fx.sql, "submissions"), 7)   // k1 (replay shares it) + 4 + 2
        }
    }

    func testPeerCapBoundsRotatingVisitorsOfOneKeyAndLeavesUnsignedAlone() async throws {
        try await withFixture(rateLimited: true) { fx in
            try await SystemSettings.write(fx.sql, key: "ingest.requestsPerMinute", value: "5", at: SubmitHandler.dbTime(now))
            try await SystemSettings.write(fx.sql, key: "ingest.peerRequestsPerMinute", value: "4", at: SubmitHandler.dbTime(now))
            // a leaked key naming a new visitor every time stays under the per-visitor budget but hits the cap of the web server
            for i in 0..<4 { let r = try await send(fx.app, headers: visitorHeaders(pairs, ip: "198.51.100.\(i + 1)", key: "r\(i)"), body: body(pairs)); XCTAssertEqual(r.status, .ok) }
            let capped = try await send(fx.app, headers: visitorHeaders(pairs, ip: "198.51.100.99", key: "r9"), body: body(pairs))
            XCTAssertEqual(capped.status, .tooManyRequests); XCTAssertTrue(capped.text.contains("ingest_rate_limited"))
            // forged claims count toward the cap too (counted before verification: no key lookup for a flood)
            let forged = try await send(fx.app, headers: visitorHeaders(pairs, ip: "198.51.100.50", claimSeed: Data(repeating: 9, count: 32)), body: body(pairs)); XCTAssertEqual(forged.status, .tooManyRequests)
            // requests without a claim are unaffected by the cap (old SDKs): visitor budget with the peer as identity
            let old = try await send(fx.app, headers: signedHeaders(pairs, key: "old"), body: body(pairs)); XCTAssertEqual(old.status, .ok)
            // 0 switches the cap off
            try await SystemSettings.write(fx.sql, key: "ingest.peerRequestsPerMinute", value: "0", at: SubmitHandler.dbTime(now))
            let free = try await send(fx.app, headers: visitorHeaders(pairs, ip: "198.51.100.77", key: "free"), body: body(pairs)); XCTAssertEqual(free.status, .ok)
        }
    }

    func testForgedClaimsAccrueToThePeerAndDoNotFrameTheNamedAddress() async throws {
        try await withFixture { fx in
            try await abuseFixtureSetup(fx)
            let other = Data((0..<32).map { UInt8($0 + 50) })
            for _ in 0..<2 { _ = try await send(fx.app, headers: visitorHeaders(pairs, ip: "203.0.113.90", claimSeed: other), body: body(pairs)) }
            let peer = try await send(fx.app, headers: signedHeaders(pairs), body: body(pairs)); XCTAssertEqual(peer.status, .tooManyRequests)
            let real = try await send(fx.app, headers: visitorHeaders(pairs, ip: "203.0.113.90"), body: body(pairs)); XCTAssertEqual(real.status, .preconditionFailed)
        }
    }

    func testAtomicAbuseCounterThresholdExpiryAndReset() async throws {
        try await withFixture { fx in
            let identity = Blob(Data(repeating: 3, count: 32)), form = UUID(uuidString: formID)!
            for _ in 0..<3 { try await AbuseProtection.recordHit(sql: fx.sql, form: form, identity: identity, now: now, threshold: 3, window: 60, duration: 120) }
            struct Counter: Decodable { let hits: Int; let blocked_until: String? }
            let row = try await fx.sql.raw("SELECT hits,CAST(blocked_until AS CHAR) AS blocked_until FROM ingest_abuse_ips").first(decoding: Counter.self)!
            XCTAssertEqual(row.hits, 3); XCTAssertNotNil(row.blocked_until)
            try await AbuseProtection.recordHit(sql: fx.sql, form: form, identity: identity, now: now.addingTimeInterval(121), threshold: 3, window: 60, duration: 120)
            let reset = try await fx.sql.raw("SELECT hits,CAST(blocked_until AS CHAR) AS blocked_until FROM ingest_abuse_ips").first(decoding: Counter.self)!
            XCTAssertEqual(reset.hits, 1); XCTAssertNil(reset.blocked_until)
        }
    }

    func testAcceptStoresSealedPackageUnchangedAndNoPlaintext() async throws {
        try await withFixture { fx in
            let res = try await send(fx.app, headers: try signedHeaders(pairs), body: body(pairs))
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: "Cache-Control"), "no-store")
            let id = try submissionID(res)
            XCTAssertNotNil(UUID(uuidString: id))

            let obj = try await fx.sql.raw("SELECT ciphertext, ciphertext_sha256, byte_count, kid, wrap_kind, state, content_encoding FROM stored_objects").first(decoding: Obj.self)!
            let wire = String(decoding: obj.ciphertext.data, as: UTF8.self)
            let pkg = try PackageV2(wire)  // strict parser: stored bytes are a valid package
            XCTAssertEqual(pkg.wire, wire)
            XCTAssertEqual(obj.ciphertext_sha256, Blob(Data(SHA256.hash(data: obj.ciphertext.data))))
            XCTAssertEqual(obj.byte_count, obj.ciphertext.data.count)
            XCTAssertEqual([obj.wrap_kind, obj.state, obj.content_encoding], ["hpke", "ready", "raw"])
            XCTAssertEqual(obj.kid, try keyID(fx.recipient.publicKey.rawRepresentation))
            XCTAssertFalse(wire.contains("SYNTHETIC-MARKER"))
            // Client-side (holder of the private key) can open it; server code path never does.
            let plain = String(decoding: try pkg.open(recipient: fx.recipient), as: UTF8.self)
            XCTAssertTrue(plain.contains("SYNTHETIC-MARKER-7731"))
            try await eq(try await count(fx.sql, "submissions"), 1)
            try await eq(try await count(fx.sql, "ingest_idempotency"), 0)  // no key, no promise
            // Technical row facts
            struct Sub: Decodable { let release_evidence: String; let environment: String; let state: String }
            let s = try await fx.sql.raw("SELECT release_evidence, environment, state FROM submissions").first(decoding: Sub.self)!
            XCTAssertEqual([s.release_evidence, s.environment, s.state], ["recorded", "production", "accepted"])
        }
    }

    func testAliasPathAccepts() async throws {
        try await withFixture { fx in
            let res = try await send(fx.app, path: "/api/v2/submit/index.php", headers: try signedHeaders(pairs), body: body(pairs))
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testIdempotentReplaySameDigestSameResponseAndConflictOnDifferentDigest() async throws {
        try await withFixture { fx in
            let first = try await send(fx.app, headers: try signedHeaders(pairs, key: "  key-0001 "), body: body(pairs))
            XCTAssertEqual(first.status, .ok)
            let id = try submissionID(first)
            // Replay with a fresh signature (different timestamp) and identical payload: same identity, no new rows.
            let ts = Int64(now.timeIntervalSince1970) - 100
            let replay = try await send(fx.app, headers: try signedHeaders(pairs, key: "key-0001", ts: ts), body: body(pairs))
            XCTAssertEqual(replay.status, .ok)
            XCTAssertEqual(try submissionID(replay), id)
            try await eq(try await count(fx.sql, "submissions"), 1)
            try await eq(try await count(fx.sql, "stored_objects"), 1)
            try await eq(try await count(fx.sql, "ingest_idempotency"), 1)
            // Same key, other payload (validly signed): conflict, nothing stored, no identity in the body.
            let other = [("nachricht", "anders"), ("name", "Beispiel Test")]
            let conflict = try await send(fx.app, headers: try signedHeaders(other, key: "key-0001"), body: body(other))
            XCTAssertEqual(conflict.status, .conflict)
            XCTAssertFalse(conflict.text.contains(id))
            try await eq(try await count(fx.sql, "submissions"), 1)
            // Other key, other payload: new submission.
            let third = try await send(fx.app, headers: try signedHeaders(other, key: "key-0002"), body: body(other))
            XCTAssertEqual(third.status, .ok)
            XCTAssertNotEqual(try submissionID(third), id)
            try await eq(try await count(fx.sql, "submissions"), 2)
            // Digest column holds an HMAC, not the plain hash of the body.
            struct D: Decodable { let request_digest: Blob }
            let canonical = try RequestSignature.canonical(fields: .array(pairs.map { ($0.0, PHPValue.string($0.1)) }))
            let rows = try await fx.sql.raw("SELECT request_digest FROM ingest_idempotency").all(decoding: D.self)
            XCTAssertFalse(rows.contains { $0.request_digest.data == Data(SHA256.hash(data: canonical)) })
        }
    }

    func testIdempotencyScopeIsPerForm() async throws {
        // Same key bytes under another form id must be independent (primary key includes form).
        try await withFixture { fx in
            let r1 = try await send(fx.app, headers: try signedHeaders(pairs, key: "shared"), body: body(pairs))
            XCTAssertEqual(r1.status, .ok)
            let other = "00000000-0000-4000-8000-000000000009"
            let r2 = try await send(fx.app, query: "f=\(other)", headers: try signedHeaders(pairs, key: "shared"), body: body(pairs))
            XCTAssertEqual(r2.status, .notFound)  // unknown form: no identity leak, no row
            try await eq(try await count(fx.sql, "ingest_idempotency"), 1)
        }
    }

    func testConcurrentSameKeyYieldsExactlyOneSubmission() async throws {
        try await withFixture { fx in
            let h = try signedHeaders(pairs, key: "race-1"), b = body(pairs)
            let statuses = try await withThrowingTaskGroup(of: (UInt, String?).self) { group -> [(UInt, String?)] in
                for _ in 0..<8 {
                    group.addTask {
                        let r = try await self.send(fx.app, headers: h, body: b)
                        return (r.status.code, r.status == .ok ? try self.submissionID(r) : nil)
                    }
                }
                var out: [(UInt, String?)] = []
                for try await x in group { out.append(x) }
                return out
            }
            XCTAssertTrue(statuses.allSatisfy { $0.0 == 200 }, "\(statuses.map(\.0))")  // identical payload: winners and replays are 200
            XCTAssertEqual(Set(statuses.compactMap(\.1)).count, 1)
            try await eq(try await count(fx.sql, "submissions"), 1)
            try await eq(try await count(fx.sql, "stored_objects"), 1)
            try await eq(try await count(fx.sql, "ingest_idempotency"), 1)
        }
    }

    func testSignatureFailuresAre403WithoutSideEffects() async throws {
        try await withFixture { fx in
            let good = try signedHeaders(pairs)
            let t0 = Int64(now.timeIntervalSince1970)
            let wrongKey = try sign(pairs, seed: Data(repeating: 9, count: 32))
            let wrongForm = try sign(pairs, form: "00000000-0000-4000-8000-000000000009")
            let cases: [(String, [String: String], String)] = [
                ("no signature", [:], body(pairs)),
                ("no timestamp", ["X-Kubus-Signature": good["X-Kubus-Signature"]!], body(pairs)),
                ("tampered body", good, body([("nachricht", "x"), ("name", "Beispiel Test")])),
                ("wrong key", ["X-Kubus-Timestamp": wrongKey.ts, "X-Kubus-Signature": wrongKey.sig], body(pairs)),
                ("wrong form", ["X-Kubus-Timestamp": wrongForm.ts, "X-Kubus-Signature": wrongForm.sig], body(pairs)),
                ("stale ts +301", try signedHeaders(pairs, ts: t0 - 301), body(pairs)),
                ("future ts +301", try signedHeaders(pairs, ts: t0 + 301), body(pairs)),
                ("bad base64", ["X-Kubus-Timestamp": good["X-Kubus-Timestamp"]!, "X-Kubus-Signature": "@@@"], body(pairs)),
                ("short signature", ["X-Kubus-Timestamp": good["X-Kubus-Timestamp"]!, "X-Kubus-Signature": Data(repeating: 1, count: 63).base64EncodedString()], body(pairs)),
                ("non-canonical timestamp", ["X-Kubus-Timestamp": "0" + good["X-Kubus-Timestamp"]!, "X-Kubus-Signature": good["X-Kubus-Signature"]!], body(pairs)),
            ]
            for (name, h, b) in cases {
                var hh = h; hh["Idempotency-Key"] = "k-\(name)"
                let r = try await send(fx.app, headers: hh, body: b)
                XCTAssertEqual(r.status, .forbidden, name)
                XCTAssertFalse(r.text.contains("SYNTHETICMARKER"), name)
                XCTAssertTrue(r.text.contains("forbidden"), name)  // uniform ProblemMiddleware envelope
            }
            // +/-300 accepted (inclusive window).
            for d in [-300, 300] {
                let r = try await send(fx.app, headers: try signedHeaders(pairs, ts: t0 + Int64(d)), body: body(pairs))
                XCTAssertEqual(r.status, .ok, "ts \(d)")
            }
            try await eq(try await count(fx.sql, "submissions"), 2)
            try await eq(try await count(fx.sql, "ingest_idempotency"), 0)
        }
    }

    func testPreviousKeyAcceptedUntilValidUntilThenRejected() async throws {
        try await withFixture { fx in
            let f = bin(UUID(uuidString: formID)!)
            // current key rotated away: old key becomes previous (initially long expired); new current is another key.
            try await fx.sql.raw("UPDATE form_protocol_keys SET state='previous', valid_until='2000-01-01 00:00:00.000000' WHERE purpose='ed25519'").run()
            let ed = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 8, count: 32)).publicKey.rawRepresentation
            try await fx.sql.raw("""
                INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,public_key,state,created_at)
                VALUES (\(bind: bin(customerID)),\(bind: f),'ed25519',2,\(bind: Blob(ed)),'current','2026-10-30 00:00:00.000000')
                """).run()
            // Make the previous key valid beyond the injected clock: accepted; expire it: rejected.
            try await fx.sql.raw("UPDATE form_protocol_keys SET valid_until=\(bind: SubmitHandler.dbTime(now.addingTimeInterval(60))) WHERE state='previous'").run()
            try await eq(try await send(fx.app, headers: try signedHeaders(pairs), body: body(pairs)).status, .ok)
            try await fx.sql.raw("UPDATE form_protocol_keys SET valid_until=\(bind: SubmitHandler.dbTime(now.addingTimeInterval(-1))) WHERE state='previous'").run()
            try await eq(try await send(fx.app, headers: try signedHeaders(pairs), body: body(pairs)).status, .forbidden)
        }
    }

    func testNoSignatureKeyRegisteredIsForbiddenNotAccepted() async throws {
        try await withFixture { fx in
            try await fx.sql.raw("DELETE FROM form_protocol_keys WHERE purpose='ed25519'").run()
            try await eq(try await send(fx.app, body: body(pairs)).status, .forbidden)  // unsigned
            try await eq(try await send(fx.app, headers: try signedHeaders(pairs), body: body(pairs)).status, .forbidden)
            try await eq(try await count(fx.sql, "submissions"), 0)
        }
    }

    func testRequestShapeErrors() async throws {
        try await withFixture { fx in
            let h = try signedHeaders(pairs)
            try await eq(try await send(fx.app, query: "x=1", headers: h, body: body(pairs)).status, .unauthorized)
            try await eq(try await send(fx.app, query: "f=", headers: h, body: body(pairs)).status, .unauthorized)
            try await eq(try await send(fx.app, query: "f=not-a-uuid", headers: h, body: body(pairs)).status, .notFound)
            try await eq(try await send(fx.app, query: "f=\(formID.uppercased())", headers: h, body: body(pairs)).status, .notFound)
            try await eq(try await send(fx.app, headers: h, body: body(pairs), contentType: "multipart/form-data").status, .unsupportedMediaType)
            try await eq(try await send(fx.app, headers: h, body: body(pairs), contentType: "application/json").status, .unsupportedMediaType)
            try await eq(try await send(fx.app, headers: h, body: "a=1&a=2").status, .badRequest)
            try await eq(try await send(fx.app, headers: h, body: "a=%FF").status, .badRequest)
            for m in [HTTPMethod.GET, .PUT, .DELETE, .PATCH] {
                try await eq(try await send(fx.app, method: m, headers: h).status, .methodNotAllowed, "\(m)")
            }
            try await eq(try await count(fx.sql, "submissions"), 0)
        }
    }

    /// Review Astra 2 M5: a stale timestamp is refused before the body is parsed (a malformed body would otherwise be a 400 after parsing).
    func testStaleTimestampIsRefusedBeforeParsing() async throws {
        try await withFixture { fx in
            let stale = try signedHeaders(pairs, ts: Int64(now.timeIntervalSince1970) - 3600)
            try await eq(try await send(fx.app, headers: stale, body: "a=1&a=2").status, .forbidden)
            var mp = stale; mp["Content-Type"] = "multipart/form-data; boundary=x"
            try await eq(try await send(fx.app, headers: mp, body: "--x\r\nbroken", contentType: nil).status, .forbidden)
            try await eq(try await send(fx.app, headers: try signedHeaders(pairs), body: "a=1&a=2").status, .badRequest, "a fresh timestamp still reaches the parser")
            try await eq(try await count(fx.sql, "submissions"), 0)
        }
    }

    func testInactiveFormAndDisabledCustomerAre404() async throws {
        try await withFixture { fx in
            let h = try signedHeaders(pairs)
            try await fx.sql.raw("UPDATE forms SET active=0").run()
            try await eq(try await send(fx.app, headers: h, body: body(pairs)).status, .notFound)
            try await fx.sql.raw("UPDATE forms SET active=1").run()
            try await fx.sql.raw("UPDATE customers SET state='disabled'").run()
            try await eq(try await send(fx.app, headers: h, body: body(pairs)).status, .notFound)
            try await eq(try await count(fx.sql, "submissions"), 0)
        }
    }

    func testMissingRecipientKeyReleaseOrDigestKeyRefuseWithoutStoring() async throws {
        try await withFixture { fx in
            let h = try signedHeaders(pairs, key: "k1")
            // no digest secret available for the ref (idempotent request cannot be bound) -> not accepted
            try await fx.sql.raw("UPDATE form_protocol_keys SET secret_ref='missing' WHERE purpose='digest-hmac'").run()
            try await eq(try await send(fx.app, headers: h, body: body(pairs)).status, .internalServerError)  // 503 intent, see handoff (middleware maps >=500 to 500)
            // without an idempotency key the digest key is not needed
            try await eq(try await send(fx.app, headers: try signedHeaders(pairs), body: body(pairs)).status, .ok)
            try await fx.sql.raw("UPDATE customer_key_generations SET state='retiring'").run()
            try await eq(try await send(fx.app, headers: try signedHeaders(pairs), body: body(pairs)).status, .internalServerError)
            try await fx.sql.raw("UPDATE customer_key_generations SET state='active'").run()
            try await fx.sql.raw("UPDATE forms SET current_release_id=NULL").run()
            try await eq(try await send(fx.app, headers: try signedHeaders(pairs), body: body(pairs)).status, .internalServerError)
            try await eq(try await count(fx.sql, "submissions"), 1)
            try await eq(try await count(fx.sql, "ingest_idempotency"), 0)
        }
    }

    func testNonReplayableIdempotencyStatesAreConflict() async throws {
        try await withFixture { fx in
            let h = try signedHeaders(pairs, key: "k-del")
            try await eq(try await send(fx.app, headers: h, body: body(pairs)).status, .ok)
            for (col, val) in [("result_state", "deleted"), ("state", "reserved"), ("state", "review"), ("result_state", "pending")] {
                try await fx.sql.raw("UPDATE ingest_idempotency SET result_state='available', state='complete'").run()
                try await fx.sql.raw("UPDATE ingest_idempotency SET \(unsafeRaw: col)=\(bind: val)").run()
                try await eq(try await send(fx.app, headers: h, body: body(pairs)).status, .conflict, "\(col)=\(val)")
            }
            try await eq(try await count(fx.sql, "submissions"), 1)
        }
    }

    func testErrorResponsesDoNotLeakRequestData() async throws {
        try await withFixture { fx in
            let r = try await send(fx.app, headers: ["X-Kubus-Timestamp": "1", "X-Kubus-Signature": "SYNTHETIC-SECRET"], body: "k=SYNTHETIC-SECRET-VALUE")
            XCTAssertEqual(r.status, .forbidden)
            XCTAssertFalse(r.text.contains("SYNTHETIC"))
            XCTAssertEqual(r.headers.first(name: "X-Content-Type-Options"), "nosniff")
            XCTAssertNotNil(r.headers.first(name: "X-Request-Id"))
        }
    }
}

// MARK: legacy compatibility layer (ADR 0047)

extension IngestDBTests {
    private var legacyHeaders: [String: String] { ["CLIENTUA-ENCRYPT": "x", "CLIENTIP-ENCRYPT": "y"] }
    private var schema: String {
        #"{"fields":{"a":{"name":"name","kind":"text","required":true},"b":{"name":"nachricht","kind":"text","validation":{"minLength":3,"pattern":"[A-Za-z0-9 ]+"}}}}"#
    }
    private func compat(_ fx: Fixture, _ on: Bool = true) async throws {
        try await SystemSettings.write(fx.sql, key: "compat.legacy", value: on ? "true" : "false", at: SubmitHandler.dbTime(now))
    }
    private func definition(_ fx: Fixture, _ json: String) async throws {
        try await fx.sql.raw("UPDATE form_versions SET definition_json=\(bind: json)").run()
    }
    private func dropKeys(_ fx: Fixture) async throws { try await fx.sql.raw("DELETE FROM form_protocol_keys WHERE purpose='ed25519'").run() }
    private func signedForm(_ ts: Int64? = nil) throws -> [String: String] {
        let canonical = try RequestSignature.canonical(fields: .array([]))
        let t = String(ts ?? Int64(now.timeIntervalSince1970))
        let text = try RequestSignature.signingText(route: .form, formID: formID, timestamp: t, canonical: canonical)
        return ["X-Kubus-Timestamp": t, "X-Kubus-Signature": try RequestSignature.sign(text, seed: sigSeed).base64EncodedString()]
    }
    private var good: [(String, String)] { [("name", "Beispiel Test"), ("nachricht", "SYNTHETICMARKER7731 hallo")] }
    private var bad: [(String, String)] { [("name", ""), ("nachricht", "SYNTHETICMARKER7731 !!")] }

    func testLegacyPathsAreNotFoundAndNewApiUnchangedWhileSettingIsOff() async throws {
        try await withFixture { fx in
            try await compat(fx, false)
            for p in ["/endpoint/", "/endpoint/index.php", "/api/getFormData.php", "/api/v2/form/", "/api/v2/key/"] {
                try await eq(try await send(fx.app, path: p, query: "f=\(formID)&z=\(formID)", body: body(good)).status, .notFound, p)
            }
            // legacy client headers on the shared path: no special treatment, no unsigned acceptance, problem+json
            let r = try await send(fx.app, headers: legacyHeaders, body: body(good))
            XCTAssertEqual(r.status, .forbidden)
            XCTAssertTrue(r.text.contains("\"code\""), r.text)
            XCTAssertFalse(r.text.contains("\"error\""))
            try await eq(try await count(fx.sql, "submissions"), 0)
        }
    }

    func testV1SubmitEndpointOldFormatAndSignatureRule() async throws {
        try await withFixture { fx in
            try await compat(fx)
            // form WITH key: unsigned stays refused
            let refused = try await send(fx.app, path: "/endpoint/", headers: legacyHeaders, body: body(good))
            XCTAssertEqual(refused.status, .forbidden); XCTAssertEqual(refused.text, "403 - Forbidden")
            try await eq(try await count(fx.sql, "submissions"), 0)
            // form WITHOUT key: accepted, plain "200 - OK" like the old v1 answer
            try await dropKeys(fx)
            let ok = try await send(fx.app, path: "/endpoint/", headers: legacyHeaders, body: body(good))
            XCTAssertEqual(ok.status, .ok); XCTAssertEqual(ok.text, "200 - OK")
            let alias = try await send(fx.app, path: "/endpoint/index.php", body: body(good))
            XCTAssertEqual(alias.status, .ok)
            try await eq(try await count(fx.sql, "submissions"), 2)
            // the unsigned relaxation does not leak to the new API (no legacy headers = no relaxation)
            let new = try await send(fx.app, body: body(good))
            XCTAssertEqual(new.status, .forbidden)
            // error shapes of the old backend
            let get = try await send(fx.app, method: .GET, path: "/endpoint/")
            XCTAssertEqual(get.status, .methodNotAllowed); XCTAssertEqual(get.text, "405 - Method Not Allowed")
            let noF = try await send(fx.app, path: "/endpoint/", query: "x=1", body: body(good)); XCTAssertEqual(noF.text, "401 - Unauthorized")
            let unknown = try await send(fx.app, path: "/endpoint/", query: "f=\(UUID().uuidString.lowercased())", body: body(good)); XCTAssertEqual(unknown.text, "404 - Not Found")
            try await fx.sql.raw("UPDATE forms SET active=0").run()
            let inactive = try await send(fx.app, path: "/endpoint/", body: body(good)); XCTAssertEqual(inactive.text, "404 - Not Found")
        }
    }

    func testFieldErrorsAre412InTheOldFormatAndStay422ForTheNewApi() async throws {
        try await withFixture { fx in
            try await compat(fx); try await definition(fx, schema)
            try await dropKeys(fx)
            let v1 = try await send(fx.app, path: "/endpoint/", body: body(bad))
            XCTAssertEqual(v1.status, .preconditionFailed); XCTAssertEqual(v1.text, "412 - Precondition Failed")
            let v2 = try await send(fx.app, headers: legacyHeaders, body: body(bad))
            XCTAssertEqual(v2.status, .preconditionFailed)
            XCTAssertEqual(v2.text, #"{"error":{"code":412,"status":"Precondition Failed"}}"#)
            // no field name, no value
            for r in [v1, v2] { XCTAssertFalse(r.text.contains("SYNTHETICMARKER")); XCTAssertFalse(r.text.contains("nachricht")) }
            // new API (no legacy headers), signed as the new SDK does: 422 problem+json
            try await fx.sql.raw("""
                INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,public_key,state,created_at)
                SELECT customer_id,id,'ed25519',1,\(bind: Blob(try Curve25519.Signing.PrivateKey(rawRepresentation: sigSeed).publicKey.rawRepresentation)),'current',created_at FROM forms
                """).run()
            let new = try await send(fx.app, headers: try signedHeaders(bad), body: body(bad))
            XCTAssertEqual(new.status.code, 422); XCTAssertTrue(new.text.contains("submission_invalid"))
            try await eq(try await count(fx.sql, "submissions"), 0)
            // valid input still passes through the same validation
            let ok = try await send(fx.app, headers: try signedHeaders(good), body: body(good))
            XCTAssertEqual(ok.status, .ok)
        }
    }

    func testOldV2SubmitSignatureRulesAndSuccessFormat() async throws {
        try await withFixture { fx in
            try await compat(fx)
            var h = legacyHeaders; h["X-Kubus-Timestamp"] = "1"; h["X-Kubus-Signature"] = "garbage"
            // key registered + invalid signature: 403 in the old JSON shape
            let r = try await send(fx.app, headers: h, body: body(good))
            XCTAssertEqual(r.status, .forbidden); XCTAssertEqual(r.text, #"{"error":{"code":403,"status":"Forbidden"}}"#)
            // key registered + valid signature: accepted, success body unchanged
            var signed = try signedHeaders(good); for (k, v) in legacyHeaders { signed[k] = v }
            let ok = try await send(fx.app, headers: signed, body: body(good))
            XCTAssertEqual(ok.status, .ok); XCTAssertTrue(ok.text.hasPrefix(#"{"submission":{"id":""#))
            // no key: the (unusable) signature of the old SDK is ignored
            try await dropKeys(fx)
            let ok2 = try await send(fx.app, headers: h, body: body(good))
            XCTAssertEqual(ok2.status, .ok)
            try await eq(try await count(fx.sql, "submissions"), 2)
        }
    }

    func testConfigV1AndV2ShapesAndErrors() async throws {
        try await withFixture { fx in
            try await compat(fx); try await dropKeys(fx)
            try await definition(fx, #"{"security":{"abuse":{"siteKey":"0x4AAAA-synthetic","testMode":false}},"fields":{"a":{"name":"name","kind":"text","required":true},"b":{"name":"nachricht","kind":"text","validation":{"pattern":"[a-z]+"}}}}"#)
            let v1 = try await send(fx.app, path: "/api/getFormData.php", query: "z=\(formID)", headers: legacyHeaders)
            XCTAssertEqual(v1.status, .ok); XCTAssertEqual(v1.text, #"{"cf-sitekey":"0x4AAAA-synthetic","mode":"production"}"#)
            let v2 = try await send(fx.app, path: "/api/v2/form/", headers: legacyHeaders)
            XCTAssertEqual(v2.status, .ok)
            XCTAssertEqual(v2.text, #"{"configuration":{"cfSitekey":"0x4AAAA-synthetic","mode":"production","signaturschluesselHinterlegt":false},"fields":[{"name":"name","required":true,"rule":null,"type":"text"},{"name":"nachricht","required":false,"rule":"[a-z]+","type":"text"}]}"#)
            try await definition(fx, #"{"security":{"abuse":{"testMode":true}}}"#)
            let t = try await send(fx.app, path: "/api/getFormData.php", query: "z=\(formID)"); XCTAssertEqual(t.text, #"{"cf-sitekey":null,"mode":"testing"}"#)
            // errors, old shape; unknown/inactive/disabled are indistinguishable
            let miss = try await send(fx.app, path: "/api/getFormData.php", query: "x=1"); XCTAssertEqual(miss.text, "401 - Unauthorized")
            let unknown = try await send(fx.app, path: "/api/v2/form/", query: "f=\(UUID().uuidString.lowercased())")
            XCTAssertEqual(unknown.text, #"{"error":{"code":404,"status":"Not Found"}}"#)
            try await fx.sql.raw("UPDATE forms SET active=0").run()
            let inactive = try await send(fx.app, path: "/api/v2/form/"); XCTAssertEqual(inactive.text, unknown.text)
            try await fx.sql.raw("UPDATE forms SET active=1").run(); try await fx.sql.raw("UPDATE customers SET state='disabled'").run()
            let disabled = try await send(fx.app, path: "/api/v2/form/"); XCTAssertEqual(disabled.text, unknown.text)
            let get = try await send(fx.app, method: .GET, path: "/api/v2/form/"); XCTAssertEqual(get.status, .methodNotAllowed)
        }
    }

    func testConfigV2NeedsSignatureWhenAKeyIsRegisteredAndKeyRouteIsConstant403() async throws {
        try await withFixture { fx in
            try await compat(fx); try await definition(fx, schema)
            let unsigned = try await send(fx.app, path: "/api/v2/form/", headers: legacyHeaders)
            XCTAssertEqual(unsigned.status, .forbidden); XCTAssertEqual(unsigned.text, #"{"error":{"code":403,"status":"Forbidden"}}"#)
            var h = try signedForm(); for (k, v) in legacyHeaders { h[k] = v }
            let ok = try await send(fx.app, path: "/api/v2/form/", headers: h, body: "")
            XCTAssertEqual(ok.status, .ok); XCTAssertTrue(ok.text.contains(#""signaturschluesselHinterlegt":true"#), ok.text)
            let stale = try signedForm(Int64(now.timeIntervalSince1970) - 1000)
            try await eq(try await send(fx.app, path: "/api/v2/form/", headers: stale).status, .forbidden)
            // key registration cannot be honoured; same answer for known and unknown forms
            let a = try await send(fx.app, path: "/api/v2/key/", headers: legacyHeaders, body: "publicKey=x")
            let b = try await send(fx.app, path: "/api/v2/key/", query: "f=\(UUID().uuidString.lowercased())", body: "publicKey=x")
            XCTAssertEqual(a.status, .forbidden); XCTAssertEqual(a.text, b.text)
            // v1 config never needs a signature (the old v1 never had one)
            let v1 = try await send(fx.app, path: "/api/getFormData.php", query: "z=\(formID)")
            XCTAssertEqual(v1.status, .ok)
        }
    }

    func testLegacyBudgetAppliesAndConfigHasItsOwnBucket() async throws {
        try await withFixture(rateLimited: true) { fx in
            try await compat(fx); try await dropKeys(fx)
            try await SystemSettings.write(fx.sql, key: "ingest.requestsPerMinute", value: "2", at: SubmitHandler.dbTime(now))
            for _ in 0..<2 { let r = try await send(fx.app, path: "/endpoint/", body: body(good)); XCTAssertEqual(r.status, .ok) }
            let limited = try await send(fx.app, path: "/endpoint/", body: body(good))
            XCTAssertEqual(limited.status, .tooManyRequests); XCTAssertEqual(limited.text, "429 - Too Many Requests")
            XCTAssertTrue((Int(limited.headers.first(name: "Retry-After") ?? "") ?? 0) >= 1)
            // the old v2 path shares the submit bucket
            let v2 = try await send(fx.app, headers: legacyHeaders, body: body(good))
            XCTAssertEqual(v2.text, #"{"error":{"code":429,"status":"Too Many Requests"}}"#)
            // config is counted separately (page renders must not exhaust submits) but is limited too
            for _ in 0..<2 { let r = try await send(fx.app, path: "/api/getFormData.php", query: "z=\(formID)"); XCTAssertEqual(r.status, .ok) }
            let cfg = try await send(fx.app, path: "/api/getFormData.php", query: "z=\(formID)")
            XCTAssertEqual(cfg.status, .tooManyRequests)
            try await eq(try await count(fx.sql, "submissions"), 2)
        }
    }

    func testOldStatusMappingForAbuseOutcomes() throws {
        let withToken = Data(#"{"fields":{"cf-turnstile-response":"t"},"files":[]}"#.utf8)
        let noToken = Data(#"{"fields":{},"files":[]}"#.utf8)
        XCTAssertEqual((LegacyStatus.fromAbuse(Abort(.preconditionFailed), canonical: withToken) as? LegacyStatus)?.code, 406)
        XCTAssertEqual((LegacyStatus.fromAbuse(Abort(.preconditionFailed), canonical: noToken) as? LegacyStatus)?.code, 412)
        XCTAssertEqual((LegacyStatus.fromAbuse(Abort(.unsupportedMediaType), canonical: noToken) as? LegacyStatus)?.code, 451)
        XCTAssertEqual((LegacyStatus.fromAbuse(Abort(.tooManyRequests), canonical: noToken) as? Abort)?.status, .tooManyRequests)
        XCTAssertEqual((LegacyStatus.fromAbuse(Abort(.forbidden), canonical: noToken) as? Abort)?.status, .forbidden)
    }
}
