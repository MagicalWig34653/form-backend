// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import NIOHTTP1
import Vapor
import XCTest
@testable import FormAuth

final class ForwardedForTests: XCTestCase {
    func testListenerPolicyDefaultsAndPublicCannotDisableFactor() {
        var config = AuthConfig(relyingParty: RelyingParty(rpID: "example.test", origin: "https://example.test"))
        XCTAssertFalse(config.secondFactorRequired)
        config.secondFactorRequired = true
        XCTAssertTrue(config.secondFactorRequired)
        config.listener = "public"
        config.secondFactorRequired = false
        XCTAssertTrue(config.secondFactorRequired)
    }

    func testAllForwardedForLinesAreJoinedSoAClientCannotWinByItsOwnLine() throws {
        var h = HTTPHeaders()
        h.add(name: "X-Forwarded-For", value: "6.6.6.6")        // sent by the client
        h.add(name: "X-Forwarded-For", value: "203.0.113.9")    // appended by the trusted proxy as a second line
        let joined = try XCTUnwrap(AuthConfig.forwardedFor(h))
        XCTAssertEqual(joined, "6.6.6.6, 203.0.113.9")
        let resolver = ClientIPResolver(trusted: [try XCTUnwrap(CIDR("10.0.0.0/8"))])
        XCTAssertEqual(resolver.resolve(peer: "10.0.0.5", forwardedFor: joined), "203.0.113.9")
        XCTAssertNil(AuthConfig.forwardedFor(HTTPHeaders()))
    }
}

extension ForwardedForTests {
    func testAuthBudgetsUseSocketPeerUnlessProxyIsTrusted() async throws {
        let app = try await Vapor.Application.make(.testing)
        do {
            let rp = RelyingParty(rpID: "admin.example.test", origin: "https://admin.example.test")
            let headers = HTTPHeaders([("Forwarded", "for=6.6.6.6"), ("X-Forwarded-For", "198.51.100.7")])
            let req = Vapor.Request(application: app, headers: headers,
                remoteAddress: try .init(ipAddress: "10.0.0.5", port: 1234), on: app.eventLoopGroup.next())
            XCTAssertEqual(AuthConfig(relyingParty: rp).clientIP(req), "10.0.0.5")
            XCTAssertEqual(AuthConfig(relyingParty: rp, trustedProxies: []).clientIP(req), "10.0.0.5")
            XCTAssertEqual(AuthConfig(relyingParty: rp, trustedProxies: [try XCTUnwrap(CIDR("10.0.0.0/8"))]).clientIP(req), "198.51.100.7")
            let untrusted = Vapor.Request(application: app, headers: headers,
                remoteAddress: try .init(ipAddress: "203.0.113.9", port: 1234), on: app.eventLoopGroup.next())
            XCTAssertEqual(AuthConfig(relyingParty: rp, trustedProxies: [try XCTUnwrap(CIDR("10.0.0.0/8"))]).clientIP(untrusted), "203.0.113.9")
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
}
