// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto
import SQLKit
import Fluent
import FormAuth
import FormCore
import FormCrypto
import FormPersistence
import MySQLNIO

public struct ImportPlan: Codable {
    public var namespace: String
    public var dumpSHA256: String
    public var customers: [String: String]
    public var formCustomers: [String: String]
    public var connectionCustomers: [String: [String]]
    public var keyCustomers: [String:String]
    public var keyGenerationNumbers: [String:Int]
    public var statisticsReview: String?
    public var statisticsPublicKeys: [String: String]
    public init(namespace: String, dumpSHA256: String, customers: [String:String], formCustomers: [String:String], connectionCustomers: [String:[String]] = [:], keyCustomers: [String:String] = [:], keyGenerationNumbers: [String:Int] = [:], statisticsReview: String? = nil, statisticsPublicKeys: [String:String] = [:]) {
        self.namespace = namespace; self.dumpSHA256 = dumpSHA256; self.customers = customers; self.formCustomers = formCustomers
        self.keyCustomers = keyCustomers; self.keyGenerationNumbers = keyGenerationNumbers; self.connectionCustomers = connectionCustomers; self.statisticsReview = statisticsReview; self.statisticsPublicKeys = statisticsPublicKeys
    }
}
extension ImportPlan {
    /// Optional fields fall back to the initializer defaults (the plan of an older caller may lack them); namespace, hash and the customer/form
    /// assignments stay mandatory. Encoding is untouched: the canonical JSON of a plan (part of the source HMAC and run identity, ADR 0014)
    /// is identical whether a field was present or defaulted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(namespace: try c.decode(String.self, forKey: .namespace), dumpSHA256: try c.decode(String.self, forKey: .dumpSHA256),
                  customers: try c.decode([String:String].self, forKey: .customers), formCustomers: try c.decode([String:String].self, forKey: .formCustomers),
                  connectionCustomers: try c.decodeIfPresent([String:[String]].self, forKey: .connectionCustomers) ?? [:],
                  keyCustomers: try c.decodeIfPresent([String:String].self, forKey: .keyCustomers) ?? [:],
                  keyGenerationNumbers: try c.decodeIfPresent([String:Int].self, forKey: .keyGenerationNumbers) ?? [:],
                  statisticsReview: try c.decodeIfPresent(String.self, forKey: .statisticsReview),
                  statisticsPublicKeys: try c.decodeIfPresent([String:String].self, forKey: .statisticsPublicKeys) ?? [:])
    }
    /// Decodes a plan file; a failure names only the top-level key (never a value, never "database").
    public static func decode(_ data: Data) throws -> ImportPlan {
        do { return try JSONDecoder().decode(ImportPlan.self, from: data) }
        catch let error as DecodingError {
            switch error {
            case .keyNotFound(let key, _): throw CLIInputError.planUnreadable(field: safeIdentifier(key.stringValue))
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                if let first = context.codingPath.first { throw CLIInputError.planUnreadable(field: safeIdentifier(first.stringValue)) }
                throw CLIInputError.planUnreadable(field: "kein gültiges JSON")
            @unknown default: throw CLIInputError.planUnreadable(field: "kein gültiges JSON")
            }
        } catch { throw CLIInputError.planUnreadable(field: "kein gültiges JSON") }
    }
}
/// Input problems of the command line (parameters, plan file): named cause, never a value.
public enum CLIInputError: Error, CustomStringConvertible {
    case missing(String), invalid(String, String), planUnreadable(field: String)
    public var description: String {
        switch self {
        case let .missing(name): return "Parameter fehlt: \(name)"
        case let .invalid(name, hint): return "Parameter ungültig: \(name) (\(hint))"
        case let .planUnreadable(field): return "Plan nicht lesbar: \(field)"
        }
    }
}
/// Stop request set by the signal handlers of the CLI; the importer's checkpoint turns it into `interrupted` at an object boundary.
public final class StopRequest: @unchecked Sendable {
    private let lock = NSLock(); private var received: Int32 = 0
    public init() {}
    public func request(_ signal: Int32) { lock.lock(); if received == 0 { received = signal }; lock.unlock() }
    public var signal: Int32 { lock.lock(); defer { lock.unlock() }; return received }
    public func check() throws { if signal != 0 { throw ImportFailure.interrupted } }
}
public enum SourceFailureReason: String, Sendable {
    case missingColumn, missingValue, invalidHex, invalidUTF8, invalidUUID, invalidIdentifier, invalidCursor, invalidProjection, invalidInteger, invalidBoolean, invalidTimestamp, countMismatch, unknownKeyGeneration
}

public enum ImportFailure: Error, CustomStringConvertible {
    case invalidPlan, conflict, missingTarget, database, interrupted, lock, invalidSource
    /// The namespace already holds an import of another snapshot (ADR 0043: one snapshot, no delta); nothing is written.
    case snapshotChanged
    /// The legacy data changed since the rehearsal (source fingerprint differs from the expected one); nothing is written.
    case sourceChanged
    /// The legacy data changed while the import was running (fingerprint at the end differs from the one at the start); the run is failed.
    case sourceNotQuiesced
    /// The plan contradicts itself or the run parameters; names the field (never a value).
    case invalidPlanField(String)
    /// Statistics row, plan without approval (statisticsReview): review case, nothing statistical is written.
    case statisticsReviewMissing
    /// Statistics row, public key of the plan is missing or no key generation of the customer: review case, nothing statistical is written.
    case statisticsKeyUnknown
    case invalidSourceAt(table: String, column: String, reason: SourceFailureReason)
    /// Driver error of the target with its safe metadata only (server error number, SQLSTATE, name of the index/column/constraint).
    /// Never the message itself: it can contain the value that was written.
    case databaseAt(table: String, code: Int, sqlState: String, object: String)
    /// The target already holds key generations of the customer that contradict the plan (checked before anything is written).
    case keyConflict(KeyConflict)
    /// The target already holds active or released forms (ADR 0014): nothing is written. The ids (never names) go to the log only.
    case targetFormsLive(ids: [String])
    /// A customer of the plan exists in the target under another name: nothing is written. The ids go to the log only.
    case customerNameMismatch(ids: [String])
    /// The target's max_allowed_packet cannot carry the largest cell of the source (finding 15C5D5E9): checked before anything is written.
    /// Byte counts only, never content.
    case targetPacketTooSmall(limit: Int, largest: Int)

