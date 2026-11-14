// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import FormCore
@testable import FormAdmin
@testable import FormMigration
@testable import FormMail
@testable import FormIngest

final class LegacyFormConverterTests: XCTestCase {
    let tenant = UUID(), form = UUID()
    func convert(_ fields: [[String: String]], config: [String: String] = [:]) throws -> LegacyFormConverter.Result {
        let source: [String: Any] = ["legacyConfiguration": config, "legacyFields": fields]
        return try LegacyFormConverter.convert(JSONSerialization.data(withJSONObject: source), standardDocument: DraftStore.standardDocument(tenant: tenant, form: form, name: "Formular"))
    }
    func testAllEditorKindsAndViewHashValidate() throws {
        let fields = ["text", "email", "datum", "zahl", "bool", "auswahl"].enumerated().map { i, type in
            ["feldName": "field_\(i)", "typ": type, "pflicht": "1", "regel": type == "auswahl" ? "{\"optionen\":[\"A\",\"B\"]}" : "{}"]
        }
        let result = try convert(fields, config: ["name": "Synthetisch", "besondereKategorien": "1", "active": "1"])
        _ = try DocumentValidator.validate(result.document, tenant: tenant, form: form)
        XCTAssertEqual(result.document["form"]?["fields"]?.object?.count, 6)
        XCTAssertEqual(result.document["form"]?["fields"]?["legacy_2"]?["kind"], .string("date"))
        XCTAssertEqual(result.document["form"]?["security"]?["specialCategories"], .bool(true))
        XCTAssertNil(result.document["form"]?["mail"])
    }
    func testInvalidFieldsAndRulesAreReportedWithoutValues() throws {
        let marker = "synthetic-person-value@example.test"
        let result = try convert([
            ["feldName": marker, "typ": "text", "pflicht": "1"],
            ["feldName": "upload", "typ": "datei", "pflicht": "1"],
            ["feldName": "selection", "typ": "auswahl", "pflicht": "1", "regel": "broken"],
            ["feldName": "valid", "typ": "text", "pflicht": "1", "regel": "{\"muster\":\"" + marker + "\"}"]
        ], config: ["name": marker, "mailBody": marker, "domains": "[\"" + marker + "\"]", marker: marker])
        let report = String(decoding: try JSONEncoder().encode(result.report), as: UTF8.self)
        XCTAssertFalse(report.contains(marker))
        XCTAssertTrue(result.report.contains { $0.source == "formularFelder/3/regel/muster" && $0.status == "nicht abbildbar" })
        _ = try DocumentValidator.validate(result.document, tenant: tenant, form: form)
    }
    func testPartialMailAndDomainsNeverEnterExecutableDocument() throws {
        let result = try convert([], config: ["domains": "[\"EXAMPLE.TEST\",\"*.example.test\",\"https://example.test\"]", "fromName": "Test", "betreff": "Hallo", "mailBody": "#=[email]=#", "toProductionMails": "[\"production@example.test\"]", "toTestingMails": "[\"test@example.test\"]", "formularSendMailToFiller": "1"])
        XCTAssertEqual(result.proposals["domains"], .array([.string("example.test")]))
        XCTAssertEqual(result.proposals["mail"]?["organisation"]?["body"], .string("#=[email]=#"))
        XCTAssertEqual(result.proposals["testingRecipients"], .array([.string("test@example.test")]))
        XCTAssertNil(result.document["form"]?["mail"])
        _ = try DocumentValidator.validate(result.document, tenant: tenant, form: form)
    }
    /// Decision 13.11.: an imported form (mailBody with placeholders, no `content`) sends the FULL mail, like the legacy backend.
    func testImportedMailTemplateYieldsTheFullStandardMail() throws {
        let result = try convert([["feldName": "email", "typ": "email", "pflicht": "1"], ["feldName": "anliegen", "typ": "text", "pflicht": "0"]],
                                 config: ["fromName": "Praxis", "betreff": "Anfrage #=[email]=#", "mailBody": "Anliegen: #=[anliegen]=#", "toProductionMails": "[\"production@example.test\"]"])
        guard case .object(var mail)? = result.proposals["mail"], case .object(var org)? = mail["organisation"] else { return XCTFail() }
        XCTAssertNil(org["content"], "the converter does not mark the import as notification")
        org["to"] = .array([.string("team@example.test")]); mail["organisation"] = .object(org)
        mail["from"] = .object(["address": .string("absender@example.test")])
        let json = try JSONSerialization.jsonObject(with: JCS.canonicalize(.object(mail))) as! [String: Any]
        let plan = try XCTUnwrap(MailPlan.parse(json, fieldNames: ["email", "anliegen"]).0)
        XCTAssertEqual(plan.organisation?.content, .full)
        let o = try XCTUnwrap(plan.organisation)
        let values = ["email": "a@example.test", "anliegen": "IMPORT-MARKER-1"]
        XCTAssertEqual(MailTemplate.renderSubject(o.template.subject, values: values), "Anfrage a@example.test")
        XCTAssertEqual(MailTemplate.render(o.template.body, values: values, html: o.template.isHTML), "Anliegen: IMPORT-MARKER-1")
    }
    func testEssentialFallbackAndDuplicateNames() throws {
        let fallback = try convert([], config: ["essentialPostFields": "[\"email\",\"email\"]"])
        XCTAssertEqual(fallback.document["form"]?["fields"]?.object?.count, 1)
        XCTAssertEqual(fallback.document["form"]?["fields"]?["essential_0"]?["sensitive"], .bool(true))
        _ = try DocumentValidator.validate(fallback.document, tenant: tenant, form: form)
        let duplicate = try convert([["feldName":"same", "typ":"text", "pflicht":"0"], ["feldName":"same", "typ":"text", "pflicht":"1"]])
        XCTAssertEqual(duplicate.document["form"]?["fields"]?.object?.count, 1)
        XCTAssertTrue(duplicate.report.contains { $0.source == "formularFelder/1" && $0.status == "nicht abbildbar" })
    }
    func testMalformedAndOversizeProjectionRejected() throws {
        let base = DraftStore.standardDocument(tenant: tenant, form: form, name: "Formular")
        XCTAssertThrowsError(try LegacyFormConverter.convert(Data("{}".utf8), standardDocument: base))
        XCTAssertThrowsError(try LegacyFormConverter.convert(Data(repeating: 32, count: 1_048_577), standardDocument: base))
    }
    // MARK: Altregeln (Karte 6E571834)
    func rules(_ typ: String, _ regel: String, pflicht: String = "1", config: [String: String] = [:]) throws -> (LegacyFormConverter.Result, [String: JSONValue]) {
        let r = try convert([["feldName": "f", "typ": typ, "pflicht": pflicht, "regel": regel]], config: config)
        _ = try DocumentValidator.validate(r.document, tenant: tenant, form: form)
        return (r, r.document["form"]?["fields"]?["legacy_0"]?["validation"]?.object ?? [:])
    }
    func accepts(_ r: LegacyFormConverter.Result, _ value: String?) -> Bool {
        let def = (try? JSONSerialization.jsonObject(with: JCS.canonicalize(r.document["form"]!))) as! [String: Any]
        var fields: [String: Any] = [:]
        if let value { fields["f"] = value }
        let canonical = (try? JSONSerialization.data(withJSONObject: ["fields": fields], options: [.sortedKeys])) ?? Data()
        return (try? SubmissionValidation.validate(canonical: canonical, definition: def)) != nil
    }
    func testLengthRulesAreCarriedAndEnforced() throws {
        let (r, v) = try rules("text", "{\"minLaenge\":2,\"maxLaenge\":4}")
        XCTAssertEqual(v["minLength"], .int(2)); XCTAssertEqual(v["maxLength"], .int(4))
        XCTAssertTrue(accepts(r, "abc")); XCTAssertFalse(accepts(r, "a")); XCTAssertFalse(accepts(r, "abcde"))
        XCTAssertTrue(r.report.contains { $0.source == "formularFelder/0/regel/minLaenge" && $0.status == "uebernommen" })
        let (bool, boolv) = try rules("text", "{\"minLaenge\":true}")
        XCTAssertNil(boolv["minLength"]); XCTAssertTrue(bool.report.contains { $0.source == "formularFelder/0/regel/minLaenge" && $0.status == "nicht abbildbar" })
        let (bad, bv) = try rules("text", "{\"minLaenge\":\"2\"}")
        XCTAssertNil(bv["minLength"])
        XCTAssertTrue(bad.report.contains { $0.source == "formularFelder/0/regel/minLaenge" && $0.status == "nicht abbildbar" })
    }
    func testConsentMussSeinBecomesSingleValueEnumKeepingRequired() throws {
        let (r, v) = try rules("text", "{\"mussSein\":\"true\"}")
        XCTAssertEqual(v["enum"], .array([.string("true")]))
        XCTAssertEqual(r.document["form"]?["fields"]?["legacy_0"]?["required"], .bool(true))
        XCTAssertTrue(accepts(r, "true")); XCTAssertFalse(accepts(r, "false")); XCTAssertFalse(accepts(r, nil))
        let (b, _) = try rules("bool", "{\"mussSein\":\"true\"}")
        XCTAssertTrue(accepts(b, "true")); XCTAssertFalse(accepts(b, "false")); XCTAssertFalse(accepts(b, "1"))
        let (n, nv) = try rules("text", "{\"mussSein\":true}")
        XCTAssertNil(nv["enum"])
        XCTAssertTrue(n.report.contains { $0.source == "formularFelder/0/regel/mussSein" && $0.status == "nicht abbildbar" })
    }
    func testPatternPartialMatchSemanticsAreKept() throws {
        // Anchored pattern: stripped, full match.
        let (a, av) = try rules("text", "{\"muster\":\"/^[0-9]{3}$/\"}")
        XCTAssertEqual(av["pattern"], .string("[0-9]{3}"))
        XCTAssertTrue(accepts(a, "123")); XCTAssertFalse(accepts(a, "1234")); XCTAssertFalse(accepts(a, "x123"))
        // Unanchored: legacy preg_match is a partial match, so the pattern is wrapped.
        let (u, _) = try rules("text", "{\"muster\":\"/[0-9]{3}/\"}")
        XCTAssertTrue(accepts(u, "ab123cd")); XCTAssertFalse(accepts(u, "ab12cd"))
        // Half anchored.
        let (h, _) = try rules("text", "{\"muster\":\"#^PLZ#\"}")
        XCTAssertTrue(accepts(h, "PLZ 12345")); XCTAssertFalse(accepts(h, "x PLZ"))
        // Anchors inside alternation keep their per-branch meaning.
        let (alt, _) = try rules("text", "{\"muster\":\"/^a|b$/\"}")
        XCTAssertTrue(accepts(alt, "azz")); XCTAssertTrue(accepts(alt, "zzb")); XCTAssertFalse(accepts(alt, "zbz"))
    }
    func testUnsupportedPatternsAreReportedNeverDropped() throws {
        for muster in ["/^\\\\d+$/i", "/(?=a)b/", "/a(?<n>b)\\\\1/", "^\\\\d+$", "/\\\\bword\\\\b/"] {
            let (r, v) = try rules("text", "{\"muster\":\"\(muster)\"}")
            XCTAssertNil(v["pattern"], muster)
            XCTAssertTrue(r.report.contains { $0.source == "formularFelder/0/regel/muster" && $0.status == "nicht abbildbar" }, muster)
        }
    }
    func testFileFieldBecomesFileKindFirstOnly() throws {
        let r = try convert([["feldName": "beleg", "typ": "datei", "pflicht": "1", "regel": "{}"], ["feldName": "zweit", "typ": "datei", "pflicht": "0"]])
        _ = try DocumentValidator.validate(r.document, tenant: tenant, form: form)
        XCTAssertEqual(r.document["form"]?["fields"]?["legacy_0"]?["kind"], .string("file"))
        XCTAssertEqual(r.document["form"]?["fields"]?["legacy_0"]?["required"], .bool(true))
        XCTAssertNil(r.document["form"]?["fields"]?["legacy_1"])
        XCTAssertTrue(r.report.contains { $0.source == "formularFelder/1" && $0.status == "nicht abbildbar" })
    }
    func testBrokenAndUnknownRulesAreReported() throws {
        let (r, _) = try rules("text", "broken")
        XCTAssertTrue(r.report.contains { $0.source == "formularFelder/0/regel" && $0.status == "nicht abbildbar" })
        let (u, _) = try rules("text", "{\"irgendwas\":1}")
        XCTAssertTrue(u.report.contains { $0.source == "formularFelder/0/regel" && $0.status == "nicht abbildbar" })
    }
}
