// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import FormCore

final class JCSTests: XCTestCase {
    private func canon(_ s: String) throws -> String { String(decoding: try JCS.canonicalize(json: Data(s.utf8)), as: UTF8.self) }

    /// RFC 8785 §3.2.3 example: keys sort by UTF-16 code units.
    func testRFC8785KeySortingExample() throws {
        let json = #"{"\u20ac":"Euro Sign","\r":"Carriage Return","\ufb33":"Hebrew Letter Dalet With Dagesh","1":"One","\ud83d\ude00":"Emoji: Grinning Face","\u0080":"Control","\u00f6":"Latin Small Letter O With Diaeresis"}"#
        let keys = try XCTUnwrap({ () -> [String]? in
            guard case .object(let o) = try JCS.parse(Data(json.utf8)) else { return nil }
            return o.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        }())
        XCTAssertEqual(keys, ["\r", "1", "\u{80}", "ö", "\u{20ac}", "\u{FB33}", "😀"].sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) })
        // The emoji (surrogates D83D DE00) sorts BEFORE U+FB33 under UTF-16 order, unlike scalar order.
        XCTAssertEqual(keys.firstIndex(of: "😀")! < keys.firstIndex(of: "\u{FB33}")!, true)
        let out = try canon(json)
        XCTAssertTrue(out.hasPrefix("{\"\\r\":\"Carriage Return\",\"1\":\"One\",\"\u{80}\":\"Control\",\"ö\":"))
    }

    func testStructureWhitespaceAndEscaping() throws {
        XCTAssertEqual(try canon(" { \"b\" : [ 1 , 2 , { \"z\":null , \"a\":true } ] , \"a\" : \"x\" } "), #"{"a":"x","b":[1,2,{"a":true,"z":null}]}"#)
        XCTAssertEqual(try canon(#""a\/b\u0041\u001f\"\\\n""#), "\"a/bA\\u001f\\\"\\\\\\n\"")
        XCTAssertEqual(try canon("\"é€😀\""), "\"é€😀\"")           // not escaped
        XCTAssertEqual(try canon("[]"), "[]")
        XCTAssertEqual(try canon("{}"), "{}")
        XCTAssertEqual(try canon("-9007199254740991"), "-9007199254740991")
    }

    func testRejectsWhatWouldBeAmbiguous() {
        let bad = [#"{"a":1,"a":2}"#, "1.0", "1e3", "-0", "01", "9007199254740992", "-9007199254740992", "1.5", #"{"a":1,}"#, "[1,]", "tru",
                   #""\ud800""#, #""\udc00""#, #""\ud800\u0041""#, "\"\u{01}\"", "{\"a\" 1}", "", "  ", "[1] x", "\u{FEFF}1"]
        for s in bad { XCTAssertThrowsError(try canon(s), s) }
        var deep = String(repeating: "[", count: 70) + String(repeating: "]", count: 70)
        XCTAssertThrowsError(try canon(deep), "depth")
        deep = String(repeating: "[", count: 60) + String(repeating: "]", count: 60)
        XCTAssertNoThrow(try canon(deep))
        XCTAssertThrowsError(try JCS.parse(Data([0x22, 0xFF, 0x22])))   // invalid UTF-8
    }

    func testIdempotentAndOrderIndependent() throws {
        let a = try canon(#"{"x":{"b":1,"a":[3,2,1]},"y":"é"}"#)
        let b = try canon(#"{"y":"\u00e9","x":{"a":[3,2,1],"b":1}}"#)
        XCTAssertEqual(a, b)
        XCTAssertEqual(try canon(a), a)
    }

    /// Cross-check against an independent implementation for data in the supported subset.
    func testMatchesPythonSortedJSONForTheSupportedSubset() throws {
        let sample = #"{"form":{"id":"f","fields":[{"n":"a","required":true},{"n":"b","max":190}]},"views":[{"id":"v","title":"Größe €"}],"flow":{"nodes":["entry","end"]}}"#
        XCTAssertEqual(try canon(sample), #"{"flow":{"nodes":["entry","end"]},"form":{"fields":[{"n":"a","required":true},{"max":190,"n":"b"}],"id":"f"},"views":[{"id":"v","title":"Größe €"}]}"#)
    }
}
