// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import FormCore
@testable import FormAdmin
@testable import FormMigration
@testable import FormMail

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
        XCTAssertTrue(result.report.contains { $0.source == "formularFelder/3/regel" && $0.status == "nicht abbildbar" })
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
}
