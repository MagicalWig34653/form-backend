// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// An error that knows its public representation (contracts/auth/p5b-ergaenzung.md E4).
/// The HTTP error middleware renders it as `Problem`; `auditReason` never leaves the process.
public protocol PublicProblemError: Error {
    var statusCode: UInt { get }
    var code: String { get }
    /// Fixed German text, never request data.
    var message: String { get }
    /// Extra response headers, e.g. `Retry-After`.
    var extraHeaders: [(name: String, value: String)] { get }
    /// Internal cause for logs/audit (no secrets, no request values). nil = nothing to record.
    var auditReason: String? { get }
}

public extension PublicProblemError {
    var extraHeaders: [(name: String, value: String)] { [] }
    var auditReason: String? { nil }
}
