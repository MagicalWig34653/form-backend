// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormIngest
import FormCrypto
import Foundation
import Vapor
import XCTest

/// Synthetic data only. Cross-checks the parser against the signature canonicalisation (PHP structure).
final class FormEncodedParserTests: XCTestCase {
    private func canon(_ body: String) throws -> String {
        String(decoding: try RequestSignature.canonical(fields: FormEncodedParser.parse(Array(body.utf8))), as: UTF8.self)
    }
    func testFlatNestedAndList() throws {
        XCTAssertEqual(try canon("b=2&a=1"), #"{"fields":{"a":"1","b":"2"},"files":[]}"#)
        XCTAssertEqual(try canon("x[1]=b&x[0]=a"), #"{"fields":{"x":["a","b"]},"files":[]}"#)
        XCTAssertEqual(try canon("x[]=a&x[]=b&y[k][]=c"), #"{"fields":{"x":["a","b"],"y":{"k":["c"]}},"files":[]}"#)
        XCTAssertEqual(try canon(""), #"{"fields":[],"files":[]}"#)
        XCTAssertEqual(try canon("m=Gr%C3%BC%C3%9Fe%20%2F+Test"), "{\"fields\":{\"m\":\"Grüße / Test\"},\"files\":[]}")
    }
    func testPHPNameMapping() throws {
        XCTAssertEqual(try canon("a.b=1&c d=2"), #"{"fields":{"a_b":"1","c_d":"2"},"files":[]}"#)
    }
    func testRejectsAmbiguousAndMalformed() {
        for bad in ["a=1&a=2", "a=1&a[]=2", "a[]=1&a=2", "a.b=1&a_b=2", "a[=1", "a]=1", "a[b][=1", "a=%zz", "a=%C3", "a=%00x=%ff", "%00a=1", "a=%FF"] {
            XCTAssertThrowsError(try FormEncodedParser.parse(Array(bad.utf8)), bad)
        }
    }
    func testAppendAfterIntMaxIsRejectedNotTrapped() {
        // Review P5-A B1: Int64 overflow used to crash the process before authentication.
        XCTAssertThrowsError(try FormEncodedParser.parse(Array("x[9223372036854775807]=a&x[]=b".utf8)))
        XCTAssertNoThrow(try FormEncodedParser.parse(Array("x[9223372036854775806]=a&x[]=b".utf8)))
    }
    func testUnicodeEquivalentKeysStayDistinct() throws {
        // Review P5-A B2: precomposed and decomposed "é" are different bytes, as in PHP.
        let out = try canon("%C3%A9=1&e%CC%81=2")
        XCTAssertTrue(out.contains("\"é\":\"1\"") && out.contains("\"e\u{301}\":\"2\"".replacingOccurrences(of: "\\u{301}", with: "\u{301}")))
    }
    func testPreAuthCostCaps() {
        // Review P5-A B3: empty-name segments count, names are bounded.
        let empties = (0...2000).map { _ in "=x" }.joined(separator: "&")
        XCTAssertThrowsError(try FormEncodedParser.parse(Array(empties.utf8)))
        let longName = String(repeating: "a", count: FormEncodedParser.maxNameBytes + 1) + "=1"
        XCTAssertThrowsError(try FormEncodedParser.parse(Array(longName.utf8)))
        XCTAssertNoThrow(try FormEncodedParser.parse(Array((String(repeating: "a", count: FormEncodedParser.maxNameBytes) + "=1").utf8)))
    }
    func testLimits() {
        let many = (0...1000).map { "k\($0)=v" }.joined(separator: "&")
        XCTAssertThrowsError(try FormEncodedParser.parse(Array(many.utf8)))
        let deep = "a" + String(repeating: "[b]", count: 64) + "=1"
        XCTAssertThrowsError(try FormEncodedParser.parse(Array(deep.utf8)))
        XCTAssertNoThrow(try FormEncodedParser.parse(Array(("a" + String(repeating: "[b]", count: 20) + "=1").utf8)))
    }
    func testIdempotencyKeyRule() {
        let k = SubmitHandler.effectiveIdempotencyKey
        XCTAssertEqual(k("  abc\t"), Data("abc".utf8))
        XCTAssertNil(k(nil)); XCTAssertNil(k("")); XCTAssertNil(k(" \t "))
        XCTAssertNotNil(k(String(repeating: "a", count: 190)))
        XCTAssertNil(k(String(repeating: "a", count: 191)))
        XCTAssertNil(k(String(repeating: "ä", count: 100)))  // 200 bytes
        XCTAssertNil(k("a\nb"))
    }
    func testCanonicalUUIDOnlyLowercase() {
        XCTAssertNotNil(SubmitHandler.canonicalUUID("00000000-0000-4000-8000-000000000001"))
        XCTAssertNil(SubmitHandler.canonicalUUID("AAAAAAAA-0000-4000-8000-000000000001"))
        XCTAssertNil(SubmitHandler.canonicalUUID("00000000000040008000000000000001"))
    }
}
