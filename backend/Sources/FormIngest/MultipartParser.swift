// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Vapor

/// Strict `multipart/form-data` reader for the submit route. Text parts are turned into an urlencoded body so that the
/// SAME bracket-name parser as for urlencoded requests decides the PHP array structure; file parts are returned separately.
/// Anything ambiguous (bad framing, missing names, oversize headers/parts) is a 400 with no side effect.
///
/// Review Astra 2 L1: only one reading of a body is accepted (checked against PHP's own parser in MultipartParserTests). Every
/// `CRLF--boundary` must be a complete delimiter (followed by CRLF, or by `--` for the end; no transport padding); the body ends right after the closing delimiter (optionally one CRLF,
/// no preamble, no epilogue); each relevant header appears at most once, without folding; parameters need their `;` separator, and
/// RFC 2231/5987 extensions (`name*=`, `filename*=`) as well as unknown parameters are refused instead of being guessed.
/// Review Astra 2 M5: file count, file size and the text budget are enforced WHILE parsing, before further parts are copied.
enum MultipartParser {
    static let maxParts = 2000
    static let maxHeaderBytes = 8192
    /// Sum of all text-part bytes (before percent-encoding), 2 MiB. The SDK sends EVERY text field as multipart as soon as one file
    /// is attached, so this is a contract limit (contracts/ingest/README.md): more is 413 `payload_too_large`, like an oversized file.
    static let maxTextBytes = 2 << 20

    struct File { let field: String; let filename: String; let declaredType: String; let data: Data }
    struct Result { let urlencoded: [UInt8]; let files: [File] }

