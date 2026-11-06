// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import NIOCore
import XCTest
import XCTVapor
@testable import FormAdmin

final class DomainProxyTests: XCTestCase {
    private func request(_ app: Application, remote: String?, spoofed: String? = nil) throws -> Request {
        var headers = HTTPHeaders()
        headers.add(name: "X-Forwarded-Host", value: "visit.example.test")
        headers.add(name: "X-Forwarded-Proto", value: "https")
        headers.add(name: "X-Real-IP", value: "198.51.100.8")
        if let spoofed {
            headers.add(name: "X-Forwarded-For", value: spoofed)
            headers.add(name: "Forwarded", value: "for=\(spoofed);proto=https")
        }
        return Request(application: app, method: .POST, url: "/api/v2/statistics/events", headers: headers,
                       remoteAddress: try remote.map { try SocketAddress(ipAddress: $0, port: 12345) },
                       logger: app.logger, on: app.eventLoopGroup.next())
    }

    func testDomainProxyRejectsMissingAndUntrustedSocketPeerDespiteSpoofedHeaders() async throws {
        let app = try await Application.make(.testing)
        do {
            let peers: [String?] = [nil, "203.0.113.9"]
            for peer in peers {
                let req = try request(app, remote: peer, spoofed: "127.0.0.1")
                // Vapor's peerAddress trusts Forwarded/XFF; only remoteAddress represents the actual socket peer.
                XCTAssertThrowsError(try StatisticsCollector.proxyHost(req, trusted: [CIDR("127.0.0.0/8")!])) {
                    XCTAssertEqual(($0 as? Abort)?.status, .forbidden)
                }
            }
            let trusted = try request(app, remote: "127.0.0.1")
            XCTAssertEqual(try StatisticsCollector.proxyHost(trusted, trusted: [CIDR("127.0.0.0/8")!]), "visit.example.test")
            for (header, invalid) in [
                ("X-Forwarded-Host", "visit.example.test,other.example.test"),
                ("X-Forwarded-Host", "visit.example.test:443"),
                ("X-Forwarded-Host", "visit.example.test/path"),
                ("X-Forwarded-Proto", "http"),
                ("X-Real-IP", "198.51.100.8,198.51.100.9"),
                ("X-Real-IP", "invalid")
            ] {
                let req = try request(app, remote: "127.0.0.1")
                req.headers.replaceOrAdd(name: header, value: invalid)
                XCTAssertThrowsError(try StatisticsCollector.proxyHost(req, trusted: [CIDR("127.0.0.0/8")!])) {
                    XCTAssertEqual(($0 as? Abort)?.status, .badRequest)
                }
            }
            for header in ["X-Forwarded-Host", "X-Forwarded-Proto", "X-Real-IP"] {
                let missing = try request(app, remote: "127.0.0.1")
                missing.headers.remove(name: header)
                XCTAssertThrowsError(try StatisticsCollector.proxyHost(missing, trusted: [CIDR("127.0.0.0/8")!])) {
                    XCTAssertEqual(($0 as? Abort)?.status, .badRequest)
                }
                let duplicate = try request(app, remote: "127.0.0.1")
                let value = duplicate.headers.first(name: header)!
                duplicate.headers.add(name: header, value: value)
                XCTAssertThrowsError(try StatisticsCollector.proxyHost(duplicate, trusted: [CIDR("127.0.0.0/8")!])) {
                    XCTAssertEqual(($0 as? Abort)?.status, .badRequest)
                }
            }
        } catch {
            try await app.asyncShutdown(); throw error
        }
        try await app.asyncShutdown()
    }
}
