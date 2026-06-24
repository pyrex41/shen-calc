import Foundation

// MARK: - CAS injection

/// The single math primitive every generator and the grader need: reduce a
/// shen-cas bracket/infix expression to its normal form. Modelled as a protocol so
/// this file compiles and unit-tests without the FFI — pass any conformer.
/// `ShenCAS` (which already has `reduce(_:) async -> String`) conforms via the
/// extension at the bottom; tests can inject a stub/recorder.
///
/// Results are bracketed S-exprs like `[Times 3 [Power x 2]]`, `[List 2 -2]`, or
/// `error:…`. Grading NEVER string-matches answers — it asks the CAS whether a
/// *difference reduces to zero* (`Expand[student - correct] == 0`, with a
/// `Simplify` fallback) or whether reduced root sets match.
protocol CASEvaluator {
    func reduce(_ input: String) async -> String
}

// MARK: - Difficulty banding

/// Random-parameter difficulty band. The Saxon-spiral scheduler picks the band
/// from the learner's mastery of the skill; the generator maps band -> parameter
/// ranges. Bands are ordinal and comparable.
enum Difficulty: Int, Codable, CaseIterable, Comparable {
    case introductory = 0   // smallest ints, no negatives, integer answers
    case standard     = 1   // negatives, simple fractions
    case advanced     = 2   // larger coeffs, fraction answers, edge cases
    case challenge    = 3   // composed forms, near-degenerate params
    static func < (a: Difficulty, b: Difficulty) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - The answer's mathematical shape (drives the grader's equivalence rule)

/// How a typed answer is compared to the canonical answer by CAS equivalence.
enum AnswerKind: Codable {
    /// Scalar / single expression. Equivalent iff the difference reduces to zero.
    case expression
    /// Solution set (Solve). Equivalent iff the reduced root multisets match.
    case solutionSet(variable: String)
    /// Unordered list/value. Equivalent iff student value == correct value.
    case list
    /// Factorization: graded by expansion equality AND a "is actually factored"
    /// guard (the student form must not Expand-equal its own input trivially).
    case factorization(of: String)   // the original polynomial string
}

// MARK: - Problem instance

/// A fully materialized problem: prompt, the CAS strings used to make/grade it,
/// the canonical answer, and (when available) the verified worked steps.
struct ProblemInstance: Identifiable {
    let id: UUID
    let skill: NodeID
    let difficulty: Difficulty

    /// Human prompt, already rendered for display, e.g. "Solve  3·x + 6 = 0".
    let prompt: String
    /// The instruction verb shown above the prompt, e.g. "Solve for x".
    let directive: String

    /// The CAS expression that *computes the canonical answer* when reduced,
    /// e.g. "Solve[3*x + 6 == 0, x]" or "Expand[(x + 3)^2]".
    let answerExpr: String

    /// The canonical answer in raw CAS bracket form (result of reduce(answerExpr)).
    let canonicalAnswerCAS: String
    /// The canonical answer rendered for display (MathPretty.render of the above).
    let canonicalAnswerPretty: String

    /// How the grader compares student input to the canonical answer.
    let answerKind: AnswerKind

    /// Verified worked steps. Empty until the trace FFI ships (`shen_cas_trace`);
    /// the grader/UI treat empty as "fall back to single-line solution".
    let steps: [Step]

    /// Echo of the parameters, for analytics / regeneration / item exposure control.
    let parameters: [String: String]
}

/// One verified rewrite in the worked solution. Mirrors shen-cas's
/// [Before After Why] step record (faithfulness invariant: last After == reduce).
struct Step: Identifiable {
    let id = UUID()
    let beforePretty: String   // MathPretty of the Before tree
    let afterPretty: String    // MathPretty of the After tree
    let why: String            // human rule label, e.g. "power rule (chain-aware)"
}

// MARK: - Grading

/// Outcome of grading one typed answer.
struct GradeResult {
    enum Verdict {
        case correct
        case incorrect
        /// CAS rejected the student's input (unparseable) — treat as "try again",
        /// not "wrong", so a typo doesn't burn a mastery attempt.
        case malformed
        /// Equivalent in value but the *form* fails a requirement (e.g. a Factor
        /// answer left unfactored). Partial credit / nudge.
        case rightValueWrongForm
    }
    let verdict: Verdict
    /// The reduced difference / comparison residue, for debugging & analytics.
    let residue: String?
    /// Worked steps to reveal on a miss (the instance's steps, possibly trimmed).
    let revealedSteps: [Step]
    /// One-line feedback for the learner.
    let message: String

    var isMasteryCredit: Bool { verdict == .correct }
}

// MARK: - The two protocols

