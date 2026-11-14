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
/// (413), reservation in the shared budget (bodies of at least `BodyBudget.minWaitBytes` (4 MiB) wait up to `BodyBudget.maxWait` for capacity, smaller ones are refused at once; refusal = 503 + Retry-After). Without Content-Length but with chunked encoding the worst case
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
        let lease: BodyBudget.Lease?
        do {
            lease = try await req.application.bodyBudget.reserveWaiting(bodyBytes: n, abandoned: { !ClientConnection.isOpen(req) })
        } catch is CancellationError { throw ClientClosedRequest() }   // gone while queued: nothing reserved, the body is never read
        guard let lease else { throw BodyBudgetExhausted() }
        defer { lease.release() }
        if lease.waited {
            // admitted after a wait: the client may have given up meanwhile. A complete request can sit unread in the socket buffers; the FIN of a
            // client that closed right after uploading is queued behind that data and invisible until it is read. So check, collect the body
            // (the handler would do it next, bounded by the reservation) and check again, with a short grace for the FIN to arrive.
            guard ClientConnection.isOpen(req) else { throw ClientClosedRequest() }
            _ = try await req.body.collect(max: maxBytes).get()
            guard await ClientConnection.staysOpen(req) else { throw ClientClosedRequest() }
        }
        return try await next.respond(to: req)
    }
}

/// The client closed the connection while its request waited for the body budget; it is dropped unread (nobody is listening for the answer).
public struct ClientClosedRequest: PublicProblemError {
    public init() {}
    public var statusCode: UInt { 499 }
    public var code: String { "client_closed_request" }
    public var message: String { "Verbindung vom Client beendet." }
    public var auditReason: String? { nil }
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
