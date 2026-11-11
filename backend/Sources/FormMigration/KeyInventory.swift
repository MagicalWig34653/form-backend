// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SQLKit
import FormCrypto

/// Metadata of the legacy data keys and of the key ids referenced by submissions, for the migration wizard
/// (ADR 0040). Read-only and bounded. Never returns private material, envelopes, public key bytes or content:
/// only kid, status, creation time, a validity flag (keyID(publicKey) == kid) and counters.
public struct LegacyKeyInventory: Sendable {
    public struct Key: Sendable, Equatable {
        public let kid: String
        /// `aktiv`, `auslaufend` or `andere` (any other or unreadable value; never echoed).
        public let status: String
        /// Unix seconds from `erstelltAm`; nil when missing or not an integer.
        public let createdAt: Int64?
        /// 32 bytes and SHA-256 prefix equal to kid, the same check the importer applies.
        public let publicKeyValid: Bool
    }
    public struct Usage: Sendable, Equatable {
        public let kid: String
        /// Submissions (rows of `anfragen`) with at least one `KUBUS-AEAD:2` package header naming this kid.
        public var submissions: Int
        public var inKeyStore: Bool
        public var formIds: [String]
        public var formIdsComplete: Bool
    }
    public var keys: [Key] = []
    /// False when more key rows exist than `maxKeys`, or rows with an unusable kid were skipped (`invalidKeys`).
    public var keysComplete = true
    public var invalidKeys = 0
    public var usage: [Usage] = []
    /// False when the submission scan stopped early (row, kid or time limit); the counters are then a lower bound.
    public var usageComplete = true
    public var scannedSubmissions = 0

    public init() {}

    public var json: [String: Any] {
        ["keys": keys.map { key -> [String: Any] in
            ["kid": key.kid, "status": key.status, "createdAt": key.createdAt.map { $0 as Any } ?? NSNull(), "publicKeyValid": key.publicKeyValid]
         },
         "keysComplete": keysComplete, "invalidKeys": invalidKeys,
         "keyUsage": ["complete": usageComplete, "scannedSubmissions": scannedSubmissions,
                      "items": usage.map { item -> [String: Any] in
                          ["kid": item.kid, "submissions": item.submissions, "inKeyStore": item.inKeyStore,
                           "formIds": item.formIds, "formIdsComplete": item.formIdsComplete]
                      }] as [String: Any]]
    }

    public struct Limits: Sendable {
        public var maxKeys = 200, maxRows = 200_000, batch = 2_000, maxKids = 200, maxFormsPerKid = 100
        public var seconds: TimeInterval = 20
        public init() {}
    }

