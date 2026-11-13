// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Data-minimised organisation mail (ADR 0041): form name, time, reference and a link into the PWA. No submitted value ever enters it.
public enum MailNotification {
    public static func render(formTitle: String, at: Date, reference: String, link: String?) -> (subject: String, body: String) {
        let clean = { (s: String) in String(s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) }) }
        let title = clean(formTitle).trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Berlin"); f.dateFormat = "dd.MM.yyyy HH:mm 'Uhr'"
        let name = title.isEmpty ? "Formular" : title
        var body = "Es ist eine neue Einsendung eingegangen.\n\nFormular: \(name)\nZeitpunkt: \(f.string(from: at))\nKennung: \(reference)\n\n"
        body += link.map { "Einsendung ansehen (Anmeldung erforderlich):\n\($0)\n\n" } ?? "Bitte in der Anwendung anmelden, um die Einsendung anzusehen.\n\n"
        body += "Diese Nachricht enthält bewusst keine Angaben aus der Einsendung."
        return (String("Neue Einsendung: \(name)".prefix(MailPlan.maxSubject)), body)
    }
}

/// Standard organisation mail in `full` mode when no subject/body is configured (decision 13.11.2026): every field as `label: value`, like the
/// legacy backend delivered everything to the team. Plain text.
public enum MailStandard {
    public static func subject(formTitle: String) -> String {
        let clean = String(formTitle.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) }).trimmingCharacters(in: .whitespaces)
        return String("Neue Einsendung: \(clean.isEmpty ? "Formular" : clean)".prefix(MailPlan.maxSubject))
    }

    public static func body(formTitle: String, at: Date, reference: String, fields: [MailPlan.Field], values: [String: String]) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Berlin"); f.dateFormat = "dd.MM.yyyy HH:mm 'Uhr'"
        let name = formTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Formular" : formTitle
        var out = "Es ist eine neue Einsendung eingegangen.\n\nFormular: \(name)\nZeitpunkt: \(f.string(from: at))\nKennung: \(reference)\n\nAngaben:\n"
        for field in fields {
            let value = (values[field.name] ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            out += "\(field.label): \(value)\n"
        }
        return out
    }
}