    public var description: String {
        switch self {
        case let .invalidSourceAt(table, column, reason):
            // Metadata is untrusted too: never print an arbitrary identifier or a source value.
            return "migration: invalidSource table=\(safeIdentifier(table)) column=\(safeIdentifier(column)) reason=\(reason.rawValue)"
        case .invalidPlan: return "migration: invalidPlan"
        case let .invalidPlanField(field): return "migration: invalidPlan field=\(safeIdentifier(field))"
        case .statisticsReviewMissing: return "migration: statisticsReviewMissing"
        case .statisticsKeyUnknown: return "migration: statisticsKeyUnknown"
        case .conflict: return "migration: conflict"
        case .missingTarget: return "migration: missingTarget"
        case .database: return "migration: database"
        case let .databaseAt(table, code, sqlState, object):
            return "migration: database table=\(safeIdentifier(table)) code=\(code) sqlstate=\(sqlState) object=\(object.isEmpty ? "-" : safeIdentifier(object))"
        case let .keyConflict(reason): return "migration: keyConflict reason=\(reason.rawValue)"
        case let .targetFormsLive(ids): return "migration: targetFormsLive count=\(ids.count) forms=\(ids.prefix(10).joined(separator: ","))"
        case let .customerNameMismatch(ids): return "migration: customerNameMismatch count=\(ids.count) customers=\(ids.prefix(10).joined(separator: ","))"
        case let .targetPacketTooSmall(limit, largest): return "migration: targetPacketTooSmall limit=\(limit) largestCell=\(largest)"
        case .snapshotChanged: return "migration: snapshotChanged"
        case .sourceChanged: return "migration: sourceChanged"
        case .sourceNotQuiesced: return "migration: sourceNotQuiesced"
        case .interrupted: return "migration: interrupted"
        case .lock: return "migration: lock"
        case .invalidSource: return "migration: invalidSource"
        }
    }
}

/// Why the key generations of the plan cannot be written next to what the target holds.
public enum KeyConflict: String, Sendable {
    /// The target customer already has an active generation of another key; the import would be the second active one.
    case active
    /// The target customer already uses this generation number for another key.
    case number
    /// The same key id exists in the target with a different public key.
    case publicKey
    /// The plan itself is contradictory: one generation number twice, or two active keys for one customer.
    case plan
}

/// Reads the safe metadata out of a target driver error. The server message can contain the written value
/// ("Duplicate entry '<value>' for key 'name'"), so only identifiers that pass `safeIdentifier` are taken from it.
enum DatabaseDiagnostics {
    static func classify(_ error: Error) -> (code: Int, sqlState: String, object: String)? {
        // The driver reports unique-key violations as their own case (message only, no packet): number 1062, SQLSTATE 23000.
        if let mysql = error as? MySQLError, case let .duplicateEntry(message) = mysql { return (1062, "23000", object(message: message)) }
        guard let mysql = error as? MySQLError, case let .server(packet) = mysql else { return nil }
        let state = (packet.sqlState ?? "").utf8.count == 5 && (packet.sqlState ?? "").utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) ? packet.sqlState! : ""
        return (Int(packet.errorCode.rawValue), state, object(message: packet.errorMessage))
    }
    static func object(message: String) -> String {
        func identifier(after marker: String, in text: String, backwards: Bool) -> String? {
            guard let range = text.range(of: marker, options: backwards ? .backwards : []) else { return nil }
            let rest = text[range.upperBound...]
            guard let open = rest.first, "'`".contains(open), let close = rest.dropFirst().firstIndex(of: open) else { return nil }
            let name = String(rest[rest.index(after: rest.startIndex)..<close]).split(separator: ".").last.map(String.init) ?? ""
            return safeIdentifier(name) == name ? name : nil
        }
        // The value of a duplicate entry sits before " for key": take the last marker, which cannot be part of the value's tail.
        if message.hasPrefix("Duplicate entry"), let name = identifier(after: " for key ", in: message, backwards: true), message.hasSuffix("'") { return name }
        if message.hasPrefix("Column "), let name = identifier(after: "Column ", in: message, backwards: false) { return name }
        if message.hasPrefix("Data too long"), let name = identifier(after: "for column ", in: message, backwards: false) { return name }
        if message.contains("CONSTRAINT "), let name = identifier(after: "CONSTRAINT ", in: message, backwards: false) { return name }
        if message.contains("for column "), let name = identifier(after: "for column ", in: message, backwards: true) { return name }
        return ""
    }
}

