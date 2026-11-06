// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Vapor

/// Strict `multipart/form-data` reader for the submit route. Text parts are turned into an urlencoded body so that the
/// SAME bracket-name parser as for urlencoded requests decides the PHP array structure; file parts are returned separately.
/// Anything ambiguous (bad framing, missing names, oversize headers/parts) is a 400 with no side effect.
enum MultipartParser {
    static let maxParts = 2000
    static let maxHeaderBytes = 8192

    struct File { let field: String; let filename: String; let declaredType: String; let data: Data }
    struct Result { let urlencoded: [UInt8]; let files: [File] }

    static func boundary(of contentType: HTTPMediaType) -> String? {
        guard contentType.type == "multipart", contentType.subType == "form-data", let b = contentType.parameters["boundary"],
              (1...70).contains(b.utf8.count), b.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F && $0 != 0x22 }) else { return nil }
        return b
    }

    static func parse(_ body: [UInt8], boundary: String) throws -> Result {
        let data = Data(body)
        let delim = Data("--\(boundary)".utf8)
        let sep = Data("\r\n--\(boundary)".utf8)
        guard data.starts(with: delim) else { throw Abort(.badRequest) }
        var pos = delim.count
        var text: [UInt8] = []
        var files: [File] = []
        var parts = 0
        while true {
            // after a delimiter: "--" closes, CRLF opens the next part
            guard data.count >= pos + 2 else { throw Abort(.badRequest) }
            let next = data[data.startIndex + pos ..< data.startIndex + pos + 2]
            if next.elementsEqual([0x2D, 0x2D]) { break }                 // closing delimiter (epilogue ignored)
            guard next.elementsEqual([0x0D, 0x0A]) else { throw Abort(.badRequest) }
            pos += 2
            parts += 1
            guard parts <= maxParts else { throw Abort(.badRequest) }
            guard let headEnd = data.range(of: Data("\r\n\r\n".utf8), options: [], in: (data.startIndex + pos)..<min(data.endIndex, data.startIndex + pos + maxHeaderBytes + 4)) else { throw Abort(.badRequest) }
            let headers = String(decoding: data[(data.startIndex + pos)..<headEnd.lowerBound], as: UTF8.self)
            let contentStart = headEnd.upperBound
            guard let end = data.range(of: sep, options: [], in: contentStart..<data.endIndex) else { throw Abort(.badRequest) }
            let content = data[contentStart..<end.lowerBound]
            pos = end.upperBound - data.startIndex

            var name: String?, filename: String?, type = "text/plain"
            for line in headers.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { throw Abort(.badRequest) }
                let key = line[..<colon].lowercased(), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key == "content-disposition" {
                    let p = try params(value)
                    guard p.kind == "form-data" else { throw Abort(.badRequest) }
                    name = p.values["name"]; filename = p.values["filename"]
                } else if key == "content-type" {
                    type = value.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? type
                } else if key == "content-transfer-encoding" {
                    guard value.lowercased() == "binary" || value.lowercased() == "8bit" || value.lowercased() == "7bit" else { throw Abort(.badRequest) }
                }
            }
            guard let field = name, !field.isEmpty else { throw Abort(.badRequest) }
            if let fn = filename {
                if fn.isEmpty { continue }   // browsers send an empty filename when no file was chosen: no file
                files.append(File(field: field, filename: fn, declaredType: type, data: Data(content)))
            } else {
                guard String(data: Data(content), encoding: .utf8) != nil else { throw Abort(.badRequest) }
                if !text.isEmpty { text.append(UInt8(ascii: "&")) }
                text += pct(field) + [UInt8(ascii: "=")] + pct(Array(content))
            }
        }
        return Result(urlencoded: text, files: files)
    }

    private static func pct(_ s: String) -> [UInt8] { pct(Array(s.utf8)) }
    private static func pct(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for c in b {
            if (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x2E || c == 0x5F || c == 0x7E { out.append(c) }
            else { out += Array(String(format: "%%%02X", c).utf8) }
        }
        return out
    }

    /// `form-data; name="x"; filename="y"` with quoted values (backslash escapes), no RFC 2231 extensions.
    private static func params(_ v: String) throws -> (kind: String, values: [String: String]) {
        var rest = Substring(v)
        guard let semi = rest.firstIndex(of: ";") else { return (v.lowercased(), [:]) }
        let kind = rest[..<semi].trimmingCharacters(in: .whitespaces).lowercased()
        rest = rest[rest.index(after: semi)...]
        var out: [String: String] = [:]
        while !rest.isEmpty {
            rest = rest.drop(while: { $0 == " " || $0 == ";" })
            if rest.isEmpty { break }
            guard let eq = rest.firstIndex(of: "=") else { throw Abort(.badRequest) }
            let key = rest[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: eq)...]
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
                let end = rest.firstIndex(of: ";") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            guard out[key] == nil else { throw Abort(.badRequest) }
            out[key] = value
        }
        return (kind, out)
    }
}
