// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Error envelope per contracts/auth/admin-api.openapi.yaml `Problem`: {code, message, requestId}.
/// Messages are fixed strings; never include request data, SQL text or driver error descriptions.
public struct Problem: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let requestId: String
    public init(code: String, message: String, requestId: String) {
        self.code = code; self.message = message; self.requestId = requestId
    }
}