private func safeIdentifier(_ s: String) -> String {
    !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
    } ? s : "<identifier>"
}
public struct TableParity: Codable {
    public var sourceCount = 0, importedCount = 0, reviewCount = 0
    public var sourceHMAC = "", targetHMAC = ""
}
/// What the default retention period would do to the imported submissions (QA 13.11.): they stay WITHOUT a due date.
public struct RetentionReport: Codable, Equatable {
    public var defaultDays = Retention.defaultDays
    /// Imported submissions (all stay without a due date until the operator sets a period and confirms).
    public var importedWithoutDeadline = 0
    /// Of those, how many would be due at once under the default period (received_at + defaultDays <= now).
    public var dueNowAtDefault = 0
}
public struct ImportReport: Codable {
    public var retention: RetentionReport?
    public var tables: [String:TableParity] = [:]
    public var inventory: [String:Int] = [:]
    public var schemaHMAC = ""
    public var dryRun: Bool
    /// SHA-256 over table name, CHECKSUM TABLE and row count of every source table (no values). Set by the rehearsal and the real run.
    public var sourceFingerprint = ""
    public var cutoverReady = false
}
// All values are encoded as hex SQL literals; identifiers are validated separately.
func query(_ s: String) -> SQLQueryString { SQLQueryString(s) }
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) throws -> Data {
    guard s.count % 2 == 0 else { throw ImportFailure.invalidSource }
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); guard let b = UInt8(s[i..<j], radix:16) else { throw ImportFailure.invalidSource }; d.append(b); i = j }
    return d
}
func val(_ s: String?) -> String { s.map { "CONVERT(X'\(hex(Data($0.utf8)))' USING utf8mb4)" } ?? "NULL" }
func bin(_ d: Data) -> String { "X'\(hex(d))'" }
func uid(_ s: String, table: String = "plan", column: String = "uuid") throws -> String {
    guard let u = UUID(uuidString:s) else { throw ImportFailure.invalidSourceAt(table:table,column:column,reason:.invalidUUID) }
    return bin(DB.bin(u).data)
}
func ident(_ s: String) throws -> String {
    guard !s.isEmpty, s.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { throw ImportFailure.invalidSourceAt(table:"schema",column:s,reason:.invalidIdentifier) }
    return "`\(s)`"
}
func json<T: Encodable>(_ v: T) throws -> String { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return String(decoding: try e.encode(v), as: UTF8.self) }
struct TextRow: Decodable { var v: String }
struct LegacyRow {
    var values: [String:String?]
    var table: String = "source"

    static func decode(_ json: String, table: String) throws -> LegacyRow {
        do { return LegacyRow(values:try JSONDecoder().decode([String:String?].self,from:Data(json.utf8)),table:table) }
        catch {
            let column = (error as? DecodingError).flatMap { error -> String? in
                switch error {
                case .typeMismatch(_,let context), .valueNotFound(_,let context), .dataCorrupted(let context): return context.codingPath.first?.stringValue
                case .keyNotFound(let key,_): return key.stringValue
                @unknown default: return nil
                }
            } ?? "projection"
            throw ImportFailure.invalidSourceAt(table:table,column:column,reason:.invalidProjection)
        }
    }
    func bytes(_ k: String) throws -> Data? {
        guard let value = values[k] else { throw ImportFailure.invalidSourceAt(table:table,column:k,reason:.missingColumn) }
        guard let h = value else { return nil }
        do { return try unhex(h) }
        catch { throw ImportFailure.invalidSourceAt(table:table,column:k,reason:.invalidHex) }
    }
    func text(_ k: String) throws -> String? {
        guard let d = try bytes(k) else { return nil }
        guard let t = String(data:d, encoding:.utf8) else { throw ImportFailure.invalidSourceAt(table:table,column:k,reason:.invalidUTF8) }
        return t
    }
    func required(_ k: String) throws -> String {
        guard let s = try text(k) else { throw ImportFailure.invalidSourceAt(table:table,column:k,reason:.missingValue) }
        return s
    }
    func uuid(_ k: String) throws -> String { try uid(required(k),table:table,column:k) }
}

struct Destination: Codable {
    var table: String, predicate: String
    enum CodingKeys: String, CodingKey { case table = "t", predicate = "p" }
}

