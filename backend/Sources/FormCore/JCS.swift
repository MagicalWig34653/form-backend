// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// JSON value for canonicalisation. Numbers are integers only (ADR 0008 F1: RFC 8785 with whole numbers in the
/// safe range ±(2^53-1); floating point is rejected so no number-formatting ambiguity exists).
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public enum JCSError: Error, Equatable {
    case invalidJSON, duplicateKey, unsupportedNumber, tooDeep, invalidUTF8
}

/// RFC 8785 JSON Canonicalization Scheme over `JSONValue` plus a strict parser (no duplicate keys, no floats,
/// no leading zeros, no BOM, valid UTF-8, bounded depth).
public enum JCS {
    public static let maxDepth = 64
    public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    public static func canonicalize(_ v: JSONValue) -> Data {
        var out = [UInt8]()
        write(v, &out)
        return Data(out)
    }

    /// Parses `data` strictly and returns the canonical bytes.
    public static func canonicalize(json data: Data) throws -> Data { canonicalize(try parse(data)) }

    // MARK: writer

    private static func write(_ v: JSONValue, _ out: inout [UInt8]) {
        switch v {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .int(let i): out += Array(String(i).utf8)
        case .string(let s): writeString(s, &out)
        case .array(let a):
            out.append(0x5B)
            for (i, e) in a.enumerated() { if i > 0 { out.append(0x2C) }; write(e, &out) }
            out.append(0x5D)
        case .object(let o):
            out.append(0x7B)
            // Keys sorted by UTF-16 code units (RFC 8785 §3.2.3), not by Unicode scalars or bytes.
            let keys = o.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (i, k) in keys.enumerated() {
                if i > 0 { out.append(0x2C) }
                writeString(k, &out); out.append(0x3A); write(o[k]!, &out)
            }
            out.append(0x7D)
        }
    }

    private static func writeString(_ s: String, _ out: inout [UInt8]) {
        out.append(0x22)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += Array("\\\"".utf8)
            case 0x5C: out += Array("\\\\".utf8)
            case 0x08: out += Array("\\b".utf8)
            case 0x0C: out += Array("\\f".utf8)
            case 0x0A: out += Array("\\n".utf8)
            case 0x0D: out += Array("\\r".utf8)
            case 0x09: out += Array("\\t".utf8)
            case 0..<0x20: out += Array(String(format: "\\u%04x", u.value).utf8)
            default: out += Array(String(u).utf8)
            }
        }
        out.append(0x22)
    }

    // MARK: parser

    public static func parse(_ data: Data) throws -> JSONValue {
        guard String(data: data, encoding: .utf8) != nil, !data.starts(with: [0xEF, 0xBB, 0xBF]) else { throw JCSError.invalidUTF8 }
        var p = Parser(bytes: [UInt8](data))
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        guard p.i == p.bytes.count else { throw JCSError.invalidJSON }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWS() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth <= JCS.maxDepth else { throw JCSError.tooDeep }
            guard i < bytes.count else { throw JCSError.invalidJSON }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1; skipWS()
                var o: [String: JSONValue] = [:]
                if peek(UInt8(ascii: "}")) { i += 1; return .object(o) }
                while true {
                    skipWS()
                    guard peek(UInt8(ascii: "\"")) else { throw JCSError.invalidJSON }
                    let k = try string()
                    skipWS()
                    guard peek(UInt8(ascii: ":")) else { throw JCSError.invalidJSON }
                    i += 1; skipWS()
                    guard o[k] == nil else { throw JCSError.duplicateKey }
                    o[k] = try value(depth: depth + 1)
                    skipWS()
                    if peek(UInt8(ascii: ",")) { i += 1; continue }
                    if peek(UInt8(ascii: "}")) { i += 1; return .object(o) }
                    throw JCSError.invalidJSON
                }
            case UInt8(ascii: "["):
                i += 1; skipWS()
                var a: [JSONValue] = []
                if peek(UInt8(ascii: "]")) { i += 1; return .array(a) }
                while true {
                    skipWS()
                    a.append(try value(depth: depth + 1))
                    skipWS()
                    if peek(UInt8(ascii: ",")) { i += 1; continue }
                    if peek(UInt8(ascii: "]")) { i += 1; return .array(a) }
                    throw JCSError.invalidJSON
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try lit("true"); return .bool(true)
            case UInt8(ascii: "f"): try lit("false"); return .bool(false)
            case UInt8(ascii: "n"): try lit("null"); return .null
            default: return try number()
            }
        }

        func peek(_ b: UInt8) -> Bool { i < bytes.count && bytes[i] == b }

        mutating func lit(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw JCSError.invalidJSON }
            i += u.count
        }

        mutating func number() throws -> JSONValue {
            let start = i
            if peek(UInt8(ascii: "-")) { i += 1 }
            let digitsStart = i
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            let digits = i - digitsStart
            guard digits > 0 else { throw JCSError.invalidJSON }
            if i < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[i]) { throw JCSError.unsupportedNumber }
            if digits > 1 && bytes[digitsStart] == 0x30 { throw JCSError.invalidJSON }          // leading zero
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if text == "-0" { throw JCSError.unsupportedNumber }
            guard digits <= 16, let n = Int64(text), abs(n) <= JCS.maxSafeInteger else { throw JCSError.unsupportedNumber }
            return .int(n)
        }

        mutating func string() throws -> String {
            i += 1   // opening quote
            var scalars = String.UnicodeScalarView()
            while true {
                guard i < bytes.count else { throw JCSError.invalidJSON }
                let b = bytes[i]
                if b == 0x22 { i += 1; return String(scalars) }
                if b < 0x20 { throw JCSError.invalidJSON }
                if b == 0x5C {
                    i += 1
                    guard i < bytes.count else { throw JCSError.invalidJSON }
                    let e = bytes[i]; i += 1
                    switch e {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        let hi = try hex4()
                        if (0xD800...0xDBFF).contains(hi) {
                            guard i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == UInt8(ascii: "u") else { throw JCSError.invalidJSON }
                            i += 2
                            let lo = try hex4()
                            guard (0xDC00...0xDFFF).contains(lo), let sc = Unicode.Scalar(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)) else { throw JCSError.invalidJSON }
                            scalars.append(sc)
                        } else {
                            guard !(0xDC00...0xDFFF).contains(hi), let sc = Unicode.Scalar(hi) else { throw JCSError.invalidJSON }  // lone surrogate
                            scalars.append(sc)
                        }
                    default: throw JCSError.invalidJSON
                    }
                } else {
                    // Raw UTF-8 sequence (validity was checked for the whole input up front).
                    let len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
                    guard i + len <= bytes.count, let s = String(bytes: bytes[i..<i + len], encoding: .utf8), let sc = s.unicodeScalars.first else { throw JCSError.invalidUTF8 }
                    scalars.append(sc); i += len
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw JCSError.invalidJSON }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]; i += 1
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c) - 0x30
                case 0x41...0x46: d = UInt32(c) - 0x37
                case 0x61...0x66: d = UInt32(c) - 0x57
                default: throw JCSError.invalidJSON
                }
                v = v << 4 | d
            }
            return v
        }
    }
}
