// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormMail
@testable import FormIngest
import XCTest

final class AbuseTests: XCTestCase {
    func testCaptchaFailureMatrix() throws {
        for test in [false, true] {
            for closed in [false, true] {
                let policy = try AbusePolicy(["siteKey": "synthetic", "testMode": test, "failPolicy": closed ? "closed" : "open"])
                XCTAssertTrue(AbuseProtection.captchaAllowed(.passed, policy: policy))
                XCTAssertEqual(AbuseProtection.captchaAllowed(.rejected, policy: policy), test)
                XCTAssertEqual(AbuseProtection.captchaAllowed(.unavailable, policy: policy), test || !closed)
            }
        }
        XCTAssertThrowsError(try AbusePolicy(["secret": "must-not-be-in-document"]))
        XCTAssertThrowsError(try AbusePolicy(["failPolicy": "typo"]))
        XCTAssertThrowsError(try AbusePolicy(["testMode": "true"]))
    }
    func testServiceFailureIsNotNegativeToken() {
        func result(_ status: Int, _ json: String) -> CaptchaResult { TurnstileVerifier.classify(status: status, body: Data(json.utf8)) }
        XCTAssertEqual(result(200, #"{"success":true}"#), .passed)
        XCTAssertEqual(result(200, #"{"success":false,"error-codes":["timeout-or-duplicate"]}"#), .rejected)
        for code in ["internal-error", "invalid-input-secret", "missing-input-secret", "bad-request"] {
            XCTAssertEqual(result(200, "{\"success\":false,\"error-codes\":[\"\(code)\"]}"), .unavailable)
        }
        XCTAssertEqual(result(503, #"{"success":false}"#), .unavailable)
        XCTAssertEqual(result(200, "invalid"), .unavailable)
        XCTAssertEqual(result(200, "{}"), .unavailable)
        XCTAssertEqual(result(200, #"{"success":1}"#), .unavailable)
        XCTAssertEqual(result(200, #"{"success":false,"error-codes":"broken"}"#), .unavailable)
    }
    struct Scanner: MalwareHashScanner {
        let result: MalwareResult
        func check(sha256: String) async throws -> MalwareResult { XCTAssertEqual(sha256.count, 64); return result }
    }
    func testHashDetectionAndUnverifiedStatus() async {
        let file = Data("synthetic".utf8)
        let hit = await AbuseProtection.scan([file], hashes: [AbuseProtection.hash(file)], scanner: nil)
        XCTAssertEqual(hit, .hit)
        let unchecked = await AbuseProtection.scan([file], hashes: [], scanner: nil)
        XCTAssertEqual(unchecked, .unchecked)
        let clear = await AbuseProtection.scan([file], hashes: [String(repeating: "0", count: 64)], scanner: nil)
        XCTAssertEqual(clear, .clear)
        let unavailable = await AbuseProtection.scan([file], hashes: [String(repeating: "0", count: 64)], scanner: Scanner(result: .unchecked))
        XCTAssertEqual(unavailable, .unchecked)
        let serviceHit = await AbuseProtection.scan([file], hashes: [], scanner: Scanner(result: .hit))
        XCTAssertEqual(serviceHit, .hit)
        let empty = await AbuseProtection.scan([], hashes: [], scanner: nil)
        XCTAssertEqual(empty, .none)
    }
    func testListsDoNotTrustHeaderAddressesAndPatternsAreLiteral() {
        XCTAssertTrue(AbuseProtection.blocked(ip: "192.0.2.4", ua: "normal", nets: "192.0.2.0/24", patterns: []))
        XCTAssertFalse(AbuseProtection.blocked(ip: "198.51.100.1", ua: "normal", nets: "192.0.2.0/24", patterns: []))
        XCTAssertTrue(AbuseProtection.blocked(ip: "::1", ua: "Suspicious BOT", nets: "", patterns: ["bot"]))
        XCTAssertFalse(AbuseProtection.blocked(ip: "::1", ua: "anything", nets: "", patterns: [".*"]))
    }
    func testRegistryRejectsDownloadURLsAndMalformedHashes() throws {
        for entry in SettingsRegistry.entries where entry.group == "Missbrauchsschutz" { try entry.validate(entry.defaultValue) }
        let hashes = SettingsRegistry.entries.first { $0.key == "abuse.hashes" }!
        XCTAssertThrowsError(try hashes.validate(#"["md5"]"#))
        let nets = SettingsRegistry.entries.first { $0.key == "abuse.blockedNets" }!
        XCTAssertThrowsError(try nets.validate("https://example.invalid/tor-list"))
        XCTAssertTrue(MailDispatcher.allowedRecipients(["Allowed@example.invalid"], allowlist: ["allowed@example.invalid"]))
        XCTAssertFalse(MailDispatcher.allowedRecipients(["allowed@example.invalid", "bcc@example.invalid"], allowlist: ["allowed@example.invalid"]))
        XCTAssertFalse(MailDispatcher.allowedRecipients(["test@example.invalid"], allowlist: []))
    }
}