/// Produces problem instances for exactly one skill node. Pure aside from the CAS
/// calls it makes through `cas`. Deterministic given `rng` — pass a seeded RNG for
/// reproducible item generation / testing. The RNG is generic (not an existential)
/// so `Int.random(in:using:)` and friends type-check.
protocol ProblemGenerator {
    var skill: NodeID { get }
    /// Skills that must be mastered before this one unlocks (DAG edges), declared
    /// here so authoring stays local. Must match the node's `prerequisites` in the
    /// shipped `KnowledgeGraph`.
    var prerequisites: [NodeID] { get }

    /// Materialize one problem. May return nil if a sampled instance is degenerate
    /// (caller retries with a fresh draw).
    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance?
}

/// Grades a typed answer against a ProblemInstance by CAS equivalence. Stateless;
/// one shared instance grades every skill (it dispatches on `instance.answerKind`).
protocol Grader {
    func grade(_ studentInput: String,
               for instance: ProblemInstance,
               cas: CASEvaluator) async -> GradeResult
}

// MARK: - Difficulty banding of random parameters

struct Band {
    let range: ClosedRange<Int>
    let allowNegative: Bool
    let allowZero: Bool
}

extension Difficulty {
    /// Default band; generators may override per parameter.
    var band: Band {
        switch self {
        case .introductory: return Band(range: 1...6,  allowNegative: false, allowZero: false)
        case .standard:     return Band(range: 1...9,  allowNegative: true,  allowZero: false)
        case .advanced:     return Band(range: 1...12, allowNegative: true,  allowZero: true)
        case .challenge:    return Band(range: 1...15, allowNegative: true,  allowZero: true)
        }
    }
}

/// Draw one banded integer. Keeps draws inside the band and avoids the
/// degeneracies (a zero where zero would collapse the problem). Generic over the
/// RNG so it works with any `RandomNumberGenerator` value type.
func draw<R: RandomNumberGenerator>(_ band: Band, using rng: inout R) -> Int {
    var v = Int.random(in: band.range, using: &rng)
    if band.allowNegative && Bool.random(using: &rng) { v = -v }
    if v == 0 && !band.allowZero { v = band.range.lowerBound }
    return v
}

/// A deterministic, seedable RNG so item generation is reproducible in tests and
/// for item-exposure control. SplitMix64 — small, fast, good distribution.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - CAS string helpers

/// Small utilities for emitting the exact syntax the CAS reader accepts and for
/// interpreting its normal-form replies. Kept next to the grading rule they serve.
///
/// The grading oracle is `Expand[student − correct] == 0`, NOT `Simplify[…]`:
/// shen-cas's `Simplify` collects like terms but does NOT expand products, so it
/// leaves a factored-vs-expanded difference non-zero. `Expand` is the sound oracle
/// for polynomial/rational forms; `Simplify` is kept only as a fallback for the
/// non-polynomial cases `Expand` can't flatten.
enum CASExpr {

    /// A reduced reply counts as zero iff it is the atom `0` (the CAS normalizes
    /// `x − x`, `Expand[(x−1)(x+1)] − (x²−1)`, etc. to `0`). Accept defensively.
    static func isZero(_ reduced: String) -> Bool {
        let t = reduced.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "0" || t == "[0]" || t == "0.0"
    }

    static func isError(_ reduced: String) -> Bool {
        reduced.trimmingCharacters(in: .whitespaces).hasPrefix("error:")
    }

    /// Primary scalar/value oracle: Expand the difference and check it's zero.
    static func expandDiff(_ student: String, _ correct: String) -> String {
        "Expand[(\(student)) - (\(correct))]"
    }

    /// Fallback oracle for non-polynomial equivalences Expand can't flatten.
    static func simplifyDiff(_ student: String, _ correct: String) -> String {
        "Simplify[(\(student)) - (\(correct))]"
    }

    /// Extract the roots from a `Solve[...]` reply. shen-cas returns a list head
    /// (`[List a b …]`) for multiple roots, a bare atom for a single root, or
    /// `[Rule x v]`-style bindings. We pull out the value sub-expressions and hand
    /// each back as a CAS string the grader can reduce independently.
    static func rootsFromSolveReply(_ reply: String) -> [String] {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isError(t) else { return [] }
        guard let node = parse(t) else { return [t] }
        return rootValues(node).map { serialize($0) }
    }

