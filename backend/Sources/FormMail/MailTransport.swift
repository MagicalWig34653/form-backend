// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Why a send failed. `code` is a short stable token that is safe to log and to store (never contains server text, addresses or content).
public struct MailTransportError: Error, Equatable, CustomStringConvertible {
    public let code: String
    /// A later identical attempt may succeed (4xx, network). Permanent: 5xx, bad configuration, blocked target.
    public let transient: Bool
    public init(_ code: String, transient: Bool) { self.code = code; self.transient = transient }
    public var description: String { "mail transport error: \(code)" }
}

public protocol MailTransport: Sendable {
    func send(_ message: MailMessage) async throws
    /// Connect and authenticate without sending anything (admin "test connection").
    func verify() async throws
}
