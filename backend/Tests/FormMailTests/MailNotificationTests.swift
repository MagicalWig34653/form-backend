// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
import FormPersistence
@testable import FormMail

/// ADR 0041 (changed 13.11.2026): the organisation mail carries ALL submitted values by default (`full`, as the legacy backend: the practice team
/// has no access to the backend). Only an explicit `content: "notification"` reduces it to name, time, reference and link.
final class MailNotificationTests: XCTestCase {
    private let fields: Set<String> = ["name", "diagnose"]

    private func plan(_ org: [String: Any]) -> MailPlan? {
        MailPlan.parse(["from": ["address": "absender@example.invalid"], "organisation": org], fieldNames: fields).0
    }

    func testContentDefaultsToFullAndTemplateIsOptional() throws {
        XCTAssertEqual(try XCTUnwrap(plan(["to": ["team@example.invalid"], "subject": "S", "body": "#=[diagnose]=#"])).organisation?.content, .full, "old forms without the key")
        XCTAssertEqual(try XCTUnwrap(plan(["to": ["team@example.invalid"]])).organisation?.content, .full, "a new form without any template must not fail")
        XCTAssertEqual(try XCTUnwrap(plan(["to": ["team@example.invalid"], "content": "full"])).organisation?.content, .full)
        XCTAssertEqual(try XCTUnwrap(plan(["to": ["team@example.invalid"], "subject": "S", "body": "B", "content": "notification"])).organisation?.content, .notification)
        XCTAssertNil(plan(["to": ["team@example.invalid"], "subject": "S", "body": "B", "content": "alles"]))
        XCTAssertNil(plan(["to": ["team@example.invalid"], "subject": "S", "body": "B", "content": true]))
    }

    /// The template is optional in both modes (empty or partial = default list); type, size and header safety stay checked.
    func testPartialOrEmptyTemplateIsAcceptedInBothModes() throws {
        let to = ["team@example.invalid"]
        for mode in [nil, "full", "notification"] {
            func p(_ extra: [String: Any]) -> MailPlan? { plan(["to": to].merging(extra) { $1 }.merging(mode.map { ["content": $0] } ?? [:]) { $1 }) }
            XCTAssertNotNil(p(["format": "html"]), "format alone (legacy importer) \(mode ?? "default")")
            XCTAssertNotNil(p(["subject": "", "body": "Text"]))
            XCTAssertNotNil(p(["body": "Text"]))
            XCTAssertNotNil(p(["subject": "S"]))
            XCTAssertNil(p(["subject": 7]), "wrong types are still rejected")
            XCTAssertNil(p(["format": "pdf"]))
            XCTAssertNil(p(["subject": "S\nBcc: x@example.invalid"]), "header injection is still rejected")
        }
        XCTAssertNil(plan(["to": to, "replyToField": "geloescht"]), "default = full: a reply-to on a deleted field stays an error")
        XCTAssertNil(plan(["to": to, "replyToField": "geloescht", "subject": "S", "body": "B", "content": "full"]))
        XCTAssertNil(try XCTUnwrap(plan(["to": to, "replyToField": "geloescht", "content": "notification"])).organisation?.replyToField, "notification ignores a stale reply-to")
        let legacy = MailPlan.parse(["from": ["address": "absender@example.invalid"], "organisation": ["to": to, "format": "html"],
                                     "confirmation": ["toField": "name", "subject": "Danke", "body": "Danke"]], fieldNames: fields).0
        XCTAssertNotNil(try XCTUnwrap(legacy).confirmation)
    }

    private func definition(_ org: [String: Any]) -> [String: Any] {
        func f(_ name: String, _ label: String?) -> [String: Any] { ["name": name, "kind": "text", "label": label.map { ["de": $0] } ?? [:]] }
        return ["title": ["de": "Aufnahmebogen"],
                "fields": ["f_2": f("diagnose", "Diagnose"), "f_10": f("zusatz", nil), "f_1": f("name", "Name der Person"), "f_3": f("leer", "Leeres Feld")],
                "mail": ["from": ["address": "absender@example.invalid"], "organisation": org]]
    }
    private func render(_ org: [String: Any], values: [String: String]) throws -> MailMessage {
        let p = try XCTUnwrap(MailDispatcher.plan(definition: definition(org)))
        let o = try XCTUnwrap(p.organisation)
        return try MailDispatcher.renderMessage(adminOrigin: "https://admin.example.org", now: Date(timeIntervalSince1970: 1_800_000_000), plan: p, to: o.to, bcc: [], replyTo: nil,
                                                template: o.template, notify: o.content == .notification, values: values, customer: DB.bin(UUID()), form: DB.bin(UUID()), submission: UUID())
    }
    private let submitted = ["name": "Erika Muster", "diagnose": "F32.1 Depression", "zusatz": "Hinweis 42"]

