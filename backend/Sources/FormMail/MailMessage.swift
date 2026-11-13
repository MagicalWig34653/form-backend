// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Strict address handling: ASCII addr-spec only (no display names, no comments, no IDN), so nothing can smuggle a header
/// or an extra recipient through a form field.
public enum MailAddress {
    /// The canonical address, or nil when it is not a plain `local@domain` we are willing to send to.
    public static func parse(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard (3...254).contains(s.utf8.count), s.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = String(parts[0]), domain = String(parts[1])
        guard (1...64).contains(local.utf8.count), !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
              local.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$", options: .regularExpression) != nil else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ (1...63).contains($0.utf8.count) && !$0.hasPrefix("-") && !$0.hasSuffix("-")
              && $0.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil }), labels.last!.range(of: "^[A-Za-z]{2,}$", options: .regularExpression) != nil
        else { return nil }
        return local + "@" + domain.lowercased()
    }
}

public enum MailError: Error, Equatable {
    case invalidAddress, invalidHeader, noRecipients, tooLarge
}

/// One outgoing message. `rfc822()` builds the wire form: UTF-8 base64 body, RFC 2047 encoded Subject/display names.
public struct MailMessage: Sendable, Equatable {
    public var fromAddress: String
    public var fromName: String?
    public var to: [String]
    public var bcc: [String]
    public var replyTo: String?
    public var subject: String
    public var body: String
    public var isHTML: Bool
    public var date: Date
    public var messageIDDomain: String

    public static let maxBytes = 10 * 1024 * 1024

    public init(fromAddress: String, fromName: String? = nil, to: [String], bcc: [String] = [], replyTo: String? = nil, subject: String, body: String,
                isHTML: Bool, date: Date = Date(), messageIDDomain: String? = nil) throws {
        guard let f = MailAddress.parse(fromAddress) else { throw MailError.invalidAddress }
        let tos = try to.map { guard let a = MailAddress.parse($0) else { throw MailError.invalidAddress }; return a }
        let bccs = try bcc.map { guard let a = MailAddress.parse($0) else { throw MailError.invalidAddress }; return a }
        guard !tos.isEmpty || !bccs.isEmpty else { throw MailError.noRecipients }
        var rt: String? = nil
        if let r = replyTo { guard let a = MailAddress.parse(r) else { throw MailError.invalidAddress }; rt = a }
        if let n = fromName, Self.hasControl(n) { throw MailError.invalidHeader }
        if Self.hasControl(subject) { throw MailError.invalidHeader }
        self.fromAddress = f; self.fromName = fromName?.isEmpty == true ? nil : fromName; self.to = tos; self.bcc = bccs; self.replyTo = rt
        self.subject = subject; self.body = body; self.isHTML = isHTML; self.date = date
        self.messageIDDomain = messageIDDomain ?? String(f.split(separator: "@").last!)
    }

    /// All envelope recipients (To and Bcc), deduplicated, in order.
    public var envelopeRecipients: [String] {
        var seen = Set<String>(); return (to + bcc).filter { seen.insert($0.lowercased()).inserted }
    }

    static func hasControl(_ s: String) -> Bool { s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }

    /// RFC 2047 encoded-word(s) for non-ASCII text, split on character boundaries so every word stays <= 75 characters.
    static func encodedWords(_ s: String) -> String {
        if s.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return s }
        var words: [String] = [], current = Data()
        for ch in s {
            let c = Data(String(ch).utf8)
            if (current.count + c.count + 2) / 3 * 4 > 45 { words.append("=?UTF-8?B?\(current.base64EncodedString())?="); current = Data() }
            current.append(c)
        }
        if !current.isEmpty { words.append("=?UTF-8?B?\(current.base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    static func displayName(_ name: String) -> String {
        if name.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return encodedWords(name)
    }

    static func httpDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"; return f.string(from: d)
    }

    public func rfc822() throws -> Data {
        var h: [String] = []
        h.append("Date: " + Self.httpDate(date))
        h.append("From: " + (fromName.map { Self.displayName($0) + " <\(fromAddress)>" } ?? fromAddress))
        if !to.isEmpty { h.append("To: " + to.joined(separator: ", ")) }   // Bcc recipients are envelope-only
        if let r = replyTo { h.append("Reply-To: " + r) }
        h.append("Subject: " + Self.encodedWords(subject))
        h.append("Message-ID: <\(UUID().uuidString.lowercased())@\(messageIDDomain)>")
        h.append("MIME-Version: 1.0")
        h.append("Content-Type: text/\(isHTML ? "html" : "plain"); charset=utf-8")
        h.append("Content-Transfer-Encoding: base64")
        // Normalise to CRLF before encoding so the decoded body has canonical line ends.
        let normalised = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let b64 = Data(normalised.utf8).base64EncodedString()
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex { let j = b64.index(i, offsetBy: 76, limitedBy: b64.endIndex) ?? b64.endIndex; lines.append(String(b64[i..<j])); i = j }
        let out = Data((h.joined(separator: "\r\n") + "\r\n\r\n" + lines.joined(separator: "\r\n") + "\r\n").utf8)
        guard out.count <= Self.maxBytes else { throw MailError.tooLarge }
        return out
    }
}
