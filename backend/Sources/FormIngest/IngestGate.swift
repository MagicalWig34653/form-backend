// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Per-replica budget of submissions in flight (review Astra 2 M5). Route middleware runs BEFORE Vapor collects the body
/// (`body: .collect` happens in the route responder), so a flood of large unauthenticated bodies cannot all be buffered and
/// parsed at once: beyond the budget the request is refused with 503 + Retry-After before a byte of the body is read.
/// The per-client budget (FA-015, `ingest.requestsPerMinute`) still applies inside the handler.
public final class IngestGate: AsyncMiddleware, Sendable {
    public let maxConcurrent: Int
    private let count = NIOLockedValueBox(0)
    /// `maxConcurrent` 0 = no budget.
    public init(maxConcurrent: Int) { self.maxConcurrent = max(0, maxConcurrent) }

    var inFlight: Int { count.withLockedValue { $0 } }

    func acquire() -> Bool {
        count.withLockedValue { n in
            guard maxConcurrent == 0 || n < maxConcurrent else { return false }
            n += 1
            return true
        }
    }
    func release() { count.withLockedValue { $0 = max(0, $0 - 1) } }

    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard acquire() else { throw IngestBusy() }
        defer { release() }
        return try await next.respond(to: request)
    }
}

/// The replica already handles `maxConcurrent` submissions; the SDK treats 503 as retryable.
public struct IngestBusy: PublicProblemError {
    public init() {}
    public var statusCode: UInt { 503 }
    public var code: String { "ingest_busy" }
    public var message: String { "Der Dienst ist gerade ausgelastet. Bitte gleich erneut versuchen." }
    public var extraHeaders: [(name: String, value: String)] { [("Retry-After", "1")] }
}
