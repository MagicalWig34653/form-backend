// SPDX-License-Identifier: AGPL-3.0-only
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Upload-Verlust: the ingest writes every sealed package (data and attachments, base64 of up to ~27 MB) as ONE bound value, and MariaDB
/// refuses a packet larger than `max_allowed_packet` (default 16 MiB). The driver reports that only as an unspecific error (HTTP 500 and
/// a retry that can never succeed) or, in a standalone write, not at all. An oversize value is therefore refused BEFORE the first write
/// (413 `payload_too_large`, operator hint in the log) and a completed write is verified, never trusted.
public enum PacketGuard {
    /// Slack for the statement text and the other bound values of the INSERT (hashes, ids, timestamps).
    static let reserve = 65_536
    /// Below this size no check runs (the hot path of ordinary submissions stays free of an extra query).
    static let checkThreshold = 1_048_576
    /// Operators are told to run at least this (docs/BETRIEB.md): above the largest sealed upload (~27 MB) and the 32 MiB request limit.
    public static let recommendedMiB = 64

    public static func needed(forValue bytes: Int) -> Int { bytes + reserve }

    /// Effective limit of THIS connection (a changed global value only reaches connections opened afterwards).
    public static func sessionLimit(_ sql: SQLDatabase) async throws -> Int {
        struct V: Decodable { let v: String }
        return Int(try await sql.raw("SELECT CAST(@@session.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
    }

    /// Refuses before any write when the largest value cannot be carried by one packet. A limit of 0 (unknown) never blocks.
    static func require(fit largest: Int, on sql: SQLDatabase, logger: Logger) async throws {
        guard largest >= checkThreshold else { return }
        let limit = try await sessionLimit(sql)
        guard limit > 0, needed(forValue: largest) > limit else { return }
        logger.error("ingest refused: sealed package of \(largest) bytes exceeds the database max_allowed_packet of \(limit) bytes; raise max_allowed_packet to at least \(recommendedMiB) MiB (docs/BETRIEB.md)")
        throw Abort(.payloadTooLarge)
    }

    /// After the inserts: every object of the submission exists and its stored length equals the expected one (DB backend only).
    static func verifyStored(submission: Blob, expected: Int, on sql: SQLDatabase, logger: Logger) async throws {
        struct R: Decodable { let total: Int; let bad: Int }
        let r = try await sql.raw("""
            SELECT COUNT(*) AS total, CAST(COALESCE(SUM(backend = 'db' AND (ciphertext IS NULL OR OCTET_LENGTH(ciphertext) <> byte_count)), 0) AS SIGNED) AS bad
            FROM stored_objects WHERE submission_id = \(bind: submission)
            """).first(decoding: R.self)
        guard let r, r.total == expected, r.bad == 0 else {
            logger.error("ingest aborted: stored objects incomplete (expected \(expected), found \(r?.total ?? -1), incomplete \(r?.bad ?? -1)); check max_allowed_packet (docs/BETRIEB.md)")
            throw Abort(.serviceUnavailable)
        }
    }

    /// Start: one line telling the operator when the database cannot carry the largest upload the ingest accepts.
    public static func warnAtStart(_ app: Application, ingestLimitBytes: Int) async {
        guard let limit = try? await sessionLimit(Persistence.sql(app)), limit > 0 else { return }
        if limit < ingestLimitBytes + reserve {
            app.logger.warning("max_allowed_packet \(limit / 1_048_576) MiB < ingest limit \(ingestLimitBytes / 1_048_576) MiB: uploads larger than about \(max(0, limit - reserve) / 1_048_576) MiB are refused with 413; set max_allowed_packet to at least \(recommendedMiB) MiB (docs/BETRIEB.md)")
        }
    }
}

struct PacketStartupCheck: LifecycleHandler {
    let ingestLimitBytes: Int
    func didBootAsync(_ app: Application) async throws { await PacketGuard.warnAtStart(app, ingestLimitBytes: ingestLimitBytes) }
}
