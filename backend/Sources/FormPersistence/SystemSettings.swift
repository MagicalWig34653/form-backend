// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormCore
import SQLKit

public enum SystemSettings {
    struct Row: Decodable { let setting_key: String; let value: String }
    public static func read(_ sql: SQLDatabase) async throws -> [String: String] {
        let rows = try await sql.raw("SELECT setting_key, JSON_UNQUOTE(safe_value_json) AS value FROM settings WHERE scope_key = 'system' AND safe_value_json IS NOT NULL").all(decoding: Row.self)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.setting_key, $0.value) })
    }
    public static func value(_ key: String, sql: SQLDatabase, env: [String: String] = ProcessInfo.processInfo.environment) async throws -> String {
        guard let entry = SettingsRegistry.entries.first(where: { $0.key == key }) else { throw SettingsRegistry.Invalid() }
        return try SettingsRegistry.resolve(entry, env: env, stored: await read(sql)).value!
    }
    public static func environment(_ sql: SQLDatabase, env: [String: String]) async throws -> [String: String] {
        let stored = try await read(sql)
        var result = env
        for entry in SettingsRegistry.entries where env[entry.envName] == nil && stored[entry.key] != nil {
            try entry.validate(stored[entry.key]!)
            result[entry.envName] = stored[entry.key]!
        }
        return result
    }
    public static func write(_ sql: SQLDatabase, key: String, value: String, at: String) async throws {
        let encoded = String(data: JCS.canonicalize(.string(value)), encoding: .utf8)!
        try await sql.raw("INSERT INTO settings (scope_key, setting_key, safe_value_json, manageable, modified_at) VALUES ('system', \(bind: key), \(bind: encoded), 1, \(bind: at)) ON DUPLICATE KEY UPDATE safe_value_json = VALUES(safe_value_json), modified_at = VALUES(modified_at)").run()
    }
    /// Serialize snapshots and updates across processes; revision lives in the existing settings table.
    public static func lock(_ sql: SQLDatabase, at: String) async throws -> String {
        try await sql.raw("INSERT INTO settings (scope_key, setting_key, safe_value_json, manageable, modified_at) VALUES ('system', '_revision', '\"0\"', 0, \(bind: at)) ON DUPLICATE KEY UPDATE setting_key = setting_key").run()
        struct Revision: Decodable { let value: String }
        return try await sql.raw("SELECT JSON_UNQUOTE(safe_value_json) AS value FROM settings WHERE scope_key = 'system' AND setting_key = '_revision' FOR UPDATE").first(decoding: Revision.self)!.value
    }
}
