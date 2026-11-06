// SPDX-License-Identifier: AGPL-3.0-only
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Optional visit context is part of the signed canonical fields, never supplied through unsigned headers.
/// No context means no event: inventing visits or a domain alias would corrupt conversion dimensions.
enum IngestStatistics {
    struct Context: Sendable { let domain: UUID; let view: UUID; let pseudonym: Data; let ads: Bool? }

    static func context(canonical: Data) throws -> Context? {
        guard let root = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
              let fields = root["fields"] as? [String: Any], let raw = fields["_statistics"] else { return nil }
        guard let text = raw as? String, text.utf8.count <= 1024,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(["domainAlias", "viewId", "visitPseudonym"]).isSubset(of: Set(obj.keys)),
              Set(obj.keys).isSubset(of: ["domainAlias", "viewId", "visitPseudonym", "ads"]),
              let domainText = obj["domainAlias"] as? String, let domain = UUID(uuidString: domainText), domain.uuidString.lowercased() == domainText,
              let viewText = obj["viewId"] as? String, let view = UUID(uuidString: viewText), view.uuidString.lowercased() == viewText,
              let hex = obj["visitPseudonym"] as? String, (32...64).contains(hex.utf8.count), hex.utf8.count % 2 == 0,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Abort(.unprocessableEntity) }
        let chars = Array(hex.utf8)
        var pseudonym = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            pseudonym.append(UInt8(String(decoding: chars[i...i+1], as: UTF8.self), radix: 16)!)
        }
        let ads: Bool?
        do { ads = try AdsIndicator.parse(obj["ads"]) } catch { throw Abort(.unprocessableEntity) }
        return Context(domain: domain, view: view, pseudonym: pseudonym, ads: ads)
    }

    /// Existing assignments make the host allowlist mandatory. A pinned release never falls back to current_release_id.
    static func resolveRelease(sql: SQLDatabase, customer: Blob, form: UUID, current: Blob?, host: String?, lock: Bool = false) async throws -> Blob {
        struct C: Decodable { let c: Int }
        struct R: Decodable { let release_id: Blob? }
        let assigned = try await sql.raw("SELECT COUNT(*) AS c FROM api_host_forms WHERE customer_id = \(bind: customer) AND form_id = \(bind: DB.bin(form))").first(decoding: C.self)?.c ?? 0
        if assigned == 0 {
            guard let current else { throw Abort(.serviceUnavailable) }
            return current
        }
        guard let host else { throw Abort(.misdirectedRequest) }
        guard let binding = try await sql.raw("""
            SELECT f.release_id FROM api_host_forms f JOIN api_hosts h ON h.id = f.api_host_id
            WHERE f.customer_id = \(bind: customer) AND f.form_id = \(bind: DB.bin(form)) AND h.host_ascii = \(bind: host) AND h.enabled = 1
            \(unsafeRaw: lock ? "FOR UPDATE" : "")
            """).first(decoding: R.self) else { throw Abort(.misdirectedRequest) }
        guard let resolved = binding.release_id ?? current else { throw Abort(.serviceUnavailable) }
        return resolved
    }

    /// Browser Origin, when present, must match the signed visit's domain exactly; SDK requests may omit it.
    static func checkOrigin(_ context: Context?, origins: [String], sql: SQLDatabase, customer: Blob, form: UUID, release: Blob, environment: String = "production") async throws {
        guard !origins.isEmpty else { return }
        guard origins.count == 1, let context else { throw Abort(.forbidden) }
        struct R: Decodable { let host_ascii: String }
        guard let row = try await sql.raw("""
            SELECT host_ascii FROM domain_bindings WHERE id = \(bind: DB.bin(context.domain)) AND customer_id = \(bind: customer)
              AND form_id = \(bind: DB.bin(form)) AND release_id = \(bind: release) AND view_id = \(bind: DB.bin(context.view))
              AND enabled = 1 AND environment = \(bind: environment)
            """).first(decoding: R.self), origins[0] == "https://\(row.host_ascii)" else { throw Abort(.forbidden) }
    }

    /// Called in the same transaction as acceptance; independent from later content erasure.
    static func record(_ context: Context?, tx: SQLDatabase, customer: Blob, form: UUID, release: Blob, submission: UUID, now: Date, origins: [String] = []) async throws {
        guard let context else { return }
        // Locks the mapping while accepting, so revocation/rebinding cannot race this event.
        struct Binding: Decodable { let id: Blob }
        guard try await tx.raw("""
            SELECT d.id FROM domain_bindings d JOIN customers c ON c.id = d.customer_id
            WHERE d.id = \(bind: DB.bin(context.domain)) AND d.customer_id = \(bind: customer) AND d.form_id = \(bind: DB.bin(form))
              AND d.release_id = \(bind: release) AND d.view_id = \(bind: DB.bin(context.view))
              AND d.enabled = 1 AND d.environment = 'production' AND c.state = 'active' FOR UPDATE
            """).first(decoding: Binding.self) != nil else { throw Abort(.unprocessableEntity) }
        try await checkOrigin(context, origins: origins, sql: tx, customer: customer, form: form, release: release)
        let pseudonym = Blob(context.pseudonym), at = DB.time(now)
        // Reuse the original visit classification, including an explicitly unmeasured visit.
        struct Visit: Decodable { let ads_present: Bool? }
        let visit = try await tx.raw("""
            SELECT ads_present FROM statistics_events WHERE customer_id = \(bind: customer) AND form_id = \(bind: DB.bin(form))
              AND release_id = \(bind: release) AND view_id = \(bind: DB.bin(context.view)) AND domain_alias = \(bind: DB.bin(context.domain))
              AND environment = 'production' AND visit_pseudonym = \(bind: pseudonym) AND event_kind = 'visit'
            """).first(decoding: Visit.self)
        let ads = visit.map { $0.ads_present } ?? context.ads
        // A late accepted submission supersedes only a collector-inferred abandonment, never a real client signal.
        try await tx.raw("""
            DELETE FROM statistics_events WHERE customer_id = \(bind: customer) AND form_id = \(bind: DB.bin(form))
              AND release_id = \(bind: release) AND view_id = \(bind: DB.bin(context.view)) AND domain_alias = \(bind: DB.bin(context.domain))
              AND environment = 'production' AND visit_pseudonym = \(bind: pseudonym) AND event_kind = 'abandon' AND abandonment_evidence = 'inactivity-inferred'
            """).run()
        // One conversion per visit even if the visitor submits twice with distinct request idempotency keys.
        try await tx.raw("""
            INSERT INTO statistics_events (id, customer_id, form_id, release_id, view_id, domain_alias, visit_pseudonym,
              event_kind, source, environment, submission_id, occurred_at, expires_at, ads_present)
            VALUES (\(bind: DB.bin(UUID())), \(bind: customer), \(bind: DB.bin(form)), \(bind: release), \(bind: DB.bin(context.view)),
              \(bind: DB.bin(context.domain)), \(bind: pseudonym), 'submit', 'ingest', 'production', \(bind: DB.bin(submission)),
              \(bind: at), DATE_ADD(CAST(\(bind: at) AS DATETIME(6)), INTERVAL 13 MONTH), \(bind: ads))
            ON DUPLICATE KEY UPDATE id = id
            """).run()
    }
}
