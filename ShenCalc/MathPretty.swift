import Foundation

/// Renders shen-cas normal-form output (a bracketed S-expression such as
/// `[Times [Power x 2] 3]`) into human-readable math (`3·x²`). Anything it
/// doesn't recognise falls back to function notation (`Head(arg, …)`) rather
/// than leaking raw brackets, and `error:` strings pass through untouched.
enum MathPretty {

    static func render(_ casOutput: String) -> String {
        let t = casOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("error:") else { return casOutput }
        var tokens = tokenize(t)
        guard let node = parse(&tokens) else { return casOutput }
        return emit(node, parent: .top)
    }

    // MARK: parse

    private indirect enum Node { case atom(String), list([Node]) }

    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for ch in s {
            switch ch {
            case "[", "]": flush(); out.append(String(ch))
            case " ", "\t", "\n": flush()
            default: cur.append(ch)
            }
        }
        flush()
        return out
    }

    private static func parse(_ tokens: inout [String]) -> Node? {
        guard !tokens.isEmpty else { return nil }
        let tok = tokens.removeFirst()
        if tok == "[" {
            var items: [Node] = []
            while let next = tokens.first {
                if next == "]" { tokens.removeFirst(); break }
                guard let n = parse(&tokens) else { break }
                items.append(n)
            }
            return .list(items)
        }
        if tok == "]" { return nil }
        return .atom(tok)
    }

    // MARK: emit

    /// Precedence context, so we only parenthesise when needed.
    private enum Ctx { case top, sum, product, power, fn }

    private static func emit(_ node: Node, parent: Ctx) -> String {
        switch node {
        case .atom(let a):
            return a
        case .list(let xs):
            // Infix binary forms the CAS emits directly, e.g. [3 / 2].
            if xs.count == 3, case .atom(let op) = xs[1],
               ["/", "+", "-", "*", "^"].contains(op) {
                let s = "\(emit(xs[0], parent: .product))\(op == "/" ? "/" : " \(op) ")\(emit(xs[2], parent: .product))"
                return op == "/" && parent == .power ? "(\(s))" : s
            }
            guard case .atom(let head)? = xs.first else { return generic(xs) }
            let args = Array(xs.dropFirst())
            switch head {
            case "Plus":  return wrapIf(parent == .product || parent == .power, sum(args))
            case "Times": return product(args, parent: parent)
            case "Power": return power(args, parent: parent)
            case "List":  return "{" + args.map { emit($0, parent: .top) }.joined(separator: ", ") + "}"
            case "Exp":   return wrapIf(parent == .power, "e^" + emit(args[0], parent: .power))
            case "Log":   return "ln(" + emit(args.first ?? .atom(""), parent: .fn) + ")"
            case "Sqrt":  return "√(" + emit(args.first ?? .atom(""), parent: .fn) + ")"
            // Minus/Divide heads are never emitted by `reduce` (it uses Plus+negatives
            // and the `/` infix form), but generators build prompts with them.
            case "Minus" where args.count == 2:
                // a − b, parenthesising a negative right operand: 8/4 − (−4/6).
                let rhs = emit(args[1], parent: .product)
                let rhsShown = rhs.hasPrefix("-") ? "(\(rhs))" : rhs
                return wrapIf(parent == .product || parent == .power,
                              "\(emit(args[0], parent: .sum)) - \(rhsShown)")
            case "Divide" where args.count == 2:
                return fraction(num: args[0], den: args[1], parent: parent)
            default:
                if isFunction(head), let a = args.first, args.count == 1 {
                    return head.lowercased() + "(" + emit(a, parent: .fn) + ")"
                }
                return generic(xs)
            }
        }
    }

    private static let functions: Set<String> = [
        "Sin", "Cos", "Tan", "Sec", "Csc", "Cot",
        "Sinh", "Cosh", "Tanh", "Arcsin", "Arccos", "Arctan", "Abs",
    ]
    private static func isFunction(_ h: String) -> Bool { functions.contains(h) }

    private static func sum(_ args: [Node]) -> String {
        var result = ""
        for (i, term) in args.enumerated() {
            let s = emit(term, parent: .sum)
            if i == 0 {
                result = s
            } else if s.hasPrefix("-") {
                result += " - " + String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                result += " + " + s
            }
        }
        return result
    }

    private static func product(_ args: [Node], parent: Ctx) -> String {
        var negative = false
        var factors: [Node] = []
        for f in args {
            if case .atom(let a) = f, a == "-1" { negative.toggle(); continue }
            factors.append(f)
        }
        // numeric / fraction coefficients first, for natural reading (3·x²).
        let coeffs = factors.filter { isNumeric($0) }
        let rest = factors.filter { !isNumeric($0) }
        let ordered = coeffs + rest
        let pieces = ordered.enumerated().map { i, f -> String in
            let s = emit(f, parent: .product)
            // bracket fractions used as coefficients: (1/3)·x³
            if case .list(let l) = f, l.count == 3, case .atom("/") = l[1] { return "(\(s))" }
            // parenthesise a negative numeric factor that isn't leading, so a
            // product reads "2·(-5)" not the ambiguous "2·-5".
            if i > 0, isNumeric(f), s.hasPrefix("-") { return "(\(s))" }
            return s
        }
        var body = pieces.isEmpty ? "1" : pieces.joined(separator: "·")
        // Applying the overall sign: parenthesise a negative body so "−1 · (−5)"
        // renders "-(-5)" rather than the double-minus "--5".
        if negative { body = "-" + (body.hasPrefix("-") ? "(\(body))" : body) }
        return wrapIf(parent == .power, body)
    }

    /// Render a `[Divide num den]` head as `num/den`, parenthesising operands that
    /// are themselves sums or fractions so a division of fractions reads clearly:
    /// `(a/b)/(c/d)` rather than the ambiguous `a/b/c/d`.
    private static func fraction(num: Node, den: Node, parent: Ctx) -> String {
        let s = "\(wrapFraction(num))/\(wrapFraction(den))"
        return parent == .power ? "(\(s))" : s
    }

    private static func wrapFraction(_ node: Node) -> String {
        let s = emit(node, parent: .product)
        let compound: Bool
        switch node {
        case .list(let l) where l.count == 3:
            if case .atom(let op) = l[1], ["/", "+", "-", "*"].contains(op) { compound = true }
            else if case .atom(let h)? = l.first, ["Divide", "Plus", "Minus"].contains(h) { compound = true }
            else { compound = false }
        case .list(let l):
            if case .atom(let h)? = l.first, ["Divide", "Plus", "Minus"].contains(h) { compound = true }
            else { compound = false }
        default:
            compound = false
        }
        return compound ? "(\(s))" : s
    }

    private static func power(_ args: [Node], parent: Ctx) -> String {
        guard args.count == 2 else { return generic([.atom("Power")] + args) }
        let base = args[0], exp = args[1]
        let baseStr = emit(base, parent: .power)
        if case .atom(let e) = exp, let n = Int(e) {
            if n == 0 { return "1" }
            if n == 1 { return baseStr }
            if n < 0 {
                let denom = n == -1 ? baseStr : baseStr + superscript(-n)
                return wrapIf(parent == .product, "1/" + denom)
            }
            return baseStr + superscript(n)
        }
        // non-integer exponent (fraction, symbol): base^(exp)
        return baseStr + "^(" + emit(exp, parent: .power) + ")"
    }

    private static func isNumeric(_ n: Node) -> Bool {
        switch n {
        case .atom(let a): return Double(a) != nil
        case .list(let l): // a fraction like [1 / 2]
            return l.count == 3 && { if case .atom("/") = l[1] { return true } else { return false } }()
        }
    }

    /// Fallback: render an unrecognised list as Head(arg, …) function notation.
    private static func generic(_ xs: [Node]) -> String {
        guard case .atom(let head)? = xs.first else {
            return "(" + xs.map { emit($0, parent: .top) }.joined(separator: " ") + ")"
        }
        let args = xs.dropFirst().map { emit($0, parent: .top) }
        return args.isEmpty ? head : head + "(" + args.joined(separator: ", ") + ")"
    }

    private static func wrapIf(_ cond: Bool, _ s: String) -> String { cond ? "(\(s))" : s }

    private static let sups: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻",
    ]
    private static func superscript(_ n: Int) -> String {
        String(String(n).map { sups[$0] ?? $0 })
    }
}
