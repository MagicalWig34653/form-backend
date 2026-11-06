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
