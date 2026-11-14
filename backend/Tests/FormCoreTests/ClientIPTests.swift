// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormCore

final class ClientIPTests: XCTestCase {
    private func r(_ cidrs: String...) -> ClientIPResolver { ClientIPResolver(trusted: cidrs.map { CIDR($0)! }) }

    func testQuotaKeyReducesIPv6ToSlash64() {
        XCTAssertEqual(IPAddr.quotaKey("2001:db8:1:2:aaaa:bbbb:cccc:dddd"), IPAddr.quotaKey("2001:db8:1:2::1"))
        XCTAssertNotEqual(IPAddr.quotaKey("2001:db8:1:2::1"), IPAddr.quotaKey("2001:db8:1:3::1"))
        XCTAssertEqual(IPAddr.quotaKey("2001:db8:1:2:aaaa::1"), "2001:db8:1:2::/64")
        XCTAssertEqual(IPAddr.quotaKey("203.0.113.9"), "203.0.113.9")
        XCTAssertEqual(IPAddr.quotaKey("::ffff:203.0.113.9"), "203.0.113.9")
        XCTAssertNotEqual(IPAddr.quotaKey("203.0.113.9"), IPAddr.quotaKey("203.0.113.10"))
        XCTAssertEqual(IPAddr.quotaKey("unknown"), "unknown")
    }