    static func boundary(of contentType: HTTPMediaType) -> String? {
        // type, subtype and parameter names are case-insensitive (RFC 9110); the boundary VALUE is taken as it is (codex gegenlesen 7)
        guard contentType.type.lowercased() == "multipart", contentType.subType.lowercased() == "form-data",
              case let found = contentType.parameters.filter({ $0.key.lowercased() == "boundary" }), found.count == 1, let b = found.first?.value,
              (1...70).contains(b.utf8.count), b.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F && $0 != 0x22 }) else { return nil }
        return b
    }

    /// Position after CRLF at `i`, or nil. RFC 2046 transport padding is NOT accepted: PHP's parser does not accept it either.
    private static func lineEnd(_ data: Data, _ i: Int) -> Int? {
        guard i + 1 < data.endIndex, data[i] == 0x0D, data[i + 1] == 0x0A else { return nil }
        return i + 2
    }

    /// After a matched `--boundary`: `.close` (followed by `--`), `.next(start)` (a complete delimiter line) or nil (anything else).
    private enum Delimiter { case close(Int), next(Int) }
    private static func classify(_ data: Data, after i: Int) -> Delimiter? {
        if i + 1 < data.endIndex, data[i] == 0x2D, data[i + 1] == 0x2D { return .close(i + 2) }
        return lineEnd(data, i).map { .next($0) }
    }

    static func parse(_ body: [UInt8], boundary: String) throws -> Result {
        let data = Data(body)
        let delim = Data("--\(boundary)".utf8)
        let sep = Data("\r\n--\(boundary)".utf8)
        let bareLFSep = Data("\n--\(boundary)".utf8)
        guard data.starts(with: delim), var state = classify(data, after: data.startIndex + delim.count) else { throw Abort(.badRequest) }
        var text: [UInt8] = []
        var textBytes = 0
        var files: [File] = []
        var parts = 0
        while case .next(let partStart) = state {
            parts += 1
            guard parts <= maxParts else { throw Abort(.badRequest) }
            guard let headEnd = data.range(of: Data("\r\n\r\n".utf8), options: [], in: partStart..<min(data.endIndex, partStart + maxHeaderBytes + 4)) else { throw Abort(.badRequest) }
            let h = try headers(data[partStart..<headEnd.lowerBound])
            guard let field = h.name, !field.isEmpty else { throw Abort(.badRequest) }
            if let fn = h.filename, !fn.isEmpty {
                guard files.count < Uploads.maxFiles else { throw Abort(.unsupportedMediaType) }   // same answer as Uploads, before copying more
            }
            let contentStart = headEnd.upperBound
            // the next delimiter must be a COMPLETE line. A boundary prefix followed by anything else is ambiguous (PHP splits there,
            // RFC 2046 reads on) and is refused; the SDK's random boundary never occurs in content.
            guard let r = data.range(of: sep, options: [], in: contentStart..<data.endIndex), let next = classify(data, after: r.upperBound) else { throw Abort(.badRequest) }
            let contentEnd = r.lowerBound
            // PHP also ends a part at a bare-LF "\n--boundary" line: refuse it rather than read on
            guard data.range(of: bareLFSep, options: [], in: contentStart..<contentEnd) == nil else { throw Abort(.badRequest) }
            let content = data[contentStart..<contentEnd]
            state = next

            if let fn = h.filename {
                if fn.isEmpty { continue }   // browsers send an empty filename when no file was chosen: no file
                guard content.count < Uploads.maxBytes else { throw Abort(.payloadTooLarge) }
                files.append(File(field: field, filename: fn, declaredType: h.type, data: Data(content)))
            } else {
                textBytes += content.count
                guard textBytes <= maxTextBytes else { throw Abort(.payloadTooLarge) }
                guard String(data: Data(content), encoding: .utf8) != nil else { throw Abort(.badRequest) }
                if !text.isEmpty { text.append(UInt8(ascii: "&")) }
                pct(Array(field.utf8), into: &text); text.append(UInt8(ascii: "=")); pct(content, into: &text)
            }
        }
        guard case .close(let end) = state,
              end == data.endIndex || (end + 2 == data.endIndex && data[end] == 0x0D && data[end + 1] == 0x0A) else { throw Abort(.badRequest) }
        return Result(urlencoded: text, files: files)
    }

    private struct PartHeaders { var name: String?; var filename: String?; var type = "text/plain" }

    private static func headers(_ raw: Data) throws -> PartHeaders {
        guard let s = String(data: raw, encoding: .utf8) else { throw Abort(.badRequest) }
        var out = PartHeaders()
        var seen = Set<String>()
        // CR and LF only as a pair (no bare CR/LF that another parser might treat as a line end)
        let bytes = Array(raw)
        for (i, c) in bytes.enumerated() where (c == 0x0D && (i + 1 == bytes.count || bytes[i + 1] != 0x0A)) || (c == 0x0A && (i == 0 || bytes[i - 1] != 0x0D)) {
            throw Abort(.badRequest)
        }
        for line in s.components(separatedBy: "\r\n") {
            // no folding, a token before the colon
            guard let first = line.unicodeScalars.first, first != " ", first != "\t", let colon = line.firstIndex(of: ":") else { throw Abort(.badRequest) }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { throw Abort(.badRequest) }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard ["content-disposition", "content-type", "content-transfer-encoding"].contains(key) else { continue }
            guard seen.insert(key).inserted else { throw Abort(.badRequest) }   // a second header would override the first in some parsers
            switch key {
            case "content-disposition":
                let p = try params(value)
                guard p.kind == "form-data" else { throw Abort(.badRequest) }
                out.name = p.values["name"]; out.filename = p.values["filename"]
            case "content-type":
                let t = value.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                guard !t.isEmpty else { throw Abort(.badRequest) }
                out.type = t
            default:
                guard ["binary", "8bit", "7bit"].contains(value.lowercased()) else { throw Abort(.badRequest) }
            }
        }
        return out
    }

    private static let hex = Array("0123456789ABCDEF".utf8)
    private static func pct<C: Collection>(_ b: C, into out: inout [UInt8]) where C.Element == UInt8 {
        out.reserveCapacity(out.count + b.count)
        for c in b {
            if (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x2E || c == 0x5F || c == 0x7E { out.append(c) }
            else { out.append(0x25); out.append(hex[Int(c >> 4)]); out.append(hex[Int(c & 0x0F)]) }
        }
    }

    /// `form-data; name="x"; filename="y"`: quoted values (backslash escapes) or tokens, one `;` before each parameter, only `name`/`filename`.
    static func params(_ v: String) throws -> (kind: String, values: [String: String]) {
        let ws: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        var rest = Substring(v)
        let kindEnd = rest.firstIndex(of: ";") ?? rest.endIndex
        let kind = rest[..<kindEnd].trimmingCharacters(in: .whitespaces).lowercased()
        rest = rest[kindEnd...]
        var out: [String: String] = [:]
        while !rest.isEmpty {
            guard rest.first == ";" else { throw Abort(.badRequest) }   // every parameter is introduced by exactly one separator
            rest = rest.dropFirst().drop(while: ws)
            guard let eq = rest.firstIndex(of: "=") else { throw Abort(.badRequest) }
            let key = rest[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "name" || key == "filename" else { throw Abort(.badRequest) }   // also refuses name*= / filename*= (RFC 2231)
            rest = rest[rest.index(after: eq)...].drop(while: ws)
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var closed = false
                while let c = rest.first {
                    rest = rest.dropFirst()
                    if c == "\\", let n = rest.first { value.append(n); rest = rest.dropFirst(); continue }
                    if c == "\"" { closed = true; break }
                    value.append(c)
                }
                guard closed else { throw Abort(.badRequest) }
            } else {
                let end = rest.firstIndex(where: { $0 == ";" || ws($0) }) ?? rest.endIndex
                value = String(rest[..<end])
                guard !value.isEmpty, !value.contains("\"") else { throw Abort(.badRequest) }
                rest = rest[end...]
            }
            rest = rest.drop(while: ws)
            guard out[key] == nil else { throw Abort(.badRequest) }
            out[key] = value
        }
        return (kind, out)
    }
}
