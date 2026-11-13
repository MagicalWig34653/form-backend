// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormAuth
import FormPersistence
import SQLKit
import XCTest
@testable import FormMigration

extension MigrationTests {
    /// Finding 15C5D5E9: the target's max_allowed_packet must carry the largest cell of the source (the chunked CONCAT checks its RESULT).
    /// The pre-check names it before anything is written. The limit is replaced through the importer's test seam: a session value cannot
    /// be lowered per connection in MariaDB, and a source cell above the server limit cannot be created on the same test server.
    func testTargetPacketPrecheckNamesTheLargestCellBeforeAnyWrite() async throws {
        try await withDatabases { source, target, secrets in
            var importer = try LegacyImporter(source: source, target: target, secrets: secrets, hmacKey: Data(repeating: 22, count: 32))
            try await source.raw("INSERT INTO anfragen (ID,UUID,formularUUID,time,data,removable) VALUES (2,'77777777-7777-4777-8777-777777777777',\(bind: self.form),1700000001,REPEAT('A',5000000),0)").run()
            let plan = ImportPlan(namespace: "packet", dumpSHA256: String(repeating: "0", count: 64), customers: [self.customer: "Synthetisch"], formCustomers: [self.form: self.customer])
            // The real limit of the test server (16 MiB) carries a 5 MB cell.
            let real = try await importer.packetShortfall()
            XCTAssertNil(real?.largest)
            importer.packetLimitOverride = 4 * 1_048_576
            let short = try await importer.packetShortfall()
            XCTAssertEqual(short?.limit, 4_194_304)
            XCTAssertEqual(short?.largest, 5_000_000)
            for dryRun in [true, false] {
                do {
                    _ = try await importer.run(plan: plan, dryRun: dryRun)
                    XCTFail("A target that cannot hold the largest cell must refuse the run")
                } catch ImportFailure.targetPacketTooSmall(let limit, let largest) {
                    XCTAssertEqual(limit, 4_194_304)
                    XCTAssertEqual(largest, 5_000_000)
                }
                let customers = try await importer.scalar(target, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM customers")
                let runs = try await importer.scalar(target, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_runs")
                XCTAssertEqual(customers, "0", "nothing may be written before the refusal (dryRun=\(dryRun))")
                XCTAssertEqual(runs, "0")
            }
            importer.packetLimitOverride = 8 * 1_048_576
            let enough = try await importer.packetShortfall()
            XCTAssertNil(enough?.limit)
        }
    }

    func testPacketRequirementArithmeticAndJobCode() {
        // 20 MB legacy upload: about 27 MB package cell; the recommended 64 MiB carries it.
        let cell = 27_000_000
        XCTAssertLessThan(PacketRequirement.neededBytes(forCell: cell), PacketRequirement.recommendedMiB * 1_048_576)
        XCTAssertEqual(PacketRequirement.neededBytes(forCell: 100), 4 * 1_048_576, "floor covers the 2 MB chunk statements")
        XCTAssertEqual(PacketRequirement.jobCode(limit: 16_777_216, largest: cell), "target_packet_too_small@16:26:26")
        XCTAssertEqual(PacketRequirement.jobCode(limit: 16_777_216, largest: 17_000_000), "target_packet_too_small@16:17:17")
        XCTAssertLessThanOrEqual(PacketRequirement.jobCode(limit: 1_073_741_824, largest: 1_073_741_824).utf8.count, 40, "column error_code is VARCHAR(40)")
    }
}
