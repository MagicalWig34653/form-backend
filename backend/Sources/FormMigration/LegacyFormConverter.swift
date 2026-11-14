// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormCore
import Crypto

/// Pure conversion of P9's preserved projection. No source database, secrets or effects.
public enum LegacyFormConverter {
    public enum Failure: Error { case invalidProjection, tooLarge }
    public struct Item: Codable, Equatable {
        public let source: String
        public let status: String
        public let reason: String
    }
    public struct Result {
        public let document: JSONValue
        /// Incomplete suggestions, deliberately outside the executable document contract.
        public let proposals: JSONValue
        public let report: [Item]
    }
    struct Projection: Decodable {
        let legacyConfiguration: [String: String?]
        let legacyFields: [[String: String?]]
    }
    public static func convert(_ data: Data, standardDocument: JSONValue) throws -> Result {
        guard data.count <= 1_048_576 else { throw Failure.tooLarge }
        guard (try? JCS.parse(data)) != nil, let source = try? JSONDecoder().decode(Projection.self, from: data),
              case .object(var doc) = standardDocument, case .object(var form)? = doc["form"],
              case .array(var views)? = doc["views"], views.count == 1,
              case .object(var view) = views[0] else { throw Failure.invalidProjection }
        let c = source.legacyConfiguration
        func value(_ key: String) -> String? { c[key] ?? nil }
        var report: [Item] = []
        func note(_ path: String, _ status: String, _ reason: String) { report.append(Item(source: path, status: status, reason: reason)) }
        func list(_ raw: String?) -> [String]? {
            guard let raw, let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }
        func validName(_ s: String) -> Bool {
            s.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil &&
            !["csrf_token", "cf-turnstile-response", "g-recaptcha-response", "h-captcha-response"].contains(s)
        }
        let title = value("name") ?? "Formular"
        if title.utf8.count <= 2000 && !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            form["title"] = .object(["de": .string(title)]); view["title"] = form["title"]
            note("name", "uebernommen", "Formulartitel übernommen.")
        } else { note("name", "angepasst", "Ungültiger Titel durch Standardtitel ersetzt.") }
        var fields: [String: JSONValue] = [:], order: [String] = [], names = Set<String>(), haveFile = false
        let kinds = ["text":"text", "email":"email", "datum":"date", "zahl":"number", "bool":"boolean", "auswahl":"choice", "datei":"file"]
        guard source.legacyFields.count <= 500 else { throw Failure.tooLarge }
        for (index, f) in source.legacyFields.enumerated() {
            // Ordinals, never arbitrary source names or values, identify report entries.
            let path = "formularFelder/\(index)"
            guard let name = f["feldName"] ?? nil, validName(name), names.insert(name).inserted,
                  let oldKind = f["typ"] ?? nil, let kind = kinds[oldKind],
                  let required = f["pflicht"] ?? nil, ["0", "1"].contains(required) else {
                note(path, "nicht abbildbar", "Feldname, Typ oder Pflichtflag nicht im aktuellen Editorvertrag; Dateifelder benötigen Anhangprüfung."); continue
            }
            var validation: [String: JSONValue] = ["type": .string("string")]
            if kind == "email" || kind == "date" { validation["format"] = .string(kind) }
            if kind == "number" { validation["pattern"] = .string("^-?[0-9]+([.,][0-9]+)?$") }
            if kind == "boolean" { validation["enum"] = .array(["0","1","true","false","on","off"].map(JSONValue.string)) }
            let rule = f["regel"] ?? nil
            if kind == "file" {
                // The legacy backend only ever handled the FIRST file field (FeldSchema::uploadFeldname); later ones were ignored.
                guard !haveFile else { note(path, "nicht abbildbar", "Weiteres Dateifeld: das Altsystem verarbeitete nur das erste Dateifeld."); continue }
                haveFile = true
            }
            if kind == "choice" {
                guard let rule, let d = rule.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let options = o["optionen"] as? [String], !options.isEmpty, options.count <= 500 else {
                    note(path, "nicht abbildbar", "Auswahl benötigt eine explizite Liste von Textoptionen."); continue
                }
                validation["enum"] = .array(options.map(JSONValue.string))
            }
            applyRules(rule, kind: kind, path: path, validation: &validation, note: note)
            let id = "legacy_\(index)"
            fields[id] = .object(["name": .string(name), "kind": .string(kind), "label": .object(["de": .string(name)]),
                "required": .bool(required == "1"), "hidden": .bool(false), "locked": .bool(false),
                "sensitive": .bool(kind == "email"), "validation": .object(validation)])
            order.append(id)
            if kind == "file" { note(path, "angepasst", "Dateifeld übernommen; Dateityp- und Größenregeln des Uploads gelten global (PDF/PNG/JPG/HEIC, unter 20 MB, höchstens 5 Dateien); Pflichtflag prüfen.") }
            note(path, "angepasst", "Typ in Editorformat übersetzt; Pflicht-, Leerwert- und Datums-/Zahlsemantik manuell prüfen; Beschriftung aus Feldname vorgeschlagen.")
        }
        if source.legacyFields.isEmpty, let requiredNames = list(value("essentialPostFields")) {
            for (index, name) in requiredNames.enumerated() {
                guard validName(name), names.insert(name).inserted, fields.count < 500 else {
                    note("essentialPostFields/\(index)", "nicht abbildbar", "Ungültiger oder doppelter Pflichtfeldname beziehungsweise Feldlimit überschritten."); continue
                }
                let id = "essential_\(index)"
                fields[id] = .object(["name": .string(name), "kind": .string("text"), "label": .object(["de": .string(name)]),
                    "required": .bool(true), "hidden": .bool(false), "locked": .bool(false), "sensitive": .bool(true),
                    "validation": .object(["type": .string("string")])])
                order.append(id)
                note("essentialPostFields/\(index)", "angepasst", "Ohne Altschema als sensibles Text-Pflichtfeld vorgeschlagen; Typ und strengere Leerwertsemantik prüfen.")
            }
        }
        if fields.isEmpty {
            note("formularFelder", "angepasst", "Kein abbildbares Feld; optionales Standardfeld als sichtbarer Platzhalter beibehalten.")
        } else { form["fields"] = .object(fields) }
        if let raw = value("essentialPostFields"), !raw.isEmpty, !source.legacyFields.isEmpty {
            note("essentialPostFields", "angepasst", "Altschema vorhanden; Legacy-Fallback-Pflichtliste nicht zusätzlich angewandt.")
        }
        var security = object(form["security"])
        security["specialCategories"] = .bool(value("besondereKategorien") != "0")
        form["security"] = .object(security)
        note("besondereKategorien", ["0", "1"].contains(value("besondereKategorien") ?? "") ? "uebernommen" : "angepasst", "Schutzkennzeichnung prüfen; fehlende oder ungültige Angabe ist kein bestätigter Schutzbedarf.")
        // No guessed sender or connection assignment: an incomplete mail is never executable.
        var mail: [String: JSONValue] = [:]
        if let name = value("fromName") { mail["from"] = .object(["name": .string(name)]) }
        var organisation: [String: JSONValue] = [:]
        if let to = list(value("toProductionMails")) { organisation["to"] = .array(to.map(JSONValue.string)) }
        for (old, key) in [("betreff", "subject"), ("mailBody", "body")] {
            if let text = value(old), !text.isEmpty {
                organisation[key] = .string(text)
                note(old, "angepasst", "Mailvorlage als Vorschlag übernommen; Platzhalter bleiben erhalten, HTML-Escaping und abgeleitete Handlerfelder prüfen.")
            }
        }
        organisation["format"] = .string("html")
        mail["organisation"] = .object(organisation)
        if value("formularSendMailToFiller") == "1" {
            var confirmation: [String: JSONValue] = ["format": .string("html")]
            for (old, key) in [("betreffToFIller", "subject"), ("mailBodyFiller", "body")] {
                if let text = value(old) { confirmation[key] = .string(text) }
            }
            mail["confirmation"] = .object(confirmation)
            note("formularSendMailToFiller", "nicht abbildbar", "Bestätigungsvorlage vorgeschlagen; Empfängerfeld muss ausdrücklich zugeordnet werden.")
        }
        var proposals: [String: JSONValue] = ["mail": .object(mail)]
        for key in ["fromName", "toProductionMails"] {
            note(key, "angepasst", "Unvollständiger Mailvorschlag; kein ausführbarer Versandplan ohne geprüfte Absenderadresse und Verbindung.")
        }
        for key in ["outgoingProductionServer", "outgoingTestingServer"] {
            note(key, "nicht abbildbar", "Verbindungszuordnung gehört in connectionCustomers des Importplans; keine automatische Zuweisung.")
        }
        if let testing = list(value("toTestingMails")) { proposals["testingRecipients"] = .array(testing.map(JSONValue.string)) }
        note("toTestingMails", "angepasst", "Testempfänger separat vorgeschlagen; niemals mit Produktionsempfängern zusammengeführt.")
        if let domains = list(value("domains")) {
            var hosts: [String] = []
            for (index, domain) in domains.enumerated() {
                let host = domain.lowercased()
                if host.count <= 253, host.split(separator: ".", omittingEmptySubsequences: false).count >= 2,
                   host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ $0.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil }) {
                    if !hosts.contains(host) { hosts.append(host) }
                    note("domains/\(index)", "angepasst", "Normalisierter Host als Vorschlag; keine Bindung, DNS- oder Freigabeänderung.")
                } else { note("domains/\(index)", "nicht abbildbar", "Kein eindeutiger DNS-Hostname; keine Wildcards, URLs oder Ports automatisch umsetzen.") }
            }
            proposals["domains"] = .array(hosts.map(JSONValue.string))
        } else { note("domains", "nicht abbildbar", "Domainliste fehlt oder ist keine JSON-Textliste.") }
        for key in ["modes", "active"] { note(key, "angepasst", "Altfreigabe nicht übernommen; Entwurf bleibt inaktiv, Standardablauf ohne Spezialhandler.") }
        note("handler", "nicht abbildbar", "Spezifische PHP-Handler sind in der Projektion nicht beschrieben; kein automatischer Ersatz durch core.mail oder andere Ablaufbausteine.")
        if value("cloudflareSecretRef") != nil { note("cloudflareSecretRef", "nicht abbildbar", "Captcha benötigt separate Einrichtung; keine Secretreferenz im Vorschlag.") }
        let known = Set(legacyConfigurationColumns + ["cloudflareSecretRef"])
        if c.keys.contains(where: { !known.contains($0) }) { note("legacyConfiguration", "nicht abbildbar", "Zusätzliche Konfigurationsspalten benötigen Prüfung.") }
        form.removeValue(forKey: "mail")
        doc["form"] = .object(form)
        if !order.isEmpty {
            var steps = array(view["steps"]), step = object(steps[0]), sections = array(step["sections"]), section = object(sections[0])
            section["fields"] = .array(order.map { .object(["fieldId": .string($0), "readOnly": .bool(false), "disabled": .bool(false)]) })
            sections[0] = .object(section); step["sections"] = .array(sections); steps[0] = .object(step); view["steps"] = .array(steps)
        }
        var reference = object(view["form"])
        reference["sha256"] = .string(SHA256.hash(data: JCS.canonicalize(.object(form))).map { String(format: "%02x", $0) }.joined())
        view["form"] = .object(reference); views[0] = .object(view); doc["views"] = .array(views)
        return Result(document: .object(doc), proposals: .object(proposals), report: report)
    }

    /// Maps the legacy `regel` JSON (minLaenge, maxLaenge, muster, mussSein, optionen) onto the editor validation. Every rule that is not
    /// mapped is reported per field (never silently dropped); reports carry rule names only, never values.
    private static func applyRules(_ rule: String?, kind: String, path: String, validation: inout [String: JSONValue], note: (String, String, String) -> Void) {
        guard let rule, !rule.isEmpty, rule != "{}" else { return }
        guard let d = rule.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            note(path + "/regel", "nicht abbildbar", "Regel ist kein JSON-Objekt (im Altsystem ein Konfigurationsfehler); Regeln von Hand anlegen."); return
        }
        let handled: Set<String> = ["optionen", "minLaenge", "maxLaenge", "muster", "mussSein"]
        if o.keys.contains(where: { !handled.contains($0) }) {
            note(path + "/regel", "nicht abbildbar", "Unbekannte Regelschlüssel nicht übernommen.")
        }
        if kind == "file" {
            if o.keys.contains(where: { $0 != "optionen" }) { note(path + "/regel", "nicht abbildbar", "Längen-, Muster- und Einwilligungsregeln gelten nicht für Dateifelder.") }
            return
        }
        for (old, key) in [("minLaenge", "minLength"), ("maxLaenge", "maxLength")] {
            guard let raw = o[old] else { continue }
            // Legacy honours only real integers (is_int); JSON booleans decode as NSNumber, so exclude them.
            if let n = raw as? NSNumber, !isJSONBool(raw), n.doubleValue == n.doubleValue.rounded(), n.doubleValue >= 0, n.doubleValue < 1e9 {
                validation[key] = .int(Int64(n.doubleValue))
                note(path + "/regel/" + old, "uebernommen", "Länge als \(key) übernommen.")
            } else { note(path + "/regel/" + old, "nicht abbildbar", "Längenregel ist keine nichtnegative Ganzzahl; im Altsystem wirkungslos, nicht übernommen.") }
        }
        if let raw = o["mussSein"] {
            // Legacy: `$wert !== mussSein` against the posted string, e.g. consent "true". Exact-value enum keeps `required` intact.
            if let text = raw as? String {
                validation["enum"] = .array([.string(text)])
                note(path + "/regel/mussSein", "uebernommen", "Pflichtwert (Einwilligung) als erlaubte Einzelauswahl übernommen.")
            } else { note(path + "/regel/mussSein", "nicht abbildbar", "mussSein ist kein Text; das Altsystem lehnte damit jeden Wert ab. Einwilligung von Hand anlegen.") }
        }
        if let raw = o["muster"] {
            if let text = raw as? String {
                switch linearPattern(fromPCRE: text) {
                case .success(let p): validation["pattern"] = .string(p); note(path + "/regel/muster", "uebernommen", "Muster in den linearen Dialekt (ADR 0046) übertragen; Treffer gilt wie im Altsystem für Teilübereinstimmung.")
                case .failure(let why): note(path + "/regel/muster", "nicht abbildbar", why.reason)
                }
            } else { note(path + "/regel/muster", "nicht abbildbar", "Muster ist kein Text.") }
        }
    }

    /// Portable (Darwin and Linux) check that a decoded JSON number was a boolean literal.
    private static func isJSONBool(_ v: Any) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: [v]), let t = String(data: d, encoding: .utf8) else { return false }
        return t == "[true]" || t == "[false]"
    }

    /// PCRE with delimiters (partial match) -> linear dialect (full match). Flags, other delimiters or unsupported constructs fail.
    static func linearPattern(fromPCRE raw: String) -> Swift.Result<String, PatternFailure> {
        let chars = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let open = chars.first, "/#~@%!".contains(open), let close = chars.lastIndex(of: open), close > 0 else {
            return .failure(PatternFailure("Muster ohne gültige Begrenzer."))
        }
        guard close == chars.count - 1 else { return .failure(PatternFailure("Muster mit Modifikatoren (Flags) ist im linearen Dialekt nicht möglich; von Hand ohne Flags neu schreiben.")) }
        var body = String(chars[1..<close])
        let anchoredStart = body.hasPrefix("^")
        var trailing = 0; for c in body.reversed().dropFirst() { if c == "\\" { trailing += 1 } else { break } }
        let anchoredEnd = body.hasSuffix("$") && trailing % 2 == 0
        if anchoredStart && anchoredEnd && !body.contains("|") {
            body = String(body.dropFirst().dropLast())
        } else {
            body = "[\\s\\S]*(?:" + body + ")[\\s\\S]*"
        }
        if let why = LinearRegex.validate(body) { return .failure(PatternFailure("Muster nicht im linearen Dialekt (\(why)); von Hand neu schreiben.")) }
        return .success(body)
    }
    struct PatternFailure: Error { let reason: String; init(_ r: String) { reason = r } }
    private static func object(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }
    private static func array(_ v: JSONValue?) -> [JSONValue] { if case .array(let a)? = v { return a }; return [] }
}
