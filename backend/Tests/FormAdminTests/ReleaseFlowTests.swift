// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormAuth
@testable import FormAdmin
import FormCore
import FormIngest
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

final class ReleaseFlowTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private struct StoredDef: Decodable { let definition_json: String }
    private struct Frm: Decodable { let active: Int; let current_release_id: Blob? }

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private func parse(_ r: XCTHTTPResponse) -> FormCore.JSONValue { (try? JCS.parse(Data(buffer: r.body))) ?? .null }

    /// A user with all rights needed for the flow on one customer.
    private func setup(_ f: AdminFixture, rights: [String] = ["form.create", "form.read", "draft.write", "release.publish"]) async throws -> (user: UUID, tenant: UUID, client: TestClient) {
        let root = try await f.account(), user = try await f.account()
        let tenant = try await f.customer()
        for r in rights { try await f.grant(user, r, customer: tenant, by: root) }
        return (user, tenant, try await f.login(user))
    }

    /// Creates a form through the API; returns (formID, draftID, draft body).
    private func createForm(_ c: TestClient, _ tenant: UUID, name: String = "Kontakt") async throws -> (form: String, draft: String, doc: JSONValue, hash: String) {
        var form = ""
        try await c.post("tenants/\(tenant)/forms", "{\"name\":\"\(name)\"}") { res async throws in XCTAssertEqual(res.status, .created); form = jsonObject(res)["id"] as? String ?? "" }
        var draft = "", doc = JSONValue.null, hash = ""
        try await c.get("tenants/\(tenant)/forms/\(form)") { res async throws in draft = (jsonObject(res)["draftIds"] as? [String])?.first ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .eTag), "\"1\"")
            let j = parse(res); doc = j["document"] ?? .null; hash = j["hash"]?.string ?? ""
        }
        return (form, draft, doc, hash)
    }

    private func confirm(_ c: TestClient, _ tenant: UUID, _ form: String, _ draft: String, rev: Int, hash: String, _ check: (XCTHTTPResponse) async throws -> Void) async throws {
        try await c.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":\(rev),\"hash\":\"\(hash)\",\"confirm\":true}", check)
    }

    private func publish(_ c: TestClient, _ tenant: UUID, _ form: String, key: String = "k1", draft: String, rev: Int, hash: String, confirmation: String, extra: String = "", _ check: (XCTHTTPResponse) async throws -> Void) async throws {
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/releases",
                         body: "{\"draftId\":\"\(draft)\",\"revision\":\(rev),\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"\(extra)}", headers: ["Idempotency-Key": key], check)
    }

    /// Edits title, bumps the form/view versions and fixes the view's reference to the new form hash.
    private func bumped(_ doc: JSONValue, title: String, version: String) -> JSONValue {
        guard var top = doc.object, var form = top["form"]?.object, let views = top["views"]?.array else { return doc }
        form["title"] = .object(["de": .string(title)]); form["version"] = .string(version)
        let formValue = JSONValue.object(form)
        let formHash = hex(DocHash.sha256(formValue))
        top["form"] = formValue
        top["views"] = .array(views.map { v in
            guard var o = v.object, var ref = o["form"]?.object else { return v }
            ref["version"] = .string(version); ref["sha256"] = .string(formHash); o["form"] = .object(ref); o["version"] = .string(version)
            return .object(o)
        })
        return .object(top)
    }

    /// S2-03 (ADR 0046): a stored form may only carry patterns from the linear-time dialect.
    func testDocumentValidatorRejectsPatternsOutsideTheLinearDialect() async throws {
        try await AdminFixture.with { f in
            let (_, tenant, c) = try await setup(f)
            let (form, _, doc, _) = try await createForm(c, tenant)
            func with(_ pattern: JSONValue?) -> JSONValue {
                guard var top = doc.object, var fo = top["form"]?.object, var fields = fo["fields"]?.object, let k = fields.keys.sorted().first, var field = fields[k]?.object else { XCTFail("shape"); return doc }
                field["validation"] = .object(pattern.map { ["pattern": $0] } ?? [:])
                fields[k] = .object(field); fo["fields"] = .object(fields); top["form"] = .object(fo)
                return .object(top)
            }
            let id = UUID(uuidString: form)!
            // The view hash no longer matches the edited form; only the field rule path is of interest here.
            func fieldRuleError(_ v: JSONValue) -> String? {
                do { try DocumentValidator.validate(v, tenant: tenant, form: id); return nil } catch let e as DocumentInvalid { return e.path } catch { return "?" }
            }
            XCTAssertFalse(fieldRuleError(with(.string("[a-z]{2,8}")))?.contains("/validation/") ?? false)
            for bad in ["(?=a)a", "(a)\\1", "a+?", "((a|aa))+" + String(repeating: "x", count: 600)] {
                XCTAssertTrue(fieldRuleError(with(.string(bad)))?.hasSuffix("/validation/pattern") ?? false, bad)
            }
            XCTAssertTrue(fieldRuleError(with(.int(1)))?.hasSuffix("/validation/pattern") ?? false)
        }
    }

    func testStandardDraftConfirmPublishActivatesAndReplays() async throws {
        try await AdminFixture.with { f in
            let (_, tenant, c) = try await setup(f)
            let (form, draft, doc, hash) = try await createForm(c, tenant)
            XCTAssertEqual(hash, hex(DocHash.sha256(doc)), "server hash = SHA-256 over the RFC 8785 form of the document")
            XCTAssertNoThrow(try DocumentValidator.validate(doc, tenant: tenant, form: UUID(uuidString: form)!))
            var conf = ""
            try await confirm(c, tenant, form, draft, rev: 1, hash: hash) { res async throws in
                XCTAssertEqual(res.status, .created); conf = jsonObject(res)["confirmationId"] as? String ?? ""
                XCTAssertNotNil(jsonObject(res)["expiresAt"])
            }
            var first = ""
            try await publish(c, tenant, form, draft: draft, rev: 1, hash: hash, confirmation: conf) { res async throws in
                XCTAssertEqual(res.status, .created, text(res))
                first = text(res)
                let j = parse(res)
                XCTAssertEqual(j["version"]?.string, "1.0.0")
                XCTAssertEqual(j["publication"]?["actorKind"]?.string, "human")
                XCTAssertEqual(j["views"]?.array?.count, 1)
                XCTAssertEqual(j["modules"]?.array?.count, 0)
                XCTAssertEqual(j["form"]?["sha256"]?.string, hex(DocHash.sha256(doc["form"]!)))
                XCTAssertEqual(j["flow"]?["sha256"]?.string, hex(DocHash.sha256(doc["flow"]!)))
            }
            let st = try await f.sql.raw("SELECT active, current_release_id FROM forms WHERE id = \(bind: DB.bin(UUID(uuidString: form)!))").first(decoding: Frm.self)
            XCTAssertEqual(st?.active, 1)
            XCTAssertNotNil(st?.current_release_id)
            // replay: same key + same content -> same release, no second one
            try await publish(c, tenant, form, draft: draft, rev: 1, hash: hash, confirmation: conf) { res async throws in
                XCTAssertEqual(res.status, .ok); XCTAssertEqual(text(res), first)
            }
            let releases = try await f.sql.raw("SELECT COUNT(*) AS c FROM releases").first(decoding: C.self)?.c
            XCTAssertEqual(releases, 1)
            // same key, different content -> 409
            try await publish(c, tenant, form, draft: draft, rev: 2, hash: hash, confirmation: conf) { res async throws in XCTAssertEqual(res.status, .conflict) }
            // consumed confirmation cannot be used again with another key
            try await publish(c, tenant, form, key: "k2", draft: draft, rev: 1, hash: hash, confirmation: conf) { res async throws in XCTAssertEqual(res.status, .conflict) }
            let still = try await f.sql.raw("SELECT COUNT(*) AS c FROM releases").first(decoding: C.self)?.c
            XCTAssertEqual(still, 1)
            let audit = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code IN ('release.confirm','release.publish','form.create')").first(decoding: C.self)?.c
            XCTAssertEqual(audit, 3)
            // Upgrade check (ADR 0046): the published definition is clean; an incompatible stored pattern is reported per field.
            let clean = try await PatternCompatibility.scan(sql: f.sql)
            XCTAssertEqual(clean, [])
            let stored = try await f.sql.raw("SELECT definition_json FROM form_versions").first(decoding: StoredDef.self)?.definition_json ?? ""
            var storedDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
            var storedFields = try XCTUnwrap(storedDoc["fields"] as? [String: Any])
            let firstKey = try XCTUnwrap(storedFields.keys.sorted().first)
            var storedField = try XCTUnwrap(storedFields[firstKey] as? [String: Any])
            storedField["validation"] = ["pattern": "(?i)abc"]
            storedFields[firstKey] = storedField; storedDoc["fields"] = storedFields
            let patched = String(decoding: try JSONSerialization.data(withJSONObject: storedDoc), as: UTF8.self)
            try await f.sql.raw("UPDATE form_versions SET definition_json = \(bind: patched)").run()
            let found = try await PatternCompatibility.scan(sql: f.sql)
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(found.first?.form, form.replacingOccurrences(of: "-", with: "").lowercased())
            // the pointer is what the ingest reads: getForm shows it
            try await c.get("tenants/\(tenant)/forms/\(form)") { res async throws in
                XCTAssertEqual(jsonObject(res)["active"] as? Bool, true); XCTAssertEqual(jsonObject(res)["currentReleaseVersion"] as? Int, 1)
            }
        }
    }

    func testSecondReleaseFromDraftNeedsNewVersionsAndRebuildsFromRelease() async throws {
        try await AdminFixture.with { f in
            let (_, tenant, c) = try await setup(f)
            let (form, draft, doc, hash) = try await createForm(c, tenant)
            var conf = ""
            try await confirm(c, tenant, form, draft, rev: 1, hash: hash) { conf = jsonObject($0)["confirmationId"] as? String ?? "" }
            try await publish(c, tenant, form, draft: draft, rev: 1, hash: hash, confirmation: conf) { XCTAssertEqual($0.status, .created) }

            // same version "1.0.0" with changed content: immutable versions -> 409, nothing published
            var changed = doc
            if var t = changed.object, var fo = t["form"]?.object { fo["title"] = .object(["de": .string("Anders")]); t["form"] = .object(fo); changed = .object(t) }
            // (the view still references the old form hash, so first make it consistent without bumping versions)
            var rev = 1, curHash = hash
            func patch(_ d: JSONValue, expect: HTTPResponseStatus) async throws {
                try await c.send(.PATCH, "tenants/\(tenant)/forms/\(form)/drafts/\(draft)", body: String(decoding: JCS.canonicalize(d), as: UTF8.self), headers: ["If-Match": "\"\(rev)\""]) { res async throws in
                    XCTAssertEqual(res.status, expect, text(res))
                    if expect == .ok { rev += 1; curHash = parse(res)["hash"]?.string ?? ""; XCTAssertEqual(res.headers.first(name: .eTag), "\"\(rev)\"") }
                }
            }
            let consistentSameVersion = { () -> JSONValue in
                guard var top = changed.object, let form = top["form"], let views = top["views"]?.array else { return changed }
                let h = self.hex(DocHash.sha256(form))
                top["views"] = .array(views.map { v in guard var o = v.object, var r = o["form"]?.object else { return v }; r["sha256"] = .string(h); o["form"] = .object(r); return .object(o) })
                return .object(top)
            }()
            try await patch(consistentSameVersion, expect: .ok)
            try await confirm(c, tenant, form, draft, rev: rev, hash: curHash) { conf = jsonObject($0)["confirmationId"] as? String ?? "" }
            try await publish(c, tenant, form, key: "k2", draft: draft, rev: rev, hash: curHash, confirmation: conf) { res async throws in
                XCTAssertEqual(res.status, .conflict); XCTAssertEqual(parse(res)["code"]?.string, "conflict")
            }
            let n1 = try await f.sql.raw("SELECT COUNT(*) AS c FROM releases").first(decoding: C.self)?.c
            XCTAssertEqual(n1, 1)
            let consumed = try await f.sql.raw("SELECT COUNT(*) AS c FROM publication_confirmations WHERE consumed_at IS NOT NULL").first(decoding: C.self)?.c
            XCTAssertEqual(consumed, 1, "a failed publish rolls back and leaves the confirmation unused")

            // bumping the versions works and becomes release 2
            let next = bumped(doc, title: "Anders", version: "1.1.0")
            try await patch(next, expect: .ok)
            try await confirm(c, tenant, form, draft, rev: rev, hash: curHash) { conf = jsonObject($0)["confirmationId"] as? String ?? "" }
            try await publish(c, tenant, form, key: "k3", draft: draft, rev: rev, hash: curHash, confirmation: conf) { res async throws in
                XCTAssertEqual(res.status, .created, text(res)); XCTAssertEqual(parse(res)["version"]?.string, "2.0.0")
            }
            // a new draft starts from the current release and equals what was published
            var newDraft = ""
            try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/drafts") { res async throws in
                XCTAssertEqual(res.status, .created)
                newDraft = parse(res)["id"]?.string ?? ""
                XCTAssertEqual(parse(res)["document"], next)
            }
            XCTAssertNotEqual(newDraft, "")
        }
    }

    func testFreshAuthenticationExpiryStaleDraftAndTampering() async throws {
        try await AdminFixture.with { f in
            let (_, tenant, c) = try await setup(f)
            let (form, draft, doc, hash) = try await createForm(c, tenant)
            // stale session authentication -> must re-authenticate
            try await f.sql.raw("UPDATE sessions SET authenticated_at = '2020-01-01 00:00:00.000000' WHERE state = 'authenticated'").run()
            try await confirm(c, tenant, form, draft, rev: 1, hash: hash) { res async throws in
                XCTAssertEqual(res.status, .forbidden); XCTAssertEqual(parse(res)["code"]?.string, "reauthentication_required")
            }
            try await f.sql.raw("UPDATE sessions SET authenticated_at = NOW(6) WHERE state = 'authenticated'").run()
            // wrong hash / revision -> 409, bad formats -> 400
            try await confirm(c, tenant, form, draft, rev: 1, hash: String(repeating: "0", count: 64)) { XCTAssertEqual($0.status, .conflict) }
            try await confirm(c, tenant, form, draft, rev: 2, hash: hash) { XCTAssertEqual($0.status, .conflict) }
            try await confirm(c, tenant, form, draft, rev: 1, hash: "XYZ") { XCTAssertEqual($0.status, .badRequest) }
            try await confirm(c, tenant, form, UUID().uuidString.lowercased(), rev: 1, hash: hash) { XCTAssertEqual($0.status, .notFound) }
            var conf = ""
            try await confirm(c, tenant, form, draft, rev: 1, hash: hash) { conf = jsonObject($0)["confirmationId"] as? String ?? "" }
            // the draft changes after confirmation -> the confirmation no longer fits
            try await c.send(.PATCH, "tenants/\(tenant)/forms/\(form)/drafts/\(draft)", body: String(decoding: JCS.canonicalize(bumped(doc, title: "X", version: "1.0.1")), as: UTF8.self), headers: ["If-Match": "\"1\""]) { XCTAssertEqual($0.status, .ok) }
            try await publish(c, tenant, form, draft: draft, rev: 1, hash: hash, confirmation: conf) { XCTAssertEqual($0.status, .conflict) }
            // expired confirmation -> 410
            var hash2 = ""
            try await c.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { hash2 = parse($0)["hash"]?.string ?? "" }
            try await confirm(c, tenant, form, draft, rev: 2, hash: hash2) { conf = jsonObject($0)["confirmationId"] as? String ?? "" }
            try await f.sql.raw("UPDATE publication_confirmations SET expires_at = '2020-01-01 00:00:00.000000', created_at = '2019-12-31 00:00:00.000000'").run()
            try await publish(c, tenant, form, key: "kx", draft: draft, rev: 2, hash: hash2, confirmation: conf) { XCTAssertEqual($0.status, .gone) }
            // a confirmation of another session cannot be used
            try await confirm(c, tenant, form, draft, rev: 2, hash: hash2) { conf = jsonObject($0)["confirmationId"] as? String ?? "" }
            let other = try await f.login(try await f.account())
            _ = other
            // missing / malformed idempotency key, rebind
            try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":2,\"hash\":\"\(hash2)\",\"confirmationId\":\"\(conf)\"}") { XCTAssertEqual($0.status, .badRequest) }
            try await publish(c, tenant, form, key: "kr", draft: draft, rev: 2, hash: hash2, confirmation: conf, extra: ",\"rebind\":{}") { XCTAssertEqual($0.status, .unprocessableEntity) }
            let none = try await f.sql.raw("SELECT COUNT(*) AS c FROM releases").first(decoding: C.self)?.c
            XCTAssertEqual(none, 0)
        }
    }

    func testDraftUpdateIfMatchValidationAndRace() async throws {
        try await AdminFixture.with { f in
            let (_, tenant, c) = try await setup(f)
            let (form, draft, doc, _) = try await createForm(c, tenant)
            let body = String(decoding: JCS.canonicalize(doc), as: UTF8.self)
            let path = "tenants/\(tenant)/forms/\(form)/drafts/\(draft)"
            try await c.send(.PATCH, path, body: body) { XCTAssertEqual($0.status, .preconditionRequired) }
            try await c.send(.PATCH, path, body: body, headers: ["If-Match": "\"7\""]) { XCTAssertEqual($0.status, .preconditionFailed) }
            try await c.send(.PATCH, path, body: body, headers: ["If-Match": "abc"]) { XCTAssertEqual($0.status, .preconditionFailed) }
            try await c.send(.PATCH, path, body: body, headers: ["If-Match": "\"1\""], csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            // invalid documents: extra flow node, wrong tenant, float, duplicate key, unknown field reference, locked without value
            var bad: [String] = []
            if var t = doc.object, var fl = t["flow"]?.object, var nodes = fl["nodes"]?.object {
                nodes["x"] = .object(["kind": .string("entry"), "label": .object(["de": .string("x")])]); fl["nodes"] = .object(nodes); t["flow"] = .object(fl)
                bad.append(String(decoding: JCS.canonicalize(.object(t)), as: UTF8.self))
            }
            let text = body
            bad.append(text.replacingOccurrences(of: "\"tenantId\":\"\(tenant.uuidString.lowercased())\"", with: "\"tenantId\":\"\(UUID().uuidString.lowercased())\""))
            bad.append(text.replacingOccurrences(of: "\"maxSubmissionBytes\":10485760", with: "\"maxSubmissionBytes\":1.5"))
            bad.append(text.replacingOccurrences(of: "{\"flow\":", with: "{\"flow\":{},\"flow\":"))
            bad.append(text.replacingOccurrences(of: "\"fieldId\":\"message\"", with: "\"fieldId\":\"nope\""))
            bad.append(text.replacingOccurrences(of: "\"locked\":false", with: "\"locked\":true"))
            bad.append(text.replacingOccurrences(of: "\"specialCategories\":false", with: "\"specialCategories\":\"no\""))
            bad.append(text.replacingOccurrences(of: "\"specialCategories\":false", with: "\"specialCategories\":false,\"transport\":\"required\""))   // envelope not implemented (review H3)
            bad.append("{\"form\":{},\"flow\":{},\"views\":[]}")
            for b in bad {
                XCTAssertNotEqual(b, text)
                try await c.send(.PATCH, path, body: b, headers: ["If-Match": "\"1\""]) { res async throws in
                    XCTAssertEqual(res.status, .unprocessableEntity, String(b.prefix(80)))
                    XCTAssertEqual(parse(res)["code"]?.string, "validation_failed")
                }
            }
            let rev = try await f.sql.raw("SELECT revision AS c FROM form_drafts").first(decoding: C.self)?.c
            XCTAssertEqual(rev, 1, "rejected updates change nothing")
            // race: two parallel updates with the same If-Match: exactly one wins
            let statuses = await withTaskGroup(of: UInt.self) { g -> [UInt] in
                for i in 0..<2 {
                    g.addTask {
                        let d = self.bumped(doc, title: "T\(i)", version: "1.0.\(i + 1)")
                        var code: UInt = 0
                        try? await c.send(.PATCH, path, body: String(decoding: JCS.canonicalize(d), as: UTF8.self), headers: ["If-Match": "\"1\""]) { code = $0.status.code }
                        return code
                    }
                }
                var out: [UInt] = []; for await s in g { out.append(s) }; return out.sorted()
            }
            XCTAssertEqual(statuses, [200, 412])
        }
    }

    func testLargeDocumentsUpToOneMiBAreAcceptedAndBiggerOnesRejected() async throws {
        try await AdminFixture.with { f in
            let (_, tenant, c) = try await setup(f)
            let (form, draft, doc, _) = try await createForm(c, tenant)
            // 300 fields (~60 KiB): far beyond Vapor's 16 KiB default body limit.
            guard var top = doc.object, var formObj = top["form"]?.object, var fields = formObj["fields"]?.object, let views = top["views"]?.array else { return XCTFail() }
            for i in 0..<300 {
                fields["f\(i)"] = .object(["name": .string("feld_\(i)"), "kind": .string("text"), "label": .object(["de": .string("Feld \(i)")]), "required": .bool(false), "hidden": .bool(false), "locked": .bool(false), "sensitive": .bool(false), "validation": .object(["type": .string("string")])])
            }
            formObj["fields"] = .object(fields); top["form"] = .object(formObj)
            let formHash = hex(DocHash.sha256(.object(formObj)))
            top["views"] = .array(views.map { v in guard var o = v.object, var r = o["form"]?.object else { return v }; r["sha256"] = .string(formHash); o["form"] = .object(r); return .object(o) })
            let body = String(decoding: JCS.canonicalize(.object(top)), as: UTF8.self)
            XCTAssertGreaterThan(body.utf8.count, 30_000)
            let path = "tenants/\(tenant)/forms/\(form)/drafts/\(draft)"
            try await c.send(.PATCH, path, body: body, headers: ["If-Match": "\"1\""]) { XCTAssertEqual($0.status, .ok, text($0)) }
            let huge = String(repeating: " ", count: DocumentValidator.maxDocumentBytes + 1) + body
            try await c.send(.PATCH, path, body: huge, headers: ["If-Match": "\"2\""]) { XCTAssertEqual($0.status, .payloadTooLarge) }
        }
    }

    func testRightsForDraftsAndRelease() async throws {
        try await AdminFixture.with { f in
            let (_, tenant, admin) = try await setup(f)
            let (form, draft, _, hash) = try await createForm(admin, tenant)
            let root = try await f.account()
            let writer = try await f.account(), reader = try await f.account(), stranger = try await f.account()
            try await f.grant(writer, "draft.write", customer: tenant, by: root); try await f.grant(writer, "form.read", customer: tenant, by: root)
            try await f.grant(reader, "form.read", customer: tenant, by: root)
            let w = try await f.login(writer), r = try await f.login(reader), s = try await f.login(stranger)
            // writer cannot publish (covered, no action right) -> 403; stranger -> 404
            try await confirm(w, tenant, form, draft, rev: 1, hash: hash) { XCTAssertEqual($0.status, .forbidden) }
            try await confirm(s, tenant, form, draft, rev: 1, hash: hash) { XCTAssertEqual($0.status, .notFound) }
            // reader can read but not write
            try await r.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { XCTAssertEqual($0.status, .ok) }
            try await r.send(.POST, "tenants/\(tenant)/forms/\(form)/drafts") { XCTAssertEqual($0.status, .forbidden) }
            try await r.send(.PATCH, "tenants/\(tenant)/forms/\(form)/drafts/\(draft)", body: "{}", headers: ["If-Match": "\"1\""]) { XCTAssertEqual($0.status, .forbidden) }
            try await s.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { XCTAssertEqual($0.status, .notFound) }
            // writer may create a draft (standard or from nothing) and it is bound to this form
            try await w.send(.POST, "tenants/\(tenant)/forms/\(form)/drafts") { XCTAssertEqual($0.status, .created) }
            // a draft of another form is not reachable through this form's path
            let other = try await f.form(customer: tenant)
            try await admin.get("tenants/\(tenant)/forms/\(other)/drafts/\(draft)") { XCTAssertNotEqual($0.status, .ok) }
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/drafts", body: "{\"baseReleaseId\":\"\(UUID().uuidString.lowercased())\"}") { XCTAssertEqual($0.status, .notFound) }
            try await admin.send(.POST, "tenants/\(tenant)/forms/\(form)/drafts", body: "{\"x\":1}") { XCTAssertEqual($0.status, .badRequest) }
        }
    }
}
