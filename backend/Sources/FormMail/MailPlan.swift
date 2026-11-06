// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The `form.mail` section of a published form version (see docs/decisions/0010-mailversand.md). Parsed defensively: a plan that
/// does not validate yields nil, which means "send nothing" (a bad configuration must never make the submission fail).
public struct MailPlan: Sendable, Equatable {
    public struct Template: Sendable, Equatable {
        public var subject: String, body: String, isHTML: Bool
    }
    public struct Organisation: Sendable, Equatable {
        public var to: [String], bcc: [String], replyToField: String?, template: Template
    }
    public struct Confirmation: Sendable, Equatable {
        public var toField: String, template: Template
    }
    public var fromAddress: String
    public var fromName: String?
    public var organisation: Organisation?
    public var confirmation: Confirmation?
    /// Template-only derived values (ADR 0035): name -> rule, evaluated per message from the in-memory fields.
    public var derived: [Derived] = []

    public struct Derived: Sendable, Equatable {
        public enum Rule: Sendable, Equatable {
            case join(fields: [String], separator: String)
            case firstNonEmpty(fields: [String])
            case date(field: String, format: String)
            case now(format: String, timeZone: String)
        }
        public var name: String, rule: Rule
    }

    /// Adds the derived values to `values`. Missing inputs yield an empty string, never an error.
    public func apply(derived values: inout [String: String], now: Date) {
        for d in derived {
            switch d.rule {
            case .join(let fields, let sep): values[d.name] = fields.compactMap { values[$0] }.filter { !$0.isEmpty }.joined(separator: sep)
            case .firstNonEmpty(let fields): values[d.name] = fields.compactMap { values[$0] }.first { !$0.isEmpty } ?? ""
            case .date(let field, let format):
                let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.timeZone = TimeZone(secondsFromGMT: 0); input.dateFormat = "yyyy-MM-dd"
                let out = DateFormatter(); out.locale = Locale(identifier: "en_US_POSIX"); out.timeZone = TimeZone(secondsFromGMT: 0); out.dateFormat = format
                values[d.name] = (values[field].flatMap { input.date(from: String($0.prefix(10))) }).map(out.string(from:)) ?? ""
            case .now(let format, let zone):
                let out = DateFormatter(); out.locale = Locale(identifier: "en_US_POSIX"); out.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0); out.dateFormat = format
                values[d.name] = out.string(from: now)
            }
        }
    }

    private static func parseDerived(_ raw: Any?, fieldNames: Set<String>) -> [Derived]? {
        guard let raw else { return [] }
        guard let map = raw as? [String: Any], map.count <= 20 else { return nil }
        var out: [Derived] = []
        for name in map.keys.sorted() {
            guard name.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil, !fieldNames.contains(name),
                  let spec = map[name] as? [String: Any], let op = spec["op"] as? String else { return nil }
            func fields() -> [String]? {
                guard let f = spec["fields"] as? [String], (1...10).contains(f.count), f.allSatisfy({ fieldNames.contains($0) }) else { return nil }
                return f
            }
            func format() -> String? {
                guard let f = spec["format"] as? String, (1...40).contains(f.count), !MailMessage.hasControl(f) else { return nil }
                return f
            }
            switch op {
            case "join":
                guard let f = fields(), let sep = (spec["separator"] as? String) ?? " " as String?, sep.count <= 10, !MailMessage.hasControl(sep) else { return nil }
                out.append(Derived(name: name, rule: .join(fields: f, separator: sep)))
            case "firstNonEmpty":
                guard let f = fields() else { return nil }
                out.append(Derived(name: name, rule: .firstNonEmpty(fields: f)))
            case "date":
                guard let field = spec["field"] as? String, fieldNames.contains(field), let f = format() else { return nil }
                out.append(Derived(name: name, rule: .date(field: field, format: f)))
            case "now":
                guard let f = format() else { return nil }
                let zone = (spec["timeZone"] as? String) ?? "Europe/Berlin"
                guard TimeZone(identifier: zone) != nil else { return nil }
                out.append(Derived(name: name, rule: .now(format: f, timeZone: zone)))
            default: return nil
            }
        }
        return out
    }

    public static let maxRecipients = 20, maxBody = 100_000, maxSubject = 300

    /// Strict validation shared by the draft validator and the ingest. `fieldNames` are the submitted names of the form fields.
    /// Returns nil with a reason (no values) when something is wrong.
    public static func parse(_ mail: [String: Any], fieldNames: Set<String>) -> (MailPlan?, String?) {
        func bad(_ r: String) -> (MailPlan?, String?) { (nil, r) }
        guard Set(mail.keys).isSubset(of: ["from", "organisation", "confirmation", "derived"]), let from = mail["from"] as? [String: Any],
              Set(from.keys).isSubset(of: ["address", "name"]), let faddr = (from["address"] as? String).flatMap(MailAddress.parse) else { return bad("from") }
        var fname: String? = nil
        if let n = from["name"] { guard let s = n as? String, s.count <= 100, !MailMessage.hasControl(s) else { return bad("from.name") }; fname = s.isEmpty ? nil : s }
        func template(_ o: [String: Any], _ path: String) -> (Template?, String?) {
            guard let subject = o["subject"] as? String, (1...maxSubject).contains(subject.count), let body = o["body"] as? String, (1...maxBody).contains(body.utf8.count),
                  !body.contains("\0"), !MailMessage.hasControl(subject) else { return (nil, path + ".subject/body") }
            let fmt = (o["format"] as? String) ?? "text"
            guard fmt == "text" || fmt == "html" else { return (nil, path + ".format") }
            return (Template(subject: subject, body: body, isHTML: fmt == "html"), nil)
        }
        func addresses(_ v: Any?, _ path: String) -> ([String]?, String?) {
            guard let arr = v as? [Any], arr.count <= maxRecipients else { return (nil, path) }
            var out: [String] = []
            for a in arr { guard let s = a as? String, let p = MailAddress.parse(s) else { return (nil, path) }; out.append(p) }
            return (out, nil)
        }
        guard let derived = parseDerived(mail["derived"], fieldNames: fieldNames) else { return bad("derived") }
        var org: Organisation? = nil, conf: Confirmation? = nil
        if let o = mail["organisation"] {
            guard let od = o as? [String: Any], Set(od.keys).isSubset(of: ["to", "bcc", "subject", "body", "format", "replyToField"]) else { return bad("organisation") }
            let (to, e1) = addresses(od["to"], "organisation.to"); if let e1 { return bad(e1) }
            let (bcc, e2) = od["bcc"] == nil ? ([], nil) : addresses(od["bcc"], "organisation.bcc"); if let e2 { return bad(e2) }
            guard !(to!.isEmpty && bcc!.isEmpty) else { return bad("organisation.to") }
            let (t, e3) = template(od, "organisation"); if let e3 { return bad(e3) }
            var rf: String? = nil
            if let r = od["replyToField"] { guard let s = r as? String, fieldNames.contains(s) else { return bad("organisation.replyToField") }; rf = s }
            org = Organisation(to: to!, bcc: bcc!, replyToField: rf, template: t!)
        }
        if let c = mail["confirmation"] {
            guard let cd = c as? [String: Any], Set(cd.keys).isSubset(of: ["toField", "subject", "body", "format"]), let tf = cd["toField"] as? String, fieldNames.contains(tf) else { return bad("confirmation.toField") }
            let (t, e) = template(cd, "confirmation"); if let e { return bad(e) }
            conf = Confirmation(toField: tf, template: t!)
        }
        guard org != nil || conf != nil else { return bad("organisation|confirmation") }
        return (MailPlan(fromAddress: faddr, fromName: fname, organisation: org, confirmation: conf, derived: derived), nil)
    }
}
