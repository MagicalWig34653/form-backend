// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormMigration

/// Legacy `outgoingMailServer.SMTPallowSelfSigned` (decision 0044): only the explicit value 1 switches certificate verification off;
/// 0, 2 (old form bug), empty, NULL and anything unknown keep it on.
final class LegacyMailServerTLSTests: XCTestCase {
    func testOnlyTheExplicitValueOneAllowsSelfSignedCertificates() {
        XCTAssertFalse(LegacyMailServer.verifiesCertificate(allowSelfSigned: "1"))
        XCTAssertFalse(LegacyMailServer.verifiesCertificate(allowSelfSigned: " 1 "))
        for v in ["0", "2", "", " ", "3", "-1", "true", "yes", "01", "1.0", "x"] { XCTAssertTrue(LegacyMailServer.verifiesCertificate(allowSelfSigned: v), "value \(v)") }
        XCTAssertTrue(LegacyMailServer.verifiesCertificate(allowSelfSigned: nil))
    }

    func testSafeConfigCarriesTheBooleanForSmtpOnly() throws {
        let smtp = try LegacyMailServer.safeConfigJSON(table: "outgoingMailServer", values: ["SMTPHost": "h", "SMTPallowSelfSigned": "1", "fromMail": "a@b.c"])
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(smtp.utf8)) as? [String: Any])
        XCTAssertEqual(o["verifyCertificate"] as? Bool, false)
        XCTAssertEqual(o["SMTPallowSelfSigned"] as? String, "1", "legacy value stays visible")
        let kept = try LegacyMailServer.safeConfigJSON(table: "outgoingMailServer", values: ["SMTPallowSelfSigned": "2"])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(kept.utf8)) as? [String: Any])?["verifyCertificate"] as? Bool, true)
        let proxy = try LegacyMailServer.safeConfigJSON(table: "outgoingMailProxy", values: ["fromMail": "a@b.c"])
        let p = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(proxy.utf8)) as? [String: Any])
        XCTAssertNil(p["verifyCertificate"]); XCTAssertEqual(p["legacyURLProtected"] as? String, "true")
    }
}
