// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCrypto
import Foundation
import Vapor

struct Upload {
    let content: Data
    /// Original file name and the SERVER-DETECTED content type (never the declared one): what a mail attachment carries (ADR 0049).
    var filename = ""
    var detectedType = "application/octet-stream"
    var wire = Data()
    var kid = ""
    var payloadHash = Data()
}

/// Upload rules of the submit route (contracts/ingest/README.md "Upload-Vertrag"): allow-listed extensions whose server-detected
/// content type matches, < 20,000,000 bytes (413), at most `maxFiles` (415, never silently dropped). The declared type is signed
/// as sent; the DETECTED type decides acceptance. Hash-based malware checks run in AbuseProtection after signature/replay verification.
enum Uploads {
    static let maxBytes = 20_000_000
    static let maxFiles = 5
    static let allowed: [String: Set<String>] = [
        "pdf": ["application/pdf"], "png": ["image/png"], "jpg": ["image/jpeg"], "jpeg": ["image/jpeg"],
        "heic": ["image/heic", "image/heic-sequence", "image/heif", "image/heif-sequence"],
        "heif": ["image/heif", "image/heif-sequence", "image/heic", "image/heic-sequence"],
    ]

    static func sniff(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(16))
        if b.starts(with: Array("%PDF-".utf8)) { return "application/pdf" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            switch String(decoding: b[8..<12], as: UTF8.self) {
            case "heic", "heix", "hevc", "hevx": return "image/heic"
            case "mif1", "msf1", "heim", "heis": return "image/heif"
            default: return nil
            }
        }
        return nil
    }

    /// Field names: `x` (one file) or `x[]` (list); x has no dots, spaces or brackets (they would not survive PHP's own rewriting).
    static func prepare(_ files: [MultipartParser.File]) throws -> ([Upload], [(String, FileField)]) {
        guard files.count <= maxFiles else { throw Abort(.unsupportedMediaType) }
        var groups: [(name: String, list: Bool, items: [(Upload, SignedFile)])] = []
        var uploads: [Upload] = []
        for f in files {
            let list = f.field.hasSuffix("[]")
            let base = list ? String(f.field.dropLast(2)) : f.field
            guard !base.isEmpty, base.utf8.count <= 190, !base.contains(where: { ".[] \t\r\n\0".contains($0) }) else { throw Abort(.unsupportedMediaType) }
            guard f.data.count < maxBytes else { throw Abort(.payloadTooLarge) }
            let ext = (f.filename as NSString).pathExtension.lowercased()
            guard let ok = allowed[ext], let real = sniff(f.data), ok.contains(real), f.filename.utf8.count <= 255,
                  !f.filename.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
                  f.declaredType.utf8.count <= 127, !f.declaredType.contains(where: { $0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? true }) else { throw Abort(.unsupportedMediaType) }
            let signed = SignedFile(name: f.filename, type: f.declaredType, error: 0, size: Int64(f.data.count), content: f.data)
            if let i = groups.firstIndex(where: { $0.name == base }) {
                guard groups[i].list, list else { throw Abort(.unsupportedMediaType) }   // the same field twice without [] would lose a file in PHP
                groups[i].items.append((Upload(content: f.data, filename: f.filename, detectedType: real), signed))
            } else {
                groups.append((base, list, [(Upload(content: f.data, filename: f.filename, detectedType: real), signed)]))
            }
        }
        var fileFields: [(String, FileField)] = []
        // ordinal = position in the signed order: field names sorted bytewise, list order inside a field
        for g in groups.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
            fileFields.append((g.name, g.list ? .multiple(g.items.map { .single($0.1) }) : .single(g.items[0].1)))
            uploads += g.items.map(\.0)
        }
        return (uploads, fileFields)
    }
}
