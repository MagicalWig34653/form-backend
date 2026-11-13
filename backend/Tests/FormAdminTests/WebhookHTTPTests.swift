// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormMail
import Foundation
import TestSupport
import XCTest
@testable import FormWebhooks
@testable import FormAdmin

final class WebhookHTTPTests: XCTestCase {
    func testWebhookDNSDeadlineAndSaturationUseBoundedPool() async throws {
        let gate = DispatchSemaphore(value: 0)
        let resolver = BoundedDNSResolver(capacity: 1, deadline: .milliseconds(40), lookup: { _ in
            gate.wait()
            return [IPAddr("8.8.8.8")!]
        })
        defer { gate.signal() }
        let start = Date()
        do { _ = try await WebhookTarget.validate("https://slow.example/hook", resolver: resolver); XCTFail("expected timeout") }
        catch { XCTAssertEqual(error as? HostGuard.Failure, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        do { try await WebhookRoutes.validateTarget("https://slow.example/hook", resolver: resolver); XCTFail("expected 422") }
        catch let error as ValidationFailed { XCTAssertEqual(error.statusCode, 422); XCTAssertTrue(error.detail.contains("Zeitlimit")) }
        // A timeout does not free the blocked libc worker's capacity.
        do { _ = try await resolver.resolve("another.example"); XCTFail("expected saturation") }
        catch { XCTAssertEqual(error as? HostGuard.Failure, .timeout) }
    }

    func testWebhookRejectsHTTPPrivateAndAmbiguousURLs() async throws {
        for url in ["http://example.com/hook", "https://127.0.0.1/hook", "https://10.0.0.1/hook", "https://[::1]/hook", "https://user:pass@example.com/hook", "https://example.com/#fragment", "https://example.com/\r\nInjected:yes"] {
            do { _ = try await WebhookTarget.validate(url); XCTFail("accepted unsafe target: \(url)") } catch {}
        }
    }

    func testWebhookHTTPPinsTLSConnectionAndDoesNotFollowRedirects() async throws {
        let server = FakeWebhookServer(statuses: [302])
        try await server.start()
        let client = WebhookHTTP(testAllowedNets: [CIDR("127.0.0.0/8")!, CIDR("::1/128")!], testAllowInsecure: true)
        do {
            let result = try await client.send(url: "https://localhost:\(server.port)/hook?token=test", body: Data("{\"event\":\"anfrage.eingegangen\"}".utf8), timestamp: "1234", signature: "test-signature")
            XCTAssertEqual(result, 302)
            let requests = server.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.uri, "/hook?token=test")
            XCTAssertEqual(requests.first?.headers.first(name: "Host"), "localhost:\(server.port)")
            XCTAssertEqual(requests.first?.headers.first(name: "X-Kubus-Webhook-Timestamp"), "1234")
            XCTAssertEqual(requests.first?.headers.first(name: "X-Kubus-Webhook-Signature"), "test-signature")
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    func testWebhookHTTPRejectsOversizedResponseAndUntrustedTLS() async throws {
        let server = FakeWebhookServer(responseBytes: 65_537)
        try await server.start()
        let url = "https://localhost:\(server.port)/hook"
        let client = WebhookHTTP(testAllowedNets: [CIDR("127.0.0.0/8")!, CIDR("::1/128")!], testAllowInsecure: true)
        do {
            _ = try await client.send(url: url, body: Data(), timestamp: "1", signature: "s")
            XCTFail("oversized response accepted")
        } catch WebhookTarget.Failure.responseTooLarge {} catch { XCTFail("unexpected \(type(of: error))") }
        let strictTLS = WebhookHTTP(testAllowedNets: [CIDR("127.0.0.0/8")!, CIDR("::1/128")!], testAllowInsecure: false)
        do { _ = try await strictTLS.send(url: url, body: Data(), timestamp: "1", signature: "s"); XCTFail("synthetic TLS certificate accepted") } catch {}
        XCTAssertEqual(server.requests.count, 1)
        await server.stop()
    }
}
