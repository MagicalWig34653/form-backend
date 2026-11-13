// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormCore
import Crypto

public enum FlowError: Error, Equatable {
    case invalidDefinition, unsupportedCapability, invalidState, budgetExceeded, missingInput
}

extension JSONValue {
    var flowObject: [String: JSONValue]? { if case .object(let x) = self { return x }; return nil }
    var flowArray: [JSONValue]? { if case .array(let x) = self { return x }; return nil }
    var flowString: String? { if case .string(let x) = self { return x }; return nil }
    var flowInt: Int? { if case .int(let x) = self { return Int(exactly: x) }; return nil }
}

public struct FlowLimits: Sendable {
    public let maxSteps: Int
    public let activeTimeoutMs: Int
    public let maxElapsedMs: Int
    public let memoryBytes: Int
    public let nodeTimeoutMs: Int
    public let maxStateBytes: Int
    init(_ value: JSONValue) throws {
        let o = try FlowCheck.object(value, keys: ["maxSteps", "activeTimeoutMs", "maxElapsedMs", "memoryBytes", "nodeTimeoutMs", "maxStateBytes"])
        guard o.values.allSatisfy({ ($0.flowInt ?? 0) > 0 }) else { throw FlowError.invalidDefinition }
        maxSteps = o["maxSteps"]!.flowInt!; activeTimeoutMs = o["activeTimeoutMs"]!.flowInt!
        maxElapsedMs = o["maxElapsedMs"]!.flowInt!; memoryBytes = o["memoryBytes"]!.flowInt!
        nodeTimeoutMs = o["nodeTimeoutMs"]!.flowInt!; maxStateBytes = o["maxStateBytes"]!.flowInt!
    }
}

public struct FlowDefinition: Sendable {
    public let id: String
    public let version: String
    public let entryNode: String
    public let limits: FlowLimits
    public let nodes: [String: JSONValue]
    public let edges: [String: [String: String]]
    let blockDefinitions: [String: JSONValue]

    /// No network schema resolution. Unsupported schema keywords and capabilities are rejected.
    public static func load(graph: Data, blocks: [Data] = [], modules: [Data] = []) throws -> FlowDefinition {
        try FlowDefinition(graph: JCS.parse(graph), blocks: blocks, modules: modules)
    }