    static func validKid(_ s: String) -> Bool {
        s.utf8.count == 16 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// kid of a `KUBUS-AEAD:2|<kid>|...` header; nil for any other format (CBC, :1, plaintext, defective header).
    public static func headerKid(_ prefix: Data) -> String? {
        let marker = Data("KUBUS-AEAD:2|".utf8)
        guard prefix.count >= marker.count + 17, prefix.prefix(marker.count) == marker,
              prefix[prefix.startIndex + marker.count + 16] == UInt8(ascii: "|"),
              let kid = String(data: prefix.subdata(in: prefix.startIndex + marker.count ..< prefix.startIndex + marker.count + 16), encoding: .utf8),
              validKid(kid) else { return nil }
        return kid
    }

    /// Reads the inventory from a legacy source session. Tables or columns that do not exist are reported as empty.
    public static func scan(_ source: SQLDatabase, limits: Limits = Limits(), now: () -> Date = Date.init) async throws -> LegacyKeyInventory {
        var result = LegacyKeyInventory()
        let started = now()
        struct Col: Decodable { let v: String }
        func columns(_ table: String) async throws -> Set<String> {
            Set(try await source.raw("SELECT COLUMN_NAME AS v FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=\(bind: table)").all(decoding: Col.self).map(\.v))
        }
        let keyColumns = try await columns("datenschluessel")
        var storeKids = Set<String>()
        if ["kid", "publicKey", "status", "erstelltAm"].allSatisfy(keyColumns.contains) {
            struct K: Decodable { let kid: String?; let pub: String?; let status: String?; let created: String? }
            let rows = try await source.raw("""
                SELECT HEX(CAST(kid AS BINARY)) AS kid, HEX(CAST(publicKey AS BINARY)) AS pub, HEX(CAST(status AS BINARY)) AS status,
                       CAST(erstelltAm AS CHAR) AS created
                FROM datenschluessel ORDER BY kid LIMIT \(unsafeRaw: String(limits.maxKeys + 1))
                """).all(decoding: K.self)
            if rows.count > limits.maxKeys { result.keysComplete = false }
            for row in rows.prefix(limits.maxKeys) {
                guard let hexKid = row.kid, let kidData = try? unhex(hexKid), let kid = String(data: kidData, encoding: .utf8), validKid(kid) else {
                    result.invalidKeys += 1; result.keysComplete = false; continue
                }
                let status = row.status.flatMap { try? unhex($0) }.flatMap { String(data: $0, encoding: .utf8) }
                let pub = row.pub.flatMap { try? unhex($0) }
                let valid = pub.map { $0.count == 32 && (try? keyID($0)) == kid } ?? false
                result.keys.append(Key(kid: kid, status: ["aktiv", "auslaufend"].contains(status ?? "") ? status! : "andere",
                                       createdAt: row.created.flatMap { Int64($0) }, publicKeyValid: valid))
                storeKids.insert(kid)
            }
        }
        let submissionColumns = try await columns("anfragen")
        let content = ["data", "file1Enc", "mailBody", "mailBodyFiller"].filter(submissionColumns.contains)
        guard submissionColumns.contains("ID"), !content.isEmpty else { return result }
        // Only the first 30 bytes ("KUBUS-AEAD:2|" + kid + "|") leave the database; never ciphertext or other content.
        let projection = content.enumerated().map { "HEX(LEFT(CAST(`\($0.element)` AS BINARY),30)) AS c\($0.offset)" }.joined(separator: ",")
        let form = submissionColumns.contains("formularUUID") ? "CAST(formularUUID AS CHAR)" : "NULL"
        var usage: [String: Usage] = [:], order: [String] = []
        var cursor: Int64?
        scan: while true {
            struct Row: Decodable { let id: Int64; let form: String?; let c0: String?; let c1: String?; let c2: String?; let c3: String? }
            let condition = cursor.map { "WHERE ID > \($0)" } ?? ""
            let take = min(limits.batch, limits.maxRows - result.scannedSubmissions)
            if take <= 0 { result.usageComplete = false; break }
            let pad = (content.count..<4).map { ",NULL AS c\($0)" }.joined()
            // Only fixed identifiers and integers are composed here.
            let sql = "SELECT ID AS id, \(form) AS form, \(projection)\(pad) FROM anfragen \(condition) ORDER BY ID LIMIT \(take + 1)"
            let rows = try await source.raw(query(sql)).all(decoding: Row.self)
            for row in rows.prefix(take) {
                cursor = row.id
                result.scannedSubmissions += 1
                var kids = Set<String>()
                for prefix in [row.c0, row.c1, row.c2, row.c3] {
                    if let prefix, let data = try? unhex(prefix), let kid = headerKid(data) { kids.insert(kid) }
                }
                for kid in kids.sorted() {
                    if usage[kid] == nil {
                        guard usage.count < limits.maxKids else { result.usageComplete = false; continue }
                        usage[kid] = Usage(kid: kid, submissions: 0, inKeyStore: false, formIds: [], formIdsComplete: true)
                        order.append(kid)
                    }
                    usage[kid]!.submissions += 1
                    if let id = row.form.flatMap(UUID.init(uuidString:))?.uuidString.lowercased(), !usage[kid]!.formIds.contains(id) {
                        if usage[kid]!.formIds.count < limits.maxFormsPerKid { usage[kid]!.formIds.append(id) } else { usage[kid]!.formIdsComplete = false }
                    } else if row.form.flatMap(UUID.init(uuidString:)) == nil { usage[kid]!.formIdsComplete = false }
                }
            }
            if rows.count <= take { break scan }
            if result.scannedSubmissions >= limits.maxRows || now().timeIntervalSince(started) > limits.seconds { result.usageComplete = false; break scan }
        }
        // Exact (binary) membership, also for kids beyond the listed keys.
        for kid in order {
            var item = usage[kid]!
            if storeKids.contains(kid) { item.inKeyStore = true }
            else if keyColumns.contains("kid") {
                struct N: Decodable { let n: Int }
                item.inKeyStore = (try await source.raw("SELECT COUNT(*) AS n FROM datenschluessel WHERE CAST(kid AS BINARY) = CAST(\(bind: kid) AS BINARY)").first(decoding: N.self)?.n ?? 0) > 0
            }
            item.formIds.sort()
            result.usage.append(item)
        }
        result.usage.sort { $0.kid < $1.kid }
        return result
    }
}
