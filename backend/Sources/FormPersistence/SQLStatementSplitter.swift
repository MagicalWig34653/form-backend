// SPDX-License-Identifier: AGPL-3.0-only

/// Splits a DDL script into statements at top-level semicolons. Understands '...' / "..." / `...`
/// quoting (doubled quote and backslash escapes), `-- ` and `#` line comments and block comments.
/// Comments are dropped; no DELIMITER support (the schema contains no routines/triggers).
public enum SQLStatementSplitter {
    /// An unterminated block comment or quoted string is an error: silently dropping the rest of a
    /// script would record a migration as applied although statements were lost.
    public enum SplitError: Error, Equatable, CustomStringConvertible {
        case unterminatedComment, unterminatedString
        public var description: String {
            switch self {
            case .unterminatedComment: return "unterminated block comment in SQL script"
            case .unterminatedString: return "unterminated quoted string or identifier in SQL script"
            }
        }
    }

    public static func split(_ script: String) throws -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        let s = Array(script.unicodeScalars)
        var i = 0
        func flush() {
            let t = String(cur).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            cur = String.UnicodeScalarView()
        }
        while i < s.count {
            let c = s[i]
            let n: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
            if c == "-" && n == "-" && (i + 2 >= s.count || s[i + 2] == " " || s[i + 2] == "\t" || s[i + 2] == "\n" || s[i + 2] == "\r") || c == "#" {
                while i < s.count && s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && n == "*" {
                i += 2
                while i + 1 < s.count && !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                guard i + 1 < s.count else { throw SplitError.unterminatedComment }
                i += 2
                cur.append(" ")
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                cur.append(c); i += 1
                var closed = false
                while i < s.count {
                    let d = s[i]
                    cur.append(d); i += 1
                    if d == "\\" && c != "`", i < s.count { cur.append(s[i]); i += 1; continue }
                    if d == c {
                        if i < s.count && s[i] == c { cur.append(s[i]); i += 1; continue }
                        closed = true
                        break
                    }
                }
                guard closed else { throw SplitError.unterminatedString }
                continue
            }
            if c == ";" { flush(); i += 1; continue }
            cur.append(c); i += 1
        }
        flush()
        return out
    }
}

import Foundation
