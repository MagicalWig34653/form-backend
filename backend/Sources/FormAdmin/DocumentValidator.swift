// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormMail
import FormFlow
import Foundation

extension JSONValue {
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int64? { if case .int(let i) = self { return i }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    /// Plain Foundation value (for APIs that take `[String: Any]`).
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }
    subscript(key: String) -> JSONValue? { object?[key] }
}

/// A draft/release document that violates the contract. `path` is a JSON-pointer-like location (no values).
public struct DocumentInvalid: Error, Equatable { public let path: String; public let rule: String }

/// SHA-256 over the RFC 8785 canonical form (ADR 0008 F1): the one hash used for drafts, versions and manifests.
enum DocHash {
    static func sha256(_ v: JSONValue) -> Data { Data(SHA256.hash(data: JCS.canonicalize(v))) }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

/// Strict, hand-written subset of contracts/flow form/graph/view schemas for the P5 scope (no external JSON-Schema
/// validator is linked; R1 in docs/handoffs/P5-B-vertrag-offen.md). Anything outside the subset is rejected, never
/// silently accepted: the release scope is form + 1..n views + the empty standard flow (entry -> end).
public enum DocumentValidator {
    public static let maxDocumentBytes = 1_048_576
    static let maxStorageBytes: Int64 = 33_554_432          // ingest hard limit
    static let reserved: Set<String> = ["csrf_token", "cf-turnstile-response", "g-recaptcha-response", "h-captcha-response"]
    static let kinds: Set<String> = ["text", "email", "date", "number", "boolean", "choice", "file"]

    struct Checked { let form: JSONValue; let flow: JSONValue; let views: [JSONValue]; let formID: UUID; let flowID: UUID; let viewIDs: [UUID] }

    @discardableResult
    public static func validate(_ doc: JSONValue, tenant: UUID, form formID: UUID) throws -> (formHash: Data, flowHash: Data, viewHashes: [Data]) {
        let c = try check(doc, tenant: tenant, form: formID)
        return (DocHash.sha256(c.form), DocHash.sha256(c.flow), c.views.map(DocHash.sha256))
    }

    static func check(_ doc: JSONValue, tenant: UUID, form formID: UUID) throws -> Checked {
        guard let top = doc.object, Set(top.keys) == ["form", "flow", "views"] else { throw DocumentInvalid(path: "", rule: "members must be exactly form, flow, views") }
        let form = top["form"]!, flow = top["flow"]!
        guard let views = top["views"]?.array, !views.isEmpty, views.count <= 20 else { throw DocumentInvalid(path: "/views", rule: "1..20 views") }
        try checkForm(form, tenant: tenant, form: formID)
        let flowID = try checkFlow(flow)
        let formHash = DocHash.hex(DocHash.sha256(form))
        var ids: [UUID] = []
        for (i, v) in views.enumerated() {
            let id = try checkView(v, at: "/views/\(i)", form: form, formID: formID, formHash: formHash)
            guard !ids.contains(id) else { throw DocumentInvalid(path: "/views/\(i)/id", rule: "duplicate view id") }
            ids.append(id)
        }
        return Checked(form: form, flow: flow, views: views, formID: formID, flowID: flowID, viewIDs: ids)
    }

    // MARK: primitives

