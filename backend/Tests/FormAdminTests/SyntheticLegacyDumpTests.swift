// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SQLKit
import XCTest

/// Generator for `FormMigrationTests/Fixtures/legacy-synthetic.sql` (run by `backend/Tests/FormMigrationTests/Fixtures/regen-legacy-synthetic.sh`,
/// skipped otherwise): builds the synthetic rehearsal source and leaves its schema in the throw-away MariaDB so that the script can dump it.
/// The 3 MB attachment of the rehearsals is removed to keep the file small. Synthetic data only.
final class SyntheticLegacyDumpTests: XCTestCase {
    func testWriteSyntheticLegacySource() async throws {
        guard let nameFile = ProcessInfo.processInfo.environment["FORM_SYNTH_NAME_FILE"] else { throw XCTSkip("FORM_SYNTH_NAME_FILE not set (generator only)") }
        try await AdminFixture.with { fx in
            let source = try await RehearsalSource.create(fx, perForm: 8, statistics: 6)
            try await source.on(fx) { s in try await s.raw("DELETE FROM anfragen WHERE file1Name='Gross.bin'").run() }
            try source.name.write(toFile: nameFile, atomically: true, encoding: .utf8)
        }
    }
}
