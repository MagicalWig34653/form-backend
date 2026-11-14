// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Regular-expression subset with guaranteed linear matching time (Thompson NFA simulation, no backtracking).
/// Used for operator-defined field patterns (ADR 0046). ICU's NSRegularExpression backtracks and has no usable
/// timeout, so a pattern like `((a|aa))+` could block a worker thread; here the cost is O(program size * input length).
///
/// Supported: literals, `.`, classes `[a-z0-9_]` / `[^...]`, `\d \D \w \W \s \S`, escaped punctuation, `\n \r \t`,
/// groups `( )` and `(?: )`, alternation `|`, quantifiers `* + ? {n} {n,} {n,m}` (n, m <= 1000), anchors `^` / `$`.
/// Refused at compile time: lookaround, backreferences, lazy/possessive quantifiers, flags, `\b`, `\p{..}`, anything else.
public struct LinearRegex: Sendable {
    public static let maxPatternBytes = 500
    public static let maxInputBytes = 2_000
    static let maxProgram = 4_000
    static let maxRepeat = 1_000

    public struct Unsupported: Error, Equatable { public let reason: String }

    indirect enum Node {
        case empty
        case set(CharSet)
        case cat([Node])
        case alt([Node])
        case star(Node), plus(Node), opt(Node)
        case rep(Node, Int, Int?)
        case bol, eol
    }

    struct CharSet: Sendable {
        var ranges: [ClosedRange<UInt32>] = []
        var classes: [Character] = []   // d D w W s S
        var negated = false
        var any = false
        func contains(_ s: Unicode.Scalar) -> Bool {
            if any { return !LinearRegex.isLineTerminator(s) }
            let hit = ranges.contains { $0.contains(s.value) } || classes.contains { LinearRegex.inClass($0, s) }
            return hit != negated
        }
    }

    enum Inst: Sendable { case set(CharSet), split(Int, Int), jmp(Int), bol, eol, match }
    let program: [Inst]

    public init(_ pattern: String) throws {
        guard pattern.utf8.count <= Self.maxPatternBytes else { throw Unsupported(reason: "pattern too long") }
        var p = Parser(Array(pattern.unicodeScalars))
        let node = try p.parseAlt()
        guard p.i == p.s.count else { throw Unsupported(reason: "unbalanced parenthesis") }
        var prog: [Inst] = []
        try Self.emit(node, &prog)
        prog.append(.match)
        self.program = prog
    }

    /// Full match of the whole input (anchored at both ends). Over-long input never matches.
    public func fullMatch(_ input: String) -> Bool {
        guard input.utf8.count <= Self.maxInputBytes else { return false }
        let text = Array(input.unicodeScalars)
        var current = [Int](), next = [Int]()
        var mark = [Int](repeating: -1, count: program.count)
        func add(_ pc: Int, _ pos: Int, _ list: inout [Int], _ gen: Int) {
            var stack = [pc]
            while let q = stack.popLast() {
                if mark[q] == gen { continue }
                mark[q] = gen
                switch program[q] {
                case .jmp(let t): stack.append(t)
                case .split(let a, let b): stack.append(b); stack.append(a)
                case .bol: if pos == 0 { stack.append(q + 1) }
                case .eol: if pos == text.count { stack.append(q + 1) }
                default: list.append(q)
                }
            }
        }
        add(0, 0, &current, 0)
        for pos in 0..<text.count {
            let c = text[pos]
            next.removeAll(keepingCapacity: true)
            for pc in current { if case .set(let cs) = program[pc], cs.contains(c) { add(pc + 1, pos + 1, &next, pos + 1) } }
            swap(&current, &next)
            if current.isEmpty { return false }
        }
        return current.contains { if case .match = program[$0] { return true } else { return false } }
    }

    /// Save-time check: nil when the pattern is acceptable, otherwise the reason.
    public static func validate(_ pattern: String) -> String? {
        do { _ = try LinearRegex(pattern); return nil } catch let e as Unsupported { return e.reason } catch { return "invalid" }
    }

