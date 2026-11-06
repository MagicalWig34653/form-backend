// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormDeploy
import Foundation

/// Every operation owns a new pinned SSH session; a failed session is never reused.
public struct SFTPObjectStore: ObjectStore {
    public let config: SFTPConfig
    public let root: String
    public let allowedNets: [CIDR]

    public init(config: [String: Any], credential: String, allowedNets: [CIDR] = []) throws {
        guard let root = config["root"] as? String, root.hasPrefix("/"), root.utf8.count <= 512,
              !root.contains("\\"), !root.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              root.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw StorageError("invalid_storage_root") }
        self.config = try DeployService.sftpConfig(config, password: credential)
        self.root = root == "/" ? "" : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.allowedNets = allowedNets
    }

    private func path(_ key: String) throws -> String {
        try ObjectStoreLimits.validateKey(key)
        return "/" + (root.isEmpty ? "" : root + "/") + key
    }
    private func session<T>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        let client = SFTPClient(config: config, allowedNets: allowedNets)
        do { try await client.connect(); let result = try await body(client); await client.close(); return result }
        catch { await client.close(); throw error }
    }

    public func put(_ key: String, data: Data) async throws {
        guard data.count <= ObjectStoreLimits.maxBytes else { throw StorageError("too_large") }
        let p = try path(key)
        try await session { client in
            // Inventory keys are revision-unique; a partial write remains tracked as prepared/failed.
            let components = p.split(separator: "/").dropLast()
            var dir = ""
            for component in components { dir += "/" + component; try await client.makeDirectory(dir) }
            try await client.upload(p, data)
        }
    }
    public func get(_ key: String) async throws -> Data {
        let p = try path(key)
        return try await session { try await $0.download(p, limit: ObjectStoreLimits.maxBytes) }
    }
    public func delete(_ key: String) async throws {
        let p = try path(key)
        try await session { client in
            do { try await client.delete(p) }
            catch let e as FTPError where e.code == "sftp_2_remove" { /* confirmed absence */ }
        }
    }
    public func head(_ key: String) async throws -> Int? {
        do { return try await get(key).count }
        catch let e as FTPError where e.code == "sftp_2_open" { return nil }
    }
}
