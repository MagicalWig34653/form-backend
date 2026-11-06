// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation

/// Installs / updates / rolls back the SDK directory on an FTP server (ADR 0011). Never overwrites the live directory: upload to a staging
/// directory, verify every file by reading it back, then swap by renames; exactly one previous version stays as `<name>.prev`.
public struct SDKDeployer: Sendable {
    public enum Outcome: Equatable, Sendable {
        case installed(version: String, previous: String?)
        case rolledBack(to: String)
    }

    public let client: any RemoteFileClient
    public init(client: any RemoteFileClient) { self.client = client }

    /// `/a/b/sdk` → parent `/a/b`, name `sdk`. Absolute, 2+ levels, conservative characters, no `..`, no trailing slash.
    public static func split(_ dir: String) throws -> (parent: String, name: String) {
        guard dir.hasPrefix("/"), !dir.hasSuffix("/"), dir.utf8.count <= 240,
              dir.range(of: "^/[A-Za-z0-9._ -]+(/[A-Za-z0-9._ -]+)+$", options: .regularExpression) != nil else { throw FTPError("path_invalid") }
        let parts = dir.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(" ") || $0.hasSuffix(" ") }) else { throw FTPError("path_invalid") }
        return ("/" + parts.dropLast().joined(separator: "/"), parts.last!)
    }

    public func installedVersion(_ dir: String) async -> String? {
        guard let d = try? await client.download(dir + "/VERSION", limit: 64) else { return nil }
        let v = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.range(of: SDKBundle.versionPattern, options: .regularExpression) != nil ? v : nil
    }

    public func previousVersion(_ dir: String) async -> String? { await installedVersion(dir + ".prev") }

    public func install(_ bundle: SDKBundle, to dir: String) async throws -> Outcome {
        let (parent, name) = try Self.split(dir)
        let staging = "\(parent)/.\(name).staging", prev = "\(dir).prev"
        guard await client.exists(parent) else { throw FTPError("parent_missing") }
        let hadDir = await client.exists(dir)
        let old = hadDir ? await installedVersion(dir) : nil
        // an existing, non-empty directory without a readable version is not ours to replace (no silent downgrade, no data loss)
        if hadDir && old == nil, !(try await client.list(dir)).isEmpty { throw FTPError("version_unknown") }
        if let old, SDKBundle.compare(bundle.version, old) < 0 { throw FTPError("downgrade_refused") }   // downgrades only via rollback
        if await client.exists(staging) { try await removeTree(staging) }
        try await client.makeDirectory(staging)
        do {
            var made: Set<String> = []
            for item in bundle.items {
                let dirs = item.path.split(separator: "/").dropLast()
                var cur = staging
                for d in dirs { cur += "/" + d; if made.insert(cur).inserted { try await client.makeDirectory(cur) } }
                try await client.upload("\(staging)/\(item.path)", item.data)
                // read back and compare: what the customer's server holds must be exactly what was shipped
                let back = try await client.download("\(staging)/\(item.path)", limit: 8 << 20)
                guard back.count == item.data.count, Data(SHA256.hash(data: back)) == Data(SHA256.hash(data: item.data)) else { throw FTPError("verify_failed") }
            }
        } catch { try? await removeTree(staging); throw error }
        // swap
        let hadCurrent = await client.exists(dir)
        if hadCurrent {
            if await client.exists(prev) { try await removeTree(prev) }
            do { try await client.rename(dir, prev) } catch { try? await removeTree(staging); throw FTPError("swap_failed") }
        }
        do { try await client.rename(staging, dir) }
        catch {
            if hadCurrent { try? await client.rename(prev, dir) }   // put the old version back
            try? await removeTree(staging)
            throw FTPError("swap_failed")
        }
        return .installed(version: bundle.version, previous: hadCurrent ? old : nil)
    }

    public func rollback(_ dir: String) async throws -> Outcome {
        let (parent, name) = try Self.split(dir)
        let prev = "\(dir).prev", tmp = "\(parent)/.\(name).swap"
        guard await client.exists(prev) else { throw FTPError("no_previous_version") }
        guard let target = await previousVersion(dir) else { throw FTPError("previous_unreadable") }
        if await client.exists(tmp) { try await removeTree(tmp) }
        // current -> tmp, prev -> current, tmp -> prev: the failed version stays available as .prev
        if await client.exists(dir) { do { try await client.rename(dir, tmp) } catch { throw FTPError("swap_failed") } }
        do { try await client.rename(prev, dir) }
        catch { try? await client.rename(tmp, dir); throw FTPError("swap_failed") }
        if await client.exists(tmp) { try? await client.rename(tmp, prev) }
        return .rolledBack(to: target)
    }

    /// Depth-first removal that never follows links: every entry is first tried as a plain delete (a file or a link is removed itself, a
    /// directory refuses), only then is it entered. Entry names must be one safe path component.
    func removeTree(_ path: String, depth: Int = 0) async throws {
        guard depth < 8 else { throw FTPError("path_invalid") }
        if (try? await client.delete(path)) != nil { return }
        guard await client.isDirectory(path) else { throw FTPError("remove_failed") }
        for n in (try await client.list(path)) {
            guard n != ".", n != "..", !n.isEmpty, !n.contains("/"), !n.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { throw FTPError("path_invalid") }
            try await removeTree("\(path)/\(n)", depth: depth + 1)
        }
        try await client.removeDirectory(path)
    }
}