    private init(graph: JSONValue, blocks: [Data], modules: [Data]) throws {
        let o = try FlowCheck.object(graph, keys: ["contractVersion", "proposalStatus", "id", "version", "engineContractVersion", "entryNode", "limits", "nodes", "edges", "failurePolicy"])
        try FlowCheck.header(o)
        guard o["engineContractVersion"] == .string("0.1.0"), o["failurePolicy"] == .string("stop-and-record"),
              let id = o["id"]?.flowString, UUID(uuidString: id) != nil, FlowCheck.matches(id, "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"),
              let version = o["version"]?.flowString, FlowCheck.matches(version, "^[0-9]+\\.[0-9]+\\.[0-9]+$"),
              let entry = o["entryNode"]?.flowString, let ns = o["nodes"]?.flowObject, !ns.isEmpty,
              ns[entry]?.flowObject?["kind"] == .string("entry"),
              ns.values.filter({ $0.flowObject?["kind"] == .string("entry") }).count == 1,
              let es = o["edges"]?.flowArray else { throw FlowError.invalidDefinition }
        self.id = id; self.version = version; self.entryNode = entry; self.limits = try FlowLimits(o["limits"]!); nodes = ns
        var moduleRegistry: [String: JSONValue] = [:]
        for data in modules {
            let v = try JCS.parse(data), m = try FlowCheck.object(v, keys: ["contractVersion", "proposalStatus", "id", "version", "title", "owner", "engineContractVersion", "configSchema", "permissions", "dependencies", "blocks", "activation", "health"])
            try FlowCheck.header(m); try FlowCheck.identity(m); try FlowCheck.localized(m["title"]!)
            guard m["engineContractVersion"] == .string("0.1.0"), let owner = m["owner"]?.flowString, FlowCheck.identifier(owner),
                  let deps = m["dependencies"]?.flowArray, deps.isEmpty,
                  let refs = m["blocks"]?.flowArray else { throw FlowError.unsupportedCapability }
            for r in refs { let x = try FlowCheck.object(r, keys: ["id", "version"]); try FlowCheck.identity(x) }
            try FlowCheck.stringIDs(m["permissions"]!); try FlowPredicate.validate(m["configSchema"]!)
            let a = try FlowCheck.object(m["activation"]!, keys: ["installed", "serverAvailable", "tenantEnabled", "formEnabled", "onDisable"])
            guard ["installed", "serverAvailable", "tenantEnabled", "formEnabled"].allSatisfy({ a[$0] == .bool(true) }),
                  ["drain", "pause", "cancel"].contains(a["onDisable"]?.flowString ?? "") else { throw FlowError.unsupportedCapability }
            let h = try FlowCheck.object(m["health"]!, keys: ["state"], optional: ["checkedAt", "code"])
            guard ["unknown", "healthy", "degraded"].contains(h["state"]?.flowString ?? "") else { throw FlowError.unsupportedCapability }
            if let date = h["checkedAt"] { guard let text = date.flowString, ISO8601DateFormatter().date(from: text) != nil else { throw FlowError.invalidDefinition } }
            if let code = h["code"], !FlowCheck.identifier(code.flowString ?? "") { throw FlowError.invalidDefinition }
            let key = FlowCheck.key(m); guard moduleRegistry[key] == nil else { throw FlowError.invalidDefinition }; moduleRegistry[key] = v
        }
        var registry: [String: JSONValue] = [:]
        for data in blocks {
            let v = try JCS.parse(data), b = try FlowCheck.object(v, keys: ["contractVersion", "proposalStatus", "id", "version", "module", "title", "inputSchema", "outputSchema", "configSchema", "locations", "permissions", "connections", "plaintext", "limits", "effectKind", "idempotency", "retry", "debug"])
            try FlowCheck.header(b); try FlowCheck.identity(b); try FlowCheck.localized(b["title"]!)
            let blockID = b["id"]!.flowString!
            guard ["core.set-fields", "core.rename-fields", "core.mail", "core.webhook", "synthetic-mail", "synthetic-validate"].contains(blockID), b["version"] == .string("1.0.0") else { throw FlowError.unsupportedCapability }
            let mr = try FlowCheck.reference(b["module"]!)
            guard let module = moduleRegistry[FlowCheck.key(mr)], FlowCheck.digest(module) == mr["sha256"]?.flowString,
                  module.flowObject?["blocks"]?.flowArray?.contains(.object(["id": b["id"]!, "version": b["version"]!])) == true else { throw FlowError.invalidDefinition }
            for key in ["inputSchema", "outputSchema", "configSchema"] { try FlowPredicate.validate(b[key]!) }
            try FlowCheck.stringIDs(b["permissions"]!)
            guard b["locations"]?.flowArray == [.string("backend-worker")] else { throw FlowError.unsupportedCapability }
            let plain = try FlowCheck.object(b["plaintext"]!, keys: ["required", "allowedLocations", "persistence"])
            guard case .bool = plain["required"]!, plain["persistence"] == .string("forbidden"),
                  plain["allowedLocations"]?.flowArray == [.string("backend-worker")] else { throw FlowError.invalidDefinition }
            _ = try FlowLimits(b["limits"]!)
            let expected = blockID.contains("mail") ? "mail" : (blockID.contains("webhook") ? "webhook" : "none")
            guard b["effectKind"] == .string(expected), b["idempotency"] == .string(expected == "mail" ? "manual-on-uncertain" : (expected == "webhook" ? "receiver-key" : "pure")) else { throw FlowError.invalidDefinition }
            let retry = try FlowCheck.object(b["retry"]!, keys: ["mode", "maxAttempts", "initialDelayMs", "maxDelayMs", "backoffFactor", "jitter"])
            guard ["never", "manual-authorized"].contains(retry["mode"]?.flowString ?? ""), (retry["maxAttempts"]?.flowInt ?? 0) > 0,
                  (retry["initialDelayMs"]?.flowInt ?? -1) >= 0, (retry["maxDelayMs"]?.flowInt ?? -1) >= 0,
                  (retry["backoffFactor"]?.flowInt ?? 0) >= 1, case .bool = retry["jitter"]! else { throw FlowError.invalidDefinition }
            if retry["mode"] == .string("never"), retry["maxAttempts"] != .int(1) { throw FlowError.invalidDefinition }
            guard let connections = b["connections"]?.flowArray else { throw FlowError.invalidDefinition }
            for c in connections { let x = try FlowCheck.object(c, keys: ["alias", "kind", "required"]); guard FlowCheck.identifier(x["alias"]?.flowString ?? ""), ["smtp", "mail-proxy", "webhook", "test-target"].contains(x["kind"]?.flowString ?? ""), case .bool = x["required"]! else { throw FlowError.invalidDefinition } }
            let debug = try FlowCheck.object(b["debug"]!, keys: ["valuePolicy", "sensitiveInputPointers", "sensitiveOutputPointers"])
            guard debug["valuePolicy"] == .string("masked-only") else { throw FlowError.invalidDefinition }
            for key in ["sensitiveInputPointers", "sensitiveOutputPointers"] { guard let ps = debug[key]?.flowArray, ps.allSatisfy({ FlowCheck.pointer($0.flowString ?? "~") }) else { throw FlowError.invalidDefinition } }
            let key = FlowCheck.key(b); guard registry[key] == nil else { throw FlowError.invalidDefinition }; registry[key] = v
        }
        var edges: [String: [String: String]] = [:]
        for e in es {
            let edge = try FlowCheck.object(e, keys: ["from", "port", "to"])
            guard let from = edge["from"]?.flowString, let to = edge["to"]?.flowString, let port = edge["port"]?.flowString,
                  ns[from] != nil, ns[to] != nil, edges[from]?[port] == nil else { throw FlowError.invalidDefinition }
            edges[from, default: [:]][port] = to
        }
        for (name, value) in ns {
            guard FlowCheck.identifier(name), let n = value.flowObject, let kind = n["kind"]?.flowString else { throw FlowError.invalidDefinition }
            try FlowCheck.localized(n["label"] ?? .null)
            let extra: [String]
            let ports: Set<String>
            switch kind {
            case "entry": extra = []; ports = ["next"]
            case "end": extra = ["result"]; ports = []; guard ["success", "rejected", "failed"].contains(n["result"]?.flowString ?? "") else { throw FlowError.invalidDefinition }
            case "condition": extra = ["predicate"]; ports = ["true", "false"]; try FlowPredicate.validate(n["predicate"] ?? .null)
            case "wait": extra = ["durationMs", "onTimeout"]; ports = ["resume"]; guard (n["durationMs"]?.flowInt ?? 0) > 0, n["onTimeout"] == .string("fail") else { throw FlowError.invalidDefinition }
            case "approval": extra = ["permission", "timeoutMs", "onTimeout", "requireHuman"]; ports = ["approved", "rejected"]; guard n["permission"] == .string("flow.approve"), n["requireHuman"] == .bool(true), (n["timeoutMs"]?.flowInt ?? 0) > 0, ["reject", "fail"].contains(n["onTimeout"]?.flowString ?? "") else { throw FlowError.invalidDefinition }
            case "block":
                extra = ["block", "location", "config", "inputBindings"]; ports = ["next"]
                let ref = try FlowCheck.reference(n["block"] ?? .null)
                guard let b = registry[FlowCheck.key(ref)], FlowCheck.digest(b) == ref["sha256"]?.flowString,
                      n["location"] == .string("backend-worker"), let bindings = n["inputBindings"]?.flowObject else { throw FlowError.invalidDefinition }
                try FlowPredicate.check(n["config"] ?? .null, schema: b.flowObject!["configSchema"]!)
                try FlowCheck.portable(n["config"] ?? .null)
                for (key, binding) in bindings { let x = try FlowCheck.object(binding, keys: ["sourceNode", "pointer"]); guard FlowCheck.identifier(key), let source = x["sourceNode"]?.flowString, ns[source] != nil, FlowCheck.pointer(x["pointer"]?.flowString ?? "~") else { throw FlowError.invalidDefinition } }
            default: throw FlowError.unsupportedCapability
            }
            _ = try FlowCheck.object(value, keys: ["kind", "label"] + extra)
            guard Set(edges[name, default: [:]].keys) == ports else { throw FlowError.invalidDefinition }
        }
        // Minimal engine has no implicit cycles; explicit loop nodes remain a later capability.
        var visiting = Set<String>(), visited = Set<String>()
        func visit(_ n: String) throws {
            guard !visiting.contains(n) else { throw FlowError.unsupportedCapability }
            if visited.contains(n) { return }; visiting.insert(n)
            for target in edges[n, default: [:]].values { try visit(target) }
            visiting.remove(n); visited.insert(n)
        }
        try visit(entry)
        guard visited.count == ns.count else { throw FlowError.invalidDefinition }
        self.edges = edges; blockDefinitions = registry
    }
}

