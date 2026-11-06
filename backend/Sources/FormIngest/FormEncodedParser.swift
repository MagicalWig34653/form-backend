// SPDX-License-Identifier: AGPL-3.0-only
import FormCrypto
import Foundation
import Vapor

/// Parses `application/x-www-form-urlencoded` into the PHP array structure (bracket notation) that the signature
/// canonicalisation expects. Stricter than PHP where PHP would silently lose data (contract ingest/README
/// "VORGESCHLAGEN": ambiguous duplicates, invalid UTF-8 and malformed names -> 400, no side effect).
enum FormEncodedParser {
    static let maxVariables = 1000   // PHP max_input_vars
    static let maxDepth = 64         // PHP max_input_nesting_level
    /// Pre-authentication cost caps (review P5-A B3): every non-empty segment counts (also empty names), names are bounded.
    static let maxSegments = 2000
    static let maxNameBytes = 4096

    private indirect enum Node {
        case leaf(String)
        case branch([(String, Node)])
    }
    private enum Key { case append, name(String) }

    static func parse(_ body: [UInt8]) throws -> PHPValue {
        var root: [(String, Node)] = []
        var count = 0
        var segments = 0
        for segment in body.split(separator: UInt8(ascii: "&"), omittingEmptySubsequences: true) {
            segments += 1
            guard segments <= maxSegments else { throw Abort(.badRequest) }
            let eq = segment.firstIndex(of: UInt8(ascii: "="))
            let rawName = eq.map { segment[segment.startIndex..<$0] } ?? segment
            let rawValue = eq.map { segment[segment.index(after: $0)...] } ?? []
            guard rawName.count <= 3 * maxNameBytes else { throw Abort(.badRequest) }
            guard let name = try decode(rawName), let value = try decode(rawValue) else { throw Abort(.badRequest) }
            guard name.utf8.count <= maxNameBytes else { throw Abort(.badRequest) }
            if name.unicodeScalars.contains(where: { $0.value == 0 }) { throw Abort(.badRequest) }
            guard let (top, keys) = splitName(name) else { throw Abort(.badRequest) }
            if top.isEmpty { continue }  // PHP skips empty names
            count += 1
            guard count <= maxVariables, keys.count < maxDepth else { throw Abort(.badRequest) }
            var path: [Key] = [.name(top)]
            path += keys
            try insert(&root, path[...], value)
        }
        return .array(root.map { ($0.0, convert($0.1)) })
    }

    private static func convert(_ n: Node) -> PHPValue {
        switch n {
        case .leaf(let s): return .string(s)
        case .branch(let items): return .array(items.map { ($0.0, convert($0.1)) })
        }
    }

    private static func insert(_ items: inout [(String, Node)], _ path: ArraySlice<Key>, _ value: String) throws {
        guard let first = path.first else { throw Abort(.badRequest) }
        let rest = path.dropFirst()
        let keyName: String
        switch first {
        case .name(let n): keyName = n
        case .append:
            // Next integer index after the highest existing integer key (PHP array append semantics).
            let highest = items.compactMap { k -> Int64? in Int64(k.0).flatMap { String($0) == k.0 ? $0 : nil } }.max()
            var next: Int64 = 0
            if let highest {
                let (n, overflow) = highest.addingReportingOverflow(1)
                if overflow { throw Abort(.badRequest) }  // PHP cannot append after PHP_INT_MAX either
                next = n
            }
            keyName = String(next)
        }
        // Bytewise comparison like PHP, not Swift's Unicode-equivalent String ==.
        if let idx = items.firstIndex(where: { $0.0.utf8.elementsEqual(keyName.utf8) }) {
            guard !rest.isEmpty, case .branch(var inner) = items[idx].1 else { throw Abort(.badRequest) }  // duplicate leaf / leaf-vs-array
            try insert(&inner, rest, value)
            items[idx].1 = .branch(inner)
        } else if rest.isEmpty {
            items.append((keyName, .leaf(value)))
        } else {
            var inner: [(String, Node)] = []
            try insert(&inner, rest, value)
            items.append((keyName, .branch(inner)))
        }
    }

    /// `a.b c[x][]` -> ("a_b_c", [.name(x), .append]). Top-level `.` and space become `_` (PHP). nil = malformed.
    private static func splitName(_ name: String) -> (String, [Key])? {
        let u = Array(name.unicodeScalars)
        var i = 0
        while i < u.count && u[i] == " " { i += 1 }  // PHP drops leading spaces
        var top = ""
        while i < u.count && u[i] != "[" {
            if u[i] == "]" { return nil }
            top.unicodeScalars.append(u[i] == "." || u[i] == " " ? "_" : u[i]); i += 1
        }
        var keys: [Key] = []
        while i < u.count {
            guard u[i] == "[" else { return nil }
            var j = i + 1, inner = ""
            while j < u.count && u[j] != "]" {
                if u[j] == "[" { return nil }
                inner.unicodeScalars.append(u[j]); j += 1
            }
            guard j < u.count else { return nil }
            keys.append(inner.isEmpty ? .append : .name(inner))
            i = j + 1
        }
        return (top, keys)
    }

    /// Percent-decoding with `+` as space; a malformed escape or invalid UTF-8 is an error (nil result is never used).
    private static func decode<S: Collection>(_ raw: S) throws -> String? where S.Element == UInt8 {
        var out: [UInt8] = []
        var it = raw.makeIterator()
        while let b = it.next() {
            if b == UInt8(ascii: "+") { out.append(32) }
            else if b == UInt8(ascii: "%") {
                guard let h = it.next(), let l = it.next(), let hv = hex(h), let lv = hex(l) else { throw Abort(.badRequest) }
                out.append(hv << 4 | lv)
            } else { out.append(b) }
        }
        let s = String(decoding: out, as: UTF8.self)
        guard s.utf8.elementsEqual(out) else { throw Abort(.badRequest) }
        return s
    }
    private static func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }
}
