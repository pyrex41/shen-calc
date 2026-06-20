import Foundation

/// The set of operations the embedded shen-cas actually evaluates, modelled as
/// "tools" the language model can call. One registry drives three things:
///   1. the model's system prompt (the tool menu + few-shot examples),
///   2. a deterministic parser that turns the model's tool call into CAS syntax,
///   3. the math-keyboard / UI labels (kept in sync by construction).
///
/// The model never does math — it only picks a tool and supplies the operands.
/// Swift builds the final shen-cas bracket expression, so the operation can't be
/// wrong (at worst the operand expression is rejected by the CAS reader).
enum CASTools {

    /// A callable operation. `tag` is what the model emits; `arity` is how many
    /// `;`-separated operands it takes; `build` assembles the CAS string.
    struct Tool {
        let tag: String                 // e.g. "INTEGRATE"
        let arity: Int                  // operand count (expression + optional var)
        let needsVar: Bool             // append a default "x" if the var is missing
        let build: ([String]) -> String
        let example: String            // shown in the prompt
    }

    static let tools: [Tool] = [
        Tool(tag: "D", arity: 2, needsVar: true,
             build: { "D[\($0[0]), \(arg($0, 1, "x"))]" },
             example: #""derivative of sin x"            -> D(Sin[x]; x)"#),
        Tool(tag: "INTEGRATE", arity: 2, needsVar: true,
             build: { "Integrate[\($0[0]), \(arg($0, 1, "x"))]" },
             example: #""integrate x squared wrt x"       -> INTEGRATE(x^2; x)"#),
        Tool(tag: "SOLVE", arity: 2, needsVar: true,
             build: { "Solve[\($0[0]), \(arg($0, 1, "x"))]" },
             example: #""solve x^2 = 4 for x"             -> SOLVE(x^2 - 4; x)"#),
        Tool(tag: "SIMPLIFY", arity: 1, needsVar: false,
             build: { "Simplify[\($0[0])]" },
             example: #""simplify a plus a"               -> SIMPLIFY(a + a)"#),
        Tool(tag: "EXPAND", arity: 1, needsVar: false,
             build: { "Expand[\($0[0])]" },
             example: #""expand (x+1) squared"            -> EXPAND((x+1)^2)"#),
        Tool(tag: "FACTOR", arity: 1, needsVar: false,
             build: { "Factor[\($0[0])]" },
             example: #""factor x squared minus one"      -> FACTOR(x^2 - 1)"#),
        Tool(tag: "EVAL", arity: 1, needsVar: false,
             build: { $0[0] },
             example: #""what is two plus three"          -> EVAL(2 + 3)"#),
    ]

    private static func arg(_ a: [String], _ i: Int, _ fallback: String) -> String {
        i < a.count && !a[i].isEmpty ? a[i] : fallback
    }

    private static var byTag: [String: Tool] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.tag, $0) })
    }

    /// System prompt: the tool menu + grammar + few-shot examples, generated from
    /// the registry so it always matches the parser.
    static var systemPrompt: String {
        let menu = tools.map { tool -> String in
            let argv = tool.arity == 2 ? "expr; var" : "expr"
            return "  \(tool.tag)(\(argv))"
        }.joined(separator: "\n")
        let examples = tools.map { "  " + $0.example }.joined(separator: "\n")
        return """
        You translate a math question into ONE tool call for a computer-algebra
        system. Output ONLY the tool call on a single line — no prose, no
        explanation, no markdown, no "=".

        Available tools (pick exactly one):
        \(menu)

        Writing expressions inside a tool call:
        - numbers and variables as-is: 2, 42, x, y, a, b
        - arithmetic infix: a + b, a - b, a * b, a / b, a^b
        - named functions ALWAYS in square brackets: Sin[x], Cos[x], Tan[x],
          Exp[x], Log[x], Sqrt[x]   (Log is natural log; write e^x as Exp[x])
        - for SOLVE, move everything to one side: "x^2 = 4" becomes x^2 - 4
        - if no variable is named for D / INTEGRATE / SOLVE, use x

        Examples:
        \(examples)

        Now output the single tool call for the user's request.
        """
    }

    /// Parse a model reply into a CAS expression. Falls back to treating the
    /// whole reply as a raw CAS expression if it isn't a recognised tool call.
    static func parse(_ reply: String) -> String {
        let line = firstMeaningfulLine(reply)
        if let (tag, args) = splitCall(line), let tool = byTag[tag.uppercased()] {
            let operands = args.map { normalizeExpr($0) }
            return tool.build(operands.isEmpty ? [""] : operands)
        }
        // Not a tool call — maybe the model emitted raw CAS syntax. Normalize and
        // pass it through so the CAS reader gets its best shot.
        return normalizeExpr(line)
    }

    /// Strip code fences / labels and take the first non-empty line.
    private static func firstMeaningfulLine(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "Output:", with: "")
        let line = t.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? t
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split "TAG(a; b)" into ("TAG", ["a", "b"]). Tolerates trailing junk.
    private static func splitCall(_ s: String) -> (String, [String])? {
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")"), open < close else { return nil }
        let tag = s[s.startIndex..<open].trimmingCharacters(in: .whitespaces)
        guard tag.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil else { return nil }
        let inside = String(s[s.index(after: open)..<close])
        let args = inside.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return (tag, args)
    }

    /// shen-cas evaluates exact integers and rationals, but its reader's
    /// tokenizer has no notion of a decimal point — a literal like `0.2` comes
    /// back as `error: tokenize: bad char .`. We rewrite every decimal literal
    /// into an equivalent exact fraction before the expression reaches the
    /// engine (`0.2` -> `(1/5)`, `3.14` -> `(157/50)`, `50000.0` -> `50000`).
    ///
    /// The fraction is parenthesised so it still composes correctly as an
    /// operand — crucially under division, where `1/0.2` must become `1/(1/5)`
    /// (= 5), not `1/1/5`. Pure integers are left untouched.
    static func rewriteDecimals(_ s: String) -> String {
        guard s.contains(".") else { return s }
        // A decimal literal: digits with a dot on at least one side. A lone `.`
        // (e.g. an ellipsis or stray dot) matches neither branch and is kept.
        let pattern = "[0-9]*\\.[0-9]+|[0-9]+\\.[0-9]*"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let r = m.range
            result += ns.substring(with: NSRange(location: last, length: r.location - last))
            result += fractionLiteral(ns.substring(with: r))
            last = r.location + r.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Turn a single decimal token (`"3.14"`, `".2"`, `"2."`) into a reduced
    /// fraction string, parenthesised unless it's a whole number.
    private static func fractionLiteral(_ token: String) -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = parts.first.map(String.init) ?? ""
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        let digits = intPart + fracPart
        guard let numerator = Int(digits.isEmpty ? "0" : digits) else { return token }
        var denominator = 1
        for _ in 0..<fracPart.count { denominator *= 10 }
        let g = gcd(numerator, denominator)
        let n = numerator / g, d = denominator / g
        return d == 1 ? "\(n)" : "(\(n)/\(d))"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    /// Best-effort fix-ups so loose model output still reads in the CAS:
    /// lowercase / paren-form functions -> bracket form, `ln`/`e^` aliases.
    static func normalizeExpr(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // function-call forms: sin(x) | sin[x] | SIN(x) -> Sin[x]; ln -> Log
        let funcs: [(String, String)] = [
            ("sin", "Sin"), ("cos", "Cos"), ("tan", "Tan"),
            ("exp", "Exp"), ("sqrt", "Sqrt"), ("log", "Log"), ("ln", "Log"),
        ]
        for (lower, canon) in funcs {
            let pattern = "(?i)\\b\(lower)\\s*[\\(\\[]\\s*([^\\)\\]]*?)\\s*[\\)\\]]"
            s = s.replacingOccurrences(of: pattern, with: "\(canon)[$1]",
                                       options: .regularExpression)
        }
        return s
    }
}