    static func uuid(_ v: JSONValue?, _ path: String) throws -> UUID {
        guard let s = v?.string, s == s.lowercased(), let u = UUID(uuidString: s), s.count == 36 else { throw DocumentInvalid(path: path, rule: "lowercase uuid") }
        return u
    }
    static func semver(_ v: JSONValue?, _ path: String) throws -> String {
        guard let s = v?.string, s.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil, s.count <= 32 else { throw DocumentInvalid(path: path, rule: "semantic version") }
        return s
    }
    static func ident(_ s: String, _ path: String) throws {
        guard s.range(of: "^[A-Za-z][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else { throw DocumentInvalid(path: path, rule: "identifier") }
    }
    static func localized(_ v: JSONValue?, _ path: String) throws {
        guard let o = v?.object, !o.isEmpty, o.count <= 20 else { throw DocumentInvalid(path: path, rule: "localized text") }
        for (k, t) in o {
            guard k.range(of: "^[a-z]{2}(-[A-Z]{2})?$", options: .regularExpression) != nil, let s = t.string, s.utf8.count <= 2000, !hasControl(s) else { throw DocumentInvalid(path: path, rule: "localized text") }
        }
    }
    static func hasControl(_ s: String) -> Bool { s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }
    static func exactly(_ o: [String: JSONValue], _ required: Set<String>, optional: Set<String> = [], _ path: String) throws {
        let keys = Set(o.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw DocumentInvalid(path: path, rule: "unexpected or missing members") }
    }

    // MARK: form

    static func checkForm(_ f: JSONValue, tenant: UUID, form formID: UUID) throws {
        guard let o = f.object else { throw DocumentInvalid(path: "/form", rule: "object") }
        try exactly(o, ["contractVersion", "proposalStatus", "id", "version", "tenantId", "title", "unknownFields", "normalization", "fields", "security", "storage"], optional: ["mail"], "/form")
        guard o["contractVersion"]?.string == "0.1.0", o["proposalStatus"]?.string == "VORGESCHLAGEN" else { throw DocumentInvalid(path: "/form/contractVersion", rule: "0.1.0 / VORGESCHLAGEN") }
        guard try uuid(o["id"], "/form/id") == formID else { throw DocumentInvalid(path: "/form/id", rule: "must equal the path form") }
        guard try uuid(o["tenantId"], "/form/tenantId") == tenant else { throw DocumentInvalid(path: "/form/tenantId", rule: "must equal the path tenant") }
        _ = try semver(o["version"], "/form/version")
        try localized(o["title"], "/form/title")
        guard let uf = o["unknownFields"]?.string, ["reject", "discard"].contains(uf) else { throw DocumentInvalid(path: "/form/unknownFields", rule: "reject|discard") }
        guard o["normalization"]?.string == "typed-v1" else { throw DocumentInvalid(path: "/form/normalization", rule: "typed-v1") }
        guard let fields = o["fields"]?.object, !fields.isEmpty, fields.count <= 500 else { throw DocumentInvalid(path: "/form/fields", rule: "1..500 fields") }
        var names = Set<String>()
        for (key, field) in fields {
            let p = "/form/fields/\(key)"
            try ident(key, p)
            guard let fo = field.object else { throw DocumentInvalid(path: p, rule: "object") }
            try exactly(fo, ["name", "kind", "label", "required", "hidden", "locked", "sensitive", "validation"], optional: ["fixedValue"], p)
            guard let name = fo["name"]?.string, (1...190).contains(name.count), name.range(of: "^[A-Za-z0-9_.()\\[\\]-]+$", options: .regularExpression) != nil, !reserved.contains(name) else { throw DocumentInvalid(path: p + "/name", rule: "field name") }
            guard names.insert(name).inserted else { throw DocumentInvalid(path: p + "/name", rule: "duplicate field name") }
            guard let kind = fo["kind"]?.string, kinds.contains(kind) else { throw DocumentInvalid(path: p + "/kind", rule: "field kind") }
            try localized(fo["label"], p + "/label")
            for b in ["required", "hidden", "locked", "sensitive"] { guard fo[b]?.bool != nil else { throw DocumentInvalid(path: p + "/" + b, rule: "boolean") } }
            guard fo["validation"]?.object != nil else { throw DocumentInvalid(path: p + "/validation", rule: "object") }
            for key in ["pattern", "muster"] {
                if let pat = fo["validation"]?.object?[key] {
                    // ADR 0046: only the linear-time regex dialect is accepted, so no stored pattern can stall the ingest.
                    guard let str = pat.string, LinearRegex.validate(str) == nil else { throw DocumentInvalid(path: p + "/validation/" + key, rule: "supported regex (no lookaround, backreference, lazy quantifier)") }
                }
            }
            guard (fo["locked"]?.bool == true) == (fo["fixedValue"] != nil) else { throw DocumentInvalid(path: p + "/fixedValue", rule: "present exactly when locked") }
        }
        if let mail = o["mail"] {
            // form.mail (ADR 0010): same strict parser the ingest uses; addresses, templates and field references are checked now, not at send time.
            guard let m = mail.foundation as? [String: Any] else { throw DocumentInvalid(path: "/form/mail", rule: "object") }
            if case (_, let why?) = MailPlan.parse(m, fieldNames: names) { throw DocumentInvalid(path: "/form/mail/" + why, rule: "invalid mail configuration") }
        }
        guard let sec = o["security"]?.object else { throw DocumentInvalid(path: "/form/security", rule: "object") }
        try exactly(sec, ["encryptionProfile", "specialCategories"], optional: ["transport", "abuse"], "/form/security")
        if let abuse = sec["abuse"] {
            guard let object = abuse.foundation as? [String: Any], (try? AbusePolicy(object)) != nil else { throw DocumentInvalid(path: "/form/security/abuse", rule: "invalid abuse configuration") }
        }
        guard sec["encryptionProfile"]?.string == "hpke-v2" else { throw DocumentInvalid(path: "/form/security/encryptionProfile", rule: "hpke-v2") }
        guard sec["specialCategories"]?.bool != nil else { throw DocumentInvalid(path: "/form/security/specialCategories", rule: "boolean (ADR 0009 F3)") }
        if let t = sec["transport"] { guard let s = t.string, ["off", "offered", "required"].contains(s) else { throw DocumentInvalid(path: "/form/security/transport", rule: "off|offered|required") }
            // The transport envelope (crypto/transport.md) is not implemented: a policy that promises it must not be publishable (review H3).
            guard s == "off" else { throw DocumentInvalid(path: "/form/security/transport", rule: "only 'off' until the transport envelope is implemented") }
        }
        guard let st = o["storage"]?.object else { throw DocumentInvalid(path: "/form/storage", rule: "object") }
        try exactly(st, ["adapter", "maxSubmissionBytes", "onFailure"], "/form/storage")
        guard st["adapter"]?.string == "db" else { throw DocumentInvalid(path: "/form/storage/adapter", rule: "db only in this scope") }
        guard let m = st["maxSubmissionBytes"]?.int, (1...maxStorageBytes).contains(m) else { throw DocumentInvalid(path: "/form/storage/maxSubmissionBytes", rule: "1..33554432") }
        guard st["onFailure"]?.string == "reject-acceptance" else { throw DocumentInvalid(path: "/form/storage/onFailure", rule: "reject-acceptance") }
    }

    // MARK: flow (empty standard flow only)

    static func checkFlow(_ g: JSONValue) throws -> UUID {
        do {
            let definition = try FlowDefinition.load(graph: JCS.canonicalize(g), blocks: FlowDefinition.builtinBlocks, modules: FlowDefinition.builtinModules)
            guard let id = UUID(uuidString: definition.id) else { throw FlowError.invalidDefinition }
            return id
        } catch { throw DocumentInvalid(path: "/flow", rule: "unsupported or invalid flow contract") }
    }

    // MARK: view

    static func checkView(_ v: JSONValue, at p: String, form: JSONValue, formID: UUID, formHash: String) throws -> UUID {
        guard let o = v.object else { throw DocumentInvalid(path: p, rule: "object") }
        try exactly(o, ["contractVersion", "proposalStatus", "id", "version", "form", "title", "theme", "steps"], p)
        guard o["contractVersion"]?.string == "0.1.0", o["proposalStatus"]?.string == "VORGESCHLAGEN" else { throw DocumentInvalid(path: p + "/contractVersion", rule: "0.1.0") }
        let id = try uuid(o["id"], p + "/id")
        _ = try semver(o["version"], p + "/version")
        guard let ref = o["form"]?.object else { throw DocumentInvalid(path: p + "/form", rule: "object") }
        try exactly(ref, ["id", "version", "sha256"], p + "/form")
        guard try uuid(ref["id"], p + "/form/id") == formID, ref["version"]?.string == form["version"]?.string, ref["sha256"]?.string == formHash else {
            throw DocumentInvalid(path: p + "/form", rule: "must reference this form version and its hash")
        }
        try localized(o["title"], p + "/title")
        guard let theme = o["theme"]?.object else { throw DocumentInvalid(path: p + "/theme", rule: "object") }
        try exactly(theme, ["id", "version", "parameters"], p + "/theme")
        try ident(theme["id"]?.string ?? "", p + "/theme/id"); _ = try semver(theme["version"], p + "/theme/version")
        guard theme["parameters"] != nil else { throw DocumentInvalid(path: p + "/theme/parameters", rule: "present") }
        guard let steps = o["steps"]?.array, !steps.isEmpty, steps.count <= 50 else { throw DocumentInvalid(path: p + "/steps", rule: "1..50 steps") }
        let fieldIDs = Set(form["fields"]?.object?.keys.map { $0 } ?? [])
        for (i, s) in steps.enumerated() {
            let sp = "\(p)/steps/\(i)"
            guard let so = s.object else { throw DocumentInvalid(path: sp, rule: "object") }
            try exactly(so, ["id", "title", "sections"], sp)
            try ident(so["id"]?.string ?? "", sp + "/id"); try localized(so["title"], sp + "/title")
            guard let secs = so["sections"]?.array, !secs.isEmpty, secs.count <= 50 else { throw DocumentInvalid(path: sp + "/sections", rule: "1..50 sections") }
            for (j, sec) in secs.enumerated() {
                let cp = "\(sp)/sections/\(j)"
                guard let co = sec.object else { throw DocumentInvalid(path: cp, rule: "object") }
                try exactly(co, ["id", "title", "fields"], cp)
                try ident(co["id"]?.string ?? "", cp + "/id"); try localized(co["title"], cp + "/title")
                guard let fl = co["fields"]?.array, fl.count <= 500 else { throw DocumentInvalid(path: cp + "/fields", rule: "array") }
                for (k, f) in fl.enumerated() {
                    let fp = "\(cp)/fields/\(k)"
                    guard let fo = f.object else { throw DocumentInvalid(path: fp, rule: "object") }
                    try exactly(fo, ["fieldId", "readOnly", "disabled"], fp)
                    guard let fid = fo["fieldId"]?.string, fieldIDs.contains(fid), fo["readOnly"]?.bool != nil, fo["disabled"]?.bool != nil else { throw DocumentInvalid(path: fp, rule: "known fieldId with boolean flags") }
                }
            }
        }
        return id
    }
}