    /// Parse "x = 2 or x = -2", "{2, -2}", "2, -2", or a single value into the list
    /// of root CAS strings the learner means. Reuses the NL normalizer.
    static func rootsFromStudent(_ raw: String, variable v: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("{") && s.hasSuffix("}") {
            s = String(s.dropFirst().dropLast())
        }
        let parts = s.replacingOccurrences(of: " or ", with: ",",
                                           options: .caseInsensitive)
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let pieces = parts.isEmpty ? [s] : parts
        return pieces.map { piece -> String in
            var val = piece
            for sep in ["=", ":"] {
                if let r = val.range(of: sep) {
                    let lhs = val[val.startIndex..<r.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                    if lhs == v || lhs.isEmpty {
                        val = String(val[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            return CASTools.normalizeExpr(val)
        }
    }

    // --- tiny bracket-S-expr parser (mirrors MathPretty's, kept local) ---

    indirect enum Node { case atom(String), list([Node]) }

    static func parse(_ s: String) -> Node? {
        var toks = tokenize(s)
        return parse(&toks)
    }

    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for ch in s {
            switch ch {
            case "[", "]": flush(); out.append(String(ch))
            case " ", "\t", "\n", ",": flush()
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

    /// Pull the root *values* out of a parsed Solve reply.
    private static func rootValues(_ node: Node) -> [Node] {
        switch node {
        case .atom:
            return [node]
        case .list(let xs):
            guard case .atom(let head)? = xs.first else { return [node] }
            let args = Array(xs.dropFirst())
            switch head {
            case "List":
                return args.flatMap { rootValues($0) }
            case "Rule", "Equal":
                return args.count >= 2 ? [args[1]] : args
            default:
                return [node]
            }
        }
    }

    private static func serialize(_ node: Node) -> String {
        switch node {
        case .atom(let a): return a
        case .list(let xs): return "[" + xs.map { serialize($0) }.joined(separator: " ") + "]"
        }
    }
}

/// Order-independent comparison of reduced root strings.
struct Multiset<Element: Hashable>: Equatable {
    private var counts: [Element: Int] = [:]
    init(_ elements: [Element]) { for e in elements { counts[e, default: 0] += 1 } }
    static func == (a: Multiset, b: Multiset) -> Bool { a.counts == b.counts }
}

// MARK: - Shared grader (the equivalence engine)

/// The heart of "provably correct grading." Dispatches on `AnswerKind` and only
/// ever asks the CAS whether a *difference reduces to zero* / whether *reduced root
/// sets match*. Never string-matches an answer.
struct CASGrader: Grader {

    func grade(_ studentInput: String,
               for instance: ProblemInstance,
               cas: CASEvaluator) async -> GradeResult {

        let student = CASTools.normalizeExpr(studentInput)
        guard !student.isEmpty else {
            return miss(.malformed, instance, "Enter an answer.", residue: nil)
        }

        switch instance.answerKind {
        case .expression:
            return await gradeValue(student, instance, cas)
        case .solutionSet(let v):
            return await gradeSet(student, variable: v, instance, cas)
        case .list:
            return await gradeValue(student, instance, cas)
        case .factorization(let original):
            return await gradeFactorization(student, original: original, instance, cas)
        }
    }

    // MARK: value — Expand[student − correct] == 0, Simplify fallback

    private func gradeValue(_ student: String,
                            _ inst: ProblemInstance,
                            _ cas: CASEvaluator) async -> GradeResult {
        let expanded = await cas.reduce(CASExpr.expandDiff(student, inst.canonicalAnswerCAS))
        if CASExpr.isError(expanded) {
            return miss(.malformed, inst,
                        "I couldn't read that expression — check your syntax.", residue: expanded)
        }
        if CASExpr.isZero(expanded) { return hit(inst) }

        // Fallback: some non-polynomial equivalences don't flatten under Expand.
        let simplified = await cas.reduce(CASExpr.simplifyDiff(student, inst.canonicalAnswerCAS))
        if !CASExpr.isError(simplified), CASExpr.isZero(simplified) { return hit(inst) }

        return miss(.incorrect, inst,
                    "Not quite — compare with the worked steps below.", residue: expanded)
    }

    // MARK: solution set — reduced-root multiset equality

    private func gradeSet(_ student: String, variable v: String,
                          _ inst: ProblemInstance, _ cas: CASEvaluator) async -> GradeResult {
        let studentRoots = CASExpr.rootsFromStudent(student, variable: v)
        let correctRoots = CASExpr.rootsFromSolveReply(inst.canonicalAnswerCAS)
        guard !studentRoots.isEmpty else {
            return miss(.malformed, inst, "Couldn't read your solutions.", residue: nil)
        }
        let s = await reduceAll(studentRoots, cas)
        let c = await reduceAll(correctRoots, cas)
        if s.contains(where: { CASExpr.isError($0) }) {
            return miss(.malformed, inst, "Couldn't read one of your solutions.",
                        residue: s.joined(separator: ", "))
        }
        return Multiset(s) == Multiset(c)
            ? hit(inst)
            : miss(.incorrect, inst, "Check the number and values of your solutions.",
                   residue: "{\(s.joined(separator: ", "))}")
    }

    // MARK: factorization — grade the VALUE, then the FORM

    private func gradeFactorization(_ student: String, original: String,
                                    _ inst: ProblemInstance, _ cas: CASEvaluator) async -> GradeResult {
        // Value check: student must Expand-equal the original polynomial.
        let val = await cas.reduce(CASExpr.expandDiff(student, original))
        if CASExpr.isError(val) {
            return miss(.malformed, inst, "Couldn't read your factorization.", residue: val)
        }
        guard CASExpr.isZero(val) else {
            return miss(.incorrect, inst,
                        "Multiply your factors back out — they don't match.", residue: val)
        }
        // Form check: a genuinely-factored answer is NOT structurally the expanded
        // polynomial. If Expand[student] equals the reduced student form, nothing
        // was factored.
        let expanded = await cas.reduce("Expand[\(student)]")
        let asIs = await cas.reduce(student)
        if !CASExpr.isError(expanded), !CASExpr.isError(asIs),
           normalized(expanded) == normalized(asIs) {
            return GradeResult(
                verdict: .rightValueWrongForm,
                residue: asIs,
                revealedSteps: inst.steps,
                message: "Right value, but it isn't factored — write it as a product of factors.")
        }
        return hit(inst)
    }

    // MARK: helpers

    private func reduceAll(_ exprs: [String], _ cas: CASEvaluator) async -> [String] {
        var out: [String] = []
        for e in exprs { out.append(normalized(await cas.reduce(e))) }   // serial engine
        return out
    }

    private func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hit(_ inst: ProblemInstance) -> GradeResult {
        GradeResult(verdict: .correct, residue: "0", revealedSteps: [], message: "Correct.")
    }

    private func miss(_ verdict: GradeResult.Verdict,
                      _ inst: ProblemInstance,
                      _ message: String,
                      residue: String?) -> GradeResult {
        GradeResult(verdict: verdict, residue: residue,
                    revealedSteps: inst.steps, message: message)
    }
}

// MARK: - Example generator 1: solve a linear equation a·x + b = 0
//
// Maps to MVP node `alg-linear-eq-1step`. Answer is the single root x = -b/a,
// graded as a solution set. Banding controls coefficient size, signs, and whether
// the root is an integer or a fraction.
//
// NOTE (integration): this is the reference/example generator kept inline with the
// protocol definitions. The SHIPPING generator for `alg-linear-eq-1step` is
// `LinearEquationOneStepGenerator` in `Learning/Generators/` — that one is what
// `GeneratorRegistry.default` registers. `SolveLinearGenerator` is retained as a
// minimal, self-contained example of the `ProblemGenerator` contract and is not
// wired into the registry (registering both would collide on the same skill id).

struct SolveLinearGenerator: ProblemGenerator {
    let skill: NodeID = "alg-linear-eq-1step"
    let prerequisites: [NodeID] = ["alg-eval-substitute"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band
        var a = draw(band, using: &rng)
        if a == 0 { a = band.range.lowerBound }
        var b: Int
        switch difficulty {
        case .introductory, .standard:
            // integer root: pick the root first, then b = -a·root
            let rootBand = Band(range: 1...max(2, band.range.upperBound),
                                allowNegative: band.allowNegative, allowZero: true)
            let root = draw(rootBand, using: &rng)
            b = -a * root
        case .advanced, .challenge:
            b = draw(band, using: &rng)
            if b == 0 { b = band.range.lowerBound }   // avoid the trivial x = 0
        }

        // Equation form: a·x + b == 0. (`==` parses to Equal in shen-cas.)
        let lhs = "\(a)*x + \(b)"
        let answerExpr = "Solve[\(lhs) == 0, x]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        let prompt = "Solve  " + MathPretty.render("[Plus [Times \(a) x] \(b)]") + " = 0"

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: prompt,
            directive: "Solve for x",
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .solutionSet(variable: "x"),
            steps: [],   // populated when shen_cas_trace ships
            parameters: ["a": "\(a)", "b": "\(b)"])
    }
}

// (Generators 2 and 3 — `FactorQuadraticGenerator` and
// `ExpandSpecialProductGenerator` — moved to one-file-per-node modules under
// `Learning/Generators/`. See that directory for the full per-skill set.)

// MARK: - ShenCAS conformance (the real engine)

/// `ShenCAS` already exposes `reduce(_:) async -> String`; declaring conformance
/// here lets the live engine flow straight into the generators and grader with no
/// adapter. (The protocol exists only so this file compiles/tests without the FFI.)
extension ShenCAS: CASEvaluator {}