/// Offline staging only. Source session is a consistent READ ONLY transaction; target objects and ledger commit together.
public struct LegacyImporter {
    public let source: SQLDatabase, target: SQLDatabase, secrets: SecretStore
    let hmacKey: SymmetricKey
    /// Test seam only: replaces the target's `max_allowed_packet` in the pre-check (a session value cannot be lowered per connection in MariaDB).
    var packetLimitOverride: Int?
    public init(source: SQLDatabase, target: SQLDatabase, secrets: SecretStore, hmacKey: Data) throws {
        guard hmacKey.count == 32 else { throw ImportFailure.invalidPlan }
        self.source = source; self.target = target; self.secrets = secrets; self.hmacKey = SymmetricKey(data:hmacKey)
    }
    func mac(_ s: String) -> String { hex(Data(HMAC<SHA256>.authenticationCode(for:Data(s.utf8), using:hmacKey))) }
    func exec(_ db: SQLDatabase, _ q: String) async throws { try await db.raw(query(q)).run() }
    func scalar(_ db: SQLDatabase, _ q: String) async throws -> String? { try await db.raw(query(q)).first(decoding:TextRow.self)?.v }
    func columns(_ db: SQLDatabase, _ table: String) async throws -> [String] {
        try await db.raw(query("SELECT COLUMN_NAME AS v FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=\(val(table)) ORDER BY ORDINAL_POSITION")).all(decoding:TextRow.self).map(\.v)
    }
    /// How cells larger than `bigCellBytes` are projected. A hex string of a large cell (or the JSON object around it) exceeds
    /// max_allowed_packet (16 MB by default), and MariaDB then returns NULL silently: the value would look absent.
    enum BigCells { case inline, fetchLater, digest }
    static let bigCellBytes = 1_000_000
    func projection(_ cols: [String], uuidColumns: Set<String> = [], big: BigCells = .inline) throws -> String {
        "JSON_OBJECT(" + (try cols.sorted().map {
            let column = try ident($0)
            // HEX(number) is numeric base conversion, not byte encoding. UUIDs must use their
            // textual representation; BINARY/VARBINARY/BLOB must retain every original byte.
            let bytes = uuidColumns.contains($0) ? "CAST(\(column) AS CHAR CHARACTER SET utf8mb4)" : "CAST(\(column) AS BINARY)"
            let hexed = "HEX(\(bytes))"
            switch big {
            case .inline: return "\(val($0)),\(hexed)"
            case .fetchLater: return "\(val($0)),IF(OCTET_LENGTH(\(bytes))>\(Self.bigCellBytes),CONCAT('@',OCTET_LENGTH(\(bytes))),\(hexed))"
            case .digest: return "\(val($0)),IF(OCTET_LENGTH(\(bytes))>\(Self.bigCellBytes),CONCAT('sha256:',SHA2(\(bytes),256)),\(hexed))"
            }
        }).joined(separator:",") + ")"
    }
    func projection(_ db: SQLDatabase, _ table: String, _ cols: [String], big: BigCells = .inline) async throws -> String {
        let uuids = try await db.raw(query("SELECT COLUMN_NAME AS v FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=\(val(table)) AND DATA_TYPE='uuid'")).all(decoding:TextRow.self)
        return try projection(cols,uuidColumns:Set(uuids.map(\.v)),big:big)
    }
    /// Reads the cells the projection left out ("@<byte count>") in chunks of 1 MB and puts their hex into the row.
    func resolveLargeCells(_ src: SQLDatabase, _ table: String, _ row: LegacyRow, keyColumn: String) async throws -> LegacyRow {
        var row = row
        for (column, value) in row.values.sorted(by: { $0.key < $1.key }) {
            guard let value, value.hasPrefix("@"), let length = Int(value.dropFirst()), length > Self.bigCellBytes,
                  let key = try row.text(keyColumn), key.utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
            var hexed = ""; hexed.reserveCapacity(length * 2)
            var offset = 1
            while offset <= length {
                guard let part = try await scalar(src,"SELECT HEX(SUBSTRING(CAST(\(try ident(column)) AS BINARY),\(offset),\(Self.bigCellBytes))) AS v FROM \(try ident(table)) WHERE \(try ident(keyColumn))=\(key)") else {
                    throw ImportFailure.invalidSourceAt(table:table,column:column,reason:.invalidProjection)
                }
                hexed += part; offset += Self.bigCellBytes
            }
            guard hexed.utf8.count == length * 2 else { throw ImportFailure.invalidSourceAt(table:table,column:column,reason:.invalidProjection) }
            row.values[column] = hexed
        }
        return row
    }
    /// Columns the operator may change after the import and that therefore never belong to the ledger evidence (retention_due_at:
    /// set by the operator's explicit retention decision, QA 13.11.). `withMutable` reproduces the older evidence that included them.
    static let mutableColumns: [String:Set<String>] = ["submissions":["retention_due_at"]]
    func snapshot(_ db: SQLDatabase, _ d: Destination, withMutable: Bool = false) async throws -> String {
        let cols = try await columns(db,d.table).filter { withMutable || !(Self.mutableColumns[d.table]?.contains($0) ?? false) }
        let projection = try await projection(db,d.table,cols,big:.digest)
        guard let s = try await scalar(db,"SELECT \(projection) AS v FROM \(try ident(d.table)) WHERE \(d.predicate)") else { throw ImportFailure.missingTarget }
        let obj = try JSONSerialization.jsonObject(with:Data(s.utf8))
        return String(decoding:try JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]),as:UTF8.self)
    }
    /// True when the row still matches its ledger proof. New proofs ignore `mutableColumns`. Proofs written before QA 13.11. also cover
    /// retention_due_at (the old import set received_at + the form period): the row is compared as written back then, i.e. with the
    /// current value, and, when the due date was reset to NULL since (upgrade 0035), with the two values the old import can have
    /// written (default 3 days, current form period). The HMAC proves the match, a wrong candidate can never pass.
    func proofMatches(_ db: SQLDatabase, _ ref: Destination, stored: String, inTransaction: Bool) async throws -> Bool {
        if mac(try await snapshot(db,ref)) == stored { return true }
        guard Self.mutableColumns[ref.table] != nil else { return false }
        if mac(try await snapshot(db,ref,withMutable:true)) == stored { return true }
        guard ref.table == "submissions",
              try await scalar(db,"SELECT '1' AS v FROM \(try ident(ref.table)) WHERE \(ref.predicate) AND retention_due_at IS NULL AND received_at IS NOT NULL") != nil else { return false }
        let current = try await scalar(db,"SELECT CAST(JSON_VALUE(safe_value_json,'$') AS CHAR) AS v FROM settings WHERE setting_key='retention.days' AND scope_key=CONCAT('form:',(SELECT LOWER(CONCAT(SUBSTR(HEX(form_id),1,8),'-',SUBSTR(HEX(form_id),9,4),'-',SUBSTR(HEX(form_id),13,4),'-',SUBSTR(HEX(form_id),17,4),'-',SUBSTR(HEX(form_id),21,12))) FROM submissions WHERE \(ref.predicate)))").flatMap { Int($0) }
        for days in Set([Retention.defaultDays] + (current.map { [$0] } ?? [])).sorted() {
            // Try the candidate inside a rolled-back unit of work: nothing is written.
            try await exec(db, inTransaction ? "SAVEPOINT proof_candidate" : "START TRANSACTION")
            var matched = false
            do {
                try await exec(db,"UPDATE submissions SET retention_due_at=DATE_ADD(received_at,INTERVAL \(days) DAY) WHERE \(ref.predicate)")
                matched = mac(try await snapshot(db,ref,withMutable:true)) == stored
            } catch { try? await exec(db, inTransaction ? "ROLLBACK TO SAVEPOINT proof_candidate" : "ROLLBACK"); throw error }
            try await exec(db, inTransaction ? "ROLLBACK TO SAVEPOINT proof_candidate" : "ROLLBACK")
            if inTransaction { try await exec(db,"RELEASE SAVEPOINT proof_candidate") }
            if matched { return true }
        }
        return false
    }
    func insert(_ db: SQLDatabase, _ table: String, _ values: [String:String], key: [String:String]) async throws -> Destination {
        let cols = values.keys.sorted()
        try await exec(db,"INSERT INTO \(try ident(table)) (\(try cols.map(ident).joined(separator:","))) VALUES (\(cols.map { values[$0]! }.joined(separator:",")))")
        return Destination(table:table,predicate:try key.keys.sorted().map { "\(try ident($0))=\(key[$0]!)" }.joined(separator:" AND "))
    }
    /// Largest byte length of one large cell (blob/text column) of `anfragen`; `store` writes such a cell as one `stored_objects.ciphertext`.
    func largestSubmissionCell(_ src: SQLDatabase) async throws -> Int {
        let cols = try await src.raw(query("SELECT COLUMN_NAME AS v FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='anfragen' AND DATA_TYPE IN ('tinyblob','blob','mediumblob','longblob','tinytext','text','mediumtext','longtext') ORDER BY COLUMN_NAME")).all(decoding:TextRow.self).map(\.v)
        guard !cols.isEmpty else { return 0 }
        let lengths = try cols.map { "IFNULL(MAX(OCTET_LENGTH(\(try ident($0)))),0)" }.joined(separator:",")
        return Int(try await scalar(src,"SELECT CAST(GREATEST(\(lengths)) AS CHAR) AS v FROM anfragen") ?? "0") ?? 0
    }
    /// Effective `max_allowed_packet` of the target connection (a changed global value only reaches connections opened afterwards).
    func targetPacketLimit(_ dst: SQLDatabase) async throws -> Int {
        if let packetLimitOverride { return packetLimitOverride }
        return Int(try await scalar(dst,"SELECT CAST(@@session.max_allowed_packet AS CHAR) AS v") ?? "0") ?? 0
    }
    /// nil when the target can carry the largest cell of the source, otherwise the limit and the cell size in bytes.
    func packetShortfall(_ src: SQLDatabase, _ dst: SQLDatabase) async throws -> (limit: Int, largest: Int)? {
        let largest = try await largestSubmissionCell(src), limit = try await targetPacketLimit(dst)
        return limit > 0 && limit < PacketRequirement.neededBytes(forCell: largest) ? (limit, largest) : nil
    }
    /// Source check (route `POST /migration/test`): the shortfall of the importer's own target, or nil.
    public func packetShortfall() async throws -> (limit: Int, largest: Int)? { try await packetShortfall(source, target) }
    public func inspectSchema() async throws -> String {
        var manifest = ""
        let tables = try await source.raw("SELECT table_name AS v FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY table_name").all(decoding: TextRow.self)
        for table in tables { manifest += try json([table.v: await columns(source, table.v)]) }
        return mac(manifest)
    }
    /// Fingerprint of the whole source schema: SHA-256 over `table:CHECKSUM TABLE:COUNT(*)` of every base table, sorted by name.
    /// Read outside of any snapshot transaction (a fresh read), SELECT is enough. The output is the hash only, never a value.
    public func sourceFingerprint() async throws -> String { try await fingerprint(source) }
    func fingerprint(_ db: SQLDatabase) async throws -> String {
        struct Sum: Decodable { let Checksum: String? }
        do {
            let tables = try await db.raw("SELECT table_name AS v FROM information_schema.tables WHERE table_schema=DATABASE() AND table_type='BASE TABLE' ORDER BY table_name").all(decoding: TextRow.self)
            var lines = ""
            for table in tables {
                let name = try ident(table.v)
                let sum = try await db.raw(query("CHECKSUM TABLE \(name)")).first(decoding: Sum.self)?.Checksum ?? "null"
                let count = try await scalar(db, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM \(name)") ?? "null"
                lines += "\(table.v):\(sum):\(count)\n"
            }
            return hex(Data(SHA256.hash(data: Data(lines.utf8))))
        } catch let failure as ImportFailure { throw failure } catch { throw ImportFailure.invalidSource }
    }
    /// Open review cases of all runs of the namespace (one per table and key), as the admin report counts them.
    public func openCases(namespace: String) async throws -> Int {
        let n = try await scalar(target,"SELECT CAST(COUNT(DISTINCT i.source_table,i.source_key) AS CHAR) AS v FROM migration_issues i JOIN migration_runs r ON r.id=i.run_id WHERE r.source_namespace=\(val(namespace)) AND i.state='open'")
        return Int(n ?? "0") ?? 0
    }
    public func run(plan: ImportPlan, dryRun: Bool = false, batchSize: Int = 100, stopAfter: Int? = nil, expectedSchema: String? = nil, expectedSourceFingerprint: String? = nil, checkpoint: ((String, Int) async throws -> Void)? = nil) async throws -> ImportReport {
        // Named before the first write (ADR 0014: nothing is written for a plan that is wrong in itself).
        guard !plan.namespace.isEmpty, plan.namespace.utf8.count <= 64, plan.namespace.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }) else { throw ImportFailure.invalidPlanField("namespace") }
        guard (try? unhex(plan.dumpSHA256).count) == 32 else { throw ImportFailure.invalidPlanField("dumpSHA256") }
        guard batchSize > 0, batchSize <= 10000 else { throw ImportFailure.invalidPlanField("batchSize") }
        guard plan.customers.keys.allSatisfy({ UUID(uuidString:$0) != nil }) else { throw ImportFailure.invalidPlanField("customers") }
        guard plan.formCustomers.values.allSatisfy({ plan.customers[$0] != nil }) else { throw ImportFailure.invalidPlanField("formCustomers") }
        let identityQuery = "SELECT CONCAT(@@hostname,':',@@port,':',DATABASE()) AS v"
        let sourceIdentity = try await scalar(source,identityQuery), targetIdentity = try await scalar(target,identityQuery)
        guard sourceIdentity != targetIdentity else { throw ImportFailure.invalidPlanField("source=target") }
        return try await target.withSession { dst in
            guard try await scalar(dst,"SELECT CAST(GET_LOCK('form_legacy_import',0) AS CHAR) AS v") == "1" else { throw ImportFailure.lock }
            do {
                if dryRun { try await exec(dst,"START TRANSACTION") }
                let report = try await source.withSession { src in
                    try await exec(src,"SET time_zone='+00:00'")
                    // Fresh read before the snapshot starts (a transaction would show its own frozen state).
                    let startFingerprint = try await fingerprint(src)
                    try await exec(src,"START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY")
                    do { let r = try await perform(src,dst,plan,dryRun,batchSize,stopAfter,expectedSchema,checkpoint,startFingerprint:startFingerprint,expectedFingerprint:expectedSourceFingerprint); try await exec(src,"ROLLBACK"); return r }
                    catch { try? await exec(src,"ROLLBACK"); throw error }
                }
                if dryRun { try await exec(dst,"ROLLBACK") }; try await exec(dst,"SELECT RELEASE_LOCK('form_legacy_import')"); return report
            } catch { try? await exec(dst,"ROLLBACK"); try? await exec(dst,"SELECT RELEASE_LOCK('form_legacy_import')"); throw error }
        }
    }
    func perform(_ src: SQLDatabase, _ dst: SQLDatabase, _ p: ImportPlan, _ dry: Bool, _ batch: Int, _ stop: Int?, _ expectedSchema: String?, _ checkpoint: ((String, Int) async throws -> Void)?, startFingerprint: String, expectedFingerprint: String?) async throws -> ImportReport {
        // Target preconditions, named before anything is written (rehearsal included, no run row is created). Ids only, never names.
        let live = try await dst.raw("SELECT LOWER(HEX(id)) AS v FROM forms WHERE active=1 OR current_release_id IS NOT NULL ORDER BY id LIMIT 50").all(decoding:TextRow.self)
        guard live.isEmpty else { throw ImportFailure.targetFormsLive(ids:live.map(\.v)) }
        // A customer that exists in the target under another name would end the real run as failed (the object is parked as review case
        // while the rehearsal looks green): abort before writing instead. The name is never overwritten.
        var renamed: [String] = []
        for id in p.customers.keys.sorted() {
            if let existing = try await scalar(dst,"SELECT name AS v FROM customers WHERE id=\(try uid(id))"), existing != p.customers[id] { renamed.append(id) }
        }
        guard renamed.isEmpty else { throw ImportFailure.customerNameMismatch(ids:renamed) }
        // The chunked write of a large cell needs a target that can hold the whole cell (see PacketRequirement): named before the first write.
        if let shortfall = try await packetShortfall(src,dst) { throw ImportFailure.targetPacketTooSmall(limit:shortfall.limit,largest:shortfall.largest) }
        let mapping = hex(Data(SHA256.hash(data:Data(try json(p).utf8))))
        let runPredicate = "source_namespace=\(val(p.namespace)) AND dump_sha256=\(bin(try unhex(p.dumpSHA256))) AND mapping_sha256=\(bin(try unhex(mapping))) AND importer_version='p9-1'"
        if !dry {
            // One snapshot per namespace (ADR 0043): another snapshot hash means a delta, which does not exist. Resuming the same snapshot stays possible.
            let other = try await scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_runs WHERE source_namespace=\(val(p.namespace)) AND dump_sha256<>\(bin(try unhex(p.dumpSHA256)))")
            guard (Int(other ?? "0") ?? 0) == 0 else { throw ImportFailure.snapshotChanged }
            // The rehearsal's fingerprint must still be the source's: otherwise the legacy system was written after the check.
            if let expectedFingerprint, expectedFingerprint != startFingerprint { throw ImportFailure.sourceChanged }
        }
        let existing = try await scalar(dst,"SELECT HEX(id) AS v FROM migration_runs WHERE \(runPredicate)")
        let run = try existing.map(unhex) ?? DB.bin(UUID()).data
        let runID = bin(run)
        if !dry && existing == nil {
            _ = try await insert(dst,"migration_runs",["id":runID,"source_namespace":val(p.namespace),"dump_sha256":bin(try unhex(p.dumpSHA256)),"mapping_sha256":bin(try unhex(mapping)),"importer_version":"'p9-1'","state":"'running'","started_at":"UTC_TIMESTAMP(6)","report_json":"'{}'"],key:["id":runID])
        }
        var report = ImportReport(dryRun:dry); report.sourceFingerprint = startFingerprint; var processed = 0; var retention = RetentionReport()
        do { try await keyPreflight(src,dst,p) } catch { if !dry { try? await exec(dst,"UPDATE migration_runs SET state='failed' WHERE id=\(runID)") }; throw error }
        let inventory = try await src.raw("SELECT table_name AS v FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY table_name").all(decoding:TextRow.self)
        var manifest = ""
        for item in inventory {
            let count = try await scalar(src,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM \(try ident(item.v))")
            report.inventory[item.v] = Int(count ?? "0")
            let cols = try await columns(src,item.v)
            manifest += try json([item.v:cols])
        }
        report.schemaHMAC = mac(manifest)
        if let expectedSchema, expectedSchema != report.schemaHMAC {
            if !dry { try await exec(dst,"UPDATE migration_runs SET state='failed' WHERE id=\(runID)") }
            throw ImportFailure.invalidSource
        }
        // Synthetic plan customers are part of the same ledger protocol as source rows.
        for id in p.customers.keys.sorted() {
            let row = LegacyRow(values:["ID":hex(Data(id.utf8)),"name":hex(Data(p.customers[id]!.utf8))])
            _ = try await object(dst,p,runID,"@customers",id,row,dry) { db in
                let customerID = try uid(id)
                if let existing = try await scalar(db, "SELECT name AS v FROM customers WHERE id=\(customerID)") {
                    guard existing == p.customers[id] else { throw ImportFailure.conflict }
                    return [Destination(table: "customers", predicate: "id=\(customerID)")]
                }
                // Active: the customer must be reachable after the import (Kunden list, forms, drafts, entries, key adoption). Nothing
                // is received or sent before the cutover anyway: forms stay inactive and unreleased, connections disabled (ADR 0014).
                return [try await insert(db,"customers",["id":try uid(id),"name":val(p.customers[id]),"state":"'active'","created_at":"'1970-01-01 00:00:00'"],key:["id":try uid(id)])]
            }
        }
        let tables = ["datenschluessel","datenschluesselRecovery","outgoingMailServer","outgoingMailProxy","formulare","formularFelder","anfragen","anfrageIdempotenz","formularWebhooks","statistics"]
        do {
            for table in tables {
                // Recovery envelopes exist only in sources with legacy migration 034; an absent table holds nothing to import.
                if table == "datenschluesselRecovery" && report.inventory[table] == nil { continue }
                try await checkpoint?(table, processed)
                let cols = try await columns(src,table)
                let keyColumn = ["datenschluessel","datenschluesselRecovery"].contains(table) ? "kid":"ID"
                guard cols.contains(keyColumn) else { throw ImportFailure.invalidSourceAt(table:table,column:keyColumn,reason:.missingColumn) }
                let projection = try await projection(src,table,cols,big:.fetchLater)
                var cursor: Int64?; var keyCursor: String?; var parity = TableParity(); var sourceHashes = HMAC<SHA256>(key:hmacKey), targetHashes = HMAC<SHA256>(key:hmacKey)
                while true {
                    let condition = keyColumn == "ID" ? cursor.map { "ID>\($0)" } ?? "1=1" : keyCursor.map { "kid>\(val($0))" } ?? "1=1"
                    let rows = try await src.raw(query("SELECT \(projection) AS v FROM \(try ident(table)) WHERE \(condition) ORDER BY \(try ident(keyColumn)) LIMIT \(batch)")).all(decoding:TextRow.self)
                    if rows.isEmpty { break }
                    for r in rows {
                        let row = try await resolveLargeCells(src,table,try LegacyRow.decode(r.v,table:table),keyColumn:keyColumn); let dict = row.values
                        let key = try row.required(keyColumn)
                        if keyColumn == "ID" { guard let n = Int64(key), cursor.map({ n > $0 }) ?? true else { throw ImportFailure.invalidSourceAt(table:table,column:keyColumn,reason:.invalidCursor) }; cursor = n } else { keyCursor = key }
                        // Check outside object(): a resumed ledger entry must still expose mapping gaps.
                        let mappingReview = table == "formulare" && row.hasUnmappedConfigurationValues
                        if mappingReview && !dry { try await reviewIssue(dst,p,table,key,"unmapped-column") }
                        let outcome = try await object(dst,p,runID,table,key,row,dry) { db in try await transform(src,db,p,table,row) }
                        parity.sourceCount += 1; sourceHashes.update(data:Data(mac(try json(dict)).utf8))
                        if let digest = outcome {
                            if table == "anfragen" {
                                retention.importedWithoutDeadline += 1
                                if let t = try row.text("time").flatMap({ Int64($0) }), t > 0, Date(timeIntervalSince1970:Double(t)).addingTimeInterval(Double(Retention.defaultDays) * 86_400) <= Date() { retention.dueNowAtDefault += 1 }
                            }
                            parity.importedCount += 1; targetHashes.update(data:Data(digest.utf8)); if table == "anfragen" || mappingReview { parity.reviewCount += 1 } } else { parity.reviewCount += 1 }
                        processed += 1
                        try await checkpoint?(table, processed)
                        if let stop, processed == stop { throw ImportFailure.interrupted }
                    }
                }
                guard report.inventory[table] == parity.sourceCount else {
                    throw ImportFailure.invalidSourceAt(table:table,column:keyColumn,reason:.countMismatch)
                }
                if !dry {
                    let mapped = try await scalar(dst,"SELECT CAST(COUNT(DISTINCT source_key) AS CHAR) AS v FROM migration_objects WHERE source_namespace=\(val(p.namespace)) AND source_table=\(val(table))")
                    if (Int(mapped ?? "0") ?? 0) > parity.sourceCount { try await reviewIssue(dst,p,table,"@table","source-deletion-review") }
                }
                parity.sourceHMAC = hex(Data(sourceHashes.finalize())); parity.targetHMAC = hex(Data(targetHashes.finalize())); report.tables[table] = parity; report.retention = retention
            }
            if !dry {
                // Quiesce check: the snapshot transaction ends first, so the read is a fresh one (it sees writes after the snapshot).
                try await exec(src,"ROLLBACK")
                guard try await fingerprint(src) == startFingerprint else { throw ImportFailure.sourceNotQuiesced }
                for (table,count) in report.inventory where count > 0 && !tables.contains(table) {
                    try await reviewIssue(dst,p,table,"@table","unmapped-table")
                }
                let issues = try await scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_issues WHERE run_id=\(runID) AND state='open'") ?? "1"
                // A data importer never certifies SDK rollout, decryption or operational cutover.
                let serialized = try json(report)
                try await exec(dst,"UPDATE migration_runs SET state=\(issues == "0" ? "'verified'" : "'failed'"),completed_at=UTC_TIMESTAMP(6),report_json=\(val(serialized)) WHERE id=\(runID)")
            }
            return report
        } catch {
            if !dry { try? await exec(dst,"UPDATE migration_runs SET state='failed' WHERE id=\(runID)") }
            throw error
        }
    }
    /// Issue code of a parked object: named for the statistics cases, otherwise the general one.
    static func reviewCode(for error: Error) -> String {
        guard let failure = error as? ImportFailure else { return "migration-review" }
        switch failure {
        case .statisticsReviewMissing: return "statistics-review-missing"
        case .statisticsKeyUnknown: return "statistics-key-unknown"
        default: return "migration-review"
        }
    }
    func object(_ db: SQLDatabase, _ p: ImportPlan, _ run: String, _ table: String, _ key: String, _ row: LegacyRow, _ dry: Bool,
                _ write: (SQLDatabase) async throws -> [Destination]) async throws -> String? {
        let sourceMAC = mac((try json(p)) + (try json(row.values)))
        let predicate = "source_namespace=\(val(p.namespace)) AND source_table=\(val(table)) AND source_key=\(bin(Data(key.utf8)))"
        struct Ledger: Decodable { var target_key: Blob, source_hmac: Blob, target_hmac: Blob, dump_hash: String }
        let old = try await db.raw(query("SELECT target_key,source_hmac,target_hmac,(SELECT LOWER(HEX(dump_sha256)) FROM migration_runs WHERE id=migration_objects.run_id) AS dump_hash FROM migration_objects WHERE \(predicate) ORDER BY target_slot")).all(decoding:Ledger.self)
        if !old.isEmpty {
            var combined = ""
            for item in old {
                // Preserve the original snapshot binding; a delta never rewrites old ledger HMACs.
                var originalPlan = p
                originalPlan.dumpSHA256 = item.dump_hash
                let originalMAC = mac((try json(originalPlan)) + (try json(row.values)))
                guard hex(item.source_hmac.data) == sourceMAC || hex(item.source_hmac.data) == originalMAC else { throw ImportFailure.conflict }
                let ref = try JSONDecoder().decode(Destination.self,from:item.target_key.data)
                guard try await proofMatches(db,ref,stored:hex(item.target_hmac.data),inTransaction:false) else { throw ImportFailure.conflict }
                combined += hex(item.target_hmac.data)
            }
            return mac(combined)
        }
        try await exec(db,dry ? "SAVEPOINT migration_object" : "START TRANSACTION")
        do {
            let refs = try await write(db)
            var combined = ""
            for (index,ref) in refs.enumerated() {
                let digest = mac(try await snapshot(db,ref)); combined += digest
                let encoded = try json(ref); guard encoded.utf8.count <= 512 else { throw ImportFailure.invalidSource }
                if !dry {
                    _ = try await insert(db,"migration_objects",["source_namespace":val(p.namespace),"source_table":val(table),"source_key":bin(Data(key.utf8)),"target_table":val(ref.table),"target_slot":val(String(format:"%08d",index)),"target_key":bin(Data(encoded.utf8)),"source_hmac":bin(try unhex(sourceMAC)),"target_hmac":bin(try unhex(digest)),"run_id":run],key:["source_namespace":val(p.namespace),"source_table":val(table),"source_key":bin(Data(key.utf8)),"target_table":val(ref.table),"target_slot":val(String(format:"%08d",index))])
                }
            }
            try await exec(db,dry ? "RELEASE SAVEPOINT migration_object" : "COMMIT")
            let digest = mac(combined)
            return digest
        } catch {
            try? await exec(db,dry ? "ROLLBACK TO SAVEPOINT migration_object" : "ROLLBACK")
            if let failure = error as? ImportFailure, case .invalidSourceAt = failure { throw failure }
            if let failure = error as? ImportFailure, case .keyConflict = failure { throw failure }
            if error is ImportFailure || error is SecretStore.Failure {
                if !dry {
                    try await exec(db,"INSERT INTO migration_issues (id,run_id,source_table,source_key,issue_code,state,reported_at) VALUES (\(bin(DB.bin(UUID()).data)),\(run),\(val(table)),\(bin(Data(key.utf8))),\(val(Self.reviewCode(for:error))),'open',UTC_TIMESTAMP(6)) ON DUPLICATE KEY UPDATE issue_code=issue_code")
                }
                return nil
            }
            // Never propagate a driver error: it may contain SQL values. Number, SQLSTATE and index/column name are safe and make the cause findable.
            if let detail = DatabaseDiagnostics.classify(error) { throw ImportFailure.databaseAt(table:table,code:detail.code,sqlState:detail.sqlState,object:detail.object) }
            throw ImportFailure.database
        }
    }
}

