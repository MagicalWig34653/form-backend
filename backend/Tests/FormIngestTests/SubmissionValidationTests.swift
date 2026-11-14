// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormIngest

final class SubmissionValidationTests: XCTestCase {
    private func canonical(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["fields": fields, "files": []] as [String: Any])
    }
    private func field(_ name: String, _ kind: String = "text", required: Bool = false, rules: [String: Any] = [:], fixed: Any? = nil) -> [String: Any] {
        var f: [String: Any] = ["name": name, "kind": kind, "required": required, "hidden": false, "locked": fixed != nil, "validation": rules]
        if let fixed { f["fixedValue"] = fixed }
        return f
    }
    private func def(_ fields: [[String: Any]], unknown: String = "reject") -> [String: Any] {
        var map: [String: Any] = [:]
        for (i, f) in fields.enumerated() { map["f\(i)"] = f }
        return ["fields": map, "unknownFields": unknown]
    }
    private func failing(_ fields: [String: Any], _ definition: [String: Any]) -> [String] {
        do { try SubmissionValidation.validate(canonical: canonical(fields), definition: definition); return [] }
        catch let e as SubmissionInvalid { return e.fields } catch { XCTFail("\(error)"); return ["?"] }
    }

    func testRequiredLengthPatternAndEnum() {
        let d = def([field("name", required: true, rules: ["minLength": 2, "maxLength": 5]), field("plz", rules: ["pattern": "\\d{5}"]),
                     field("art", "choice", rules: ["enum": ["a", "b"]])])
        XCTAssertEqual(failing([:], d), ["name"])
        XCTAssertEqual(failing(["name": "x"], d), ["name"])
        XCTAssertEqual(failing(["name": "abcdef"], d), ["name"])
        XCTAssertEqual(failing(["name": "abc", "plz": "1234"], d), ["plz"])
        XCTAssertEqual(failing(["name": "abc", "plz": "12345x"], d), ["plz"])
        XCTAssertEqual(failing(["name": "abc", "art": "c"], d), ["art"])
        XCTAssertEqual(failing(["name": "abc", "plz": "12345", "art": "b"], d), [])
    }

    func testKindsAndUnknownFieldsAndFixedValue() {
        let d = def([field("mail", "email"), field("n", "number", rules: ["minimum": 1, "maximum": 10]), field("ok", "boolean", fixed: "true")])
        XCTAssertEqual(failing(["mail": "kein-mail"], d), [])  // address syntax is handled by the mail layer, not rejected at ingest
        XCTAssertEqual(failing(["n": "11"], d), ["n"])
        XCTAssertEqual(failing(["n": "abc"], d), ["n"])
        XCTAssertEqual(failing(["ok": "false"], d), ["ok"])
        XCTAssertEqual(failing(["mail": "a@b.de", "n": "5", "ok": "true", "zusatz": "x"], d), ["zusatz"])
        XCTAssertEqual(failing(["mail": "a@b.de", "zusatz": "x"], def([field("mail", "email")], unknown: "discard")), [])
    }

    func testTransportFieldsAreIgnoredAndStripped() throws {
        let d = def([field("name")])
        XCTAssertEqual(failing(["name": "x", "cf-turnstile-response": "token", "csrf_token": "t"], d), [])
        let stripped = SubmissionValidation.stripTransport(canonical: canonical(["name": "x", "cf-turnstile-response": "token", "_statistics": "{}"]))
        let fields = try XCTUnwrap((try JSONSerialization.jsonObject(with: stripped) as? [String: Any])?["fields"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["name", "_statistics"])
        let untouched = canonical(["name": "x"])
        XCTAssertEqual(SubmissionValidation.stripTransport(canonical: untouched), untouched)
    }

    func testDiscardDropsUnknownFields() throws {
        let d = def([field("name")], unknown: "discard")
        let out = SubmissionValidation.discardUnknown(canonical: canonical(["name": "x", "extra": "y", "_statistics": "{}"]), definition: d)
        let fields = try XCTUnwrap((try JSONSerialization.jsonObject(with: out) as? [String: Any])?["fields"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["name", "_statistics"])
        let reject = canonical(["name": "x", "extra": "y"])
        XCTAssertEqual(SubmissionValidation.discardUnknown(canonical: reject, definition: def([field("name")])), reject)
    }

    func testReviewFindings() throws {
        // Required file fields are satisfied by the object-shaped `files` of the signed canonical form.
        let withFile = try JSONSerialization.data(withJSONObject: ["fields": [:], "files": ["antrag": ["name": "a.pdf", "type": "application/pdf", "size": 3, "sha256": "x"]]] as [String: Any])
        let fileDef = def([field("antrag", "file", required: true)])
        XCTAssertNoThrow(try SubmissionValidation.validate(canonical: withFile, definition: fileDef))
        XCTAssertThrowsError(try SubmissionValidation.validate(canonical: canonical([:]), definition: fileDef))
        // Schema names the ingest parser rewrites (`.`, space, brackets) are matched under their stored key.
        let dotted = def([field("a.b", required: true), field("liste[]")], unknown: "discard")
        XCTAssertEqual(failing([:], dotted), ["a_b"])
        XCTAssertEqual(failing(["a_b": "x", "liste": ["1"]], dotted), [])
        let kept = SubmissionValidation.discardUnknown(canonical: canonical(["a_b": "x", "zzz": "y"]), definition: dotted)
        let fields = try XCTUnwrap((try JSONSerialization.jsonObject(with: kept) as? [String: Any])?["fields"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["a_b"])
        // Only reserved helper fields skip the schema; other `_x` fields are unknown (rejected / discarded).
        XCTAssertEqual(failing(["name": "x", "_foo": "y"], def([field("name")])), ["_foo"])
        XCTAssertEqual(failing(["_statistics": "{}"], def([field("name")])), [])
        // Numbers: no NaN / inf / hex, bounds hold; dates must exist; patterns are anchored with \z.
        let nums = def([field("n", "number", rules: ["minimum": 1, "maximum": 10]), field("d", "date"), field("p", rules: ["pattern": "[0-9]{3}"])])
        for bad in ["nan", "inf", "0x5", "1e3"] { XCTAssertEqual(failing(["n": bad], nums), ["n"], bad) }
        XCTAssertEqual(failing(["d": "2026-02-30"], nums), ["d"])
        XCTAssertEqual(failing(["d": "2026-02-28"], nums), [])
        XCTAssertEqual(failing(["p": "123\n"], nums), ["p"])
        // Catastrophic-backtracking shapes are refused instead of evaluated.
        XCTAssertEqual(failing(["x": String(repeating: "a", count: 40) + "!"], def([field("x", rules: ["pattern": "(a+)+$"])])), ["x"])
        // S2-03: the former filter let ((a|aa))+ through; the linear engine evaluates it in bounded time and refuses what it cannot guarantee.
        for p in ["((a|aa))+", "(a|aa)+$", "(a+)+$"] {
            let t0 = Date()
            XCTAssertEqual(failing(["x": String(repeating: "a", count: 100) + "!"], def([field("x", rules: ["pattern": p])])), ["x"])
            XCTAssertLessThan(Date().timeIntervalSince(t0), 2, p)
        }
        XCTAssertEqual(failing(["x": "aaaa"], def([field("x", rules: ["pattern": "((a|aa))+"])])), [])
        XCTAssertEqual(failing(["x": "ab"], def([field("x", rules: ["pattern": "(?=a)ab"])])), ["x"])
        // Rule values with a JSON number type still apply.
        XCTAssertEqual(failing(["t": "abcdef"], def([field("t", rules: ["maxLength": 5.0])])), ["t"])
    }

    func testFormWithoutSchemaAcceptsEverything() {
        XCTAssertEqual(failing(["beliebig": "x"], ["fields": [:]]), [])
    }
}
