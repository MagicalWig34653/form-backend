// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormCore

/// This value contains plaintext: persistence must encrypt its canonical JSON first.
public struct FlowState: Equatable, Sendable {
    public var nodeID: String
    public var fields: [String: JSONValue]
    public var outputs: [String: JSONValue]
    public var steps: Int
    public init(nodeID: String, fields: [String: JSONValue], outputs: [String: JSONValue] = [:], steps: Int = 0) {
        self.nodeID = nodeID; self.fields = fields; self.outputs = outputs; self.steps = steps
    }
    public var json: JSONValue { .object(["nodeID": .string(nodeID), "fields": .object(fields), "outputs": .object(outputs), "steps": .int(Int64(steps))]) }
    public init(json: JSONValue) throws {
        let o = try FlowCheck.object(json, keys: ["nodeID", "fields", "outputs", "steps"])
        guard let node = o["nodeID"]?.flowString, FlowCheck.identifier(node), let f = o["fields"]?.flowObject, let outputs = o["outputs"]?.flowObject,
              let steps = o["steps"]?.flowInt, steps >= 0 else { throw FlowError.invalidState }
        self.init(nodeID: node, fields: f, outputs: outputs, steps: steps)
    }
}

public enum FlowStep: Equatable, Sendable {
    case next(FlowState)
    case effect(kind: String, nodeID: String, input: JSONValue, config: JSONValue, next: FlowState)
    case waiting(kind: String, durationMs: Int, next: FlowState)
    case end(result: String, state: FlowState)
}

public enum FlowInterpreter {
    public static func step(definition: FlowDefinition, state: FlowState) throws -> FlowStep {
        guard state.steps >= 0, state.steps < definition.limits.maxSteps,
              JCS.canonicalize(state.json).count <= min(definition.limits.maxStateBytes, definition.limits.memoryBytes) else { throw FlowError.budgetExceeded }
        guard let n = definition.nodes[state.nodeID]?.flowObject, let kind = n["kind"]?.flowString else { throw FlowError.invalidState }
        var next = state; next.steps += 1
        func advance(_ port: String) throws -> FlowState {
            guard let target = definition.edges[state.nodeID]?[port] else { throw FlowError.invalidDefinition }
            var result = next; result.nodeID = target
            guard JCS.canonicalize(result.json).count <= min(definition.limits.maxStateBytes, definition.limits.memoryBytes) else { throw FlowError.budgetExceeded }; return result
        }
        switch kind {
        case "entry": next.outputs[state.nodeID] = .object(state.fields); return .next(try advance("next"))
        case "end": return .end(result: n["result"]!.flowString!, state: next)
        case "condition": return .next(try advance(FlowPredicate.matches(.object(state.fields), schema: n["predicate"]!) ? "true" : "false"))
        case "wait": return .waiting(kind: "timer", durationMs: n["durationMs"]!.flowInt!, next: try advance("resume"))
        case "approval": return .waiting(kind: "approval", durationMs: n["timeoutMs"]!.flowInt!, next: try advance("approved"))
        case "block":
            let ref = n["block"]!.flowObject!, id = ref["id"]!.flowString!
            guard let block = definition.blockDefinitions[FlowCheck.key(ref)]?.flowObject else { throw FlowError.invalidDefinition }
            var inputs: [String: JSONValue] = [:]
            for (key, b) in n["inputBindings"]!.flowObject! {
                let binding = b.flowObject!
                guard let output = state.outputs[binding["sourceNode"]!.flowString!], let value = resolve(output, pointer: binding["pointer"]!.flowString!) else { throw FlowError.missingInput }
                inputs[key] = value
            }
            let input = JSONValue.object(inputs), config = n["config"]!
            try FlowPredicate.check(input, schema: block["inputSchema"]!)
            switch id {
            case "core.set-fields":
                for (key, value) in config.flowObject!["values"]!.flowObject! { next.fields[key] = value }
                next.outputs[state.nodeID] = .object(next.fields)
            case "core.rename-fields":
                let mapping = config.flowObject!["mapping"]!.flowObject!
                let targets = mapping.values.compactMap(\.flowString)
                guard Set(targets).count == mapping.count else { throw FlowError.invalidState }
                // All sources are read from the same snapshot; order of JSON properties is irrelevant.
                var changed = state.fields
                for source in mapping.keys { guard state.fields[source] != nil else { throw FlowError.missingInput }; changed.removeValue(forKey: source) }
                for source in mapping.keys.sorted() {
                    let target = mapping[source]!.flowString!
                    guard changed[target] == nil else { throw FlowError.invalidState }; changed[target] = state.fields[source]
                }
                next.fields = changed; next.outputs[state.nodeID] = .object(changed)
            case "synthetic-validate": next.outputs[state.nodeID] = .object(["valid": .bool(true)]); next.fields["valid"] = .bool(true)
            case "core.mail", "synthetic-mail", "core.webhook":
                // Effect ledger/transport owns acknowledgement. This pure function never sends.
                return .effect(kind: id.contains("mail") ? "mail" : "webhook", nodeID: state.nodeID, input: input, config: config, next: try advance("next"))
            default: throw FlowError.unsupportedCapability
            }
            try FlowPredicate.check(next.outputs[state.nodeID]!, schema: block["outputSchema"]!)
            return .next(try advance("next"))
        default: throw FlowError.unsupportedCapability
        }
    }

    private static func resolve(_ value: JSONValue, pointer: String) -> JSONValue? {
        if pointer.isEmpty { return value }
        var current = value
        for token in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let o = current.flowObject, let v = o[key] { current = v }
            else if let a = current.flowArray, let index = Int(key), String(index) == key, a.indices.contains(index) { current = a[index] }
            else { return nil }
        }
        return current
    }
}
