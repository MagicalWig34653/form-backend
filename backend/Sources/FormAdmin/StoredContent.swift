// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormPersistence
import FormStorage
import Foundation
import SQLKit
import Vapor

enum StoredContent {
    static func read(_ req: Request, sql: SQLDatabase, customer: UUID, form: UUID, object: Blob, fallback: Blob?, hash: Blob) async throws -> Data {
        if let storage = req.application.storage[StorageServiceKey.self] { return try await storage.read(sql: sql, customer: customer, form: form, object: object) }
        guard let bytes = fallback?.data, Data(SHA256.hash(data: bytes)) == hash.data else { throw Abort(.serviceUnavailable) }
        return bytes
    }
}
