// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormCore

final class SettingsRegistryTests: XCTestCase {
    func testPrecedenceAndLockEvenWithEmptyEnvironment() throws {
        let entry = SettingsRegistry.entries.first { $0.key == "mail.allowedNets" }!
        let db = [entry.key: "127.0.0.0/8"]
        XCTAssertEqual(try SettingsRegistry.resolve(entry, env: [:], stored: [:]).source, "default")
        XCTAssertEqual(try SettingsRegistry.resolve(entry, env: [:], stored: db).value, "127.0.0.0/8")
        let env = try SettingsRegistry.resolve(entry, env: [entry.envName: ""], stored: db)
        XCTAssertTrue(env.locked); XCTAssertEqual(env.source, "env"); XCTAssertEqual(env.value, "")
    }
    func testOAuthBudgetDefaultsAndValidation() throws {
        for (key, fallback) in [("oauth.registrationsPerHour", "200"), ("oauth.maxUnusedClients", "1000")] {
            let entry = SettingsRegistry.entries.first { $0.key == key }!
            XCTAssertEqual(entry.defaultValue, fallback)
            XCTAssertFalse(entry.restartRequired)
            XCTAssertEqual(try SettingsRegistry.resolve(entry, env: [:], stored: [:]).value, fallback)
            for invalid in ["0", "-1", "100001", "1.5"] { XCTAssertThrowsError(try entry.validate(invalid)) }
        }
    }
    func testStrictValidation() throws {
        let integer = SettingsRegistry.entries.first { $0.key == "mcp.requestsPerMinute" }!
        try integer.validate("60")
        for value in ["0", "-1", "100001", "1.0", "true", " 60", "060", "1e2", "60\n"] { XCTAssertThrowsError(try integer.validate(value)) }
        let nets = SettingsRegistry.entries.first { $0.type == "cidrs" }!
        for value in ["anything", "127.0.0.1/99", "127.0.0.1/8,"] { XCTAssertThrowsError(try nets.validate(value)) }
        XCTAssertFalse(SettingsRegistry.entries.contains { $0.envName.contains("PASSWORD") || $0.envName.contains("SERVER_KEY") || $0.envName.contains("PORT") || $0.envName.contains("TRUSTED") || $0.envName.contains("INSECURE") })
    }
    func testSensitiveValueNeverLeavesResolutionOrAudit() throws {
        let entry = SettingsRegistry.Entry("synthetic.secret", "Test", "path", "/secret", "TEST_SECRET", sensitive: true)
        let resolved = try SettingsRegistry.resolve(entry, env: ["TEST_SECRET": "/private-secret"], stored: [:])
        XCTAssertNil(resolved.value)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(resolved), as: UTF8.self).contains("private-secret"))
        XCTAssertEqual(SettingsRegistry.auditDetails(keys: [entry.key]), "{\"keys\":[\"synthetic.secret\"]}")
    }
}
