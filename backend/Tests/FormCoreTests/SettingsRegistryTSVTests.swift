// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormCore

/// Keeps `deploy/swarm/config-registry.tsv` (read by `deploy/<mode>/settings.sh`) in sync with `SettingsRegistry.entries`.
/// Regenerate with: UPDATE_CONFIG_TSV=1 swift test --filter SettingsRegistryTSVTests
final class SettingsRegistryTSVTests: XCTestCase {
    static let columns = ["key", "group", "type", "default", "unit", "min", "max", "choices", "apply", "secret", "summary"]
    static let levels = ["trace", "debug", "info", "notice", "warning", "error", "critical"]

    /// Operator-facing descriptions keyed by registry key (German, one line). Every entry with an ENV name needs one.
    static let summaries: [String: String] = [
        "ops.threshold": "Schwelle der Betriebsmeldungen (1 = Warnung, 2 = nur Fehler); Einstellung ops.threshold.",
        "ops.intervalSeconds": "Prüfintervall der Betriebsüberwachung; Einstellung ops.intervalSeconds.",
        "ops.retentionDays": "Aufbewahrung der Betriebsmeldungen in Tagen; Einstellung ops.retentionDays.",
        "ops.recipient": "Empfänger der Betriebsmeldungen (E-Mail, leer = keiner); Einstellung ops.recipient.",
        "ops.sender": "Absender der Betriebsmeldungen (E-Mail, leer = Standard); Einstellung ops.sender.",
        "ops.connection": "UUID der Mail-Verbindung für Betriebsmeldungen (leer = keine); Einstellung ops.connection.",
        "abuse.blockedNets": "Gesperrte Netze (CIDR, kommagetrennt); Einstellung abuse.blockedNets.",
        "abuse.uaPatterns": "Gesperrte User-Agent-Muster als JSON-Liste (Teilstrings, ohne Groß-/Kleinschreibung); Einstellung abuse.uaPatterns.",
        "abuse.hashes": "Gesperrte Absender-Hashes als JSON-Liste (64 Hex-Zeichen); Einstellung abuse.hashes.",
        "abuse.threshold": "Fehlversuche bis zur automatischen Sperre; Einstellung abuse.threshold.",
        "abuse.windowSeconds": "Zeitfenster für die Zählung der Fehlversuche; Einstellung abuse.windowSeconds.",
        "abuse.banSeconds": "Dauer der automatischen Sperre; Einstellung abuse.banSeconds.",
        "mail.restricted": "Mailversand nur an erlaubte Empfänger (true/false); Einstellung mail.restricted.",
        "mail.allowedRecipients": "Erlaubte Empfänger als JSON-Liste von E-Mail-Adressen; Einstellung mail.allowedRecipients.",
        "compat.legacy": "Alte Website-Pfade und Statuscodes des alten Backends bedienen (true/false); Einstellung compat.legacy.",
        "migration.allowedNets": "Netze (CIDR), aus denen der Umstieg erlaubt ist; Einstellung migration.allowedNets.",
        "mail.allowedNets": "Private Mail-/SDK-Zielnetze (CIDR, kommagetrennt; leer = nur öffentliche Ziele); Einstellung mail.allowedNets.",
        "log.level": "Log-Stufe der Anwendung; Einstellung log.level.",
        "sdk.directory": "Verzeichnis des SDK-Bundles im Container; Einstellung sdk.directory.",
        "webhook.perForm": "Webhooks je Formular (0 = keine); Einstellung webhook.perForm.",
        "webhook.perCustomer": "Webhooks je Kunde (0 = keine); Einstellung webhook.perCustomer.",
        "webhook.backlog": "Maximale offene Webhook-Zustellungen je Kunde; Einstellung webhook.backlog.",
        "mcp.requestsPerMinute": "MCP-Anfragen je Token und Minute; Einstellung mcp.requestsPerMinute.",
        "ingest.requestsPerMinute": "Einsendungen je Minute und Quelle (0 = aus); Einstellung ingest.requestsPerMinute.",
        "oauth.authorizeBaseURL": "Öffentliche Basis-Origin der OAuth-Autorisierung (https, leer = Admin-Origin); Einstellung oauth.authorizeBaseURL.",
        "oauth.registrationsPerHour": "OAuth-Client-Registrierungen je Stunde; Einstellung oauth.registrationsPerHour.",
        "oauth.maxUnusedClients": "Höchstzahl unbenutzter OAuth-Clients; Einstellung oauth.maxUnusedClients.",
        "oauth.issuer": "OAuth-Aussteller (https-Origin, leer = Admin-Origin); Einstellung oauth.issuer.",
        "admin.origin": "Öffentliche HTTPS-Origin der Verwaltung (ohne Pfad); Einstellung admin.origin.",
        "admin.rpID": "Passkey-RP-ID (Hostname in Kleinbuchstaben); bei vorhandenen Passkeys nicht ändern; Einstellung admin.rpID."
    ]