internal enum FlowCheck {
    static func object(_ value: JSONValue, keys: [String], optional: [String] = []) throws -> [String: JSONValue] {
        guard let o = value.flowObject, Set(keys).isSubset(of: Set(o.keys)), Set(o.keys).isSubset(of: Set(keys + optional)) else { throw FlowError.invalidDefinition }; return o
    }
    static func header(_ o: [String: JSONValue]) throws { guard o["contractVersion"] == .string("0.1.0"), o["proposalStatus"] == .string("VORGESCHLAGEN") else { throw FlowError.invalidDefinition } }
    static func identity(_ o: [String: JSONValue]) throws { guard identifier(o["id"]?.flowString ?? ""), matches(o["version"]?.flowString ?? "", "^[0-9]+\\.[0-9]+\\.[0-9]+$") else { throw FlowError.invalidDefinition } }
    static func key(_ o: [String: JSONValue]) -> String { (o["id"]?.flowString ?? "") + "@" + (o["version"]?.flowString ?? "") }
    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    static func identifier(_ s: String) -> Bool { matches(s, "^[A-Za-z][A-Za-z0-9._-]{0,127}$") }
    static func digest(_ v: JSONValue) -> String { SHA256.hash(data: JCS.canonicalize(v)).map { String(format: "%02x", $0) }.joined() }
    static func reference(_ v: JSONValue) throws -> [String: JSONValue] { let o = try object(v, keys: ["id", "version", "sha256"]); try identity(o); guard matches(o["sha256"]?.flowString ?? "", "^[a-f0-9]{64}$") else { throw FlowError.invalidDefinition }; return o }
    static func localized(_ v: JSONValue) throws { guard let o = v.flowObject, !o.isEmpty, o.allSatisfy({ matches($0.key, "^[a-z]{2}(-[A-Z]{2})?$") && $0.value.flowString != nil }) else { throw FlowError.invalidDefinition } }
    static func stringIDs(_ v: JSONValue) throws { guard let a = v.flowArray, a.allSatisfy({ identifier($0.flowString ?? "") }), Set(a.compactMap(\.flowString)).count == a.count else { throw FlowError.invalidDefinition } }
    static func pointer(_ s: String) -> Bool { matches(s, "^(|(/([^~/]|~[01])*)+)$") }
    static func portable(_ value: JSONValue) throws {
        switch value { case .object(let o):
            for (key, v) in o { guard !matches(key.lowercased(), "^(credentials?|password|passphrase|secret|token|private.?key|authorization|cookie)$") else { throw FlowError.invalidDefinition }; try portable(v) }
        case .array(let a): for v in a { try portable(v) }
        default: break }
    }
}

