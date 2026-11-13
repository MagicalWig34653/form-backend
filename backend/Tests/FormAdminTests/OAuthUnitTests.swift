// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormCore
import XCTest

final class OAuthUnitTests: XCTestCase {
    func testS256RFC7636VectorAndVerifierGrammar() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthService.challenge(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertTrue(OAuthService.validVerifier(verifier))
        for bad in ["", String(repeating: "a", count: 42), String(repeating: "a", count: 129), String(repeating: "a", count: 42) + "+"] { XCTAssertFalse(OAuthService.validVerifier(bad)) }
    }
    func testRedirectGrammarRejectsOpenRedirectTricks() {
        for good in ["https://claude.example/callback", "http://localhost:9000/cb", "http://127.0.0.1:7000/cb", "http://[::1]:9000/cb"] { XCTAssertTrue(OAuthService.validRedirect(good), good) }
        for bad in ["http://evil.test/cb", "//evil.test", "https://user@evil.test", "https://evil.test/#x", "javascript:alert(1)", "http://localhost.evil.test/cb", "https://evil.test\\@localhost/cb", "https://evil.test/cb?code=x"] { XCTAssertFalse(OAuthService.validRedirect(bad), bad) }
    }
    func testParametersRejectDuplicatesAndDecodeOnce() throws {
        XCTAssertEqual(try OAuthRoutes.parameters("scope=a+b&state=%2526"), ["scope": "a b", "state": "%26"])
        for bad in ["a=1&a=2", "a=1&%61=2", "missing", "a=%XX"] { XCTAssertThrowsError(try OAuthRoutes.parameters(bad)) }
    }
    func testMetadataAdvertisesActualInternalAuthorizationOrigin() {
        var config = AuthConfig(relyingParty: RelyingParty(rpID: "internal.test", origin: "https://internal.test"))
        config.oauthIssuer = "https://public.test"
        let meta = OAuthRoutes.metadata(config)
        XCTAssertEqual(meta["authorization_endpoint"] as? String, "https://internal.test/oauth/authorize")
        XCTAssertEqual(meta["token_endpoint"] as? String, "https://public.test/oauth/token")
        config.oauthAuthorizeBaseURL = "https://dashboard.test"
        XCTAssertEqual(OAuthRoutes.metadata(config)["authorization_endpoint"] as? String, "https://dashboard.test/oauth/authorize")
    }
    func testSettingsAndOrigins() throws {
        let entry = SettingsRegistry.entries.first { $0.key == "mcp.requestsPerMinute" }!
        XCTAssertEqual(try SettingsRegistry.resolve(entry, env: [:], stored: [:]).value, "60")
        XCTAssertEqual(try SettingsRegistry.resolve(entry, env: ["FORM_MCP_TOKEN_RATE_LIMIT": "7"], stored: [entry.key: "9"]).value, "7")
        XCTAssertThrowsError(try entry.validate("0"))
        XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD": "synthetic", "FORM_OAUTH_AUTHORIZE_BASE_URL": "https://internal.test/path"]))
    }
}
