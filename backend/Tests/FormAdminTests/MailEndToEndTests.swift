// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormAuth
import FormCore
@testable import FormCrypto
import FormMail
import FormPersistence
import Foundation
import SQLKit
import TestSupport
import XCTest
import XCTVapor
@testable import FormAdmin

/// Mail with content through the whole chain: published form with `form.mail` -> connection (SMTP to a scriptable server) ->
/// signed submission -> delivery rows -> mails, with every failure mode visible as state and never leaking content.
final class MailEndToEndTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private struct Row: Decodable { let mail_kind: String; let state: String; let attempts: Int; let last_error_code: String?; let transport_kind: String }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func parse(_ r: XCTHTTPResponse) -> FormCore.JSONValue { (try? JCS.parse(Data(buffer: r.body))) ?? .null }

    private let defaultMail: FormCore.JSONValue = .object([
        "from": .object(["address": .string("info@example.org"), "name": .string("Praxis Müller")]),
        "organisation": .object(["to": .array([.string("empfang@example.org")]), "bcc": .array([.string("archiv@example.org")]), "replyToField": .string("email"),
                                 "subject": .string("Neue Anfrage von #=[name]=#"), "body": .string("<p>#=[nachricht]=#</p><p>#=[liste]=#</p>"), "format": .string("html")]),
        "confirmation": .object(["toField": .string("email"), "subject": .string("Danke, #=[name]=#"), "body": .string("Wir melden uns, #=[name]=#.\nIhre Nachricht: #=[nachricht]=#")]),
    ])

    struct World {
        let f: AdminFixture; let tenant: UUID; let form: String; let user: TestClient; let sys: TestClient; let seed: Data; let customerKey: Curve25519.KeyAgreement.PrivateKey; let root: UUID; let userID: UUID
    }

    /// Creates tenant, rights, published form (with `mail` if given), customer key and SDK credentials. SMTP connection is set up separately.
    private func world(_ f: AdminFixture, mail: FormCore.JSONValue?) async throws -> World {
        let root = try await f.account(), user = try await f.account(), sysAcc = try await f.account(), tenant = try await f.customer()
        for r in ["form.create", "form.read", "draft.write", "release.publish", "key.manage"] { try await f.grant(user, r, customer: tenant, by: root) }
        try await f.grant(sysAcc, "system.manage", system: true, by: root)
        let c = try await f.login(user), sys = try await f.login(sysAcc)
        var form = "", draft = "", doc = FormCore.JSONValue.null, hash = "", conf = ""
        try await c.post("tenants/\(tenant)/forms", "{\"name\":\"Kontakt\"}") { form = obj($0)["id"] as? String ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)") { draft = (obj($0)["draftIds"] as? [String])?.first ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { doc = parse($0)["document"] ?? .null }
        if let mail { doc = withMail(doc, mail) }
        try await c.send(.PATCH, "tenants/\(tenant)/forms/\(form)/drafts/\(draft)", body: String(decoding: JCS.canonicalize(doc), as: UTF8.self), headers: ["If-Match": "\"1\""]) { res async throws in
            XCTAssertEqual(res.status, .ok, text(res)); hash = parse(res)["hash"]?.string ?? ""
        }
        try await c.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":2,\"hash\":\"\(hash)\",\"confirm\":true}") { conf = obj($0)["confirmationId"] as? String ?? "" }
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":2,\"hash\":\"\(hash)\",\"confirmationId\":\"\(conf)\"}", headers: ["Idempotency-Key": "k"]) { XCTAssertEqual($0.status, .created, text($0)) }
        let sk = Curve25519.KeyAgreement.PrivateKey()
        try await c.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
        var seed = Data()
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: obj($0)["signingSeed"] as? String ?? "") ?? Data() }
        return World(f: f, tenant: tenant, form: form, user: c, sys: sys, seed: seed, customerKey: sk, root: root, userID: user)
    }

    /// Adds name/email fields and the mail section; keeps the views' form reference consistent.
    private func withMail(_ doc: FormCore.JSONValue, _ mail: FormCore.JSONValue) -> FormCore.JSONValue {
        guard var top = doc.object, var form = top["form"]?.object, var fields = form["fields"]?.object, let views = top["views"]?.array else { return doc }
        func field(_ name: String, _ kind: String) -> FormCore.JSONValue { .object(["name": .string(name), "kind": .string(kind), "label": .object(["de": .string(name)]), "required": .bool(false), "hidden": .bool(false), "locked": .bool(false), "sensitive": .bool(false), "validation": .object(["type": .string("string")])]) }
        fields["name"] = field("name", "text"); fields["email"] = field("email", "email"); fields["liste"] = field("liste", "text")
        form["fields"] = .object(fields); form["mail"] = mail
        let formValue = FormCore.JSONValue.object(form)
        let h = hex(DocHash.sha256(formValue))
        top["form"] = formValue
        top["views"] = .array(views.map { v in guard var o = v.object, var r = o["form"]?.object else { return v }; r["sha256"] = .string(h); o["form"] = .object(r); return .object(o) })
        return .object(top)
    }

    /// SMTP connection (plain to the fake server; the fixture allows loopback and insecure for development), assigned to tenant and form.
    @discardableResult
    private func connect(_ w: World, _ smtp: FakeSMTPServer, user: String? = nil, password: String? = nil) async throws -> String {
        var config: [String: Any] = ["host": "127.0.0.1", "port": smtp.port, "security": "plain"]
        if let user { config["username"] = user }
        var body: [String: Any] = ["kind": "smtp", "name": "Test-SMTP", "config": config]
        if let password { body["credential"] = password }
        var id = ""
        try await w.sys.send(.POST, "connections", body: String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)) { res async throws in
            XCTAssertEqual(res.status, .created, text(res)); id = obj(res)["id"] as? String ?? ""
        }
        try await w.sys.send(.PUT, "tenants/\(w.tenant)/connections/\(id)") { XCTAssertEqual($0.status, .noContent) }
        try await w.user.send(.PUT, "tenants/\(w.tenant)/forms/\(w.form)/mail-connection", body: "{\"connectionId\":\"\(id)\"}") { XCTAssertEqual($0.status, .noContent, text($0)) }
        return id
    }

    private func submit(_ w: World, _ pairs: [(String, String)], key: String? = nil, _ check: (XCTHTTPResponse) async throws -> Void) async throws {
        let fields = PHPValue.array(pairs.map { ($0.0, PHPValue.string($0.1)) })
        let canonical = try RequestSignature.canonical(fields: fields)
        let ts = String(Int64(Date().timeIntervalSince1970))
        let sig = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: w.form, timestamp: ts, canonical: canonical), seed: w.seed)
        var h = HTTPHeaders(); h.contentType = .urlEncodedForm
        h.add(name: "X-Kubus-Timestamp", value: ts); h.add(name: "X-Kubus-Signature", value: sig.base64EncodedString())
        if let key { h.add(name: "Idempotency-Key", value: key) }
        let body = pairs.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" }.joined(separator: "&")
        try await w.f.app.test(.POST, "api/v2/submit/?f=\(w.form)", headers: h, body: ByteBuffer(string: body), afterResponse: check)
    }

    private func until(_ timeout: TimeInterval = 8, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if try await cond() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("condition not reached in time")
    }

    private func decoded(_ data: String) -> (headers: [String: String], body: String) {
        let parts = data.components(separatedBy: "\r\n\r\n")
        var h: [String: String] = [:]
        for l in parts[0].replacingOccurrences(of: "\r\n ", with: "").components(separatedBy: "\r\n") { if let i = l.firstIndex(of: ":") { h[String(l[..<i]).lowercased()] = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces) } }
        let b64 = parts.dropFirst().joined().replacingOccurrences(of: "\r\n", with: "")
        return (h, String(decoding: Data(base64Encoded: b64) ?? Data(), as: UTF8.self))
    }
    private func subject(_ s: String) -> String {
        guard s.contains("=?UTF-8?B?") else { return s }   // plain ASCII subjects are not encoded
        return s.components(separatedBy: "=?UTF-8?B?").dropFirst().map { String(decoding: Data(base64Encoded: String($0.prefix(while: { $0 != "?" }))) ?? Data(), as: UTF8.self) }.joined()
    }
    private func deliveries(_ f: AdminFixture) async throws -> [Row] {
        try await f.sql.raw("SELECT mail_kind, state, attempts, last_error_code, transport_kind FROM mail_deliveries ORDER BY mail_kind").all(decoding: Row.self)
    }
    private let pairs: [(String, String)] = [("name", "Erika <Muster>"), ("email", "erika@example.net"), ("nachricht", "Grüße & <b>Hallo</b> MAIL-MARKER-4711"), ("liste", "a")]

    func testRestrictedRecipientsBlockBCCAndConfirmationBeforeSMTP() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            try await connect(w, smtp)
            try await SystemSettings.write(f.sql, key: "mail.restricted", value: "true", at: DB.time(Date()))
            try await SystemSettings.write(f.sql, key: "mail.allowedRecipients", value: #"["empfang@example.org"]"#, at: DB.time(Date()))
            try await submit(w, pairs, key: "restricted") { XCTAssertEqual($0.status, .ok) }
            let denied = try await deliveries(f)
            XCTAssertEqual(denied.count, 2)
            XCTAssertTrue(denied.allSatisfy { $0.state == "abandoned" && $0.last_error_code == "recipient_not_allowed" })
            XCTAssertTrue(smtp.mails.isEmpty)
            try await SystemSettings.write(f.sql, key: "mail.allowedRecipients", value: #"["empfang@example.org","archiv@example.org","erika@example.net"]"#, at: DB.time(Date()))
            try await submit(w, pairs, key: "allowed") { XCTAssertEqual($0.status, .ok) }
            try await until { smtp.mails.count == 2 }
        }
    }

    func testMailsWithContentAreSentAndRecordedWithoutStoringContent() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            try await connect(w, smtp)
            var id = ""
            try await submit(w, pairs, key: "m1") { res async throws in XCTAssertEqual(res.status, .ok, text(res)); id = ((obj(res)["submission"] as? [String: Any])?["id"] as? String) ?? "" }
            try await until { smtp.mails.count == 2 }
            let org = try XCTUnwrap(smtp.mails.first { $0.rcpts.contains("empfang@example.org") }), conf = try XCTUnwrap(smtp.mails.first { $0.rcpts == ["erika@example.net"] })
            // organisation mail: To + Bcc on the envelope, Bcc not in the headers, HTML with escaped values, Reply-To from the submitted address
            XCTAssertEqual(org.rcpts, ["empfang@example.org", "archiv@example.org"]); XCTAssertEqual(org.from, "info@example.org")
            let o = decoded(org.data)
            XCTAssertEqual(o.headers["to"], "empfang@example.org"); XCTAssertEqual(o.headers["reply-to"], "erika@example.net"); XCTAssertNil(o.headers["bcc"])
            XCTAssertEqual(o.headers["content-type"], "text/html; charset=utf-8")
            XCTAssertEqual(subject(o.headers["subject"] ?? ""), "Neue Anfrage von Erika <Muster>", "the subject is text, not HTML")
            XCTAssertEqual(o.body, "<p>Grüße &amp; &lt;b&gt;Hallo&lt;/b&gt; MAIL-MARKER-4711</p><p>a</p>")
            // confirmation: plain text to the submitted address
            let c = decoded(conf.data)
            XCTAssertEqual(c.headers["content-type"], "text/plain; charset=utf-8"); XCTAssertEqual(c.headers["to"], "erika@example.net")
            XCTAssertEqual(c.body, "Wir melden uns, Erika <Muster>.\r\nIhre Nachricht: Grüße & <b>Hallo</b> MAIL-MARKER-4711")
            // state: both accepted, one attempt each, transport recorded
            try await until { try await deliveries(f).allSatisfy { $0.state == "smtp-accepted" } }
            let rows = try await deliveries(f)
            XCTAssertEqual(rows.map(\.mail_kind), ["confirmation", "organisation"]); XCTAssertTrue(rows.allSatisfy { $0.attempts == 1 && $0.last_error_code == nil && $0.transport_kind == "smtp" })
            // a retry with the same idempotency key creates neither a submission nor mail
            try await submit(w, pairs, key: "m1") { res async throws in XCTAssertEqual(res.status, .ok); XCTAssertEqual((obj(res)["submission"] as? [String: Any])?["id"] as? String, id) }
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(smtp.mails.count, 2); let again = try await deliveries(f); XCTAssertEqual(again.count, 2)
            // the content lives nowhere in the database
            for table in ["mail_deliveries", "audit_events", "stored_objects", "submissions", "ingest_idempotency"] {
                let cols = try await f.sql.raw("SELECT COLUMN_NAME AS n FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = \(bind: table)").all(decoding: ColName.self)
                for col in cols {
                    let hits = try await f.sql.raw("SELECT COUNT(*) AS c FROM \(ident: table) WHERE CAST(\(ident: col.n) AS CHAR CHARACTER SET latin1) LIKE '%MAIL-MARKER%' OR CAST(\(ident: col.n) AS CHAR CHARACTER SET latin1) LIKE '%erika@example.net%'").first(decoding: C.self)?.c
                    XCTAssertEqual(hits, 0, "\(table).\(col.n)")
                }
            }
            // admins can see the states, without content
            try await w.user.get("tenants/\(w.tenant)/forms/\(w.form)/mail-deliveries") { res async throws in
                XCTAssertEqual(res.status, .ok); let items = obj(res)["items"] as? [[String: Any]] ?? []
                XCTAssertEqual(items.count, 2); XCTAssertEqual(Set(items.compactMap { $0["state"] as? String }), ["smtp-accepted"])
                XCTAssertFalse(text(res).contains("MARKER")); XCTAssertFalse(text(res).contains("erika"))
            }
        }
    }
    private struct ColName: Decodable { let n: String }

    func testFailuresAreVisibleStatesAndNeverFailTheSubmission() async throws {
        var o = FakeSMTPServer.Options(); o.rejectRecipients = ["empfang@example.org"]
        let smtp = FakeSMTPServer(o); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            // 1. no connection configured: the submission is accepted, rows say why nothing was sent
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok) }
            var rows = try await deliveries(f)
            XCTAssertEqual(rows.map(\.state), ["waiting-manual", "waiting-manual"]); XCTAssertEqual(Set(rows.compactMap(\.last_error_code)), ["no_connection"])
            try await f.sql.raw("DELETE FROM mail_deliveries").run()
            // 2. connection exists, the server refuses the organisation recipient; the confirmation still goes out
            try await connect(w, smtp)
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok) }
            try await until { try await deliveries(f).allSatisfy { $0.state != "leased" } }
            rows = try await deliveries(f)
            XCTAssertEqual(rows.first { $0.mail_kind == "organisation" }?.state, "waiting-manual"); XCTAssertEqual(rows.first { $0.mail_kind == "organisation" }?.last_error_code, "rcpt_rejected")
            XCTAssertEqual(rows.first { $0.mail_kind == "confirmation" }?.state, "smtp-accepted")
            XCTAssertEqual(smtp.mails.count, 1); XCTAssertEqual(smtp.mails.first?.rcpts, ["erika@example.net"])
            XCTAssertTrue(rows.allSatisfy { $0.attempts == 1 }, "no automatic retry (ADR 0002 Nr. 19)")
            try await Task.sleep(nanoseconds: 500_000_000)
            let still = try await deliveries(f); XCTAssertEqual(still.first { $0.mail_kind == "organisation" }?.attempts, 1)
            // 3. an invalid or missing confirmation address is recorded, not silently dropped
            try await f.sql.raw("DELETE FROM mail_deliveries").run()
            try await submit(w, [("name", "X"), ("email", "not an address"), ("nachricht", "n")]) { XCTAssertEqual($0.status, .ok) }
            rows = try await deliveries(f)
            XCTAssertEqual(rows.first { $0.mail_kind == "confirmation" }?.state, "abandoned"); XCTAssertEqual(rows.first { $0.mail_kind == "confirmation" }?.last_error_code, "recipient_invalid")
            // 4. a header-injection attempt in the address field never reaches the server
            let before = smtp.mails.count
            try await submit(w, [("name", "X"), ("email", "a@example.net\r\nBcc: evil@example.org"), ("nachricht", "n")]) { XCTAssertEqual($0.status, .ok) }
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertFalse(smtp.mails.dropFirst(before).contains { $0.data.contains("evil@example.org") || $0.rcpts.contains { $0.contains("evil") } })
        }
    }

    func testManualResendUsesTheOriginalFieldsFromTheStoredPackageAndTheContentKey() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            // accepted without a connection: both mails wait for a human
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok) }
            let initial = try await deliveries(f).map(\.state)
            XCTAssertEqual(initial, ["waiting-manual", "waiting-manual"])
            try await connect(w, smtp)
            var entry = "", org = "", conf = ""
            try await w.user.get("tenants/\(w.tenant)/forms/\(w.form)/mail-deliveries") { res async throws in
                for d in (obj(res)["items"] as? [[String: Any]]) ?? [] {
                    entry = d["submissionId"] as? String ?? ""
                    if d["kind"] as? String == "organisation" { org = d["id"] as? String ?? "" } else { conf = d["id"] as? String ?? "" }
                }
            }
            XCTAssertFalse(org.isEmpty); XCTAssertFalse(conf.isEmpty)
            // the content key as the browser would hand it over: unwrapped from the stored package with the customer's private key
            struct Obj: Decodable { let ciphertext: Blob }
            let objRow = try await f.sql.raw("SELECT ciphertext FROM stored_objects").first(decoding: Obj.self)
            let wire = String(decoding: try XCTUnwrap(objRow).ciphertext.data, as: UTF8.self)
            let pkg = try PackageV2(wire)
            let cek = try HPKE.open(pkg.b, enc: pkg.a, recipient: w.customerKey, info: Data("kubus-anfrage v2".utf8), aad: Data(pkg.kid.utf8))
            let url = "tenants/\(w.tenant)/forms/\(w.form)/entries/\(entry)/resends"
            let key = cek.base64URLString

            // without the rights: forbidden (the user has neither content.resend nor content.decrypt)
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(org)\",\"contentKey\":\"\(key)\"}") { XCTAssertEqual($0.status, .forbidden) }
            for r in ["content.resend", "content.decrypt"] { try await f.grant(w.userID, r, customer: w.tenant, by: w.root) }
            // a wrong key changes nothing and sends nothing
            let wrong = Data(repeating: 7, count: 32).base64URLString
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(org)\",\"contentKey\":\"\(wrong)\"}") { XCTAssertEqual($0.status.code, 422) }
            let unchanged = try await deliveries(f).map(\.state)
            XCTAssertEqual(unchanged, ["waiting-manual", "waiting-manual"]); XCTAssertTrue(smtp.mails.isEmpty)
            // unknown fields in the body / foreign delivery id
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(org)\",\"contentKey\":\"\(key)\",\"fields\":{}}") { XCTAssertEqual($0.status, .badRequest) }
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(UUID().uuidString.lowercased())\",\"contentKey\":\"\(key)\"}") { XCTAssertEqual($0.status, .notFound) }
            // the right key: the organisation mail goes out with the ORIGINAL fields
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(org)\",\"contentKey\":\"\(key)\"}") { res async throws in
                XCTAssertEqual(res.status, .accepted, text(res)); XCTAssertFalse(text(res).contains(key))
            }
            try await until { smtp.mails.count == 1 }
            let sent = try XCTUnwrap(smtp.mails.first)
            XCTAssertTrue(sent.rcpts.contains("empfang@example.org"))
            XCTAssertTrue(decoded(sent.data).body.contains("MAIL-MARKER-4711"))
            try await until { try await deliveries(f).first { $0.mail_kind == "organisation" }?.state == "smtp-accepted" }
            // a delivery that is already accepted cannot be sent again; uncertain only with explicit confirmation
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(org)\",\"contentKey\":\"\(key)\"}") { XCTAssertEqual($0.status, .conflict) }
            try await f.sql.raw("UPDATE mail_deliveries SET state = 'uncertain' WHERE mail_kind = 'confirmation'").run()
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(conf)\",\"contentKey\":\"\(key)\"}") { XCTAssertEqual($0.status, .conflict) }
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(conf)\",\"contentKey\":\"\(key)\",\"confirmUncertain\":true}") { XCTAssertEqual($0.status.code, 422, "confirmation needs the fence") }
            // a stale confirmation (the row changed since the human looked) is refused, the current fence is accepted
            var fence = 0
            try await w.user.get("tenants/\(w.tenant)/forms/\(w.form)/mail-deliveries") { res async throws in
                fence = (((obj(res)["items"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == conf }?["fence"] as? Int) ?? -1
            }
            XCTAssertGreaterThanOrEqual(fence, 0)
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(conf)\",\"contentKey\":\"\(key)\",\"confirmUncertain\":true,\"expectedFence\":\(fence + 1)}") { XCTAssertEqual($0.status, .conflict) }
            let none = smtp.mails.count
            XCTAssertEqual(none, 1)
            try await w.user.send(.POST, url, body: "{\"deliveryId\":\"\(conf)\",\"contentKey\":\"\(key)\",\"confirmUncertain\":true,\"expectedFence\":\(fence)}") { XCTAssertEqual($0.status, .accepted) }
            try await until { smtp.mails.count == 2 }
            XCTAssertEqual(smtp.mails.last?.rcpts, ["erika@example.net"])
            // every resend is audited, the key is nowhere in the database
            let audited = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'mail.resend'").first(decoding: C.self)?.c
            XCTAssertEqual(audited, 2)
        }
    }

    func testLeaseExpiryMarksUncertainAndOnlyOneReplicaRuns() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            let smtp = FakeSMTPServer(); try await smtp.start()
            defer { Task { await smtp.stop() } }
            try await connect(w, smtp)
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok) }
            try await until { try await deliveries(f).allSatisfy { $0.state == "smtp-accepted" } }
            // a delivery that was handed over and then lost (process died): leased with an expired lease
            try await f.sql.raw("UPDATE mail_deliveries SET state = 'leased', lease_token = UNHEX(REPEAT('ab',16)), lease_until = '2020-01-01 00:00:00.000000' WHERE mail_kind = 'organisation'").run()
            let n = try await MailMaintenanceScheduler.runOnce(db: f.app.db(.mysql), now: Date())
            XCTAssertEqual(n, 1)
            var rows = try await deliveries(f)
            XCTAssertEqual(rows.first { $0.mail_kind == "organisation" }?.state, "uncertain"); XCTAssertEqual(rows.first { $0.mail_kind == "organisation" }?.last_error_code, "lease_expired")
            XCTAssertEqual(rows.first { $0.mail_kind == "confirmation" }?.state, "smtp-accepted", "settled rows are untouched")
            // a replica that finds the lock taken skips the round
            struct L: Decodable { let l: Int? }
            try await f.sql.withSession { other in
                _ = try await other.raw("SELECT GET_LOCK(\(literal: MailMaintenanceScheduler.lockName), 0) AS l").first(decoding: L.self)
                let skipped = try await MailMaintenanceScheduler.runOnce(db: f.app.db(.mysql), now: Date()); XCTAssertNil(skipped)
                _ = try await other.raw("SELECT RELEASE_LOCK(\(literal: MailMaintenanceScheduler.lockName))").run()
            }
            rows = try await deliveries(f); XCTAssertEqual(rows.count, 2)
        }
    }

    func testSMTPAuthenticationAndPasswordStorage() async throws {
        var o = FakeSMTPServer.Options(); o.authMechanisms = ["PLAIN"]; o.user = "mailer"; o.password = "p4ss-w0rd"
        let smtp = FakeSMTPServer(o); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            let cid = try await connect(w, smtp, user: "mailer", password: "p4ss-w0rd")
            // the password is stored encrypted and never returned
            struct Ref: Decodable { let credential_ref: String? }
            let ref = try await f.sql.raw("SELECT credential_ref FROM connections").first(decoding: Ref.self)?.credential_ref
            XCTAssertTrue(ref?.hasPrefix("s1:") ?? false)
            let leak = try await f.sql.raw("SELECT COUNT(*) AS c FROM connections WHERE safe_config_json LIKE '%p4ss%' OR credential_ref LIKE '%p4ss%'").first(decoding: C.self)?.c
            XCTAssertEqual(leak, 0)
            try await w.sys.get("connections") { res async throws in
                XCTAssertEqual(res.status, .ok); XCTAssertFalse(text(res).contains("p4ss")); XCTAssertTrue(text(res).contains("\"hasCredential\":true"))
            }
            // test connection: ok with the right password
            try await w.sys.send(.POST, "connections/\(cid)/test") { res async throws in XCTAssertEqual(obj(res)["ok"] as? Bool, true, text(res)) }
            XCTAssertTrue(smtp.mails.isEmpty, "a connection test sends no mail")
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok) }
            try await until { smtp.mails.count == 2 }
            // wrong password after the fact: delivery fails permanently and visibly
            try await f.sql.raw("UPDATE managed_secrets SET ciphertext = UNHEX(REPEAT('00', 60)) WHERE ref = \(bind: ref ?? "")").run()
            try await w.sys.send(.POST, "connections/\(cid)/test") { res async throws in XCTAssertEqual(obj(res)["ok"] as? Bool, false); XCTAssertEqual(obj(res)["code"] as? String, "connection_invalid") }
            try await f.sql.raw("DELETE FROM mail_deliveries").run()
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok) }
            try await until { try await deliveries(f).allSatisfy { $0.state != "leased" } }
            let rows = try await deliveries(f)
            XCTAssertEqual(Set(rows.map(\.state)), ["waiting-manual"]); XCTAssertEqual(Set(rows.compactMap(\.last_error_code)), ["credential_missing"])
        }
    }

    func testConnectionAdministrationRightsAndValidation() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            let ok: [String: Any] = ["host": "127.0.0.1", "port": smtp.port, "security": "plain"]
            func body(_ extra: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: ["kind": "smtp", "name": "n", "config": ok].merging(extra) { $1 }), as: UTF8.self) }
            // only system administrators manage connections: others do not even learn the resource exists
            try await w.user.send(.POST, "connections", body: body([:])) { XCTAssertEqual($0.status, .notFound) }
            try await w.user.get("connections") { XCTAssertEqual($0.status, .notFound) }
            try await w.sys.send(.POST, "connections", body: body([:]), csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            // validation
            for bad in [["kind": "s3"], ["name": ""], ["config": ["host": "h", "port": 0, "security": "plain"]], ["config": ["host": "h h", "port": 25, "security": "tls"]], ["config": ["host": "h.example", "port": 25, "security": "tls", "extra": 1]],
                        ["credential": ""], ["config": ["host": "h.example", "port": 25, "security": "tls"], "credential": "pw-without-user"], ["unknown": 1]] as [[String: Any]] {
                try await w.sys.send(.POST, "connections", body: body(bad)) { XCTAssertTrue([400, 422].contains($0.status.code), "\(bad) -> \($0.status)") }
            }
            let none = try await f.sql.raw("SELECT COUNT(*) AS c FROM connections").first(decoding: C.self)?.c; XCTAssertEqual(none, 0)
            // assignment and form selection need an assigned connection
            var id = ""
            try await w.sys.send(.POST, "connections", body: body([:])) { id = obj($0)["id"] as? String ?? "" }
            try await w.user.send(.PUT, "tenants/\(w.tenant)/forms/\(w.form)/mail-connection", body: "{\"connectionId\":\"\(id)\"}") { XCTAssertEqual($0.status.code, 422, "not assigned to this customer") }
            try await w.user.send(.PUT, "tenants/\(w.tenant)/connections/\(id)") { XCTAssertEqual($0.status, .notFound, "a customer admin cannot assign connections") }
            try await w.sys.send(.PUT, "tenants/\(w.tenant)/connections/\(id)") { XCTAssertEqual($0.status, .noContent) }
            try await w.user.send(.PUT, "tenants/\(w.tenant)/forms/\(w.form)/mail-connection", body: "{\"connectionId\":\"\(id)\"}") { XCTAssertEqual($0.status, .noContent) }
            try await w.user.send(.PUT, "tenants/\(w.tenant)/forms/\(w.form)/mail-connection", body: "{\"connectionId\":\"\(UUID().uuidString.lowercased())\"}") { XCTAssertEqual($0.status.code, 422) }
            // another customer's form cannot use it
            let other = try await f.customer(); let otherForm = try await f.form(customer: other)
            let stranger = try await f.account(); try await f.grant(stranger, "release.publish", customer: other, by: w.root)
            try await (try await f.login(stranger)).send(.PUT, "tenants/\(other)/forms/\(otherForm)/mail-connection", body: "{\"connectionId\":\"\(id)\"}") { XCTAssertEqual($0.status.code, 422) }
            // deliveries are only visible with form.read
            let nobody = try await f.account()
            try await (try await f.login(nobody)).get("tenants/\(w.tenant)/forms/\(w.form)/mail-deliveries") { XCTAssertEqual($0.status, .notFound) }
            // stale login is refused for connection changes
            try await f.sql.raw("UPDATE sessions SET authenticated_at = '2020-01-01 00:00:00.000000' WHERE state = 'authenticated'").run()
            try await w.sys.send(.POST, "connections", body: body([:])) { XCTAssertEqual(obj($0)["code"] as? String, "reauthentication_required") }
        }
    }

    func testMailConfigurationIsValidatedWhenTheDraftIsSaved() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, mail: nil)
            var draft = "", doc = FormCore.JSONValue.null
            try await w.user.get("tenants/\(w.tenant)/forms/\(w.form)") { draft = (obj($0)["draftIds"] as? [String])?.first ?? "" }
            try await w.user.send(.POST, "tenants/\(w.tenant)/forms/\(w.form)/drafts") { res async throws in draft = parse(res)["id"]?.string ?? draft; doc = parse(res)["document"] ?? .null; XCTAssertEqual(res.status, .created) }
            var rev = 1
            func patch(_ mail: FormCore.JSONValue, _ expect: HTTPResponseStatus) async throws {
                try await w.user.send(.PATCH, "tenants/\(w.tenant)/forms/\(w.form)/drafts/\(draft)", body: String(decoding: JCS.canonicalize(withMail(doc, mail)), as: UTF8.self), headers: ["If-Match": "\"\(rev)\""]) { res async throws in
                    XCTAssertEqual(res.status, expect, text(res)); if expect == .ok { rev += 1 } else { XCTAssertEqual(parse(res)["code"]?.string, "validation_failed") }
                }
            }
            func s(_ v: String) -> FormCore.JSONValue { .string(v) }
            let from: FormCore.JSONValue = .object(["address": s("info@example.org")])
            let org: FormCore.JSONValue = .object(["to": .array([s("a@example.org")]), "subject": s("S"), "body": s("B")])
            try await patch(.object(["from": from, "organisation": org]), .ok)
            for bad: FormCore.JSONValue in [
                .object(["from": from]),                                                                                                   // nothing to send
                .object(["organisation": org]),                                                                                            // no sender
                .object(["from": .object(["address": s("Name <x@example.org>")]), "organisation": org]),                                   // display name smuggling
                .object(["from": from, "organisation": .object(["to": .array([s("a@example.org\r\nBcc: b@example.org")]), "subject": s("S"), "body": s("B")])]),
                .object(["from": from, "organisation": .object(["to": .array([]), "subject": s("S"), "body": s("B")])]),                    // no recipients
                .object(["from": from, "organisation": .object(["to": .array((0..<21).map { s("u\($0)@example.org") }), "subject": s("S"), "body": s("B")])]),
                .object(["from": from, "organisation": .object(["to": .array([s("a@example.org")]), "subject": s("S\nX"), "body": s("B")])]),   // line break in the subject
                .object(["from": from, "organisation": .object(["to": .array([s("a@example.org")]), "subject": s("S"), "body": s("B"), "format": s("pdf")])]),
                .object(["from": from, "organisation": .object(["to": .array([s("a@example.org")]), "subject": s("S"), "body": s("B"), "replyToField": s("nope")])]),
                .object(["from": from, "confirmation": .object(["toField": s("nope"), "subject": s("S"), "body": s("B")])]),                // unknown field
                .object(["from": from, "organisation": org, "extra": s("x")]),
            ] { try await patch(bad, .unprocessableEntity) }
            let revNow = try await f.sql.raw("SELECT revision AS c FROM form_drafts").first(decoding: C.self)?.c
            XCTAssertEqual(revNow, rev, "rejected configurations change nothing")
        }
    }
}
