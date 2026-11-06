// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation

/// Server-side field validation against the published form definition (parity FA-024) and removal of
/// transport-only fields before sealing. Values never appear in errors, only field names.
public struct SubmissionInvalid: PublicProblemError {
    public let fields: [String]
    public init(fields: [String]) { self.fields = fields }
    public var statusCode: UInt { 422 }
    public var code: String { "submission_invalid" }
    public var message: String { "Die Eingaben sind ungültig. Bitte die markierten Felder prüfen." }
    public var extraHeaders: [(name: String, value: String)] { [] }
}

enum SubmissionValidation {
    /// Spam/transport helpers that must never be stored or forwarded (see DocumentValidator.reserved).
    static let transportFields: Set<String> = ["csrf_token", "cf-turnstile-response", "g-recaptcha-response", "h-captcha-response"]
    /// Signed helper fields that are consumed by the server itself and never validated against the schema.
    static let reservedFields: Set<String> = ["_statistics"]

    /// The key under which the ingest parser stores a form field (PHP rules: `.` and space become `_`, `a[b]` is stored as `a`).
    static func storedKey(_ schemaName: String) -> String {
        let base = schemaName.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? schemaName
        return String(base.map { $0 == "." || $0 == " " ? "_" : $0 })
    }

    /// Returns canonical bytes without transport fields (unchanged object if none present).
    static func stripTransport(canonical: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any],
              var fields = root["fields"] as? [String: Any], fields.keys.contains(where: transportFields.contains) else { return canonical }
        for key in transportFields { fields.removeValue(forKey: key) }
        root["fields"] = fields
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? canonical
    }

    /// `unknownFields: discard`: fields outside the schema are dropped before sealing (ADR 0034). `_`-prefixed transport fields stay.
    static func discardUnknown(canonical: Data, definition: [String: Any]?) -> Data {
        guard let definition, (definition["unknownFields"] as? String) == "discard", let schema = definition["fields"] as? [String: Any], !schema.isEmpty,
              var root = (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any], var fields = root["fields"] as? [String: Any] else { return canonical }
        let known = Set(schema.values.compactMap { ($0 as? [String: Any])?["name"] as? String }.map(storedKey))
        let unknown = fields.keys.filter { !known.contains($0) && !reservedFields.contains($0) && !transportFields.contains($0) }
        guard !unknown.isEmpty else { return canonical }
        for key in unknown { fields.removeValue(forKey: key) }
        root["fields"] = fields
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? canonical
    }

    /// Throws `SubmissionInvalid` listing offending field names. Forms without a field schema accept everything.
    static func validate(canonical: Data, definition: [String: Any]) throws {
        guard let schema = definition["fields"] as? [String: Any], !schema.isEmpty else { return }
        let root = (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any] ?? [:]
        let submitted = (root["fields"] as? [String: Any] ?? [:]).filter { !transportFields.contains($0.key) && !reservedFields.contains($0.key) }
        // `files` is an object keyed by field name (or a list when the keys are "0", "1", …).
        let files: Set<String>
        if let object = root["files"] as? [String: Any] { files = Set(object.keys) }
        else if let list = root["files"] as? [Any] { files = Set(list.indices.map(String.init)) }
        else { files = [] }
        var byName: [String: [String: Any]] = [:]
        for case let spec as [String: Any] in schema.values { if let name = spec["name"] as? String { byName[storedKey(name)] = spec } }
        var bad = Set<String>()
        if (definition["unknownFields"] as? String) == "reject" {
            for name in submitted.keys where byName[name] == nil && !files.contains(name) { bad.insert(name) }
        }
        for (name, spec) in byName {
            let kind = spec["kind"] as? String ?? "text"
            let value = submitted[name]
            if let fixed = spec["fixedValue"] {
                if let value, !same(value, fixed) { bad.insert(name) }
                continue
            }
            if kind == "file" {
                if (spec["required"] as? Bool) == true && !files.contains(name) { bad.insert(name) }
                continue
            }
            guard let value, !isEmpty(value) else {
                if (spec["required"] as? Bool) == true && (spec["hidden"] as? Bool) != true { bad.insert(name) }
                continue
            }
            if !check(value, kind: kind, rules: spec["validation"] as? [String: Any] ?? [:]) { bad.insert(name) }
        }
        if !bad.isEmpty { throw SubmissionInvalid(fields: bad.sorted()) }
    }

    private static func isEmpty(_ v: Any) -> Bool {
        if let s = v as? String { return s.isEmpty }
        if let a = v as? [Any] { return a.isEmpty }
        return false
    }

    private static func same(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? String, let y = b as? String { return x == y }
        return String(describing: a) == String(describing: b)
    }

    private static func number(_ v: Any) -> Double? {
        if let s = v as? String {
            guard s.range(of: "^-?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil, let d = Double(s), d.isFinite else { return nil }
            return d
        }
        if v is Bool { return nil }
        if let n = v as? Double { return n }
        if let n = v as? Int { return Double(n) }
        return nil
    }

    private static func check(_ value: Any, kind: String, rules: [String: Any]) -> Bool {
        let values: [Any] = (value as? [Any]) ?? [value]
        if values.count > 1 && kind != "choice" { return false }
        for item in values {
            guard let text = item as? String ?? (item as? NSNumber).map({ "\($0)" }) else { return false }
            switch kind {
            case "date":
                guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil, isRealDate(text) else { return false }
            case "number":
                guard let n = number(item) else { return false }
                if let lo = number(rules["minimum"] ?? rules["min"] ?? ""), n < lo { return false }
                if let hi = number(rules["maximum"] ?? rules["max"] ?? ""), n > hi { return false }
            case "boolean":
                guard ["true", "false", "1", "0", "on", "off", "yes", "no"].contains(text.lowercased()) || item is Bool else { return false }
            default: break
            }
            let length = text.count
            if let lo = intRule(rules["minLength"] ?? rules["minLaenge"]), length < lo { return false }
            if let hi = intRule(rules["maxLength"] ?? rules["maxLaenge"]), length > hi { return false }
            if let pattern = (rules["pattern"] ?? rules["muster"]) as? String {
                // Anchored full match; an unparsable pattern rejects rather than silently accepting.
                // Bounded input and pattern size limit the cost of an expensive (admin-defined) expression.
                guard pattern.utf8.count <= 500, text.utf8.count <= 2_000, !hasNestedQuantifier(pattern),
                      let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")\\z"),
                      re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
            }
            if let allowed = (rules["enum"] ?? rules["options"] ?? rules["erlaubt"]) as? [Any], !allowed.contains(where: { same($0, item) }) { return false }
        }
        return true
    }

    private static func intRule(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double, d == d.rounded(), abs(d) < 1e9 { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func isRealDate(_ text: String) -> Bool {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), parts[2] >= 1 else { return false }
        let leap = (parts[0] % 4 == 0 && parts[0] % 100 != 0) || parts[0] % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return parts[2] <= days[parts[1] - 1]
    }

    /// Rejects the classic catastrophic-backtracking shapes (a quantified group that itself contains a quantifier or an alternation).
    /// ICU has no usable timeout, so such an admin-defined expression is refused instead of risking the ingest worker.
    static func hasNestedQuantifier(_ pattern: String) -> Bool {
        pattern.range(of: "\\([^)]*[+*{|][^)]*\\)[+*{]", options: .regularExpression) != nil
    }
}