/// Deliberately bounded Draft-2020-12 subset. Unknown keywords reject at publication/load,
/// rather than evaluating a condition differently from its declared schema.
internal enum FlowPredicate {
    static func validate(_ schema: JSONValue) throws {
        if case .bool = schema { return }
        let o = try FlowCheck.object(schema, keys: [], optional: ["type", "const", "enum", "properties", "required", "additionalProperties", "minLength", "maxLength", "minimum", "maximum", "items", "allOf", "anyOf", "not", "format"])
        if let t = o["type"] { guard ["object", "array", "string", "integer", "number", "boolean", "null"].contains(t.flowString ?? "") else { throw FlowError.unsupportedCapability } }
        if let e = o["enum"] { guard let a = e.flowArray, !a.isEmpty, a.enumerated().allSatisfy({ index, value in !a.prefix(index).contains(value) }) else { throw FlowError.invalidDefinition } }
        if let p = o["properties"] { guard let ps = p.flowObject else { throw FlowError.invalidDefinition }; for s in ps.values { try validate(s) } }
        if let r = o["required"] { guard let a = r.flowArray, a.allSatisfy({ $0.flowString != nil }), Set(a.compactMap(\.flowString)).count == a.count else { throw FlowError.invalidDefinition } }
        if let a = o["additionalProperties"] { try validate(a) }
        for k in ["items", "not"] { if let s = o[k] { try validate(s) } }
        for k in ["allOf", "anyOf"] { if let s = o[k] { guard let a = s.flowArray, !a.isEmpty else { throw FlowError.invalidDefinition }; for v in a { try validate(v) } } }
        for k in ["minLength", "maxLength"] { if let v = o[k] { guard (v.flowInt ?? -1) >= 0 else { throw FlowError.invalidDefinition } } }
        for k in ["minimum", "maximum"] { if let v = o[k], v.flowInt == nil { throw FlowError.invalidDefinition } }
        if let f = o["format"], f != .string("email") { throw FlowError.unsupportedCapability }
    }
    static func check(_ value: JSONValue, schema: JSONValue) throws { guard matches(value, schema: schema) else { throw FlowError.invalidState } }
    static func matches(_ value: JSONValue, schema: JSONValue) -> Bool {
        if case .bool(let b) = schema { return b }; guard let o = schema.flowObject else { return false }
        if let t = o["type"]?.flowString {
            let actual: String
            switch value { case .null: actual = "null"; case .bool: actual = "boolean"; case .int: actual = "integer"; case .string: actual = "string"; case .array: actual = "array"; case .object: actual = "object" }
            if t != actual && !(t == "number" && actual == "integer") { return false }
        }
        if let c = o["const"], value != c { return false }
        if let a = o["enum"]?.flowArray, !a.contains(value) { return false }
        if let ps = value.flowObject {
            if let required = o["required"]?.flowArray, required.contains(where: { ps[$0.flowString!] == nil }) { return false }
            let props = o["properties"]?.flowObject ?? [:]
            for (key, v) in ps { if let s = props[key] { if !matches(v, schema: s) { return false } } else if let a = o["additionalProperties"], !matches(v, schema: a) { return false } }
        }
        if let s = value.flowString {
            let n = s.unicodeScalars.count
            if let min = o["minLength"]?.flowInt, n < min { return false }; if let max = o["maxLength"]?.flowInt, n > max { return false }
            if o["format"] == .string("email"), !FlowCheck.matches(s, "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$") { return false }
        }
        if let n = value.flowInt { if let min = o["minimum"]?.flowInt, n < min { return false }; if let max = o["maximum"]?.flowInt, n > max { return false } }
        if let a = value.flowArray, let s = o["items"], !a.allSatisfy({ matches($0, schema: s) }) { return false }
        if let a = o["allOf"]?.flowArray, !a.allSatisfy({ matches(value, schema: $0) }) { return false }
        if let a = o["anyOf"]?.flowArray, !a.contains(where: { matches(value, schema: $0) }) { return false }
        if let s = o["not"], matches(value, schema: s) { return false }
        return true
    }
}

