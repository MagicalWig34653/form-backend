// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation

/// 422 with the violated rule (static strings of the validator, never request values).
public struct ValidationFailed: PublicProblemError {
    let detail: String
    init(_ e: DocumentInvalid) { detail = e.path.isEmpty ? e.rule : "\(e.path): \(e.rule)" }
    init(detail: String) { self.detail = detail }
    public var statusCode: UInt { 422 }
    public var code: String { "validation_failed" }
    public var message: String { "Dokument ungültig: \(detail)" }
}

/// 409: a version (resource + semantic version) already exists with different content.
public struct VersionConflict: PublicProblemError {
    let kind: String
    init(kind: String) { self.kind = kind }
    public var statusCode: UInt { 409 }
    public var code: String { "conflict" }
    public var message: String { "Die Version von \(kind) existiert bereits mit anderem Inhalt. Bitte die Version erhöhen." }
}

/// 404 for a customer key generation without a recovery wrap (the migration left none, or the generation is not live). Thrown only
/// AFTER the caller was authorised (key.manage), so it reveals nothing to outsiders; the browser uses the code to point to the
/// legacy key adoption instead of reporting a generic failure.
public struct KeyRecoveryMissing: PublicProblemError {
    public var statusCode: UInt { 404 }
    public var code: String { "recovery_missing" }
    public var message: String { "Für diese Schlüsselgeneration ist keine Wiederherstellung hinterlegt." }
}

/// Retention period problems (ADR 0012 no. 2): fixed German reasons, never request data.
struct RetentionProblem: PublicProblemError {
    let statusCode: UInt
    let code: String
    let message: String
    /// `days: null`, missing or a value outside 1-3650.
    static let required = RetentionProblem(statusCode: 422, code: "retention_required", message: "Aufbewahrungsfrist ist Pflicht (\(Retention.minDays)–\(Retention.maxDays) Tage).")
    /// Publishing without a stored period.
    static let missing = RetentionProblem(statusCode: 409, code: "retention_missing", message: "Aufbewahrungsfrist fehlt")
    /// Changing the period would rewrite imported submissions while the import can still be resumed.
    static let importRunning = RetentionProblem(statusCode: 409, code: "retention_import_running", message: "Die Aufbewahrungsfrist kann nicht geändert werden, solange ein Import fortgesetzt werden kann. Import abschließen oder im Umstieg schließen, danach erneut versuchen.")
}
