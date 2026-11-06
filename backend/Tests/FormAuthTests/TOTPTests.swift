// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import FormAuth

final class TOTPTests: XCTestCase {
    func testRFC6238SHA1VectorsIncluding64BitTime() {
        let secret = Data("12345678901234567890".utf8)
        for (time, expected) in [(59, "94287082"), (1111111109, "07081804"), (1111111111, "14050471"), (1234567890, "89005924"), (2000000000, "69279037"), (20000000000, "65353130")] as [(Int64, String)] {
            XCTAssertEqual(TOTP.code(secret: secret, step: time / 30, digits: 8), expected)
        }
        XCTAssertEqual(TOTP.base32(secret), "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    }
    func testWindowFormatAndReplay() {
        let secret = Data(repeating: 9, count: 20), date = Date(timeIntervalSince1970: 3000)
        let code = TOTP.code(secret: secret, step: 100)
        XCTAssertEqual(TOTP.matchingStep(secret: secret, code: code, at: date, after: 99), 100)
        XCTAssertNil(TOTP.matchingStep(secret: secret, code: code, at: date, after: 100))
        XCTAssertEqual(TOTP.matchingStep(secret: secret, code: code, at: date.addingTimeInterval(30), after: 99), 100)
        XCTAssertNil(TOTP.matchingStep(secret: secret, code: code, at: date.addingTimeInterval(60), after: 99))
        for bad in ["", "12345", "1234567", "１２３４５６", " 123456", "abcdef"] {
            XCTAssertNil(TOTP.matchingStep(secret: secret, code: bad, at: date, after: -1))
        }
    }
}
