// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormMail

final class DerivedValuesTests: XCTestCase {
    private func plan(_ derived: [String: Any]) -> (MailPlan?, String?) {
        MailPlan.parse([
            "from": ["address": "absender@example.invalid"],
            "organisation": ["to": ["team@example.invalid"], "subject": "Betreff", "body": "Text"],
            "derived": derived,
        ], fieldNames: ["prename", "lastname", "abWann", "a", "b"])
    }

    func testJoinFirstNonEmptyDateAndNow() throws {
        let p = try XCTUnwrap(plan([
            "fullName": ["op": "join", "fields": ["prename", "lastname"], "separator": " "],
            "wahl": ["op": "firstNonEmpty", "fields": ["a", "b"]],
            "ab": ["op": "date", "field": "abWann", "format": "dd.MM.yyyy"],
            "jetzt": ["op": "now", "format": "dd.MM.yyyy - HH:mm", "timeZone": "Europe/Berlin"],
        ]).0)
        var v = ["prename": "Erika", "lastname": "Muster", "a": "", "b": "zweite", "abWann": "2026-12-01"]
        p.apply(derived: &v, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(v["fullName"], "Erika Muster")
        XCTAssertEqual(v["wahl"], "zweite")
        XCTAssertEqual(v["ab"], "01.12.2026")
        XCTAssertEqual(v["jetzt"], "15.01.2027 - 09:00")
        var missing = ["lastname": "Muster"]
        p.apply(derived: &missing, now: Date())
        XCTAssertEqual(missing["fullName"], "Muster"); XCTAssertEqual(missing["ab"], ""); XCTAssertEqual(missing["wahl"], "")
    }

    func testInvalidRulesAreRejected() {
        XCTAssertNil(plan(["x": ["op": "join", "fields": ["unbekannt"]]]).0)
        XCTAssertNil(plan(["prename": ["op": "now", "format": "yyyy"]]).0, "must not shadow a form field")
        XCTAssertNil(plan(["x": ["op": "eval", "code": "1"]]).0)
        XCTAssertNil(plan(["x": ["op": "now", "format": "yyyy", "timeZone": "Mars/Base"]]).0)
        XCTAssertNil(plan(["bad name": ["op": "now", "format": "yyyy"]]).0)
    }
}
