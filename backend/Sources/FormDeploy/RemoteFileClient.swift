// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What the SDK installer needs from a remote file system; implemented by FTP/FTPS and SFTP (ADR 0011).
public protocol RemoteFileClient: Sendable {
    func connect() async throws
    func close() async
    func exists(_ path: String) async -> Bool
    func isDirectory(_ path: String) async -> Bool
    func makeDirectory(_ path: String) async throws
    func upload(_ path: String, _ data: Data) async throws
    func download(_ path: String, limit: Int) async throws -> Data
    func rename(_ from: String, _ to: String) async throws
    func delete(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func list(_ dir: String) async throws -> [String]
}

extension FTPClient: RemoteFileClient {
    public func isDirectory(_ path: String) async -> Bool {
        guard (try? await changeDirectory(path)) != nil else { return false }
        _ = try? await changeDirectory("/")
        return true
    }
}
