// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import FormCore
@testable import FormFlow

final class FlowInterpreterTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("contracts/flow/examples/\(name).json"))
    }
    private func graph(nodes: [String: JSONValue], edges: [(String, String, String)]) -> JSONValue {
        .object(["contractVersion": .string("0.1.0"), "proposalStatus": .string("VORGESCHLAGEN"), "id": .string("11111111-1111-4111-8111-111111111111"), "version": .string("1.0.0"), "engineContractVersion": .string("0.1.0"), "entryNode": .string("entry"), "limits": .object(["maxSteps": .int(100), "activeTimeoutMs": .int(1000), "maxElapsedMs": .int(10000), "memoryBytes": .int(1048576), "nodeTimeoutMs": .int(1000), "maxStateBytes": .int(1048576)]), "nodes": .object(nodes), "edges": .array(edges.map { .object(["from": .string($0.0), "port": .string($0.1), "to": .string($0.2)]) }), "failurePolicy": .string("stop-and-record")])
    }
    private func node(_ kind: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(extra.merging(["kind": .string(kind), "label": .object(["de": .string(kind)])]) { _, b in b })
    }
    private func block(_ id: String, config: JSONValue) throws -> JSONValue {
        node("block", ["block": try FlowDefinition.builtinReference(id: id), "location": .string("backend-worker"), "config": config, "inputBindings": .object([:])])
    }
    private func load(_ value: JSONValue) throws -> FlowDefinition {
        try FlowDefinition.load(graph: JCS.canonicalize(value), blocks: FlowDefinition.builtinBlocks, modules: FlowDefinition.builtinModules)
    }
    func testContractMailExampleProducesEffectWithoutSending() throws {
        let d = try FlowDefinition.load(graph: fixture("mail-graph"), blocks: [fixture("mail-block")], modules: [fixture("module")])
        let initial = FlowState(nodeID: d.entryNode, fields: ["email": .string("synthetic@example.invalid")])
        guard case .next(let started) = try FlowInterpreter.step(definition: d, state: initial),
              case .effect(let kind, let node, let input, _, let next) = try FlowInterpreter.step(definition: d, state: started) else { return XCTFail("Expected mail effect") }
        XCTAssertEqual(kind, "mail"); XCTAssertEqual(node, "synthetic-mail-node")
        XCTAssertEqual(input, .object(initial.fields)); XCTAssertEqual(next.nodeID, "end")
        XCTAssertEqual(try FlowState(json: next.json), next)
        XCTAssertEqual(try FlowInterpreter.step(definition: d, state: next), .end(result: "success", state: FlowState(nodeID: "end", fields: initial.fields, outputs: started.outputs, steps: 3)))
    }
    func testScriptGraphRejectedAndSimpleSubflowFixtureAccepted() throws {
        XCTAssertThrowsError(try FlowDefinition.load(graph: fixture("graph"), blocks: [fixture("block")], modules: [fixture("module")]))
        XCTAssertEqual(try FlowDefinition.load(graph: fixture("subflow")).entryNode, "entry")
    }
    func testDeterministicRenameAndCondition() throws {
        let g = graph(nodes: [
            "entry": node("entry"),
            "set": try block("core.set-fields", config: .object(["values": .object(["status": .string("ok")])])),
            "rename": try block("core.rename-fields", config: .object(["mapping": .object(["first": .string("second"), "second": .string("first")])])),
            "condition": node("condition", ["predicate": .object(["type": .string("object"), "properties": .object(["status": .object(["const": .string("ok")])]), "required": .array([.string("status")])])]),
            "yes": node("end", ["result": .string("success")]), "no": node("end", ["result": .string("rejected")])
        ], edges: [("entry", "next", "set"), ("set", "next", "rename"), ("rename", "next", "condition"), ("condition", "true", "yes"), ("condition", "false", "no")])
        let d = try load(g)
        var s = FlowState(nodeID: "entry", fields: ["first": .int(1), "second": .int(2)])
        for _ in 0..<4 { let a = try FlowInterpreter.step(definition: d, state: s); XCTAssertEqual(a, try FlowInterpreter.step(definition: d, state: s)); guard case .next(let n) = a else { return XCTFail("Expected next") }; s = n }
        XCTAssertEqual(s.nodeID, "yes"); XCTAssertEqual(s.fields["first"], .int(2)); XCTAssertEqual(s.fields["second"], .int(1))
    }
    func testWaitAndApprovalReturnSuspensionOnly() throws {
        let d = try load(graph(nodes: ["entry": node("entry"), "wait": node("wait", ["durationMs": .int(1000), "onTimeout": .string("fail")]), "approval": node("approval", ["permission": .string("flow.approve"), "timeoutMs": .int(1000), "onTimeout": .string("reject"), "requireHuman": .bool(true)]), "end": node("end", ["result": .string("success")]), "reject": node("end", ["result": .string("rejected")])], edges: [("entry", "next", "wait"), ("wait", "resume", "approval"), ("approval", "approved", "end"), ("approval", "rejected", "reject")]))
        guard case .waiting(let kind, let duration, let next) = try FlowInterpreter.step(definition: d, state: FlowState(nodeID: "wait", fields: [:])) else { return XCTFail("Expected timer suspension") }
        XCTAssertEqual(kind, "timer"); XCTAssertEqual(duration, 1000); XCTAssertEqual(next.nodeID, "approval")
        guard case .waiting(let approval, _, _) = try FlowInterpreter.step(definition: d, state: next) else { return XCTFail("Expected approval suspension") }; XCTAssertEqual(approval, "approval")
    }
    func testInvalidDefinitionsAndBudgetsFailClosed() throws {
        let end = node("end", ["result": .string("success")])
        let good = graph(nodes: ["entry": node("entry"), "end": end], edges: [("entry", "next", "end")])
        let d = try load(good)
        XCTAssertThrowsError(try FlowInterpreter.step(definition: d, state: FlowState(nodeID: "entry", fields: [:], steps: 100)))
        XCTAssertThrowsError(try FlowInterpreter.step(definition: d, state: FlowState(nodeID: "entry", fields: ["large": .string(String(repeating: "x", count: 1048576))])))
        XCTAssertThrowsError(try load(graph(nodes: ["entry": node("entry"), "end": end], edges: [("entry", "next", "end"), ("entry", "next", "entry")])))
        XCTAssertThrowsError(try load(graph(nodes: ["entry": node("entry"), "end": end], edges: [("entry", "next", "missing")])))
        XCTAssertThrowsError(try load(graph(nodes: ["entry": node("entry"), "route": node("condition", ["predicate": .object(["$ref": .string("https://example.invalid/schema")])]), "end": end], edges: [("entry", "next", "route"), ("route", "true", "end"), ("route", "false", "end")])))
        XCTAssertThrowsError(try FlowDefinition.load(graph: Data("{\"id\":1,\"id\":2}".utf8)))
    }
    func testTamperedBlockReferenceIsRejected() throws {
        var b = try block("core.mail", config: .object([:])).flowObject!
        b["block"] = .object(["id": .string("core.mail"), "version": .string("1.0.0"), "sha256": .string(String(repeating: "0", count: 64))])
        XCTAssertThrowsError(try load(graph(nodes: ["entry": node("entry"), "mail": .object(b), "end": node("end", ["result": .string("success")])], edges: [("entry", "next", "mail"), ("mail", "next", "end")])))
    }
}
