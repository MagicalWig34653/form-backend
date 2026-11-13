// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreFoundation

/// Published, trusted configuration; never inferred from a submitted field or header.
public struct AbusePolicy: Sendable {
    public let siteKey: String?
    public let failClosed: Bool
    public let testMode: Bool
    public init(_ value: [String: Any] = [:]) throws {
        guard Set(value.keys).isSubset(of: ["siteKey", "failPolicy", "testMode"]),
              value["testMode"] == nil || (value["testMode"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true,
              value["failPolicy"] == nil || ["open", "closed"].contains(value["failPolicy"] as? String ?? "") else { throw SettingsRegistry.Invalid() }
        if let key = value["siteKey"] {
            guard let text = key as? String, (1...100).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw SettingsRegistry.Invalid() }
            siteKey = text
        } else { siteKey = nil }
        failClosed = value["failPolicy"] as? String == "closed"
        testMode = value["testMode"] as? Bool ?? false
    }
}
