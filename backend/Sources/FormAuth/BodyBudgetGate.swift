// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import Vapor

private struct BodyBudgetKey: StorageKey { typealias Value = BodyBudget }
private let bodyBudgetInit = NSLock()

public extension Application {
    /// The shared in-flight body budget of both listeners (internal and public surface use the same Application).
    var bodyBudget: BodyBudget {
        get {
            bodyBudgetInit.lock(); defer { bodyBudgetInit.unlock() }
            if let b = storage[BodyBudgetKey.self] { return b }
            let b = BodyBudget(); storage[BodyBudgetKey.self] = b; return b
        }
        set { bodyBudgetInit.lock(); storage[BodyBudgetKey.self] = newValue; bodyBudgetInit.unlock() }
    }
}

/// Route middleware for routes with large bodies. Vapor collects `body: .collect` inside the route responder, i.e. AFTER route
/// middleware: everything here runs before a single body byte is buffered. Order: `preflight` (authentication, binding, cheap header
/// checks; anything it throws ends the request, the body is drained and discarded by the server), declared length against `maxBytes`
/// (413), reservation in the shared budget (503 + Retry-After). Without Content-Length but with chunked encoding the worst case
/// (`maxBytes`) is reserved; `.collect(maxSize:)` still stops the stream at the limit. Without either the body is empty.
public struct BodyBudgetGate: AsyncMiddleware {
    public let maxBytes: Int
    public let preflight: @Sendable (Request) async throws -> Void
    public init(maxBytes: Int, preflight: @escaping @Sendable (Request) async throws -> Void = { _ in }) {
        self.maxBytes = maxBytes; self.preflight = preflight
    }

    public static func declaredBytes(_ req: Request, maxBytes: Int) throws -> Int {
        if let raw = req.headers.first(name: .contentLength) {
            guard raw.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(raw) else { throw Abort(.badRequest) }
            guard n <= maxBytes else { throw RequestBodyTooLarge() }
            return n
        }
        return req.headers.first(name: .transferEncoding) == nil ? 0 : maxBytes
    }

    public func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        try await preflight(req)
        let n = try Self.declaredBytes(req, maxBytes: maxBytes)
        guard let lease = req.application.bodyBudget.reserve(bodyBytes: n) else { throw BodyBudgetExhausted() }
        defer { lease.release() }
        return try await next.respond(to: req)
    }
}

/// Too much request data is in flight in this replica; the request was not read. Retryable.
public struct BodyBudgetExhausted: PublicProblemError {
    public init() {}
    public var statusCode: UInt { 503 }
    public var code: String { "body_budget_exhausted" }
    public var message: String { "Der Dienst ist gerade ausgelastet. Bitte gleich erneut versuchen." }
    public var extraHeaders: [(name: String, value: String)] { [("Retry-After", "1")] }
    public var auditReason: String? { nil }
}

/// The declared body is larger than the route accepts; the body was not read.
public struct RequestBodyTooLarge: PublicProblemError {
    public init() {}
    public var statusCode: UInt { 413 }
    public var code: String { "payload_too_large" }
    public var message: String { "Anfrage zu groß." }
    public var auditReason: String? { nil }
}
