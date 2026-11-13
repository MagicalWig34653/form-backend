// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Legacy placeholder syntax `#=[Name]=#` (`\w+`). Unknown placeholders stay as written (legacy behaviour). Values are
/// HTML-escaped in HTML bodies (a deliberate deviation: the legacy code did not escape), and stripped of line breaks in subjects.
public enum MailTemplate {
    private static let regex = try! NSRegularExpression(pattern: "#=\\[(\\w+)\\]=#")

    public static func render(_ template: String, values: [String: String], html: Bool) -> String {
        replace(template, values: values) { html ? escapeHTML($0) : $0 }
    }

    public static func renderSubject(_ template: String, values: [String: String]) -> String {
        let r = replace(template, values: values) { v in String(v.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) }) }
        return String(r.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) }.prefix(300))
    }

    private static func replace(_ t: String, values: [String: String], transform: (String) -> String) -> String {
        let ns = t as NSString
        var out = "", last = 0
        for m in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            out += values[name].map(transform) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    public static func escapeHTML(_ s: String) -> String {
        var o = ""; o.reserveCapacity(s.count)
        for c in s { switch c { case "&": o += "&amp;"; case "<": o += "&lt;"; case ">": o += "&gt;"; case "\"": o += "&quot;"; case "'": o += "&#39;"; default: o.append(c) } }
        return o
    }

    /// Flattens submitted fields (strings, lists, maps) to placeholder values: lists as "a, b", maps as "k: v, k2: v2".
    public static func values(fromFields fields: [String: Any]) -> [String: String] {
        func flat(_ v: Any) -> String {
            switch v {
            case let s as String: return s
            case let a as [Any]: return a.map(flat).joined(separator: ", ")
            case let d as [String: Any]: return d.keys.sorted().map { "\($0): \(flat(d[$0]!))" }.joined(separator: ", ")
            default: return "\(v)"
            }
        }
        var out: [String: String] = [:]
        for (k, v) in fields where k.range(of: "^\\w+$", options: .regularExpression) != nil { out[k] = flat(v) }
        return out
    }
}
