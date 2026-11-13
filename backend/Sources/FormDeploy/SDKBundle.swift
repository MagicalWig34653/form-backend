// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation

/// The PHP SDK as shipped inside the server image: version + files (ADR 0011). Only a fixed list of file kinds is ever deployed.
public struct SDKBundle: Sendable {
    public struct Item: Sendable { public let path: String; public let data: Data; public var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() } }
    public let version: String
    public let items: [Item]

    public enum Failure: Error, Equatable { case missing, versionInvalid, tooLarge, unexpectedFile(String) }

    static let versionPattern = "^[0-9]{1,9}\\.[0-9]{1,9}\\.[0-9]{1,9}$"

    /// `dir/VERSION` plus `src/*.php`, `bin/*.php`, `composer.json`, `README.md`, `VERSION`. Symlinks, other kinds and oversized sets are refused.
    public static func load(from dir: URL) throws -> SDKBundle {
        let fm = FileManager.default
        guard let v = try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8) else { throw Failure.missing }
        let version = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: versionPattern, options: .regularExpression) != nil else { throw Failure.versionInvalid }
        var items: [Item] = []
        var total = 0
        func add(_ rel: String) throws {
            let url = dir.appendingPathComponent(rel)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw Failure.unexpectedFile(rel) }   // no symlinks
            let d = try Data(contentsOf: url)
            total += d.count
            guard total <= 4 << 20 else { throw Failure.tooLarge }
            items.append(Item(path: rel, data: d))
        }
        for rel in ["VERSION", "composer.json", "README.md"] { if fm.fileExists(atPath: dir.appendingPathComponent(rel).path) { try add(rel) } }
        for sub in ["src", "bin"] {
            let names = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path)) ?? []
            for n in names.sorted() where n.hasSuffix(".php") && !n.hasPrefix(".") { try add("\(sub)/\(n)") }
        }
        guard items.contains(where: { $0.path.hasPrefix("src/") }) else { throw Failure.missing }
        return SDKBundle(version: version, items: items)
    }

    /// SemVer ordering of two `x.y.z` strings.
    public static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<3 { let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0; if l != r { return l < r ? -1 : 1 } }
        return 0
    }
}
