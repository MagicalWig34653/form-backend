// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Retention period of submissions (ADR 0012 no. 2). Every form has one (`settings` `retention.days`, in days);
/// the default is 72 hours = 3 days and can be changed per form, but not switched off.
public enum Retention {
    public static let defaultHours = 72
    public static let defaultDays = defaultHours / 24
    public static let minDays = 1
    public static let maxDays = 3650
    public static let settingKey = "retention.days"
    public static func scopeKey(_ form: UUID) -> String { "form:\(form.uuidString.lowercased())" }
}
