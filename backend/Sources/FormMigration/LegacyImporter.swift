// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto
import SQLKit
import Fluent
import FormAuth
import FormCrypto
import FormPersistence

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
public enum SourceFailureReason: String, Sendable {
    case missingColumn, missingValue, invalidHex, invalidUTF8, invalidUUID, invalidIdentifier, invalidCursor, invalidProjection, invalidInteger, invalidBoolean, invalidTimestamp, countMismatch, unknownKeyGeneration
}

public enum ImportFailure: Error, CustomStringConvertible {
    case invalidPlan, conflict, missingTarget, database, interrupted, lock, invalidSource
    case invalidSourceAt(table: String, column: String, reason: SourceFailureReason)

    public var description: String {
        switch self {
        case let .invalidSourceAt(table, column, reason):
            // Metadata is untrusted too: never print an arbitrary identifier or a source value.
            return "migration: invalidSource table=\(safeIdentifier(table)) column=\(safeIdentifier(column)) reason=\(reason.rawValue)"
        case .invalidPlan: return "migration: invalidPlan"
        case .conflict: return "migration: conflict"
        case .missingTarget: return "migration: missingTarget"
        case .database: return "migration: database"
        case .interrupted: return "migration: interrupted"
        case .lock: return "migration: lock"
        case .invalidSource: return "migration: invalidSource"
        }
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
public struct ImportReport: Codable {
    public var tables: [String:TableParity] = [:]
    public var inventory: [String:Int] = [:]
    public var schemaHMAC = ""
    public var dryRun: Bool
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
    func projection(_ cols: [String], uuidColumns: Set<String> = []) throws -> String {
        "JSON_OBJECT(" + (try cols.sorted().map {
            let column = try ident($0)
            // HEX(number) is numeric base conversion, not byte encoding. UUIDs must use their
            // textual representation; BINARY/VARBINARY/BLOB must retain every original byte.
            let bytes = uuidColumns.contains($0) ? "CAST(\(column) AS CHAR CHARACTER SET utf8mb4)" : "CAST(\(column) AS BINARY)"
            return "\(val($0)),HEX(\(bytes))"
        }).joined(separator:",") + ")"
    }
    func projection(_ db: SQLDatabase, _ table: String, _ cols: [String]) async throws -> String {
        let uuids = try await db.raw(query("SELECT COLUMN_NAME AS v FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=\(val(table)) AND DATA_TYPE='uuid'")).all(decoding:TextRow.self)
        return try projection(cols,uuidColumns:Set(uuids.map(\.v)))
    }
    func snapshot(_ db: SQLDatabase, _ d: Destination) async throws -> String {
        let cols = try await columns(db,d.table)
        let projection = try await projection(db,d.table,cols)
        guard let s = try await scalar(db,"SELECT \(projection) AS v FROM \(try ident(d.table)) WHERE \(d.predicate)") else { throw ImportFailure.missingTarget }
        let obj = try JSONSerialization.jsonObject(with:Data(s.utf8))
        return String(decoding:try JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]),as:UTF8.self)
    }
    func insert(_ db: SQLDatabase, _ table: String, _ values: [String:String], key: [String:String]) async throws -> Destination {
        let cols = values.keys.sorted()
        try await exec(db,"INSERT INTO \(try ident(table)) (\(try cols.map(ident).joined(separator:","))) VALUES (\(cols.map { values[$0]! }.joined(separator:",")))")
        return Destination(table:table,predicate:try key.keys.sorted().map { "\(try ident($0))=\(key[$0]!)" }.joined(separator:" AND "))
    }
    public func inspectSchema() async throws -> String {
        var manifest = ""
        let tables = try await source.raw("SELECT table_name AS v FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY table_name").all(decoding: TextRow.self)
        for table in tables { manifest += try json([table.v: await columns(source, table.v)]) }
        return mac(manifest)
    }
    public func run(plan: ImportPlan, dryRun: Bool = false, batchSize: Int = 100, stopAfter: Int? = nil, expectedSchema: String? = nil, checkpoint: ((String, Int) async throws -> Void)? = nil) async throws -> ImportReport {
        guard !plan.namespace.isEmpty, plan.namespace.utf8.count <= 64, plan.namespace.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }), (try? unhex(plan.dumpSHA256).count) == 32, batchSize > 0, batchSize <= 10000,
              plan.customers.keys.allSatisfy({ UUID(uuidString:$0) != nil }), plan.formCustomers.values.allSatisfy({ plan.customers[$0] != nil }) else { throw ImportFailure.invalidPlan }
        let identityQuery = "SELECT CONCAT(@@hostname,':',@@port,':',DATABASE()) AS v"
        let sourceIdentity = try await scalar(source,identityQuery), targetIdentity = try await scalar(target,identityQuery)
        guard sourceIdentity != targetIdentity else { throw ImportFailure.invalidPlan }
        return try await target.withSession { dst in
            guard try await scalar(dst,"SELECT CAST(GET_LOCK('form_legacy_import',0) AS CHAR) AS v") == "1" else { throw ImportFailure.lock }
            do {
                if dryRun { try await exec(dst,"START TRANSACTION") }
                let report = try await source.withSession { src in
                    try await exec(src,"SET time_zone='+00:00'")
                    try await exec(src,"START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY")
                    do { let r = try await perform(src,dst,plan,dryRun,batchSize,stopAfter,expectedSchema,checkpoint); try await exec(src,"ROLLBACK"); return r }
                    catch { try? await exec(src,"ROLLBACK"); throw error }
                }
                if dryRun { try await exec(dst,"ROLLBACK") }; try await exec(dst,"SELECT RELEASE_LOCK('form_legacy_import')"); return report
            } catch { try? await exec(dst,"ROLLBACK"); try? await exec(dst,"SELECT RELEASE_LOCK('form_legacy_import')"); throw error }
        }
    }
    func perform(_ src: SQLDatabase, _ dst: SQLDatabase, _ p: ImportPlan, _ dry: Bool, _ batch: Int, _ stop: Int?, _ expectedSchema: String?, _ checkpoint: ((String, Int) async throws -> Void)?) async throws -> ImportReport {
        guard try await scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM forms WHERE active=1 OR current_release_id IS NOT NULL") == "0" else { throw ImportFailure.invalidPlan }
        let mapping = hex(Data(SHA256.hash(data:Data(try json(p).utf8))))
        let runPredicate = "source_namespace=\(val(p.namespace)) AND dump_sha256=\(bin(try unhex(p.dumpSHA256))) AND mapping_sha256=\(bin(try unhex(mapping))) AND importer_version='p9-1'"
        let existing = try await scalar(dst,"SELECT HEX(id) AS v FROM migration_runs WHERE \(runPredicate)")
        let run = try existing.map(unhex) ?? DB.bin(UUID()).data
        let runID = bin(run)
        if !dry && existing == nil {
            _ = try await insert(dst,"migration_runs",["id":runID,"source_namespace":val(p.namespace),"dump_sha256":bin(try unhex(p.dumpSHA256)),"mapping_sha256":bin(try unhex(mapping)),"importer_version":"'p9-1'","state":"'running'","started_at":"UTC_TIMESTAMP(6)","report_json":"'{}'"],key:["id":runID])
        }
        var report = ImportReport(dryRun:dry); var processed = 0
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
                return [try await insert(db,"customers",["id":try uid(id),"name":val(p.customers[id]),"state":"'disabled'","created_at":"'1970-01-01 00:00:00'"],key:["id":try uid(id)])]
            }
        }
        let tables = ["datenschluessel","outgoingMailServer","outgoingMailProxy","formulare","formularFelder","anfragen","anfrageIdempotenz","formularWebhooks","statistics"]
        do {
            for table in tables {
                try await checkpoint?(table, processed)
                let cols = try await columns(src,table)
                let keyColumn = table == "datenschluessel" ? "kid":"ID"
                guard cols.contains(keyColumn) else { throw ImportFailure.invalidSourceAt(table:table,column:keyColumn,reason:.missingColumn) }
                let projection = try await projection(src,table,cols)
                var cursor: Int64?; var keyCursor: String?; var parity = TableParity(); var sourceHashes = HMAC<SHA256>(key:hmacKey), targetHashes = HMAC<SHA256>(key:hmacKey)
                while true {
                    let condition = keyColumn == "ID" ? cursor.map { "ID>\($0)" } ?? "1=1" : keyCursor.map { "kid>\(val($0))" } ?? "1=1"
                    let rows = try await src.raw(query("SELECT \(projection) AS v FROM \(try ident(table)) WHERE \(condition) ORDER BY \(try ident(keyColumn)) LIMIT \(batch)")).all(decoding:TextRow.self)
                    if rows.isEmpty { break }
                    for r in rows {
                        let row = try LegacyRow.decode(r.v,table:table); let dict = row.values
                        let key = try row.required(keyColumn)
                        if keyColumn == "ID" { guard let n = Int64(key), cursor.map({ n > $0 }) ?? true else { throw ImportFailure.invalidSourceAt(table:table,column:keyColumn,reason:.invalidCursor) }; cursor = n } else { keyCursor = key }
                        // Check outside object(): a resumed ledger entry must still expose mapping gaps.
                        let mappingReview = table == "formulare" && row.hasUnmappedConfigurationValues
                        if mappingReview && !dry { try await reviewIssue(dst,p,table,key,"unmapped-column") }
                        let outcome = try await object(dst,p,runID,table,key,row,dry) { db in try await transform(src,db,p,table,row) }
                        parity.sourceCount += 1; sourceHashes.update(data:Data(mac(try json(dict)).utf8))
                        if let digest = outcome { parity.importedCount += 1; targetHashes.update(data:Data(digest.utf8)); if table == "anfragen" || mappingReview { parity.reviewCount += 1 } } else { parity.reviewCount += 1 }
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
                parity.sourceHMAC = hex(Data(sourceHashes.finalize())); parity.targetHMAC = hex(Data(targetHashes.finalize())); report.tables[table] = parity
            }
            if !dry {
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
                let digest = mac(try await snapshot(db,ref))
                guard digest == hex(item.target_hmac.data) else { throw ImportFailure.conflict }
                combined += digest
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
            if error is ImportFailure || error is SecretStore.Failure {
                if !dry {
                    try await exec(db,"INSERT INTO migration_issues (id,run_id,source_table,source_key,issue_code,state,reported_at) VALUES (\(bin(DB.bin(UUID()).data)),\(run),\(val(table)),\(bin(Data(key.utf8))),'migration-review','open',UTC_TIMESTAMP(6)) ON DUPLICATE KEY UPDATE issue_code=issue_code")
                }
                return nil
            }
            // Never propagate a driver error: it may contain SQL values.
            throw ImportFailure.database
        }
    }
}
