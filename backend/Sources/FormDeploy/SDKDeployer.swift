// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation

/// Installs / updates / rolls back the SDK directory on an FTP server (ADR 0011). Never overwrites the live directory: upload to a staging
/// directory, verify every file by reading it back, then swap by renames; exactly one previous version stays as `<name>.prev`.
///
/// Recovery contract (review Astra 2 M2): every rename result is checked, including the renames that put things back. A state in
/// which the live path is missing or a version sits only in `.<name>.swap` is reported as `repair_required`, never as a plain
/// failure or as success. `.<name>.swap` is never deleted (it can hold the only copy of a formerly live version); `.<name>.staging`
/// only ever holds new uploads and may be removed. `phase` is called BEFORE each group of remote changes so the caller can persist it.
public struct SDKDeployer: Sendable {
    public typealias Phase = @Sendable (String) async throws -> Void
    public enum Outcome: Equatable, Sendable {
        case installed(version: String, previous: String?)
        case rolledBack(to: String)
        /// The version is already live: nothing was changed (live and `.prev` stay as they are).
        case unchanged(version: String, previous: String?)
    }

    public let client: any RemoteFileClient
    let phase: Phase
    public init(client: any RemoteFileClient, phase: @escaping Phase = { _ in }) { self.client = client; self.phase = phase }

    /// `/a/b/sdk` → parent `/a/b`, name `sdk`. Absolute, 2+ levels, conservative characters, no `..`, no trailing slash.
    public static func split(_ dir: String) throws -> (parent: String, name: String) {
        guard dir.hasPrefix("/"), !dir.hasSuffix("/"), dir.utf8.count <= 240,
              dir.range(of: "^/[A-Za-z0-9._ -]+(/[A-Za-z0-9._ -]+)+$", options: .regularExpression) != nil else { throw FTPError("path_invalid") }
        let parts = dir.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(" ") || $0.hasSuffix(" ") }) else { throw FTPError("path_invalid") }
        return ("/" + parts.dropLast().joined(separator: "/"), parts.last!)
    }

    /// Every remote path a target uses: live, `.prev`, staging, swap.
    public static func footprint(_ dir: String) -> [String] {
        guard let (parent, name) = try? split(dir) else { return [dir] }
        return [dir, dir + ".prev", "\(parent)/.\(name).staging", "\(parent)/.\(name).swap"]
    }
    /// Two targets on one account overlap if any of their paths are equal or one contains the other (review Astra 2 M1). Compared
    /// without case: on a case-insensitive server file system `/web/SDK` and `/web/sdk` are one directory (rather too strict).
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        let fb = footprint(b.lowercased())
        return footprint(a.lowercased()).contains { x in fb.contains { y in x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/") } }
    }

    public func installedVersion(_ dir: String) async -> String? {
        guard let d = try? await client.download(dir + "/VERSION", limit: 64) else { return nil }
        let v = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.range(of: SDKBundle.versionPattern, options: .regularExpression) != nil ? v : nil
    }

    public func previousVersion(_ dir: String) async -> String? { await installedVersion(dir + ".prev") }

    /// A failure that does not say whether the server executed the command (no reply, connection lost, deadline). Only an explicit
    /// answer of the server (`ftp_<code>_…`, `sftp_<code>_…`) or a refusal before sending proves that a rename did NOT happen.
    static func isUnclear(_ error: Error) -> Bool {
        guard let e = error as? FTPError else { return true }
        return !(e.code.hasPrefix("ftp_") || e.code.hasPrefix("sftp_") || e.code == "path_invalid" || e.code == "bad_argument")
    }

    public func install(_ bundle: SDKBundle, to dir: String) async throws -> Outcome {
        let (parent, name) = try Self.split(dir)
        let staging = "\(parent)/.\(name).staging", prev = "\(dir).prev", swap = "\(parent)/.\(name).swap"
        guard await client.exists(parent) else { throw FTPError("parent_missing") }
        if await client.exists(swap) { throw FTPError("repair_required") }   // an interrupted rollback left a version there
        let hadDir = await client.exists(dir)
        let old = hadDir ? await installedVersion(dir) : nil
        // an existing, non-empty directory without a readable version is not ours to replace (no silent downgrade, no data loss)
        if hadDir && old == nil, !(try await client.list(dir)).isEmpty { throw FTPError("version_unknown") }
        if let old, SDKBundle.compare(bundle.version, old) < 0 { throw FTPError("downgrade_refused") }   // downgrades only via rollback
        // the same version is never installed over itself: that would replace the real .prev by a copy of live (gegenlesen Astra 2)
        if let old, SDKBundle.compare(bundle.version, old) == 0 { return .unchanged(version: old, previous: await previousVersion(dir)) }
        try await phase("upload")
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
        // swap: a rename whose outcome is unclear (no answer) may have happened on the server, so it is repair_required, never swap_failed
        try await phase("swap")
        let hadCurrent = await client.exists(dir)
        if hadCurrent {
            if await client.exists(prev) { try await removeTree(prev) }
            do { try await client.rename(dir, prev) } catch {
                if Self.isUnclear(error) { throw FTPError("repair_required") }
                try? await removeTree(staging); throw FTPError("swap_failed")
            }
        }
        do { try await client.rename(staging, dir) }
        catch {
            if Self.isUnclear(error) { throw FTPError("repair_required") }
            if hadCurrent {   // put the old version back; if that fails too, live is missing
                do { try await client.rename(prev, dir) } catch { try? await removeTree(staging); throw FTPError("repair_required") }
            }
            try? await removeTree(staging)
            throw FTPError("swap_failed")
        }
        // without a live directory before, `.prev` was left alone: report what it really holds, not a remembered value
        return .installed(version: bundle.version, previous: hadCurrent ? old : await previousVersion(dir))
    }

    public func rollback(_ dir: String) async throws -> Outcome {
        let (parent, name) = try Self.split(dir)
        let prev = "\(dir).prev", tmp = "\(parent)/.\(name).swap"
        guard await client.exists(prev) else { throw FTPError("no_previous_version") }
        guard let target = await previousVersion(dir) else { throw FTPError("previous_unreadable") }
        if await client.exists(tmp) { throw FTPError("repair_required") }   // never delete it: it may hold the only copy of a version
        try await phase("swap")
        // current -> tmp, prev -> current, tmp -> prev: the failed version stays available as .prev
        let hadCurrent = await client.exists(dir)
        if hadCurrent { do { try await client.rename(dir, tmp) } catch { throw FTPError(Self.isUnclear(error) ? "repair_required" : "swap_failed") } }
        do { try await client.rename(prev, dir) }
        catch {
            if Self.isUnclear(error) { throw FTPError("repair_required") }
            guard hadCurrent else { throw FTPError("swap_failed") }
            do { try await client.rename(tmp, dir) } catch { throw FTPError("repair_required") }
            throw FTPError("swap_failed")
        }
        if hadCurrent { do { try await client.rename(tmp, prev) } catch { throw FTPError("repair_required") } }   // live is right, .prev is missing
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
