// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormPersistence
import Foundation
import SQLKit

/// Only engine metadata crosses this boundary. There is deliberately no arbitrary JSON/value/message parameter.
public struct FlowDebugEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case nodeStarted = "node-started", nodeFinished = "node-finished", validation, branch, suspended, resumed, failed, fieldChanged = "field-changed" }
    public enum Status: String, Codable, Sendable { case running, success, rejected, waiting, failed }
    public struct Reference: Codable, Sendable {
        public let id: String, version: String, sha256: String
        public init(id: UUID, version: String, sha256: String) { self.id = id.uuidString.lowercased(); self.version = version; self.sha256 = sha256 }
    }
    public struct Mask: Codable, Sendable {
        public let fieldId: String, pointer: String
        public let display = "[MASKIERT]", reason = "default-deny"
        enum CodingKeys: String, CodingKey { case fieldId, pointer, display, reason }
        public init(fieldId: String) { self.fieldId = fieldId; self.pointer = "/" + fieldId.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
    }
    public let contractVersion = "0.1.0", proposalStatus = "VORGESCHLAGEN", ttlSeconds = 900, exportPolicy = "masked-only"
    public let eventId: String, tenantId: String, form: Reference, release: Reference, executionId: String, debugSessionId: String
    public let sequence: Int, mode: String, effectMode: String, occurredAt: String, recordingStartedAt: String, expiresAt: String
    public let event: Kind, nodeId: String, visit: Int, status: Status
    public let input: [Mask], output: [Mask], changedFieldIds: [String], validationCodes: [String], recipientAliases: [String], keyIds: [String]
    public let encryptionState = "ephemeral-plaintext"
    enum CodingKeys: String, CodingKey {
        case contractVersion, proposalStatus, ttlSeconds, exportPolicy, eventId, tenantId, form, release, executionId, debugSessionId
        case sequence, mode, effectMode, occurredAt, recordingStartedAt, expiresAt, event, nodeId, visit, status
        case input, output, changedFieldIds, validationCodes, recipientAliases, keyIds, encryptionState
    }

    public init(tenant: UUID, form: Reference, release: Reference, execution: UUID, session: UUID, sequence: Int, mode: String, started: Date, at: Date, kind: Kind, node: String, visit: Int, status: Status, inputFieldIDs: [String] = [], outputFieldIDs: [String] = []) throws {
        guard ["test", "observe"].contains(mode), sequence > 0, visit > 0,
              Self.validID(node), (inputFieldIDs + outputFieldIDs).allSatisfy(Self.validID),
              at >= started, at < started.addingTimeInterval(900),
              [form, release].allSatisfy({ $0.version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil && $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { throw FlowDebugError.invalidMetadata }
        let iso = ISO8601DateFormatter()
        self.eventId = UUID().uuidString.lowercased(); self.tenantId = tenant.uuidString.lowercased(); self.form = form; self.release = release; self.executionId = execution.uuidString.lowercased(); self.debugSessionId = session.uuidString.lowercased()
        self.sequence = sequence; self.mode = mode; self.effectMode = mode == "observe" ? "observe-only" : "simulate"
        self.occurredAt = iso.string(from: at); self.recordingStartedAt = iso.string(from: started); self.expiresAt = iso.string(from: started.addingTimeInterval(900))
        self.event = kind; self.nodeId = node; self.visit = visit; self.status = status
        self.input = Array(Set(inputFieldIDs)).sorted().map(Mask.init); self.output = Array(Set(outputFieldIDs)).sorted().map(Mask.init)
        self.changedFieldIds = kind == .fieldChanged ? Array(Set(outputFieldIDs)).sorted() : []
        self.validationCodes = []; self.recipientAliases = []; self.keyIds = []
    }
    private static func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil }
}
public enum FlowDebugError: Error { case invalidMetadata, missing, expired, conflict }

public struct FlowDebugStore {
    let db: Database
    public init(db: Database) { self.db = db }
    private struct Row: Decodable { let state: String; let expires_at: Date; let recording_started_at: Date?; let mode: String }
    public struct Snapshot: Encodable {
        public let id: String, expiresAt: String, status: String
        public let events: [FlowDebugEvent]
    }
    /// Called inside the same engine transaction as its checkpoint; locks prevent duplicated sequence numbers.
    public static func record(on sql: SQLDatabase, tenant: UUID, form: UUID, release: UUID, submission: UUID, execution: UUID,
                              formRef: FlowDebugEvent.Reference, releaseRef: FlowDebugEvent.Reference, kind: FlowDebugEvent.Kind,
                              node: String, visit: Int, status: FlowDebugEvent.Status, inputFieldIDs: [String] = [], outputFieldIDs: [String] = [], now: Date) async throws {
        struct R: Decodable { let id: Blob; let mode: String; let recording_started_at: Date? }
        let sessions = try await sql.raw("""
            SELECT id, mode, recording_started_at FROM debug_requests WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))
            AND release_id = \(bind: DB.bin(release)) AND mode = 'observe' AND expires_at > \(bind: DB.time(now))
            AND (state = 'waiting' OR (state = 'recording' AND submission_id = \(bind: DB.bin(submission)))) ORDER BY id LIMIT 20 FOR UPDATE
            """).all(decoding: R.self)
        for s in sessions {
            guard let id = DB.uuid(s.id.data) else { continue }
            let start = s.recording_started_at ?? now
            if s.recording_started_at == nil {
                try await sql.raw("UPDATE debug_requests SET state = 'recording', recording_started_at = \(bind: DB.time(start)), expires_at = \(bind: DB.time(start.addingTimeInterval(900))), submission_id = \(bind: DB.bin(submission)) WHERE id = \(bind: s.id)").run()
            }
            struct C: Decodable { let n: Int }
            let n = try await sql.raw("SELECT COALESCE(MAX(sequence_no),0) + 1 AS n FROM debug_events WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND debug_request_id = \(bind: s.id)").first(decoding: C.self)?.n ?? 1
            // Bound tracing independently of workflow budgets.
            guard n <= 10000 else { continue }
            let event = try FlowDebugEvent(tenant: tenant, form: formRef, release: releaseRef, execution: execution, session: id, sequence: n, mode: s.mode, started: start, at: now, kind: kind, node: node, visit: visit, status: status, inputFieldIDs: inputFieldIDs, outputFieldIDs: outputFieldIDs)
            let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            try await sql.raw("INSERT INTO debug_events (customer_id, form_id, debug_request_id, sequence_no, occurred_at, masked_event_json, expires_at) VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(form)), \(bind: s.id), \(bind: n), \(bind: DB.time(now)), \(bind: json), \(bind: DB.time(start.addingTimeInterval(900))))").run()
        }
    }
    public func snapshot(tenant: UUID, form: UUID, id: UUID, now: Date) async throws -> Snapshot {
        let sql = db as! SQLDatabase
        guard let row = try await sql.raw("SELECT state, expires_at, recording_started_at, mode FROM debug_requests WHERE id = \(bind: DB.bin(id)) AND customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form))").first(decoding: Row.self) else { throw FlowDebugError.missing }
        guard row.expires_at > now, row.state != "expired" else { throw FlowDebugError.expired }
        struct E: Decodable { let masked_event_json: String }
        let rows = try await sql.raw("SELECT masked_event_json FROM debug_events WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(form)) AND debug_request_id = \(bind: DB.bin(id)) AND expires_at > \(bind: DB.time(now)) ORDER BY sequence_no LIMIT 10000").all(decoding: E.self)
        return Snapshot(id: id.uuidString.lowercased(), expiresAt: ISO8601DateFormatter().string(from: row.expires_at), status: row.state, events: try rows.map { try JSONDecoder().decode(FlowDebugEvent.self, from: Data($0.masked_event_json.utf8)) })
    }
    /// No plaintext debug objects are created by this engine. FK links are removed before expired events.
    public func purge(now: Date) async throws {
        try await db.transaction { conn in
            let sql = conn as! SQLDatabase
            try await sql.raw("DELETE o FROM debug_objects o JOIN debug_events e ON e.customer_id = o.customer_id AND e.form_id = o.form_id AND e.debug_request_id = o.debug_request_id AND e.sequence_no = o.sequence_no WHERE e.expires_at <= \(bind: DB.time(now))").run()
            try await sql.raw("DELETE FROM debug_events WHERE expires_at <= \(bind: DB.time(now))").run()
            try await sql.raw("UPDATE debug_requests SET state = 'expired', lease_token = NULL, lease_until = NULL WHERE expires_at <= \(bind: DB.time(now)) AND state != 'cancelled'").run()
        }
    }
}
