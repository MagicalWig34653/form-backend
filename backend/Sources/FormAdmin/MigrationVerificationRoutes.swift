// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormMigration
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Human attestations only: no plaintext digest and no private key cross this boundary.
enum MigrationVerificationRoutes {
    struct Sample: Decodable {
        let ciphertext: Blob
    }
    static func sample(_ tx: SQLDatabase, job: MigrationJob) async throws -> String {
        guard job.state == "review", job.dry_run == 0 else { throw Abort(.conflict) }
        let plan = try JSONDecoder().decode(ImportPlan.self, from: Data(job.plan_json.utf8))
        // Resolve only ledger-owned objects, never arbitrary customer submissions.
        struct Ref: Decodable { let target_key: Blob }
        struct Destination: Decodable { let table: String; let predicate: String; enum CodingKeys: String, CodingKey { case table = "t", predicate = "p" } }
        let refs = try await tx.raw("SELECT target_key FROM migration_objects WHERE source_namespace=\(bind: plan.namespace) AND source_table='anfragen' AND target_table='stored_objects' ORDER BY source_key,target_slot LIMIT 1000").all(decoding: Ref.self)
        for ref in refs {
            let destination = try JSONDecoder().decode(Destination.self, from: ref.target_key.data)
            // The persisted predicate is not executed as SQL.
            let parts = destination.predicate.components(separatedBy: "'")
            guard parts.count == 3, let id = UUID(uuidString: parts[1].enumerated().map { index, c in
                ([8,12,16,20].contains(index) ? "-" : "") + String(c)
            }.joined()) else { continue }
            if let object = try await tx.raw("SELECT ciphertext FROM stored_objects WHERE id=\(bind: DB.bin(id)) AND object_role='data' AND state='ready' AND backend='db'").first(decoding: Sample.self),
               let wire = String(data: object.ciphertext.data, encoding: .utf8), wire.contains("|hpke|") { return wire }
        }
        throw Abort(.notFound, reason: "Keine geeignete migrierte :2-Probe vorhanden")
    }
    static func hash(_ wire: String) -> String { SHA256.hash(data: Data(wire.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func register(_ root: RoutesBuilder, service: MigrationService,
                         authorize: @escaping (Request, Bool) async throws -> UUID) {
        root.get("jobs", ":jobId", "probe") { req async throws -> Response in
            let actor = try await authorize(req, false), id = try FormAdmin.uuidParam(req, "jobId")
            return try await service.db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard let job = try await tx.raw("SELECT * FROM migration_jobs WHERE id=\(bind: DB.bin(id)) FOR UPDATE").first(decoding: MigrationJob.self) else { throw Abort(.notFound) }
                let wire = try await sample(tx, job: job)
                try await service.audit(tx, actor: actor, action: "migration.probe.read")
                return try SetupMigrationRoutes.response(["wire": wire, "hash": hash(wire)])
            }
        }
        root.post("jobs", ":jobId", "verify") { req async throws -> Response in
            let actor = try await authorize(req, true), id = try FormAdmin.uuidParam(req, "jobId")
            struct Input: Decodable { let hash: String; let success: Bool; let testHash: String? }
            let input: Input = try SetupMigrationRoutes.decode(req, allowed: ["hash", "success", "testHash"])
            guard input.success, input.testHash == nil || input.testHash!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw Abort(.unprocessableEntity) }
            try await service.db.transaction { conn in
                let tx = conn as! SQLDatabase
                guard let job = try await tx.raw("SELECT * FROM migration_jobs WHERE id=\(bind: DB.bin(id)) FOR UPDATE").first(decoding: MigrationJob.self) else { throw Abort(.notFound) }
                guard hash(try await sample(tx, job: job)) == input.hash else { throw Abort(.conflict) }
                if input.testHash != nil {
                    struct R: Decodable { let probe_hash: String? }
                    guard try await tx.raw("SELECT probe_hash FROM migration_jobs WHERE id=\(bind: DB.bin(id))").first(decoding: R.self)?.probe_hash == input.hash else { throw Abort(.conflict) }
                }
                try await tx.raw("UPDATE migration_jobs SET probe_hash=\(bind: input.hash),test_hash=\(bind: input.testHash),updated_at=UTC_TIMESTAMP(6) WHERE id=\(bind: DB.bin(id))").run()
                try await service.audit(tx, actor: actor, action: input.testHash == nil ? "migration.probe.confirm" : "migration.probe.test")
            }
            return try SetupMigrationRoutes.response(["status": "confirmed"])
        }
    }
}