/// What the target's `max_allowed_packet` must carry for the largest legacy cell (finding 15C5D5E9). MariaDB checks the RESULT of
/// `UPDATE stored_objects SET ciphertext = CONCAT(ciphertext, <1 MB chunk>)` against the limit, so the whole cell must fit even though
/// every statement stays below 2 MB. 256 KiB of slack cover the row overhead; the floor covers the 2 MB chunk statements.
public enum PacketRequirement {
    static let mebibyte = 1_048_576
    /// Value recommended to operators (docs/UMSTIEG-CHECKLISTE.md): above a 20 MB legacy upload (about 27 MB as base64 package)
    /// and the 32 MiB request limit of the ingest.
    public static let recommendedMiB = 64
    public static func neededBytes(forCell largest: Int) -> Int { max(largest + 262_144, 4 * mebibyte) }
    public static func neededMiB(forCell largest: Int) -> Int { (neededBytes(forCell: largest) + mebibyte - 1) / mebibyte }
    public static func largestMiB(_ largest: Int) -> Int { (largest + mebibyte - 1) / mebibyte }
    public static func limitMiB(_ limit: Int) -> Int { limit / mebibyte }
    /// Job code `target_packet_too_small@<limit MiB>:<largest cell MiB>:<needed MiB>` (column error_code is VARCHAR(40)).
    public static func jobCode(limit: Int, largest: Int) -> String { "target_packet_too_small@\(limitMiB(limit)):\(largestMiB(largest)):\(neededMiB(forCell: largest))" }
}
