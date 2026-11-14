// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Vapor
import FormCore
import SQLKit

/// Upgrade check for ADR 0046: finds field patterns of published (current) form versions that the linear regex dialect
/// cannot evaluate. Such a pattern rejects every non-empty value at ingest, so operators must learn about it before rollout.
public enum PatternCompatibility {
    public struct Finding: Equatable, Sendable {
        public let form: String      // hex form id (empty for a bare definition)
        public let field: String     // field name
        public let reason: String
    }

    /// Pure check of one form definition (the `form` object with `fields`).
    public static func findings(definition: [String: Any], form: String = "") -> [Finding] {
        guard let fields = definition["fields"] as? [String: Any] else { return [] }
        var out: [Finding] = []
        for key in fields.keys.sorted() {
            guard let f = fields[key] as? [String: Any], let rules = f["validation"] as? [String: Any] else { continue }
            for rk in ["pattern", "muster"] {
                guard let raw = rules[rk] else { continue }
                guard let pattern = raw as? String else { out.append(Finding(form: form, field: f["name"] as? String ?? key, reason: "pattern is not a string")); continue }
                if let why = LinearRegex.validate(pattern) { out.append(Finding(form: form, field: f["name"] as? String ?? key, reason: why)) }
            }
        }
        return out
    }

    private struct Row: Decodable { let form_id: String; let definition_json: String }

    /// Scans the current release of every form (read-only).
    public static func scan(sql: SQLDatabase) async throws -> [Finding] {
        let rows = try await sql.raw("""
            SELECT LOWER(HEX(f.id)) AS form_id, fv.definition_json AS definition_json
            FROM forms f JOIN releases r ON r.id = f.current_release_id
            JOIN form_versions fv ON fv.customer_id = r.customer_id AND fv.form_id = r.form_id AND fv.version_no = r.form_version_no
            """).all(decoding: Row.self)
        return rows.flatMap { row -> [Finding] in
            guard let def = (try? JSONSerialization.jsonObject(with: Data(row.definition_json.utf8))) as? [String: Any] else { return [] }
            return findings(definition: def, form: row.form_id)
        }
    }
}
