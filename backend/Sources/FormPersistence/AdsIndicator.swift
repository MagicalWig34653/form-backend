// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreFoundation

/// Only a presence bit crosses the statistics boundary. Never accept URL/click values.
public enum AdsIndicator {
    public enum Invalid: Error { case value }
    public static func parse(_ value: Any?) throws -> Bool? {
        guard let value else { return nil }
        guard let object = value as? [String: Any], Set(object.keys) == ["gclidPresent"],
              let number = object["gclidPresent"] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Invalid.value }
        return number.boolValue
    }
}