extension FlowDefinition {
    private static var catalogLimits: JSONValue { .object(["maxSteps": .int(1000), "activeTimeoutMs": .int(30000), "maxElapsedMs": .int(86400000), "memoryBytes": .int(67108864), "nodeTimeoutMs": .int(5000), "maxStateBytes": .int(1048576)]) }
    public static let builtinIDs = ["core.set-fields", "core.rename-fields", "core.mail", "core.webhook"]
    private static var builtinModule: JSONValue { .object([
        "contractVersion": .string("0.1.0"), "proposalStatus": .string("VORGESCHLAGEN"), "id": .string("core"), "version": .string("1.0.0"),
        "title": .object(["de": .string("Kernbausteine")]), "owner": .string("form-backend"), "engineContractVersion": .string("0.1.0"),
        "configSchema": .object(["type": .string("object"), "additionalProperties": .bool(false)]), "permissions": .array([.string("flow.execute")]),
        "dependencies": .array([]), "blocks": .array(builtinIDs.map { .object(["id": .string($0), "version": .string("1.0.0")]) }),
        "activation": .object(["installed": .bool(true), "serverAvailable": .bool(true), "tenantEnabled": .bool(true), "formEnabled": .bool(true), "onDisable": .string("pause")]), "health": .object(["state": .string("healthy")])
    ]) }
    public static var builtinModules: [Data] { [JCS.canonicalize(builtinModule)] }
    public static var builtinBlocks: [Data] { builtinIDs.map { JCS.canonicalize(builtinBlock($0)) } }
    public static func builtinReference(id: String) throws -> JSONValue {
        guard builtinIDs.contains(id) else { throw FlowError.unsupportedCapability }
        return .object(["id": .string(id), "version": .string("1.0.0"), "sha256": .string(FlowCheck.digest(builtinBlock(id)))])
    }
    private static func builtinBlock(_ id: String) -> JSONValue {
        let effect = id == "core.mail" ? "mail" : (id == "core.webhook" ? "webhook" : "none")
        let config: JSONValue
        if id == "core.set-fields" { config = .object(["type": .string("object"), "properties": .object(["values": .object(["type": .string("object")])]), "required": .array([.string("values")]), "additionalProperties": .bool(false)]) }
        else if id == "core.rename-fields" { config = .object(["type": .string("object"), "properties": .object(["mapping": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")])])]), "required": .array([.string("mapping")]), "additionalProperties": .bool(false)]) }
        else { config = .object(["type": .string("object"), "additionalProperties": .bool(false)]) }
        return .object([
            "contractVersion": .string("0.1.0"), "proposalStatus": .string("VORGESCHLAGEN"), "id": .string(id), "version": .string("1.0.0"),
            "module": .object(["id": .string("core"), "version": .string("1.0.0"), "sha256": .string(FlowCheck.digest(builtinModule))]),
            "title": .object(["de": .string(id)]), "inputSchema": .object(["type": .string("object")]), "outputSchema": .object(["type": .string("object")]),
            "configSchema": config, "locations": .array([.string("backend-worker")]), "permissions": .array([.string("flow.execute")]), "connections": .array([]),
            "plaintext": .object(["required": .bool(true), "allowedLocations": .array([.string("backend-worker")]), "persistence": .string("forbidden")]),
            "limits": catalogLimits, "effectKind": .string(effect), "idempotency": .string(effect == "mail" ? "manual-on-uncertain" : (effect == "webhook" ? "receiver-key" : "pure")),
            "retry": .object(["mode": .string("never"), "maxAttempts": .int(1), "initialDelayMs": .int(0), "maxDelayMs": .int(0), "backoffFactor": .int(1), "jitter": .bool(false)]),
            "debug": .object(["valuePolicy": .string("masked-only"), "sensitiveInputPointers": .array([]), "sensitiveOutputPointers": .array([])])
        ])
    }
}
