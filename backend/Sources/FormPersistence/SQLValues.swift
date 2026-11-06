// SPDX-License-Identifier: AGPL-3.0-only
import FluentMySQLDriver
import Foundation
import NIOCore

/// Binary column value. `Data` is not a `MySQLDataConvertible` (the driver would JSON-encode it as a byte array),
/// so binary parameters/columns go through this wrapper and are sent as a real BLOB.
public struct Blob: Codable, MySQLDataConvertible, Equatable, Sendable {
    public let data: Data
    public init(_ data: Data) { self.data = data }
    public init?(mysqlData: MySQLData) {
        guard var buf = mysqlData.buffer, let bytes = buf.readBytes(length: buf.readableBytes) else { return nil }
        data = Data(bytes)
    }
    public var mysqlData: MySQLData? { MySQLData(type: .blob, buffer: ByteBuffer(bytes: data)) }
    public init(from decoder: Decoder) throws { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Blob decodes via MySQLDataConvertible")) }
    public func encode(to encoder: Encoder) throws { throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Blob encodes via MySQLDataConvertible")) }
}

/// Conversions between Swift values and the schema's column formats (BINARY(16) ids, DATETIME(6) in UTC).
public enum DB {
    public static func bin(_ u: UUID) -> Blob { Blob(withUnsafeBytes(of: u.uuid) { Data($0) }) }
    public static func uuid(_ d: Data) -> UUID? {
        guard d.count == 16 else { return nil }
        return d.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
    /// DATETIME(6) literal in UTC.
    public static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return f.string(from: d)
    }
    public static func isDuplicateKey(_ error: Error) -> Bool {
        guard let e = error as? MySQLError else { return false }
        switch e {
        case .duplicateEntry: return true
        case .server(let p): return p.errorCode.rawValue == 1062
        default: return false
        }
    }
}