    // MARK: classes
    static func isLineTerminator(_ s: Unicode.Scalar) -> Bool { [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains(s.value) }
    static func inClass(_ k: Character, _ s: Unicode.Scalar) -> Bool {
        let digit = s.properties.numericType == .decimal
        let word = s.properties.isAlphabetic || digit || s == "_" || s.properties.generalCategory == .nonspacingMark
        let space = s.properties.isWhitespace
        switch k {
        case "d": return digit
        case "D": return !digit
        case "w": return word
        case "W": return !word
        case "s": return space
        default: return !space
        }
    }

    // MARK: compile
    static func emit(_ n: Node, _ p: inout [Inst]) throws {
        guard p.count <= maxProgram else { throw Unsupported(reason: "pattern too complex") }
        switch n {
        case .empty: break
        case .set(let c): p.append(.set(c))
        case .bol: p.append(.bol)
        case .eol: p.append(.eol)
        case .cat(let xs): for x in xs { try emit(x, &p) }
        case .alt(let xs):
            var jumps: [Int] = []
            for (k, x) in xs.enumerated() {
                if k < xs.count - 1 {
                    let sp = p.count; p.append(.split(0, 0))
                    try emit(x, &p)
                    jumps.append(p.count); p.append(.jmp(0))
                    p[sp] = .split(sp + 1, p.count)
                } else { try emit(x, &p) }
            }
            for j in jumps { p[j] = .jmp(p.count) }
        case .opt(let x):
            let sp = p.count; p.append(.split(0, 0)); try emit(x, &p); p[sp] = .split(sp + 1, p.count)
        case .star(let x):
            let sp = p.count; p.append(.split(0, 0)); try emit(x, &p); p.append(.jmp(sp)); p[sp] = .split(sp + 1, p.count)
        case .plus(let x):
            let st = p.count; try emit(x, &p); p.append(.split(st, p.count + 1))
        case .rep(let x, let lo, let hi):
            for _ in 0..<lo { try emit(x, &p) }
            if let hi { for _ in lo..<hi { try emit(.opt(x), &p) } } else { try emit(.star(x), &p) }
        }
        guard p.count <= maxProgram else { throw Unsupported(reason: "pattern too complex") }
    }

    // MARK: parser
    struct Parser {
        let s: [Unicode.Scalar]; var i = 0; var depth = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }
        func peek() -> Unicode.Scalar? { i < s.count ? s[i] : nil }

        mutating func parseAlt() throws -> Node {
            var branches = [try parseCat()]
            while peek() == "|" { i += 1; branches.append(try parseCat()) }
            return branches.count == 1 ? branches[0] : .alt(branches)
        }
        mutating func parseCat() throws -> Node {
            var items: [Node] = []
            while let c = peek(), c != "|", c != ")" { items.append(try parseQuantified()) }
            return items.isEmpty ? .empty : .cat(items)
        }
        mutating func parseQuantified() throws -> Node {
            var atom = try parseAtom()
            if let c = peek(), c == "*" || c == "+" || c == "?" || c == "{" {
                switch c {
                case "*": i += 1; atom = .star(atom)
                case "+": i += 1; atom = .plus(atom)
                case "?": i += 1; atom = .opt(atom)
                default: atom = try parseBraces(atom)
                }
                // Lazy/possessive suffixes and stacked quantifiers are refused (also keeps nested repetition out).
                if let n = peek(), n == "?" || n == "+" || n == "*" || n == "{" { throw Unsupported(reason: "lazy, possessive or stacked quantifier") }
            }
            return atom
        }
        mutating func parseBraces(_ atom: Node) throws -> Node {
            i += 1
            func num(_ me: inout Parser) -> Int? {
                var v = 0, any = false
                while let c = me.peek(), c.isASCII, let d = Int(String(c)) { v = min(v * 10 + d, 100_000); any = true; me.i += 1 }
                return any ? v : nil
            }
            guard let lo = num(&self) else { throw Unsupported(reason: "bad repetition") }
            var hi: Int? = lo
            if peek() == "," { i += 1; hi = num(&self) }
            guard peek() == "}" else { throw Unsupported(reason: "bad repetition") }
            i += 1
            guard lo <= LinearRegex.maxRepeat, (hi ?? 0) <= LinearRegex.maxRepeat, hi == nil || hi! >= lo else { throw Unsupported(reason: "repetition too large") }
            return .rep(atom, lo, hi)
        }
        mutating func parseAtom() throws -> Node {
            let c = s[i]; i += 1
            switch c {
            case "(":
                if peek() == "?" {
                    guard i + 1 < s.count, s[i + 1] == ":" else { throw Unsupported(reason: "lookaround, flags or named group") }
                    i += 2
                }
                depth += 1
                guard depth <= 20 else { throw Unsupported(reason: "nesting too deep") }
                let inner = try parseAlt()
                guard peek() == ")" else { throw Unsupported(reason: "unbalanced parenthesis") }
                i += 1; depth -= 1
                return inner
            case ".": var cs = CharSet(); cs.any = true; return .set(cs)
            case "^": return .bol
            case "$": return .eol
            case "[": return .set(try parseClass())
            case "\\": return .set(try parseEscape())
            case "*", "+", "?", "{": throw Unsupported(reason: "nothing to repeat")
            default: var cs = CharSet(); cs.ranges = [c.value...c.value]; return .set(cs)
            }
        }
        mutating func parseEscape() throws -> CharSet {
            guard let e = peek() else { throw Unsupported(reason: "trailing backslash") }
            i += 1
            var cs = CharSet()
            switch e {
            case "d", "D", "w", "W", "s", "S": cs.classes = [Character(e)]
            case "n": cs.ranges = [10...10]
            case "r": cs.ranges = [13...13]
            case "t": cs.ranges = [9...9]
            default:
                guard e.isASCII, !(e.properties.isAlphabetic || e.properties.numericType != nil) else { throw Unsupported(reason: "unsupported escape") }
                cs.ranges = [e.value...e.value]
            }
            return cs
        }
        mutating func parseClass() throws -> CharSet {
            var cs = CharSet()
            if peek() == "^" { cs.negated = true; i += 1 }
            var first = true
            while true {
                guard let c = peek() else { throw Unsupported(reason: "unterminated class") }
                i += 1
                if c == "]", !first { return cs }
                first = false
                if c == "[" { throw Unsupported(reason: "nested class") }
                var lo = c.value
                if c == "\\" {
                    let e = try parseEscape()
                    if !e.classes.isEmpty { cs.classes += e.classes; continue }
                    lo = e.ranges[0].lowerBound
                }
                if peek() == "-", i + 1 < s.count, s[i + 1] != "]" {
                    i += 1
                    let h = s[i]; i += 1
                    var hi = h.value
                    if h == "\\" {
                        let e = try parseEscape()
                        guard e.classes.isEmpty else { throw Unsupported(reason: "bad range") }
                        hi = e.ranges[0].lowerBound
                    }
                    guard hi >= lo else { throw Unsupported(reason: "bad range") }
                    cs.ranges.append(lo...hi)
                } else { cs.ranges.append(lo...lo) }
            }
        }
    }
}
