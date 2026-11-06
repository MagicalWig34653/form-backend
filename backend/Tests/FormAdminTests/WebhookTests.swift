// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormCore
@testable import FormCrypto
import FormPersistence
@testable import FormWebhooks
import Foundation
import SQLKit
import TestSupport
import XCTest
import XCTVapor
@testable import FormAdmin

final class WebhookTests: XCTestCase {
    private struct Count: Decodable { let c: Int }
    private struct State: Decodable { let state: String; let attempts: Int; let next_attempt_at: Date?; let fence: Int }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date = Date()) { self.date = date }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
    }
    private actor Requests {
        var count = 0
        func increment() { count += 1 }
    }
    private func secrets(_ f: AdminFixture) throws -> SecretStore {
        SecretStore(db: f.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 7, count: 32)))
    }
    private func count(_ f: AdminFixture, _ table: String) async throws -> Int {
        try await f.sql.raw("SELECT COUNT(*) AS c FROM \(unsafeRaw: table)").first(decoding: Count.self)!.c
    }
    private func state(_ f: AdminFixture) async throws -> State {
        try await f.sql.raw("SELECT state, attempts, next_attempt_at, fence FROM webhook_outbox").first(decoding: State.self)!
    }
    private func seed(_ f: AdminFixture, at: Date) async throws -> (UUID, UUID, UUID, Curve25519.Signing.PrivateKey) {
        let tenant = try await f.customer(), form = try await f.form(customer: tenant), endpoint = UUID(), entry = UUID()
        let key = Curve25519.Signing.PrivateKey(), store = try secrets(f)
        let ref = try await store.put(key.rawRepresentation)
        try await f.sql.raw("""
            INSERT INTO webhook_endpoints (id, customer_id, form_id, target_url, signing_secret_ref, public_key, active, created_at)
            VALUES (\(bind: DB.bin(endpoint)), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), 'https://8.8.8.8/hook', \(bind: ref), \(bind: Blob(key.publicKey.rawRepresentation)), 1, \(bind: DB.time(at)))
            """).run()
        try await f.sql.raw("""
            INSERT INTO webhook_outbox (id, customer_id, form_id, webhook_id, submission_id, received_at, state, attempts, next_attempt_at, created_at)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: DB.bin(endpoint)), \(bind: DB.bin(entry)), \(bind: DB.time(at)), 'ready', 0, \(bind: DB.time(at)), \(bind: DB.time(at)))
            """).run()
        return (tenant, form, entry, key)
    }

    private actor Gate {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
        func signal() { open = true; for w in waiters { w.resume() }; waiters = [] }
    }

    func testWebhookAPIEnforcesQuotaOnCreateAndReactivation() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer(), form = try await f.form(customer: tenant)
            try await f.grant(user, "key.manage", customer: tenant, by: root)
            let client = try await f.login(user), base = "tenants/\(tenant)/forms/\(form)/webhooks"
            var first = "", disabled = ""
            for _ in 0..<5 {
                try await client.post(base, "{\"targetURL\":\"https://8.8.8.8/hook\"}") { res in
                    XCTAssertEqual(res.status, .created); first = jsonObject(res)["id"] as? String ?? ""
                }
            }
            try await client.post(base, "{\"targetURL\":\"https://8.8.8.8/hook\"}") { XCTAssertEqual($0.status.code, 422) }
            try await client.post(base, "{\"targetURL\":\"https://8.8.8.8/hook\",\"active\":false}") { res in
                XCTAssertEqual(res.status, .created); disabled = jsonObject(res)["id"] as? String ?? ""
            }
            try await client.send(.PUT, "\(base)/\(disabled)", body: "{\"active\":true}") { XCTAssertEqual($0.status.code, 422) }
            try await client.send(.PUT, "\(base)/\(first)", body: "{\"active\":false}") { XCTAssertEqual($0.status, .noContent) }
            try await client.send(.PUT, "\(base)/\(disabled)", body: "{\"active\":true}") { XCTAssertEqual($0.status, .noContent) }
        }
    }

    func testWebhookFormAndCustomerQuotas() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, _, _) = try await self.seed(f, at: Date())
            let limits = WebhookLimits(perForm: 1, perCustomer: 2, backlog: 2)
            try await f.app.db(.mysql).transaction { conn in
                let tx = conn as! SQLDatabase
                try await WebhookLimits.lockCustomer(tx, customer: DB.bin(tenant))
                do {
                    try await limits.checkActivation(tx, customer: DB.bin(tenant), form: DB.bin(form), excluding: DB.bin(UUID()))
                    XCTFail("form quota must reject")
                } catch let error as Abort { XCTAssertEqual(error.status, .unprocessableEntity) }
                do {
                    try await WebhookLimits(perForm: 5, perCustomer: 1).checkActivation(tx, customer: DB.bin(tenant), form: DB.bin(form), excluding: DB.bin(UUID()))
                    XCTFail("customer quota must reject")
                } catch let error as Abort { XCTAssertEqual(error.status, .unprocessableEntity) }
                try await WebhookLimits(perForm: 1, perCustomer: 1).checkActivation(tx, customer: DB.bin(tenant), form: DB.bin(form), excluding: (try await tx.raw("SELECT id FROM webhook_endpoints").first(decoding: WebhookLimits.ID.self))!.id)
            }
        }
    }

    func testWebhookBacklogProducesTerminalMetadata() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, _, _) = try await self.seed(f, at: Date())
            try await f.app.db(.mysql).transaction { conn in
                let tx = conn as! SQLDatabase
                try await WebhookLimits.lockCustomer(tx, customer: DB.bin(tenant))
                for _ in 0..<3 {
                    try await WebhookLimits(backlog: 2).enqueue(tx, customer: DB.bin(tenant), form: DB.bin(form), submission: DB.bin(UUID()), at: DB.time(Date()))
                }
            }
            let pending = try await f.sql.raw("SELECT COUNT(*) AS c FROM webhook_outbox WHERE state = 'ready'").first(decoding: Count.self)!.c
            let overflow = try await f.sql.raw("SELECT COUNT(*) AS c FROM webhook_outbox WHERE state = 'failed-terminal' AND last_error_code = 'backlog' AND attempts = 0 AND completed_at IS NOT NULL").first(decoding: Count.self)!.c
            XCTAssertEqual(pending, 2); XCTAssertEqual(overflow, 2)
        }
    }

    func testWebhookRoundRobinAndParallelDelivery() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, _, _) = try await self.seed(f, at: Date())
            let (_, otherForm, _, _) = try await self.seed(f, at: Date())
            // First tenant has a large backlog, second only one row.
            try await f.app.db(.mysql).transaction { conn in
                let tx = conn as! SQLDatabase
                try await WebhookLimits.lockCustomer(tx, customer: DB.bin(tenant))
                for _ in 0..<25 { try await WebhookLimits().enqueue(tx, customer: DB.bin(tenant), form: DB.bin(form), submission: DB.bin(UUID()), at: DB.time(Date())) }
            }
            let bothStarted = Gate(), calls = Requests()
            let worker = WebhookDispatcher(db: f.app.db(.mysql), secrets: try self.secrets(f), send: { _, _, _, _ in
                await calls.increment()
                if await calls.count == 2 { await bothStarted.signal() }
                await bothStarted.wait()
                return 204
            })
            let delivered = try await worker.run(batch: 2)
            XCTAssertEqual(delivered, 2)
            let other = try await f.sql.raw("SELECT COUNT(*) AS c FROM webhook_outbox WHERE form_id = \(bind: DB.bin(otherForm)) AND state = 'succeeded'").first(decoding: Count.self)!.c
            XCTAssertEqual(other, 1)
            let next = try await worker.run()
            XCTAssertEqual(next, 20) // per-customer pass cap
        }
    }

    func testWebhookFinishAfterLockWaitMarksExpiredLeaseUncertain() async throws {
        try await AdminFixture.with { f in
            let clock = Clock(), _ = try await self.seed(f, at: clock.now())
            let worker = WebhookDispatcher(db: f.app.db(.mysql), secrets: try self.secrets(f), now: { clock.now() })
            let claim = try await worker.claim()!, locked = Gate(), release = Gate()
            let holder = Task {
                try await f.app.db(.mysql).transaction { conn in
                    struct ID: Decodable { let id: Blob }
                    _ = try await (conn as! SQLDatabase).raw("SELECT id FROM webhook_outbox FOR UPDATE").first(decoding: ID.self)
                    await locked.signal(); await release.wait()
                }
            }
            await locked.wait()
            let finisher = Task { try await worker.finish(claim, status: 204) }
            try await Task.sleep(nanoseconds: 100_000_000)
            clock.advance(31); await release.signal()
            try await holder.value
            let completed = try await finisher.value
            XCTAssertFalse(completed)
            let row = try await self.state(f); XCTAssertEqual(row.state, "uncertain")
        }
    }

    func testWebhookDeletingEndpointDuringOpenDeliveryCannotRecreateOutbox() async throws {
        try await AdminFixture.with { f in
            let (tenant, form, _, _) = try await self.seed(f, at: Date())
            let root = try await f.account(), user = try await f.account()
            try await f.grant(user, "key.manage", customer: tenant, by: root)
            let client = try await f.login(user), started = Gate(), release = Gate()
            struct Endpoint: Decodable { let id: Blob }
            let id = try await f.sql.raw("SELECT id FROM webhook_endpoints").first(decoding: Endpoint.self)!.id
            let worker = WebhookDispatcher(db: f.app.db(.mysql), secrets: try self.secrets(f), send: { _, _, _, _ in
                await started.signal(); await release.wait(); return 204
            })
            let running = Task { try await worker.run() }
            await started.wait()
            try await client.send(.DELETE, "tenants/\(tenant)/forms/\(form)/webhooks/\(DB.uuid(id.data)!)") { XCTAssertEqual($0.status, .noContent) }
            await release.signal(); _ = try await running.value
            let outbox = try await self.count(f, "webhook_outbox"), endpoints = try await self.count(f, "webhook_endpoints")
            XCTAssertEqual(outbox, 0); XCTAssertEqual(endpoints, 0)
        }
    }

    func testWebhookAdministrationRightsSSRFSecretsAndFreshAuthentication() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer(), form = try await f.form(customer: tenant)
            try await f.grant(user, "form.read", customer: tenant, by: root)
            let client = try await f.login(user), base = "tenants/\(tenant)/forms/\(form)/webhooks"
            try await client.get(base) { XCTAssertEqual($0.status, .forbidden) }
            try await client.post(base, "{\"targetURL\":\"https://8.8.8.8/hook\"}") { XCTAssertEqual($0.status, .forbidden) }
            // Form-scoped key rights do not grant customer-scoped management.
            try await f.grant(user, "key.manage", customer: tenant, form: form, by: root)
            try await client.get(base) { XCTAssertEqual($0.status, .forbidden) }
            try await f.grant(user, "key.manage", customer: tenant, by: root)
            for url in ["http://8.8.8.8/hook", "https://127.0.0.1/hook", "https://10.0.0.1/hook", "https://[::1]/hook", "https://user:pass@8.8.8.8/hook"] {
                try await client.post(base, "{\"targetURL\":\"\(url)\"}") { XCTAssertEqual($0.status.code, 422) }
            }
            var id = "", privateKey = Data(), publicKey = Data()
            try await client.post(base, "{\"targetURL\":\"https://8.8.8.8/hook\"}") { res in
                XCTAssertEqual(res.status, .created)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                let object = jsonObject(res)
                id = object["id"] as? String ?? ""
                privateKey = Data(base64Encoded: object["privateKey"] as? String ?? "") ?? Data()
                publicKey = Data(base64Encoded: object["publicKey"] as? String ?? "") ?? Data()
            }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
            XCTAssertEqual(key.publicKey.rawRepresentation, publicKey)
            struct Secret: Decodable { let signing_secret_ref: String; let ciphertext: Blob }
            let stored = try await f.sql.raw("SELECT e.signing_secret_ref, s.ciphertext FROM webhook_endpoints e JOIN managed_secrets s ON s.ref = e.signing_secret_ref").first(decoding: Secret.self)!
            XCTAssertNotEqual(stored.ciphertext.data, privateKey)
            let opened = try await self.secrets(f).get(stored.signing_secret_ref)
            XCTAssertEqual(opened, privateKey)
            try await client.get(base) { res in
                XCTAssertEqual(res.status, .ok)
                let items = jsonObject(res)["items"] as? [[String: Any]] ?? []
                XCTAssertEqual(items.count, 1)
                XCTAssertNil(items.first?["privateKey"])
            }
            try await client.send(.PUT, "\(base)/\(id)", body: "{\"active\":false}") { XCTAssertEqual($0.status, .noContent) }
            try await client.send(.PUT, "\(base)/\(id)", body: "{\"active\":1}") { XCTAssertEqual($0.status.code, 400) }
            let other = try await f.customer()
            try await client.get("tenants/\(other)/forms/\(form)/webhooks") { XCTAssertEqual($0.status, .notFound) }
            try await client.send(.DELETE, "\(base)/\(id)") { XCTAssertEqual($0.status, .noContent) }
            let endpoints = try await self.count(f, "webhook_endpoints"); XCTAssertEqual(endpoints, 0)
            let missing = try await self.secrets(f).get(stored.signing_secret_ref)
            XCTAssertNil(missing)
            let audit = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE category = 'webhook'").first(decoding: Count.self)!.c
            XCTAssertGreaterThanOrEqual(audit, 4)
            try await f.sql.raw("UPDATE sessions SET authenticated_at = DATE_SUB(NOW(), INTERVAL 10 MINUTE) WHERE account_id = \(bind: DB.bin(user))").run()
            try await client.get(base) { XCTAssertEqual($0.status.code, 403) }
        }
    }

    func testWebhookSignaturePayloadAndRetryBackoffExhaustion() async throws {
        try await AdminFixture.with { f in
            let clock = Clock(), (_, form, entry, key) = try await self.seed(f, at: clock.now()), requests = Requests()
            let dispatcher = WebhookDispatcher(db: f.app.db(.mysql), secrets: try self.secrets(f), now: { clock.now() }, send: { url, body, timestamp, signature in
                await requests.increment()
                let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                XCTAssertEqual(Set(payload.keys), ["event", "deliveryUUID", "formularUUID", "anfrageUUID", "eingegangenAm"])
                XCTAssertEqual(payload["event"] as? String, "anfrage.eingegangen")
                XCTAssertEqual(payload["formularUUID"] as? String, form.uuidString.lowercased())
                XCTAssertEqual(payload["anfrageUUID"] as? String, entry.uuidString.lowercased())
                let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
                let signed = Data("KUBUS-WEBHOOK\nPOST\n\(url)\n\(timestamp)\n\(hash)".utf8)
                XCTAssertTrue(key.publicKey.isValidSignature(Data(base64Encoded: signature)!, for: signed))
                XCTAssertFalse(key.publicKey.isValidSignature(Data(base64Encoded: signature)!, for: body))
                return 503
            })
            let delays = [60, 300, 900, 3600, 10800, 21600, 43200]
            for attempt in 1...8 {
                let result = try await dispatcher.run()
                XCTAssertEqual(result, 1)
                let state = try await self.state(f)
                XCTAssertEqual(state.attempts, attempt)
                if attempt < 8 {
                    XCTAssertEqual(state.state, "ready")
                    XCTAssertEqual(state.next_attempt_at!.timeIntervalSince(clock.now()), Double(delays[attempt - 1]), accuracy: 0.01)
                    let tooEarly = try await dispatcher.run(); XCTAssertEqual(tooEarly, 0)
                    clock.advance(Double(delays[attempt - 1]))
                } else { XCTAssertEqual(state.state, "failed-terminal") }
            }
            let final = try await dispatcher.run(); XCTAssertEqual(final, 0)
            let sent = await requests.count; XCTAssertEqual(sent, 8)
        }
    }

    func testWebhookTwoWorkersDoNotSendTwiceAndStaleFenceCannotComplete() async throws {
        try await AdminFixture.with { f in
            let clock = Clock(), _ = try await self.seed(f, at: clock.now()), requests = Requests()
            let send: @Sendable (String, Data, String, String) async throws -> Int = { _, _, _, _ in
                await requests.increment()
                try await Task.sleep(nanoseconds: 100_000_000)
                return 204
            }
            let first = WebhookDispatcher(db: f.app.db(.mysql), secrets: try self.secrets(f), now: { clock.now() }, send: send)
            let second = WebhookDispatcher(db: f.app.db(.mysql), secrets: try self.secrets(f), now: { clock.now() }, send: send)
            async let a = first.run(); async let b = second.run()
            _ = try await (a, b)
            let sent = await requests.count; XCTAssertEqual(sent, 1)
            let succeeded = try await self.state(f); XCTAssertEqual(succeeded.state, "succeeded")
            try await f.sql.raw("UPDATE webhook_outbox SET state = 'ready', attempts = 0, next_attempt_at = \(bind: DB.time(clock.now()))").run()
            let claim = try await first.claim()!
            XCTAssertEqual(claim.attempts, 1)
            let other = try await second.claim(); XCTAssertNil(other)
            // A stale worker cannot finalize a row after ownership has advanced.
            try await f.sql.raw("UPDATE webhook_outbox SET fence = fence + 1").run()
            let stale = try await first.finish(claim, status: 204); XCTAssertFalse(stale)
            clock.advance(31)
            let expired = try await second.claim(); XCTAssertNil(expired)
            let uncertain = try await self.state(f); XCTAssertEqual(uncertain.state, "uncertain")
            let late = try await first.finish(claim, status: 204); XCTAssertFalse(late)
            let after = try await second.run(); XCTAssertEqual(after, 0)
            let stillOnce = await requests.count; XCTAssertEqual(stillOnce, 1)
        }
    }
    func testWebhookIngestIsAtomicIdempotentAndSurvivesSubmissionErasure() async throws {
        try await AdminFixture.with(webhookLimits: WebhookLimits(backlog: 2)) { f in
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            for right in ["form.create", "form.read", "draft.write", "release.publish", "key.manage", "content.delete"] {
                try await f.grant(user, right, customer: tenant, by: root)
            }
            let client = try await f.login(user)
            var form = "", draft = "", hash = "", confirmation = "", signingSeed = Data()
            try await client.post("tenants/\(tenant)/forms", "{\"name\":\"Kontakt\"}") { form = jsonObject($0)["id"] as? String ?? "" }
            let base = "tenants/\(tenant)/forms/\(form)"
            try await client.get(base) { draft = (jsonObject($0)["draftIds"] as? [String])?.first ?? "" }
            try await client.get("\(base)/drafts/\(draft)") { hash = jsonObject($0)["hash"] as? String ?? "" }
            try await client.post("\(base)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirm\":true}") {
                confirmation = jsonObject($0)["confirmationId"] as? String ?? ""
            }
            try await client.send(.POST, "\(base)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":1,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key": "release"]) { XCTAssertEqual($0.status, .created) }
            let recipient = Curve25519.KeyAgreement.PrivateKey()
            try await client.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(recipient.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
            try await client.send(.POST, "\(base)/sdk-credentials") { signingSeed = Data(base64URLString: jsonObject($0)["signingSeed"] as? String ?? "") ?? Data() }
            for active in [true, true, false] {
                try await client.post("\(base)/webhooks", "{\"targetURL\":\"https://8.8.8.8/hook\",\"active\":\(active)}") { XCTAssertEqual($0.status, .created) }
            }
            let canonical = try RequestSignature.canonical(fields: PHPValue.array([("nachricht", .string("SECRET-CONTENT"))]))
            let stamp = String(Int64(Date().timeIntervalSince1970))
            let signature = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: form, timestamp: stamp, canonical: canonical), seed: signingSeed)
            var headers = HTTPHeaders()
            headers.contentType = .urlEncodedForm
            headers.add(name: "X-Kubus-Timestamp", value: stamp)
            headers.add(name: "X-Kubus-Signature", value: signature.base64EncodedString())
            headers.add(name: "Idempotency-Key", value: "submission")
            // A failing outbox insert must roll the submission, sealed objects and idempotency key back together.
            try await f.sql.raw("CREATE TRIGGER fail_webhook_insert BEFORE INSERT ON webhook_outbox FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'synthetic outbox failure'").run()
            try await f.app.test(.POST, "api/v2/submit/?f=\(form)", headers: headers, body: ByteBuffer(string: "nachricht=SECRET%2DCONTENT")) { XCTAssertEqual($0.status, .internalServerError) }
            for table in ["submissions", "stored_objects", "webhook_outbox", "ingest_idempotency"] {
                let remaining = try await self.count(f, table); XCTAssertEqual(remaining, 0, table)
            }
            try await f.sql.raw("DROP TRIGGER fail_webhook_insert").run()
            var entry = ""
            for _ in 0..<2 {
                try await f.app.test(.POST, "api/v2/submit/?f=\(form)", headers: headers, body: ByteBuffer(string: "nachricht=SECRET%2DCONTENT")) { res in
                    XCTAssertEqual(res.status, .ok)
                    entry = (jsonObject(res)["submission"] as? [String: Any])?["id"] as? String ?? ""
                }
                let submissions = try await self.count(f, "submissions"), jobs = try await self.count(f, "webhook_outbox")
                XCTAssertEqual(submissions, 1); XCTAssertEqual(jobs, 2)
            }
            let ready = try await f.sql.raw("SELECT COUNT(*) AS c FROM webhook_outbox WHERE state = 'ready' AND attempts = 0").first(decoding: Count.self)!.c
            XCTAssertEqual(ready, 2)
            // Backlog saturation must not reject a new signed submission.
            headers.replaceOrAdd(name: "Idempotency-Key", value: "overflow-submission")
            try await f.app.test(.POST, "api/v2/submit/?f=\(form)", headers: headers, body: ByteBuffer(string: "nachricht=SECRET%2DCONTENT")) {
                XCTAssertEqual($0.status, .ok)
            }
            let overflow = try await f.sql.raw("SELECT COUNT(*) AS c FROM webhook_outbox WHERE state = 'failed-terminal' AND last_error_code = 'backlog'").first(decoding: Count.self)!.c
            XCTAssertEqual(overflow, 2)
            try await client.send(.DELETE, "\(base)/entries/\(entry)") { XCTAssertEqual($0.status, .noContent) }
            let jobs = try await self.count(f, "webhook_outbox"), submissions = try await self.count(f, "submissions")
            XCTAssertEqual(jobs, 4); XCTAssertEqual(submissions, 1)
            let requestCount = Requests()
            let worker = WebhookDispatcher(db: f.app.db(.mysql), secrets: try self.secrets(f), send: { _, body, _, _ in
                await requestCount.increment()
                XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("SECRET-CONTENT"))
                return 200
            })
            let delivered = try await worker.run(); XCTAssertEqual(delivered, 2)
            let sends = await requestCount.count; XCTAssertEqual(sends, 2)
        }
    }

    func testWebhookWorkerDeliversSignedMetadataOverHTTPS() async throws {
        try await AdminFixture.with { f in
            let (_, form, entry, key) = try await self.seed(f, at: Date())
            let server = FakeWebhookServer(statuses: [204])
            try await server.start()
            do {
                let url = "https://localhost:\(server.port)/hook?source=test"
                try await f.sql.raw("UPDATE webhook_endpoints SET target_url = \(bind: url)").run()
                let client = WebhookHTTP(testAllowedNets: [CIDR("127.0.0.0/8")!, CIDR("::1/128")!], testAllowInsecure: true)
                let worker = WebhookDispatcher(db: f.app.db(.mysql), secrets: try self.secrets(f), send: { url, body, timestamp, signature in
                    try await client.send(url: url, body: body, timestamp: timestamp, signature: signature)
                })
                let delivered = try await worker.run(); XCTAssertEqual(delivered, 1)
                let state = try await self.state(f); XCTAssertEqual(state.state, "succeeded"); XCTAssertEqual(state.attempts, 1)
                let again = try await worker.run(); XCTAssertEqual(again, 0)
                let requests = server.requests
                XCTAssertEqual(requests.count, 1)
                let request = try XCTUnwrap(requests.first)
                XCTAssertEqual(request.uri, "/hook?source=test")
                let timestamp = try XCTUnwrap(request.headers.first(name: "X-Kubus-Webhook-Timestamp"))
                let signature = try XCTUnwrap(request.headers.first(name: "X-Kubus-Webhook-Signature").flatMap { Data(base64Encoded: $0) })
                let hash = SHA256.hash(data: request.body).map { String(format: "%02x", $0) }.joined()
                let signed = Data("KUBUS-WEBHOOK\nPOST\n\(url)\n\(timestamp)\n\(hash)".utf8)
                XCTAssertTrue(key.publicKey.isValidSignature(signature, for: signed))
                let payload = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
                XCTAssertEqual(Set(payload.keys), ["event", "deliveryUUID", "formularUUID", "anfrageUUID", "eingegangenAm"])
                XCTAssertEqual(payload["event"] as? String, "anfrage.eingegangen")
                XCTAssertEqual(payload["formularUUID"] as? String, form.uuidString.lowercased())
                XCTAssertEqual(payload["anfrageUUID"] as? String, entry.uuidString.lowercased())
            } catch { await server.stop(); throw error }
            await server.stop()
        }
    }

}