    static func root() -> URL {
        // .../backend/Tests/FormCoreTests/SettingsRegistryTSVTests.swift -> repository root
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static func swarmDirectory() -> URL { root().appendingPathComponent("deploy/swarm") }

    static func field(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func row(_ e: SettingsRegistry.Entry) -> String {
        var type = "text:free", lo = "", hi = "", choices = ""
        switch e.type {
        case "integer": type = "int"; lo = String(e.minimum!); hi = String(e.maximum!)
        case "boolean": type = "bool"
        case "level": type = "choice"; choices = levels.joined(separator: "|")
        case "mailbox": type = "text:mailbox"; hi = "254"
        case "uuid": type = "text:uuid"; hi = "36"
        case "cidrs": type = "text:cidrs"; hi = "4096"
        case "patterns", "hashes", "recipients": type = "text:json\(e.type)"; hi = "4096"
        case "origin": type = "text:origin"; hi = "255"
        case "host": type = "text:host"; hi = "253"
        case "path": type = "text:path"; hi = "4096"
        default: XCTFail("unmapped registry type \(e.type)")
        }
        let cells = [e.envName, e.group, type, e.defaultValue, "", lo, hi, choices,
                     e.restartRequired ? "restart" : "live", e.sensitive ? "1" : "0", summaries[e.key] ?? ""]
        return cells.map(field).joined(separator: "\t")
    }

    /// Entries with an ENV name can appear in the deployment env file; DB-only entries (setup.*) cannot.
    static var envEntries: [SettingsRegistry.Entry] { SettingsRegistry.entries.filter { !$0.envName.isEmpty } }

    static func generate() -> String {
        (["#" + columns.joined(separator: "\t")] + envEntries.map(row)).joined(separator: "\n") + "\n"
    }

    func testEveryEnvEntryHasSummaryAndNoSecretIsExported() {
        for entry in Self.envEntries {
            XCTAssertNotNil(Self.summaries[entry.key], "summary missing for \(entry.key)")
            XCTAssertFalse(entry.sensitive, "sensitive entries never belong into the env tables")
        }
        XCTAssertEqual(Set(Self.summaries.keys), Set(Self.envEntries.map(\.key)), "stale summaries")
    }

    func testTableMatchesRegistry() throws {
        let file = Self.swarmDirectory().appendingPathComponent("config-registry.tsv")
        let expected = Self.generate()
        if ProcessInfo.processInfo.environment["UPDATE_CONFIG_TSV"] == "1" {
            try expected.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let actual = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertEqual(actual, expected, """
            deploy/swarm/config-registry.tsv ist nicht aktuell (SettingsRegistry.entries wurde geaendert).
            Neu erzeugen mit: UPDATE_CONFIG_TSV=1 swift test --filter SettingsRegistryTSVTests
            und die Datei mit dem Code committen.
            """)
    }

    func testExtraTableIsWellFormedAndDisjoint() throws {
        let file = Self.swarmDirectory().appendingPathComponent("config-extra.tsv")
        let text = try String(contentsOf: file, encoding: .utf8)
        let registry = Set(Self.envEntries.map(\.envName))
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(cells.count, Self.columns.count, "config-extra.tsv: \(cells.first ?? "?") hat \(cells.count) Spalten")
            guard cells.count == Self.columns.count else { continue }
            XCTAssertFalse(registry.contains(cells[0]), "\(cells[0]) steht schon im Register, nicht in config-extra.tsv")
            XCTAssertTrue(seen.insert(cells[0]).inserted, "\(cells[0]) doppelt in config-extra.tsv")
            XCTAssertTrue(["envOnly"].contains(cells[8]), "\(cells[0]): apply \(cells[8])")
            XCTAssertTrue(["0", "1"].contains(cells[9]), "\(cells[0]): secret \(cells[9])")
        }
        XCTAssertFalse(seen.isEmpty)
    }

    func testTemplatesNameEveryRegistryEnv() throws {
        for template in ["deploy/swarm/stack.env.example", "deploy/compose/.env.example"] {
            let text = try String(contentsOf: Self.root().appendingPathComponent(template), encoding: .utf8)
            for entry in Self.envEntries {
                XCTAssertTrue(text.contains("# \(entry.envName)=") || text.contains("\n\(entry.envName)="), "\(template) lacks \(entry.envName)")
            }
        }
    }
}