    /// Review 13.11.: without any template the standard mail still carries every field (label: value), as the legacy backend did.
    func testStandardMailWithoutTemplateListsAllFieldsWithLabelsAndValues() throws {
        for org in [["to": ["team@example.invalid"]], ["to": ["team@example.invalid"], "subject": "", "body": "", "content": "full"]] as [[String: Any]] {
            let m = try render(org, values: submitted)
            XCTAssertEqual(m.subject, "Neue Einsendung: Aufnahmebogen")
            XCTAssertFalse(m.isHTML)
            for line in ["Name der Person: Erika Muster", "Diagnose: F32.1 Depression", "zusatz: Hinweis 42", "Leeres Feld:"] { XCTAssertTrue(m.body.contains(line), "\(line)\n\(m.body)") }
            let n = m.body.range(of: "Name der Person")!.lowerBound, d = m.body.range(of: "Diagnose")!.lowerBound, z = m.body.range(of: "zusatz")!.lowerBound
            XCTAssertTrue(n < d && d < z, "field order follows the ids numerically (f_1, f_2, f_10)")
        }
    }

    func testStandardMailWithTemplateRendersTheTemplateAndPartialTemplatesFallBackPerPart() throws {
        let m = try render(["to": ["team@example.invalid"], "subject": "Befund: #=[diagnose]=#", "body": "Name #=[name]=#"], values: submitted)
        XCTAssertEqual(m.subject, "Befund: F32.1 Depression"); XCTAssertEqual(m.body, "Name Erika Muster")
        let onlySubject = try render(["to": ["team@example.invalid"], "subject": "Eigener Betreff"], values: submitted)
        XCTAssertEqual(onlySubject.subject, "Eigener Betreff"); XCTAssertTrue(onlySubject.body.contains("Diagnose: F32.1 Depression"))
    }

    func testStandardMailListKeepsValuesVerbatimAndIsPlainText() throws {
        let m = try render(["to": ["team@example.invalid"], "format": "html"], values: ["name": "A\r\nB <b>", "diagnose": "x"])
        XCTAssertFalse(m.isHTML, "the generated list is plain text even if the unused template says html")
        XCTAssertTrue(m.body.contains("Name der Person: A\nB <b>"), m.body)
    }

    /// An explicit notification is still a notification: no template text, no value.
    func testExplicitNotificationCarriesNoValue() throws {
        let m = try render(["to": ["team@example.invalid"], "subject": "Befund: #=[diagnose]=#", "body": "#=[name]=#", "content": "notification"], values: submitted)
        let wire = m.subject + m.body
        for secret in ["Erika", "F32", "Depression", "Hinweis", "Name der Person"] { XCTAssertFalse(wire.contains(secret), secret) }
        XCTAssertTrue(m.subject.contains("Aufnahmebogen")); XCTAssertTrue(m.body.contains("/entries"))
    }

    func testFormTitleComesFromTheLocalizedTitle() {
        func title(_ t: Any?) -> String? {
            var def: [String: Any] = ["fields": [:], "mail": ["from": ["address": "absender@example.invalid"], "organisation": ["to": ["team@example.invalid"]]]]
            if let t { def["title"] = t }
            return MailDispatcher.plan(definition: def)?.formTitle
        }
        XCTAssertEqual(title(["en": "Intake", "de": "Aufnahmebogen"]), "Aufnahmebogen")
        XCTAssertEqual(title(["fr": "Accueil", "en": "Intake"]), "Intake", "without de: the first value (keys sorted)")
        XCTAssertEqual(title(["de": "", "en": "Intake"]), "Intake")
        XCTAssertEqual(title("Alt"), "Alt")
        XCTAssertEqual(title(nil), "")
    }

