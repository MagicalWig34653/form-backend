// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormPersistence
import Foundation
import SQLKit

/// Outcome of releasing imported submissions (ADR 0014, addendum "Freigabe importierter Einsendungen").
public struct SubmissionRelease: Equatable {
    /// Imported submissions of the namespace that are released (`accepted`) after the call, including earlier releases.
    public var released: Int
    /// Released by this call only.
    public var newlyReleased: Int
    /// Still `migration-review`: open review case, no valid :2 data package, or a target that diverged from its ledger proof.
    public var kept: Int
}

extension LegacyImporter {
    /// Sets imported submissions of `namespace` from `migration-review` to `accepted`, only those without an open review case
    /// and with a ready :2 data package. Nothing else changes: the packages stay byte-identical and no mail, webhook, outbox
    /// or flow is started (no row is created anywhere).
    ///
    /// Ledger: the target proof (`migration_objects.target_hmac`, slot 0 of the submission) is an HMAC over the whole submission row,
    /// including `state`. The proof is therefore recomputed exactly as the importer computes it (HMAC over the sorted row projection)
    /// and rewritten in the same transaction; a later import/retry then finds the row consistent and reports no conflict. A row whose
    /// current content does not match its stored proof is never touched (stays in review).
    ///
    /// `target` must be inside the caller's transaction. A running import (session lock) makes this fail with `ImportFailure.lock`.
    public func releaseSubmissions(namespace: String) async throws -> SubmissionRelease {
        guard try await scalar(target, "SELECT CAST(GET_LOCK('form_legacy_import',0) AS CHAR) AS v") == "1" else { throw ImportFailure.lock }
        do {
            let result = try await releaseLocked(namespace: namespace)
            try await exec(target, "SELECT RELEASE_LOCK('form_legacy_import')")
            return result
        } catch { try? await exec(target, "SELECT RELEASE_LOCK('form_legacy_import')"); throw error }
    }

    private func releaseLocked(namespace: String) async throws -> SubmissionRelease {
        // Open review cases per submission (source key of the table "anfragen"), over all runs of the namespace.
        let open = Set(try await target.raw(query("SELECT DISTINCT HEX(i.source_key) AS v FROM migration_issues i JOIN migration_runs r ON r.id=i.run_id WHERE r.source_namespace=\(val(namespace)) AND i.source_table='anfragen' AND i.state='open'")).all(decoding: TextRow.self).map(\.v))
        struct Entry: Decodable { var key: String, target_key: Blob, target_hmac: Blob }
        var result = SubmissionRelease(released: 0, newlyReleased: 0, kept: 0)
        var after = ""
        while true {
            let page = try await target.raw(query("SELECT HEX(source_key) AS `key`,target_key,target_hmac FROM migration_objects WHERE source_namespace=\(val(namespace)) AND source_table='anfragen' AND target_table='submissions' AND target_slot=\(val(String(format: "%08d", 0))) AND \(after.isEmpty ? "1=1" : "source_key>X'\(after)'") ORDER BY source_key LIMIT 500")).all(decoding: Entry.self)
            if page.isEmpty { break }
            for entry in page {
                after = entry.key
                let ref = try JSONDecoder().decode(Destination.self, from: entry.target_key.data)
                guard let state = try await scalar(target, "SELECT state AS v FROM submissions WHERE \(ref.predicate)") else { result.kept += 1; continue }
                if state == "accepted" { result.released += 1; continue }
                guard state == "migration-review", !open.contains(entry.key),
                      try await scalar(target, "SELECT '1' AS v FROM stored_objects WHERE submission_id=(SELECT id FROM submissions WHERE \(ref.predicate)) AND object_role='data' AND state='ready' AND packet_format='KUBUS-AEAD:2' LIMIT 1") != nil,
                      mac(try await snapshot(target, ref)) == hex(entry.target_hmac.data) else { result.kept += 1; continue }
                try await exec(target, "UPDATE submissions SET state='accepted' WHERE \(ref.predicate) AND state='migration-review'")
                let digest = mac(try await snapshot(target, ref))
                try await exec(target, "UPDATE migration_objects SET target_hmac=\(bin(try unhex(digest))) WHERE source_namespace=\(val(namespace)) AND source_table='anfragen' AND target_table='submissions' AND target_slot=\(val(String(format: "%08d", 0))) AND source_key=X'\(entry.key)'")
                result.released += 1; result.newlyReleased += 1
            }
        }
        return result
    }
}
