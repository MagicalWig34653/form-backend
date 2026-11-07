// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormCore

final class AppConfigTests: XCTestCase {
    func testInternalSecondFactorIsExplicitOptIn() throws {
        XCTAssertFalse(try AppConfig(env: ["FORM_DB_PASSWORD": "test"]).internalSecondFactor)
        XCTAssertTrue(try AppConfig(env: ["FORM_DB_PASSWORD": "test", "FORM_INTERNAL_SECOND_FACTOR": "1"]).internalSecondFactor)
        XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD": "test", "FORM_INTERNAL_SECOND_FACTOR": "true"]))
    }

    func testDefaultsAndRedaction() throws {
        let c = try AppConfig(env: ["FORM_DB_PASSWORD": "synthetic-pw-123"])
        XCTAssertEqual(c.httpPort, 8081)
        XCTAssertEqual(c.dbTLS, .verify)
        XCTAssertFalse(c.description.contains("synthetic-pw-123"))
    }
    func testPasswordRequired() {
        XCTAssertThrowsError(try AppConfig(env: [:])) {
            XCTAssertEqual(($0 as? ConfigError)?.variable, "FORM_DB_PASSWORD")
        }
    }
    func testInvalidValuesRejectedWithoutEchoingValue() {
        for (k, v) in [("FORM_DB_PORT", "99999"), ("FORM_INTERNAL_PORT", "x"), ("FORM_DB_TLS", "maybe"), ("FORM_LOG_LEVEL", "loud")] {
            XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD": "p", k: v])) {
                let e = $0 as? ConfigError
                XCTAssertEqual(e?.variable, k)
                XCTAssertFalse("\($0)".contains(v))
            }
        }
    }
    func testInsecureTLSNeedsExplicitDevOptIn() throws {
        XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD": "p", "FORM_DB_TLS": "disable"])) {
            XCTAssertEqual(($0 as? ConfigError)?.variable, "FORM_DB_TLS")
        }
        XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD": "p", "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "true"]))
        XCTAssertEqual(try AppConfig(env: ["FORM_DB_PASSWORD": "p", "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1"]).dbTLS, .disable)
    }
    func testStrictPortAndHost() {
        for (k, v) in [("FORM_INTERNAL_PORT", "+80"), ("FORM_DB_PORT", " 80"), ("FORM_DB_PORT", "0"), ("FORM_HTTP_HOST", "")] {
            XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD": "p", k: v]), "\(k)=\(v)")
        }
    }
}
