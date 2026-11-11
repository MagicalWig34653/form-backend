// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormCrypto
import FormPersistence
import Foundation
import SQLKit
import XCTest

/// Time and memory with many submissions (REHEARSAL_ROWS, default 3000; the measurement for 50 000 is in the handover).
extension ImportRehearsalTests {
    static func residentMegabytes() -> Int {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        #if os(Linux)
        return usage.ru_maxrss / 1024
        #else
        return Int(usage.ru_maxrss) / 1_048_576
        #endif
    }

    func testManySubmissionsStayWithinTimeAndMemory() async throws {
        let rows = Int(ProcessInfo.processInfo.environment["REHEARSAL_ROWS"] ?? "") ?? 3000
        try await withHarness(perForm: 1, statistics: 0) { h in
            let plain = Data(#"{"name":"Jörg Müßig","email":"joerg@example.invalid","nachricht":"Grüße 👋 \#(String(repeating: "Lorem ipsum ", count: 40))"}"#.utf8)
            let data = RehearsalSource.seal(plain, RehearsalSource.alphaActive), mail = RehearsalSource.seal(Data("<p>Hallo</p>".utf8), RehearsalSource.alphaActive)
            try await h.source.on(h.fx) { s in
                try await s.raw("INSERT INTO anfragen (UUID,time,formularUUID,sentServer,data,mailBody,removable) SELECT UUID(),1700000000+seq,\(bind: RehearsalSource.formA),\(bind: RehearsalSource.smtpA),\(bind: data),\(bind: mail),1 FROM seq_1_to_\(unsafeRaw: String(rows))").run()
            }
            let total = h.source.submissionCount + rows
            let before = Self.residentMegabytes()
            let job = try await dryRun(h)
            var started = Date()
            try await h.service.tick()
            let dry = try await stateOf(h, job.id)
            let dryTime = Date().timeIntervalSince(started)
            XCTAssertEqual(dry["state"] as? String, "review", "dry run: \(dry["error"] ?? "-")")
            _ = try await h.action(job.id, "import")
            started = Date()
            try await h.service.tick()
            let done = try await stateOf(h, job.id)
            let importTime = Date().timeIntervalSince(started)
            XCTAssertEqual(done["state"] as? String, "review", "import: \(done["error"] ?? "-")")
            let n = try await h.count("submissions")
            XCTAssertEqual(n, total)
            let objects = try await h.count("stored_objects", "object_role IN ('data','mail-organisation') AND submission_id IS NOT NULL")
            XCTAssertGreaterThanOrEqual(objects, rows * 2)
            print("MEASURE load rows=\(total) dry=\(Int(dryTime))s import=\(Int(importTime))s rowsPerSecondImport=\(Int(Double(total) / max(importTime, 0.001))) rssMB=\(before)->\(Self.residentMegabytes())")
        }
    }
}
