// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto

/// PHP arrays retain key type and insertion order. Numeric string keys are converted as PHP does.
public indirect enum PHPValue {
    case string(String), integer(Int64), boolean(Bool), null
    case array([(String, PHPValue)])
    // K13: unapproved floating-point/parser input is rejected, never reformatted.
    case unsupportedFloat(Double)

    public static func utf8(_ raw: Data) throws -> PHPValue {
        guard let s = strictUTF8(raw) else { throw FormCryptoError.format }
        return .string(s)
    }
    /// Validating UTF-8 decode that preserves a leading BOM (Foundation's String(data:encoding:) may drop it).
    /// Invalid sequences are rejected (they would be U+FFFD after lossy decoding and no longer round-trip).
    static func strictUTF8(_ raw: Data) -> String? {
        let s = String(decoding: raw, as: UTF8.self)
        return s.utf8.elementsEqual(raw) ? s : nil
    }
    static func quote(_ text: String) -> String {
        var out = "\""
        for u in text.unicodeScalars {
            switch u.value {
            case 34: out += "\\\""
            case 92: out += "\\\\"
            case 8: out += "\\b"
            case 9: out += "\\t"
            case 10: out += "\\n"
            case 12: out += "\\f"
            case 13: out += "\\r"
            case 0..<32, 0x2028, 0x2029: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
    /// PHP json_encode default depth. The canonical wrapper object counts as level 1.
    static let maxDepth = 512
    func json(depth: Int = 2) throws -> String {
        switch self {
        case .string(let s): return Self.quote(s)
        case .integer(let i): return String(i)
        case .boolean(let b): return b ? "true" : "false"
        case .null: return "null"
        case .unsupportedFloat: throw FormCryptoError.unsupportedPHPType
        case .array(let original):
            guard depth <= Self.maxDepth else { throw FormCryptoError.depthExceeded }
            // String representation of PHP integer keys equals the canonical decimal input.
            // Reject duplicates; a PHP parser adapter must resolve overwrites before this boundary.
            var seen = Set<Data>()
            guard original.allSatisfy({ seen.insert(Data($0.0.utf8)).inserted }) else { throw FormCryptoError.format }
            func isList(_ a: [(String, PHPValue)]) -> Bool {
                a.enumerated().allSatisfy { $0.element.0 == String($0.offset) }
            }
            let pairs = isList(original) ? original : original.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
            if isList(pairs) { return "[" + (try pairs.map { try $0.1.json(depth: depth + 1) }).joined(separator: ",") + "]" }
            return "{" + (try pairs.map { Self.quote($0.0) + ":" + (try $0.1.json(depth: depth + 1)) }).joined(separator: ",") + "}"
        }
    }
}

public struct SignedFile {
    public let name: String
    public let type: String
    public let error: Int64
    public let size: Int64
    public let content: Data?
    public init(name: String = "", type: String = "", error: Int64 = 4, size: Int64 = 0, content: Data? = nil) {
        self.name = name; self.type = type; self.error = error; self.size = size; self.content = content
    }
    func json() -> String {
        "{\"name\":" + PHPValue.quote(name) + ",\"type\":" + PHPValue.quote(type) + ",\"error\":0,\"size\":" + String(size) + ",\"sha256\":" + (content.map { PHPValue.quote(sha256($0).hex) } ?? "null") + "}"
    }
}
public indirect enum FileField {
    case single(SignedFile), multiple([FileField])
    func json() -> String? {
        switch self {
        case .single(let f): return f.error == 0 ? f.json() : nil
        case .multiple(let a):
            let parts = a.compactMap { $0.json() }
            return parts.isEmpty ? nil : "[" + parts.joined(separator: ",") + "]"
        }
    }
}

public enum RequestSignature {
    public static func canonical(fields: PHPValue, files: [(String, FileField)] = []) throws -> Data {
        guard case .array = fields else { throw FormCryptoError.format }
        var seen = Set<Data>()
        guard files.allSatisfy({ seen.insert(Data($0.0.utf8)).inserted }) else { throw FormCryptoError.format }
        let parts = files.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }.compactMap { k, v in v.json().map { (k, $0) } }
        let list = parts.enumerated().allSatisfy { $0.element.0 == String($0.offset) }
        let fileJSON = parts.isEmpty ? "[]" : (list ? "[" + parts.map { $0.1 }.joined(separator: ",") + "]" : "{" + parts.map { PHPValue.quote($0.0) + ":" + $0.1 }.joined(separator: ",") + "}")
        return bytes("{\"fields\":" + (try fields.json()) + ",\"files\":" + fileJSON + "}")
    }
    /// Public signing text for a known route. Method, route, form, timestamp and body hash are bound here;
    /// callers never supply the text (contract: path literal only from route constants).
    public static func signingText(method: String = "POST", route: SignatureRoute, formID: String, timestamp: String, canonical: Data) throws -> Data {
        try text(method: method, path: route.rawValue, formID: formID, timestamp: timestamp, canonical: canonical)
    }
    /// Raw-path variant implementing the legacy PHP normalisation; internal (tests, differential vectors).
    static func text(method: String = "POST", path: String, formID: String, timestamp: String, canonical: Data) throws -> Data {
        guard !method.isEmpty, method.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              isDecimalTimestamp(timestamp) else { throw FormCryptoError.format }
        // Preserve raw path bytes: URLComponents.percentEncodedPath would change signed bytes.
        guard !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw FormCryptoError.format }
        var p = phpURLPath(path) ?? ""
        if p.isEmpty || p == "0" { p = path } // PHP's ?: treats an unset/empty path and the string "0" as false.
        while p.hasPrefix("/") { p.removeFirst() }
        p = "/" + p
        while p.hasSuffix("/") { p.removeLast() }
        let unreserved = Set(bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
        let id = formID.utf8.map { unreserved.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
        return bytes("KUBUS-V2\n" + String(decoding: method.utf8.map { (97...122).contains($0) ? $0 - 32 : $0 }, as: UTF8.self) + "\n" + p + "/?f=" + id + "\n" + timestamp + "\n" + sha256(canonical).hex)
    }
    /// Emulates PHP's `parse_url($s, PHP_URL_PATH)` (php_url_parse_ex2) closely enough for the signed path;
    /// nil means "no path component / parse failure" (the caller then falls back to the raw string).
    /// Differentially verified against the legacy PHP in alt-sdk.json.
    static func phpURLPath(_ str: String) -> String? {
        let b = Array(str.utf8)
        func string(_ r: ArraySlice<UInt8>) -> String { String(decoding: r, as: UTF8.self) }
        func pathPart(_ from: Int) -> String? {
            var end = from
            while end < b.count && b[end] != 63 && b[end] != 35 { end += 1 }  // ? #
            return string(b[from..<end])
        }
        func authority(_ afterSlashes: Int) -> String? {  // "//host[:port]/path"
            var i = afterSlashes
            while i < b.count && b[i] != 47 && b[i] != 63 && b[i] != 35 { i += 1 }
            return i < b.count && b[i] == 47 ? pathPart(i) : nil
        }
        func isDigit(_ c: UInt8) -> Bool { (48...57).contains(c) }
        func port(_ digits: ArraySlice<UInt8>) -> Bool { digits.count <= 5 && (Int(string(digits)) ?? 99999) <= 65535 }
        guard let e = b.firstIndex(of: 58), e != 0 else {
            if b.starts(with: [47, 47]) { return authority(2) }
            return pathPart(0)
        }
        let schemeOK = b[0..<e].allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || isDigit($0) || $0 == 43 || $0 == 46 || $0 == 45 }
        if schemeOK {
            if e + 1 == b.count { return nil }  // only a scheme
            if b[e + 1] != 47 {
                var p = e + 1
                while p < b.count && isDigit(b[p]) { p += 1 }
                if (p == b.count || b[p] == 47) && (p - e) < 7 {  // "host:80/..." is host and port
                    return port(b[(e + 1)..<p]) ? (p < b.count ? pathPart(p) : nil) : nil
                }
                return pathPart(e + 1)
            }
            if e + 2 < b.count && b[e + 2] == 47 { return authority(e + 3) }
            return pathPart(e + 1)
        }
        let firstQH = b.firstIndex(where: { $0 == 63 || $0 == 35 }) ?? b.count
        if e + 1 < b.count && e < firstQH {
            var pp = e + 1
            while pp < b.count && pp - (e + 1) < 6 && isDigit(b[pp]) { pp += 1 }
            let n = pp - (e + 1)
            if n > 0 && n < 6 && (pp == b.count || b[pp] == 47) {
                return port(b[(e + 1)..<pp]) ? (pp < b.count ? pathPart(pp) : nil) : nil
            }
            if n == 0 && pp == b.count { return nil }
        }
        if b.starts(with: [47, 47]) { return authority(2) }
        return pathPart(0)
    }
    static func isDecimalTimestamp(_ t: String) -> Bool {
        !t.isEmpty && t.utf8.allSatisfy { (48...57).contains($0) } && (t == "0" || !t.hasPrefix("0"))
    }
    public static func validTimestamp(_ timestamp: String, now: Int64) -> Bool {
        guard !timestamp.isEmpty, timestamp.utf8.allSatisfy({ (48...57).contains($0) }), timestamp == "0" || !timestamp.hasPrefix("0"), let t = Int64(timestamp) else { return false }
        let distance = t.subtractingReportingOverflow(now)
        return !distance.overflow && distance.partialValue >= -300 && distance.partialValue <= 300
    }
    /// libsodium secret-key layout: seed[32] || publicKey[32].
    public static func sign(_ text: Data, sodiumSecretKey: Data) throws -> Data {
        guard sodiumSecretKey.count == 64 else { throw FormCryptoError.format }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: sodiumSecretKey.prefix(32))
        guard key.publicKey.rawRepresentation == sodiumSecretKey.suffix(32) else { throw FormCryptoError.keyMismatch }
        return try key.signature(for: text)
    }
    public static func sign(_ text: Data, seed: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: text)
    }
    /// Verifies a request signature. The signed text is rebuilt here from method/route/form/timestamp/body
    /// (the caller cannot supply or alter it); Ed25519 verification is strict (see `Ed25519Strict`).
    public static func verify(signature: Data, method: String = "POST", route: SignatureRoute, formID: String, timestamp: String,
                              canonical: Data, publicKey: Data, now: Int64) -> Bool {
        guard validTimestamp(timestamp, now: now),
              let text = try? signingText(method: method, route: route, formID: formID, timestamp: timestamp, canonical: canonical)
        else { return false }
        return Ed25519Strict.isValidSignature(signature, for: text, publicKey: publicKey)
    }
}

/// Fixed signing paths (contract signatur.md); never derived from a raw request path.
public enum SignatureRoute: String, Sendable {
    case submit = "/api/v2/submit"
    case form = "/api/v2/form"
}
