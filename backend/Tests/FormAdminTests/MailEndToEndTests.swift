// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormAuth
import FormCore
import FormIngest
@testable import FormCrypto
@testable import FormMail
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
                                 "subject": .string("Neue Anfrage von #=[name]=#"), "body": .string("<p>#=[nachricht]=#</p><p>#=[liste]=#</p>"), "format": .string("html"), "content": .string("full")]),
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

    // 30 s: delivery is asynchronous (outbox worker + SMTP); 8 s was too tight on a loaded machine (seen with load averages above 10, also before the SMTP change).
    private func until(_ timeout: TimeInterval = 30, _ cond: () async throws -> Bool) async throws {
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

    private func mailWithout(content: String?, template: Bool = true) -> FormCore.JSONValue {
        guard case .object(var mail) = defaultMail, case .object(var org)? = mail["organisation"] else { return .null }
        org["content"] = content.map { .string($0) }
        if !template { org["subject"] = nil; org["body"] = nil; org["format"] = nil }
        mail["organisation"] = .object(org); mail["confirmation"] = nil
        return .object(mail)
    }

    /// ADR 0041 (13.11.): the standard (no `content`, i.e. every form and release that existed before) is the FULL mail, as the legacy backend sent it:
    /// the practice team has no access to the backend, everything must be in the mail.
    func testStandardMailWithTemplateCarriesAllValues() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: mailWithout(content: nil))   // as stored before ADR 0041: no content key
            try await connect(w, smtp)
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok, text($0)) }
            try await until { smtp.mails.count == 1 }
            let o = decoded(try XCTUnwrap(smtp.mails.first).data)
            XCTAssertEqual(subject(o.headers["subject"] ?? ""), "Neue Anfrage von Erika <Muster>")
            XCTAssertEqual(o.body, "<p>Grüße &amp; &lt;b&gt;Hallo&lt;/b&gt; MAIL-MARKER-4711</p><p>a</p>")
            XCTAssertEqual(o.headers["reply-to"], "erika@example.net")
        }
    }

    /// A new form without any mail template must not fail and must still send every field (label: value).
    func testStandardMailWithoutTemplateListsAllFields() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: mailWithout(content: nil, template: false))
            try await connect(w, smtp)
            var id = ""
            try await submit(w, pairs) { res async throws in XCTAssertEqual(res.status, .ok, text(res)); id = ((obj(res)["submission"] as? [String: Any])?["id"] as? String) ?? "" }
            try await until { smtp.mails.count == 1 }
            let o = decoded(try XCTUnwrap(smtp.mails.first).data)
            XCTAssertEqual(o.headers["content-type"], "text/plain; charset=utf-8")
            XCTAssertEqual(subject(o.headers["subject"] ?? ""), "Neue Einsendung: Kontakt")
            for line in ["name: Erika <Muster>", "email: erika@example.net", "liste: a"] { XCTAssertTrue(o.body.contains(line), "\(line)\n\(o.body)") }
            XCTAssertTrue(o.body.contains("Kennung: \(id)"), o.body)
            XCTAssertEqual(o.headers["reply-to"], "erika@example.net")
        }
    }

    /// Explicit choice: a notification carries no submitted value; a resend renders the same mode.
    func testExplicitNotificationSendsOnlyTheLink() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: mailWithout(content: "notification"))
            try await connect(w, smtp)
            var id = ""
            try await submit(w, pairs) { res async throws in XCTAssertEqual(res.status, .ok, text(res)); id = ((obj(res)["submission"] as? [String: Any])?["id"] as? String) ?? "" }
            try await until { smtp.mails.count == 1 }
            let o = decoded(try XCTUnwrap(smtp.mails.first).data)
            let wire = try XCTUnwrap(smtp.mails.first).data + (o.headers["subject"] ?? "") + o.body
            for secret in ["MAIL-MARKER", "Erika", "Muster", "erika@example.net", "Grüße"] { XCTAssertFalse(wire.contains(secret), secret) }
            XCTAssertNil(o.headers["reply-to"], "the submitted address is a submitted value too")
            XCTAssertEqual(o.headers["content-type"], "text/plain; charset=utf-8")
            XCTAssertEqual(subject(o.headers["subject"] ?? ""), "Neue Einsendung: Kontakt", "the localized form title, not the fallback")
            XCTAssertTrue(o.body.contains("Kennung: \(id)"), o.body)
            XCTAssertTrue(o.body.contains("\(AdminFixture.origin)/t/\(w.tenant.uuidString.lowercased())/f/\(w.form)/entries"), o.body)
            XCTAssertTrue(o.body.contains("Formular: Kontakt"), o.body)
        }
    }

    /// Review 0041: the manual resend of a notification carries no submitted value either, and its time is the receipt of the submission.
    func testManualResendOfANotificationCarriesNoValueAndTheReceiptTime() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: mailWithout(content: "notification"))
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok) }   // no connection yet: waits for a human
            try await f.sql.raw("UPDATE submissions SET received_at = '2027-01-15 08:00:00.000000'").run()
            try await connect(w, smtp)
            var entry = "", org = ""
            try await w.user.get("tenants/\(w.tenant)/forms/\(w.form)/mail-deliveries") { res async throws in
                let d = try XCTUnwrap(((obj(res)["items"] as? [[String: Any]]) ?? []).first)
                entry = d["submissionId"] as? String ?? ""; org = d["id"] as? String ?? ""
            }
            struct Obj: Decodable { let ciphertext: Blob }
            let objRow = try await f.sql.raw("SELECT ciphertext FROM stored_objects").first(decoding: Obj.self)
            let pkg = try PackageV2(String(decoding: try XCTUnwrap(objRow).ciphertext.data, as: UTF8.self))
            let cek = try HPKE.open(pkg.b, enc: pkg.a, recipient: w.customerKey, info: Data("kubus-anfrage v2".utf8), aad: Data(pkg.kid.utf8))
            for r in ["content.resend", "content.decrypt"] { try await f.grant(w.userID, r, customer: w.tenant, by: w.root) }
            try await w.user.send(.POST, "tenants/\(w.tenant)/forms/\(w.form)/entries/\(entry)/resends", body: "{\"deliveryId\":\"\(org)\",\"contentKey\":\"\(cek.base64URLString)\"}") { res async throws in
                XCTAssertEqual(res.status, .accepted, text(res))
            }
            try await until { smtp.mails.count == 1 }
            let o = decoded(try XCTUnwrap(smtp.mails.first).data)
            let wire = try XCTUnwrap(smtp.mails.first).data + (o.headers["subject"] ?? "") + o.body
            for secret in ["MAIL-MARKER", "Erika", "Muster", "erika@example.net", "Grüße"] { XCTAssertFalse(wire.contains(secret), secret) }
            XCTAssertNil(o.headers["reply-to"])
            XCTAssertEqual(subject(o.headers["subject"] ?? ""), "Neue Einsendung: Kontakt")
            XCTAssertTrue(o.body.contains("Zeitpunkt: 15.01.2027 09:00 Uhr"), "receipt in Europe/Berlin, not the resend time: \(o.body)")
            XCTAssertTrue(o.body.contains("Kennung: \(entry)"), o.body)
            XCTAssertTrue(o.body.contains("\(AdminFixture.origin)/t/\(w.tenant.uuidString.lowercased())/f/\(w.form)/entries"), o.body)
        }
    }

    /// Decision 13.11.: no extra audit entry or warning for either mode (the choice itself in the Mail tab is enough).
    func testNoExtraAuditEntryForAnyContentMode() async throws {
        try await AdminFixture.with { f in
            _ = try await world(f, mail: defaultMail)
            _ = try await world(f, mail: mailWithout(content: nil))
            _ = try await world(f, mail: mailWithout(content: "notification"))
            let extra = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'release.mail-fulltext'").first(decoding: C.self)?.c
            XCTAssertEqual(extra, 0)
            let publishes = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'release.publish'").first(decoding: C.self)?.c
            XCTAssertEqual(publishes, 3)
        }
    }

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
    /// Regression (Flake, belegt): `DB.time` has millisecond resolution; two lease renewals within the same millisecond write identical values,
    /// MariaDB then reports 0 changed rows. That used to count as "lease lost" and the delivery was dropped silently (row stuck `leased`).
    /// A frozen clock makes the collision deterministic.
    func testLeaseRenewalWithIdenticalTimestampStillCountsAsOwned() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok) }   // no connection: rows end `waiting-manual`, nothing is sent
            struct Id: Decodable { let id: Blob }
            let idRow = try await f.sql.raw("SELECT id FROM mail_deliveries LIMIT 1").first(decoding: Id.self)
            let rowID = try XCTUnwrap(idRow).id
            let token = UUID()
            try await f.sql.raw("UPDATE mail_deliveries SET state='leased', lease_token=\(bind: DB.bin(token)), lease_until='2030-01-01 00:00:00.000000' WHERE id=\(bind: rowID)").run()
            let frozen = Date(timeIntervalSince1970: 1_800_000_000)
            let dispatcher = MailDispatcher(db: f.app.db(.mysql), secrets: NoSecrets(), allowedNets: [], allowInsecure: true, logger: f.app.logger, now: { frozen })
            let message = try MailMessage(fromAddress: "info@example.org", to: ["a@example.org"], subject: "s", body: "b", isHTML: false, date: frozen)
            let mine = PreparedMail(deliveryID: try XCTUnwrap(DB.uuid(rowID.data)), leaseToken: token, message: message, connection: nil)
            let first = await dispatcher.renewLease(mine), second = await dispatcher.renewLease(mine), third = await dispatcher.renewLease(mine)
            XCTAssertTrue(first); XCTAssertTrue(second, "identical timestamps must not look like a lost lease"); XCTAssertTrue(third)
            let foreign = PreparedMail(deliveryID: mine.deliveryID, leaseToken: UUID(), message: message, connection: nil)
            let lost = await dispatcher.renewLease(foreign)
            XCTAssertFalse(lost, "a foreign token must still be refused")
        }
    }
    private struct NoSecrets: MailSecretProvider { func secret(ref: String) async throws -> String? { nil } }
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

    /// Self-signed certificates (decision 0044): a per-connection choice, allowed in production, audited without host or secrets.
    func testTLSVerificationOffIsAnExplicitAuditedPerConnectionChoice() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, mail: defaultMail)
            func create(_ extra: [String: Any]) -> String {
                let cfg: [String: Any] = ["host": "mail.example.org", "port": 587, "security": "starttls", "username": "u"].merging(extra) { $1 }
                return String(decoding: try! JSONSerialization.data(withJSONObject: ["kind": "smtp", "name": "n", "config": cfg, "credential": "synthetic-pw-Q7"].merging([:]) { $1 }), as: UTF8.self)
            }
            func auditCount(_ code: String, _ id: String) async throws -> Int {
                try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = \(bind: code) AND subject_id = UNHEX(REPLACE(\(bind: id), '-', ''))").first(decoding: C.self)?.c ?? -1
            }
            // without the option: verification stays on, no tls audit
            var plainID = ""
            try await w.sys.send(.POST, "connections", body: create([:])) { XCTAssertEqual($0.status, .created, text($0)); plainID = obj($0)["id"] as? String ?? "" }
            let n1 = try await auditCount("connection.tls-verification-off", plainID); XCTAssertEqual(n1, 0)
            // not a boolean: refused
            try await w.sys.send(.POST, "connections", body: create(["verifyCertificate": "no"])) { XCTAssertEqual($0.status.code, 422) }
            // a customer administrator cannot
            try await w.user.send(.POST, "connections", body: create(["verifyCertificate": false])) { XCTAssertEqual($0.status, .notFound) }
            // explicit option: created, audited with connection id, no host/secret in the audit details
            var offID = ""
            try await w.sys.send(.POST, "connections", body: create(["verifyCertificate": false])) { XCTAssertEqual($0.status, .created, text($0)); offID = obj($0)["id"] as? String ?? "" }
            let n2 = try await auditCount("connection.tls-verification-off", offID); XCTAssertEqual(n2, 1)
            struct D: Decodable { let safe_details_json: String }
            let details = try await f.sql.raw("SELECT safe_details_json FROM audit_events WHERE action_code = 'connection.tls-verification-off'").first(decoding: D.self)?.safe_details_json ?? ""
            XCTAssertFalse(details.contains("mail.example.org") || details.contains("synthetic-pw"), details)
            try await w.sys.get("connections") { res async throws in
                let items = obj(res)["items"] as? [[String: Any]] ?? []
                let off = items.first { $0["id"] as? String == offID }
                XCTAssertEqual((off?["config"] as? [String: Any])?["verifyCertificate"] as? Bool, false)
            }
            // switching back to verification: audited as well, needs system.manage and a fresh login
            try await w.user.send(.PUT, "connections/\(offID)/tls-verification", body: #"{"verifyCertificate":true}"#) { XCTAssertEqual($0.status, .notFound) }
            try await w.sys.send(.PUT, "connections/\(offID)/tls-verification", body: #"{"verifyCertificate":"x"}"#) { XCTAssertEqual($0.status.code, 422) }
            try await w.sys.send(.PUT, "connections/\(offID)/tls-verification", body: #"{"verifyCertificate":true}"#) { XCTAssertEqual($0.status, .noContent, text($0)) }
            let n3 = try await auditCount("connection.tls-verification-on", offID); XCTAssertEqual(n3, 1)
            try await w.sys.send(.PUT, "connections/\(offID)/tls-verification", body: #"{"verifyCertificate":false}"#) { XCTAssertEqual($0.status, .noContent) }
            let n4 = try await auditCount("connection.tls-verification-off", offID); XCTAssertEqual(n4, 2)
            try await w.sys.send(.PUT, "connections/\(UUID().uuidString.lowercased())/tls-verification", body: #"{"verifyCertificate":false}"#) { XCTAssertEqual($0.status, .notFound) }
            // only SMTP connections carry the option
            var proxyID = ""
            try await w.sys.send(.POST, "connections", body: #"{"kind":"mail-proxy","name":"p","config":{"url":"https://proxy.example.org/send"},"credential":"acode"}"#) { proxyID = obj($0)["id"] as? String ?? "" }
            try await w.sys.send(.PUT, "connections/\(proxyID)/tls-verification", body: #"{"verifyCertificate":false}"#) { XCTAssertEqual($0.status.code, 422) }
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
            // Review 0041: in notification mode a hidden, partial template or a stale reply-to field never blocks saving.
            for hidden: FormCore.JSONValue in [
                .object(["to": .array([s("a@example.org")]), "format": s("html")]),
                .object(["to": .array([s("a@example.org")]), "subject": s(""), "body": s("B"), "format": s("text"), "content": s("notification")]),
                .object(["to": .array([s("a@example.org")]), "replyToField": s("nope"), "content": s("notification")]),
                .object(["to": .array([s("a@example.org")]), "subject": s(""), "body": s("B"), "content": s("full")]),   // template optional: default list
                .object(["to": .array([s("a@example.org")])]),                                                          // new form, no template at all
            ] { try await patch(.object(["from": from, "organisation": hidden]), .ok) }
            for bad: FormCore.JSONValue in [
                .object(["from": from]),                                                                                                   // nothing to send
                .object(["organisation": org]),                                                                                            // no sender
                .object(["from": .object(["address": s("Name <x@example.org>")]), "organisation": org]),                                   // display name smuggling
                .object(["from": from, "organisation": .object(["to": .array([s("a@example.org\r\nBcc: b@example.org")]), "subject": s("S"), "body": s("B")])]),
                .object(["from": from, "organisation": .object(["to": .array([]), "subject": s("S"), "body": s("B")])]),                    // no recipients
                .object(["from": from, "organisation": .object(["to": .array((0..<21).map { s("u\($0)@example.org") }), "subject": s("S"), "body": s("B")])]),
                .object(["from": from, "organisation": .object(["to": .array([s("a@example.org")]), "subject": s("S\nX"), "body": s("B")])]),   // line break in the subject
                .object(["from": from, "organisation": .object(["to": .array([s("a@example.org")]), "subject": s("S"), "body": s("B"), "format": s("pdf")])]),
                .object(["from": from, "organisation": .object(["to": .array([s("a@example.org")]), "subject": s("S"), "body": s("B"), "replyToField": s("nope"), "content": s("full")])]),
                .object(["from": from, "confirmation": .object(["toField": s("nope"), "subject": s("S"), "body": s("B")])]),                // unknown field
                .object(["from": from, "organisation": org, "extra": s("x")]),
            ] { try await patch(bad, .unprocessableEntity) }
            let draftID = try XCTUnwrap(UUID(uuidString: draft))   // the fixture may hold a second draft: read exactly this one
            let revNow = try await f.sql.raw("SELECT revision AS c FROM form_drafts WHERE id=\(bind: DB.bin(draftID))").first(decoding: C.self)?.c
            XCTAssertEqual(revNow, rev, "rejected configurations change nothing")
        }
    }

    /// Operator path, finding C (13.11.2026): a mail connection taken over by the Umstieg is disabled and was not usable at all (no way to
    /// enable it, legacy config format). `PUT /connections/{id}/enabled` activates it after a check: system.manage + fresh login, audited,
    /// a legacy-format row (written by an earlier importer) is converted once to the native schema; afterwards it is assigned and delivers.
    func testImportedLegacyConnectionIsActivatedConvertedAndDelivers() async throws {
        var options = FakeSMTPServer.Options(); options.authMechanisms = ["PLAIN", "LOGIN"]; options.user = "legacy-user"; options.password = "Alt Passwort ä!7"
        let smtp = FakeSMTPServer(options); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, mail: mailWithout(content: nil))
            let store = SecretStore(db: f.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 7, count: 32)))
            // exactly what the importer before 13.11.2026 wrote: legacy keys in the safe config, a JSON credential, enabled=0
            let legacyRef = try await store.put(Data(#"{"password":"Alt Passwort ä!7","username":"legacy-user"}"#.utf8))
            let id = UUID(), cid = id.uuidString.lowercased()
            let legacy = #"{"SMTPHost":"127.0.0.1","SMTPPort":"\#(smtp.port)","SMTPSecurity":"none","SMTPallowSelfSigned":"0","fromMail":"alt@example.org","verifyCertificate":true}"#
            try await f.sql.raw("INSERT INTO connections (id, kind, name, safe_config_json, credential_ref, enabled) VALUES (\(bind: DB.bin(id)), 'smtp', 'Alt-SMTP', \(bind: legacy), \(bind: legacyRef), 0)").run()
            // disabled: cannot be given to the customer
            try await w.sys.send(.PUT, "tenants/\(w.tenant)/connections/\(cid)") { XCTAssertEqual($0.status, .notFound) }
            // only a system administrator may activate; the value must be a boolean
            try await w.user.send(.PUT, "connections/\(cid)/enabled", body: #"{"enabled":true}"#) { XCTAssertEqual($0.status, .notFound) }
            try await w.sys.send(.PUT, "connections/\(cid)/enabled", body: #"{"enabled":"yes"}"#) { XCTAssertEqual($0.status.code, 422) }
            try await w.sys.send(.PUT, "connections/\(cid)/enabled", body: #"{"enabled":true}"#) { XCTAssertEqual($0.status, .noContent, text($0)) }
            struct Conn: Decodable { let safe_config_json: String; let credential_ref: String?; let enabled: Int }
            let fetched = try await f.sql.raw("SELECT safe_config_json, credential_ref, enabled FROM connections WHERE id=\(bind: DB.bin(id))").first(decoding: Conn.self)
            let row = try XCTUnwrap(fetched)
            XCTAssertEqual(row.enabled, 1)
            let cfg = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(row.safe_config_json.utf8)) as? [String: Any])
            XCTAssertEqual(cfg["host"] as? String, "127.0.0.1"); XCTAssertEqual(cfg["port"] as? Int, smtp.port)
            XCTAssertEqual(cfg["security"] as? String, "plain"); XCTAssertEqual(cfg["username"] as? String, "legacy-user")
            XCTAssertNil(cfg["SMTPHost"], "converted once to the native schema")
            let secret = try await store.get(try XCTUnwrap(row.credential_ref)).map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(secret, "Alt Passwort ä!7", "the native credential is the password")
            let oldGone = try await store.get(legacyRef)
            XCTAssertNil(oldGone, "the legacy JSON credential is removed")
            let audits = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code='connection.enable' AND subject_id=\(bind: DB.bin(id)) AND safe_details_json NOT LIKE '%Passwort%' AND safe_details_json NOT LIKE '%127.0.0.1%'").first(decoding: C.self)?.c
            XCTAssertEqual(audits, 1)
            // now usable like any connection: customer, form, a signed submission, the full mail arrives (authenticated)
            try await w.sys.send(.PUT, "tenants/\(w.tenant)/connections/\(cid)") { XCTAssertEqual($0.status, .noContent) }
            try await w.user.send(.PUT, "tenants/\(w.tenant)/forms/\(w.form)/mail-connection", body: "{\"connectionId\":\"\(cid)\"}") { XCTAssertEqual($0.status, .noContent, text($0)) }
            try await submit(w, pairs) { XCTAssertEqual($0.status, .ok, text($0)) }
            try await until { smtp.mails.count == 1 }
            XCTAssertTrue(decoded(try XCTUnwrap(smtp.mails.first).data).body.contains("MAIL-MARKER-4711"))
            // a legacy proxy whose URL carries credentials cannot be activated (it would show them in clear): named reason, stays disabled
            let proxyRef = try await store.put(Data(#"{"auth":"A","url":"https://u:p@proxy.example.org/send"}"#.utf8))
            let pid = UUID()
            try await f.sql.raw("INSERT INTO connections (id, kind, name, safe_config_json, credential_ref, enabled) VALUES (\(bind: DB.bin(pid)), 'mail-proxy', 'Alt-Proxy', '{\"fromMail\":\"a@b.c\",\"legacyURLProtected\":\"true\"}', \(bind: proxyRef), 0)").run()
            try await w.sys.send(.PUT, "connections/\(pid.uuidString.lowercased())/enabled", body: #"{"enabled":true}"#) { res async throws in
                XCTAssertEqual(res.status.code, 422); XCTAssertFalse(text(res).contains("u:p"), text(res))
            }
            let still = try await f.sql.raw("SELECT enabled AS c FROM connections WHERE id=\(bind: DB.bin(pid))").first(decoding: C.self)?.c
            XCTAssertEqual(still, 0)
            // switching off again is audited as well
            try await w.sys.send(.PUT, "connections/\(cid)/enabled", body: #"{"enabled":false}"#) { XCTAssertEqual($0.status, .noContent) }
            let off = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code='connection.disable'").first(decoding: C.self)?.c
            XCTAssertEqual(off, 1)
        }
    }
    /// Card 14298EC0 (ADR 0041, standard "full"): a submission with an attachment of 19.9 MB (sealed package about 27 MB, above the driver packet limit).
    /// Mails carry the field values and NO attachment (ADR 0041, "Anhänge existieren in Mails noch nicht"; the proxy transport sends empty attachment fields).
    /// What must hold: the upload is accepted and stored completely, the organisation and confirmation mails are delivered with all values, they stay small
    /// (the attachment bytes must not leak into or inflate a mail), and delivery states are clean. Needs P3B_DB_ARGS=--max-allowed-packet=67108864.
    func testFullMailForSubmissionWithAttachmentAbove16MiBIsDeliveredWithoutTheAttachment() async throws {
        let smtp = FakeSMTPServer(); try await smtp.start()
        defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            struct V: Decodable { let v: String }
            let limit = Int(try await f.sql.raw("SELECT CAST(@@global.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
            try XCTSkipIf(limit < 60_000_000, "needs max_allowed_packet >= 64 MiB (got \(limit))")
            let w = try await world(f, mail: defaultMail)
            try await connect(w, smtp)
            var content = Data("%PDF-1.4\n".utf8) + Data(count: 19_900_000 - 9)
            for i in stride(from: 9, to: content.count, by: 4093) { content[i] = UInt8(truncatingIfNeeded: i / 4093) }
            let signed = FileField.single(SignedFile(name: "antrag.pdf", type: "application/pdf", error: 0, size: Int64(content.count), content: content))
            let fields = PHPValue.array(pairs.map { ($0.0, PHPValue.string($0.1)) })
            let canonical = try RequestSignature.canonical(fields: fields, files: [("antrag", signed)])
            let ts = String(Int64(Date().timeIntervalSince1970))
            let sig = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: w.form, timestamp: ts, canonical: canonical), seed: w.seed)
            var h = HTTPHeaders(); h.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=XBOUNDX")
            h.add(name: "X-Kubus-Timestamp", value: ts); h.add(name: "X-Kubus-Signature", value: sig.base64EncodedString()); h.add(name: "Idempotency-Key", value: "mail-big")
            var body = Data()
            for (k, v) in pairs { body += Data("--XBOUNDX\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
            body += Data("--XBOUNDX\r\nContent-Disposition: form-data; name=\"antrag\"; filename=\"antrag.pdf\"\r\nContent-Type: application/pdf\r\n\r\n".utf8) + content + Data("\r\n--XBOUNDX--\r\n".utf8)
            try await w.f.app.test(.POST, "api/v2/submit/?f=\(w.form)", headers: h, body: ByteBuffer(data: body)) { XCTAssertEqual($0.status, .ok, String(text($0).prefix(300))) }
            try await until(60) { smtp.mails.count == 2 }
            let org = try XCTUnwrap(smtp.mails.first { $0.rcpts.contains("empfang@example.org") })
            let o = decoded(org.data)
            XCTAssertEqual(o.body, "<p>Grüße &amp; &lt;b&gt;Hallo&lt;/b&gt; MAIL-MARKER-4711</p><p>a</p>", "all values are in the mail")
            for mail in smtp.mails {
                XCTAssertLessThan(mail.data.utf8.count, 100_000, "the 19.9 MB attachment must not be part of a mail")
                XCTAssertFalse(mail.data.contains("antrag.pdf")); XCTAssertFalse(mail.data.lowercased().contains("multipart/"))
            }
            try await until { try await deliveries(f).allSatisfy { $0.state == "smtp-accepted" } }
            let rows = try await deliveries(f)
            XCTAssertEqual(rows.map(\.mail_kind), ["confirmation", "organisation"]); XCTAssertTrue(rows.allSatisfy { $0.attempts == 1 && $0.last_error_code == nil })
            // the attachment itself is stored completely and byte-exact in the database (length and hash over the whole cell)
            struct Cell: Decodable { let n: Int; let h: Blob; let sha: Blob }
            let cell = try await f.sql.raw("SELECT CAST(OCTET_LENGTH(ciphertext) AS SIGNED) AS n, UNHEX(SHA2(ciphertext, 256)) AS h, ciphertext_sha256 AS sha FROM stored_objects WHERE object_role = 'attachment'").first(decoding: Cell.self)
            let c = try XCTUnwrap(cell)
            XCTAssertGreaterThan(c.n, 16_777_215); XCTAssertEqual(c.h.data, c.sha.data)
            print("MEASURE mail with 19.9 MB attachment: organisation mail \(org.data.utf8.count) bytes, attachment object \(c.n) bytes")
        }
    }
}
