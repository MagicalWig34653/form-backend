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

    /// Operator path, finding C (13.11.2026): legacy mail connections become native connections (the schema `POST /connections` and the
    /// transports read), so an imported connection can be activated and used. PHPMailer semantics: `tls` = STARTTLS, `ssl` = implicit TLS.
    func testLegacyMailServerBecomesANativeConnection() throws {
        let smtp = try LegacyMailServer.native(kind: "smtp", values: ["SMTPHost": " mail.example.org ", "SMTPPort": "587", "SMTPSecurity": "STARTTLS",
                                                                     "SMTPUsername": "form@example.org", "SMTPPassword": " pw with blanks ", "SMTPallowSelfSigned": "1"])
        XCTAssertEqual(smtp.config["host"] as? String, "mail.example.org")
        XCTAssertEqual(smtp.config["port"] as? Int, 587)
        XCTAssertEqual(smtp.config["security"] as? String, "starttls")
        XCTAssertEqual(smtp.config["username"] as? String, "form@example.org")
        XCTAssertEqual(smtp.config["verifyCertificate"] as? Bool, false)
        XCTAssertEqual(smtp.secret, " pw with blanks ", "the password is taken over byte for byte")
        XCTAssertEqual(Set(smtp.config.keys), ["host", "port", "security", "username", "verifyCertificate"], "no secret and no unknown member in the config")
        for (legacy, native) in [("tls", "starttls"), ("ssl", "tls"), ("SSL", "tls"), ("none", "plain"), ("", "plain")] {
            let c = try LegacyMailServer.native(kind: "smtp", values: ["SMTPHost": "h", "SMTPPort": "25", "SMTPSecurity": legacy])
            XCTAssertEqual(c.config["security"] as? String, native, legacy)
            XCTAssertNil(c.secret); XCTAssertNil(c.config["username"])
        }
        func reason(_ values: [String: String?]) -> String? {
            do { _ = try LegacyMailServer.native(kind: "smtp", values: values); return nil } catch let e as LegacyMailServer.NativeInvalid { return e.reason } catch { return "other" }
        }
        XCTAssertEqual(reason(["SMTPHost": "", "SMTPPort": "25"]), "host")
        XCTAssertEqual(reason(["SMTPHost": "h", "SMTPPort": "x"]), "port")
        XCTAssertEqual(reason(["SMTPHost": "h", "SMTPPort": "25", "SMTPSecurity": "weird"]), "security")
        XCTAssertEqual(reason(["SMTPHost": "h", "SMTPPort": "25", "SMTPUsername": "u"]), "credentials")
        XCTAssertEqual(reason(["SMTPHost": "h", "SMTPPort": "25", "SMTPSecurity": "none", "SMTPallowSelfSigned": "1"]), "verifyCertificate")
        let proxy = try LegacyMailServer.native(kind: "mail-proxy", values: ["proxyURL": "https://proxy.example.org/send", "proxyAuth": "ACODE-1"])
        XCTAssertEqual(proxy.config as? [String: String], ["url": "https://proxy.example.org/send"]); XCTAssertEqual(proxy.secret, "ACODE-1")
        for url in ["http://proxy.example.org/send", "https://u:p@proxy.example.org/send", "https://proxy.example.org/send?acode=1", ""] {
            XCTAssertThrowsError(try LegacyMailServer.native(kind: "mail-proxy", values: ["proxyURL": url, "proxyAuth": "A"]), url)
        }
        XCTAssertThrowsError(try LegacyMailServer.native(kind: "mail-proxy", values: ["proxyURL": "https://proxy.example.org/send", "proxyAuth": nil]))
    }
}
