// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One file attached to a mail (ADR 0049). The bytes exist only in memory (they are the plaintext of the upload that is still in the
/// ingest request); they are never logged and never written to a table. `Data` is copy-on-write, so the upload, the `PreparedMail`
/// and this value share one buffer until the wire form is built.
public struct MailAttachment: Sendable, Equatable {
    public let filename: String
    public let contentType: String
    public let data: Data
    /// Same as the upload limit of the ingest (5 files); the legacy mail proxy carries one.
    public static let maxPerMail = 5

    /// `filename` is sanitised (no control characters, no path separators, no quotes, no bidi overrides), `contentType` must be a plain
    /// `type/subtype` token, anything else becomes `application/octet-stream`. Text/HTML/XML types are never used (no active content in a viewer).
    public init(filename: String, contentType: String, data: Data) {
        self.filename = Self.sanitizedFilename(filename)
        self.contentType = Self.safeContentType(contentType)
        self.data = data
    }

    static func safeContentType(_ raw: String) -> String {
        let t = raw.lowercased()
        guard t.range(of: "^[a-z]+/[a-z0-9][a-z0-9.+-]{0,60}$", options: .regularExpression) != nil,
              !t.hasPrefix("text/"), !t.contains("html"), !t.contains("xml"), !t.hasPrefix("multipart/"), !t.hasPrefix("message/") else { return "application/octet-stream" }
        return t
    }

    static func sanitizedFilename(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            switch s.value {
            case 0..<0x20, 0x7F, 0x80..<0xA0, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069, 0x200B...0x200F, 0xFEFF, 0xFFFE, 0xFFFF: continue
            case 0x2F, 0x5C, 0x22: out.append("_")   // / \ "
            default: out.append(s)
            }
        }
        var name = String(out).trimmingCharacters(in: .whitespaces)
        while name.utf8.count > 255 { name.removeLast() }
        return name.isEmpty ? "anhang" : name
    }

    /// ASCII-only fallback for mail clients that ignore RFC 2231: German umlauts transliterated, everything else `_`.
    static func asciiFallback(_ name: String) -> String {
        var o = ""
        for s in name.unicodeScalars {
            switch s {
            case "ä": o += "ae"
            case "ö": o += "oe"
            case "ü": o += "ue"
            case "Ä": o += "Ae"
            case "Ö": o += "Oe"
            case "Ü": o += "Ue"
            case "ß": o += "ss"
            default: o.append(s.value >= 0x20 && s.value < 0x7F ? Character(s) : "_")
            }
        }
        return o
    }

    /// RFC 5987 `attr-char` percent encoding of the UTF-8 bytes.
    static func rfc5987(_ name: String) -> String {
        let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)
        return name.utf8.map { ok.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    /// `; <param>="ascii"`, plus `; <param>*=UTF-8''…` when the name is not plain ASCII.
    static func parameter(_ param: String, _ name: String) -> String {
        if name.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return "; \(param)=\"\(name)\"" }
        return "; \(param)=\"\(asciiFallback(name))\"; \(param)*=UTF-8''\(rfc5987(name))"
    }

    /// Size of the encoded part on the wire (base64 with CRLF every 76 characters, plus headers); used to decide what fits without building anything.
    var wireBytes: Int {
        let b64 = (data.count + 2) / 3 * 4
        return b64 + (b64 + 75) / 76 * 2 + header().utf8.count + 64
    }

    func header() -> String {
        "Content-Type: \(contentType)\(Self.parameter("name", filename))\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment\(Self.parameter("filename", filename))\r\n"
    }

    static func base64Lines(_ d: Data) -> Data {
        var out = d.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        out.append(contentsOf: [0x0D, 0x0A])
        return out
    }
}

/// Which attachments fit into one mail and what was left out. Nothing is dropped silently: the omitted ones are named in the mail
/// and reported in the delivery status (`attachments_omitted`).
public struct MailAttachmentFit: Sendable {
    public let attached: [MailAttachment]
    public let omitted: [MailAttachment]
    /// `baseBytes`: size of the mail without attachments. Greedy in upload order; a file that does not fit is left out, later smaller ones may still fit.
    public init(_ all: [MailAttachment], baseBytes: Int, limit: Int, maxCount: Int) {
        var used = baseBytes
        var a: [MailAttachment] = [], o: [MailAttachment] = []
        for x in all {
            if a.count < maxCount, used + x.wireBytes <= limit { a.append(x); used += x.wireBytes } else { o.append(x) }
        }
        attached = a; omitted = o
    }
}

enum MailAttachmentNotice {
    static func size(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576).replacingOccurrences(of: ".", with: ",") : "\(max(1, (bytes + 1023) / 1024)) KB"
    }
    /// Plain-text or HTML notice appended to the organisation mail.
    static func render(omitted: [MailAttachment], unavailable: Int, limit: Int, html: Bool) -> String {
        var lines: [String] = []
        if !omitted.isEmpty {
            lines.append("Hinweis: \(omitted.count == 1 ? "Ein Anhang konnte" : "\(omitted.count) Anhänge konnten") nicht an diese Mail angehängt werden (Größenlimit je Mail: \(size(limit))):")
            lines += omitted.map { "- \($0.filename) (\(size($0.data.count)))" }
        }
        if unavailable > 0 {
            lines.append("Hinweis: \(unavailable == 1 ? "Ein hochgeladener Anhang ist" : "\(unavailable) hochgeladene Anhänge sind") bei diesem Versand nicht beigefügt (Wiederversand oder verzögerte Mail).")
        }
        lines.append("Die Datei(en) sind in der Einsendung im Backend abrufbar.")
        if !html { return "\r\n\r\n-- \r\n" + lines.joined(separator: "\r\n") }
        return "<hr><p>" + lines.map(MailTemplate.escapeHTML).joined(separator: "<br>") + "</p>"
    }
}