    func testNotificationTimeIsTheReceiptOfTheSubmissionNotTheRendering() throws {
        var p = try XCTUnwrap(plan(["to": ["team@example.invalid"], "content": "notification"]))
        p.formTitle = "Aufnahmebogen"
        let o = try XCTUnwrap(p.organisation)
        let received = Date(timeIntervalSince1970: 1_800_000_000), now = received.addingTimeInterval(3 * 86_400)
        let note = try MailDispatcher.renderMessage(adminOrigin: nil, now: now, receivedAt: received, plan: p, to: o.to, bcc: [], replyTo: nil, template: o.template, notify: true, values: [:],
                                                    customer: DB.bin(UUID()), form: DB.bin(UUID()), submission: UUID())
        XCTAssertTrue(note.body.contains("Zeitpunkt: 15.01.2027 09:00 Uhr"), note.body)
        XCTAssertEqual(note.date, now, "the Date header stays the sending time")
    }

    func testNotificationContainsOnlyTitleTimeReferenceAndLink() {
        let n = MailNotification.render(formTitle: "Aufnahme\r\nBcc: x@y.de", at: Date(timeIntervalSince1970: 1_800_000_000),
                                        reference: "aaaaaaaa-0000-4000-8000-000000000001", link: "https://admin.example.org/t/1/f/2/entries")
        XCTAssertEqual(n.subject, "Neue Einsendung: Aufnahme  Bcc: x@y.de")
        XCTAssertFalse(n.subject.contains("\n"))
        XCTAssertTrue(n.body.contains("Formular: Aufnahme"))
        XCTAssertTrue(n.body.contains("Zeitpunkt: 15.01.2027 09:00 Uhr"))
        XCTAssertTrue(n.body.contains("Kennung: aaaaaaaa-0000-4000-8000-000000000001"))
        XCTAssertTrue(n.body.contains("https://admin.example.org/t/1/f/2/entries"))
        let noLink = MailNotification.render(formTitle: "", at: Date(), reference: "r", link: nil)
        XCTAssertTrue(noLink.subject.hasSuffix("Formular")); XCTAssertFalse(noLink.body.contains("http"))
    }

    func testDispatcherRendersNotificationWithoutAnyFieldValue() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), origin = "https://admin.example.org"
        var p = try XCTUnwrap(plan(["to": ["team@example.invalid"], "subject": "Befund: #=[diagnose]=#", "body": "Name #=[name]=#, Diagnose #=[diagnose]=#", "content": "notification"]))
        p.formTitle = "Aufnahmebogen"
        let values = ["name": "Erika Muster", "diagnose": "F32.1 Depression"]
        let o = try XCTUnwrap(p.organisation)
        let sub = UUID(), cust = UUID(), form = UUID()
        let note = try MailDispatcher.renderMessage(adminOrigin: origin, now: now, plan: p, to: o.to, bcc: [], replyTo: "x@example.org", template: o.template, notify: o.content == .notification, values: values,
                                       customer: DB.bin(cust), form: DB.bin(form), submission: sub)
        let wire = String(decoding: try note.rfc822(), as: UTF8.self) + note.subject + note.body
        for secret in ["Erika", "Muster", "F32", "Depression", "diagnose", "x@example.org"] { XCTAssertFalse(wire.contains(secret), secret) }
        XCTAssertTrue(note.subject.contains("Aufnahmebogen"))
        XCTAssertTrue(note.body.contains("https://admin.example.org/t/\(cust.uuidString.lowercased())/f/\(form.uuidString.lowercased())/entries"))
        XCTAssertTrue(note.body.contains(sub.uuidString.lowercased()))
        XCTAssertFalse(note.isHTML)
        // explicit full mode still renders the template
        let full = try MailDispatcher.renderMessage(adminOrigin: origin, now: now, plan: p, to: o.to, bcc: [], replyTo: nil, template: o.template, notify: false, values: values,
                                       customer: DB.bin(cust), form: DB.bin(form), submission: sub)
        XCTAssertTrue(full.body.contains("Diagnose F32.1 Depression")); XCTAssertEqual(full.subject, "Befund: F32.1 Depression")
    }
}