    func testCIDRParsingAndMembership() {
        let c = CIDR("10.0.0.0/8")!
        XCTAssertTrue(c.contains(IPAddr("10.255.1.2")!)); XCTAssertFalse(c.contains(IPAddr("11.0.0.1")!))
        XCTAssertTrue(CIDR("172.18.0.5")!.contains(IPAddr("172.18.0.5")!)); XCTAssertFalse(CIDR("172.18.0.5")!.contains(IPAddr("172.18.0.6")!))
        XCTAssertTrue(CIDR("fd00::/8")!.contains(IPAddr("fd12:3456::1")!)); XCTAssertFalse(CIDR("fd00::/8")!.contains(IPAddr("fe80::1")!))
        XCTAssertTrue(CIDR("10.0.0.0/8")!.contains(IPAddr("::ffff:10.1.1.1")!), "IPv4-mapped form matches")
        XCTAssertTrue(CIDR("0.0.0.0/0")!.contains(IPAddr("8.8.8.8")!))
        for bad in ["", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/x", "10.0.0/8", "::1/129", "10.0.0.0/8/8", "host", "10.0.0.256"] { XCTAssertNil(CIDR(bad), bad) }
    }

    func testCanonicalText() {
        XCTAssertEqual(IPAddr("::ffff:1.2.3.4")?.text, "1.2.3.4")
        XCTAssertEqual(IPAddr("2001:0db8:0000:0000:0000:0000:0000:0001")?.text, "2001:db8::1")
        XCTAssertNil(IPAddr("1.2.3")); XCTAssertNil(IPAddr("gggg::"))
    }

    func testUntrustedPeerIgnoresForwardedHeader() {
        XCTAssertEqual(r("10.0.0.0/8").resolve(peer: "203.0.113.7", forwardedFor: "1.1.1.1"), "203.0.113.7")
        XCTAssertEqual(ClientIPResolver(trusted: []).resolve(peer: "10.0.0.2", forwardedFor: "1.1.1.1"), "10.0.0.2")
        XCTAssertEqual(r("10.0.0.0/8").resolve(peer: nil, forwardedFor: "1.1.1.1"), "unknown")
    }

    func testTrustedProxyUsesRightmostUntrustedHop() {
        let res = r("10.0.0.0/8")
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: "198.51.100.9"), "198.51.100.9")
        // a client-supplied left part cannot override what the trusted proxy appended
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: "6.6.6.6, 198.51.100.9"), "198.51.100.9")
        // chain of two trusted proxies
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: "198.51.100.9, 10.0.0.3"), "198.51.100.9")
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: "10.0.0.3, 10.0.0.4"), "10.0.0.3", "all hops trusted: original client is internal")
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: " 2001:db8::5 "), "2001:db8::5")
    }

    func testMalformedOrMissingHeaderFallsBackToPeer() {
        let res = r("10.0.0.0/8")
        for bad in ["", "garbage", "198.51.100.9, junk", "198.51.100.9,"] {
            XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: bad), "10.0.0.2", bad)
        }
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: nil), "10.0.0.2")
    }

    /// D98A9893: a long client-controlled left part must not push the result back to the (trusted) peer, which would count as "no
    /// visitor named" (generous server-to-server budget, no ban). Only the hops the trusted proxy appended on the right matter.
    func testLongClientControlledForwardedChainStillResolvesFromTheRight() {
        let res = r("10.0.0.0/8")
        let junk = String(repeating: "6.6.6.6, ", count: 30)
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: junk + "198.51.100.9"), .init(ip: "198.51.100.9", viaProxy: true))
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: String(repeating: "garbage, ", count: 30) + "198.51.100.9"),
                       .init(ip: "198.51.100.9", viaProxy: true), "unparsable text left of the first untrusted hop is never read")
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: junk + "198.51.100.9, 10.0.0.3").ip, "198.51.100.9")
        // a genuinely endless trusted chain is still refused (bounded work), falling back to the peer
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: String(repeating: "10.0.0.3, ", count: 30) + "10.0.0.4"),
                       .init(ip: "10.0.0.2", viaProxy: false))
    }

    func testConfigParsing() throws {
        XCTAssertEqual(try AppConfig(env: ["FORM_DB_PASSWORD": "x", "FORM_TRUSTED_PROXIES": "10.0.0.0/8, 172.16.0.0/12 ,fd00::/8"]).trustedProxies.count, 3)
        XCTAssertEqual(try AppConfig(env: ["FORM_DB_PASSWORD": "x"]).trustedProxies.count, 0)
        XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD": "x", "FORM_TRUSTED_PROXIES": "10.0.0.0/8,evil"]))
    }

    func testRealIPOrderAndSpoofing() {
        let res = r("10.0.0.0/8")
        // trusted peer: X-Forwarded-For first, then X-Real-IP, then the peer
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: nil, realIP: "198.51.100.9"), "198.51.100.9")
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: "198.51.100.8", realIP: "198.51.100.9"), "198.51.100.8")
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: nil, realIP: nil), "10.0.0.2")
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: "", realIP: "2001:db8::5"), "2001:db8::5")
        XCTAssertEqual(res.resolve(peer: "10.0.0.2", forwardedFor: nil, realIP: "garbage"), "10.0.0.2")
        // untrusted peer / no trusted proxies: X-Real-IP is never believed
        XCTAssertEqual(res.resolve(peer: "203.0.113.7", forwardedFor: nil, realIP: "1.1.1.1"), "203.0.113.7")
        XCTAssertEqual(ClientIPResolver(trusted: []).resolve(peer: "10.0.0.2", forwardedFor: nil, realIP: "1.1.1.1"), "10.0.0.2")
        // viaProxy: only a real (non-trusted) visitor named by a trusted proxy counts as resolved
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: nil, realIP: "198.51.100.9"), .init(ip: "198.51.100.9", viaProxy: true))
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: "198.51.100.8", realIP: nil).viaProxy, true)
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: nil, realIP: nil).viaProxy, false)
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: "10.0.0.3", realIP: nil).viaProxy, false, "internal hop is no visitor")
        XCTAssertEqual(res.resolveDetailed(peer: "10.0.0.2", forwardedFor: nil, realIP: "10.0.0.9").viaProxy, false)
        XCTAssertEqual(res.resolveDetailed(peer: "203.0.113.7", forwardedFor: "1.1.1.1", realIP: "1.1.1.1").viaProxy, false)
    }
}
