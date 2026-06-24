import Foundation

// MARK: - Generator: alg-int-arith
//
// Root of the MVP ladder. Exact integer arithmetic with order of operations:
// the parser's PEMDAS *is* the answer key (e.g. `(2 + 3)^2 → 25`). The student
// evaluates a multi-operation integer expression to a single integer.
//
// casOps (per KnowledgeGraph.mvp): reduce, Plus, Times, Minus, Power,
// parser-precedence.
//
// Engine limits honored: int64 only — every intermediate (sums, products, and
// especially the `^` power) is kept small so the reduced result never overflows
// to an inert form. Powers use a base in 2…4 and an exponent in 2…3, and the
// number of additive terms grows with band, not their magnitude.

/// Evaluate an integer arithmetic expression to a single integer.
///
/// The answer is the *reduced* expression itself (the CAS normal form is the
/// answer key), graded as a scalar `.expression` (`Expand[student − correct] == 0`).
struct IntArithGenerator: ProblemGenerator {
    let skill: NodeID = "alg-int-arith"
    let prerequisites: [NodeID] = []

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        // Build the infix expression for the CAS reader and a parallel bracket
        // tree for MathPretty (so the prompt renders with real ·, superscripts).
        let casString = buildExpression(difficulty: difficulty, band: band, using: &rng)
        let answerExpr = casString.infix
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: "Evaluate  " + MathPretty.render(casString.tree),
            directive: "Evaluate",
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .expression,
            steps: [],   // populated when shen_cas_trace ships
            parameters: casString.params)
    }

    // MARK: - Expression construction

    /// An assembled problem: the infix form the CAS reads, the bracket tree
    /// MathPretty renders, and the echoed parameters.
    private struct Built {
        let infix: String
        let tree: String
        let params: [String: String]
    }

    /// Sample a band-appropriate arithmetic expression. Operand magnitudes and the
    /// shape grow with difficulty, but every intermediate stays int64-safe:
    ///   - introductory: `a + b · c`              (no negatives, no powers)
    ///   - standard:     `a · b − c`              (negatives allowed)
    ///   - advanced:     `(a + b) · c − d`        (grouping)
    ///   - challenge:    `(a + b)^k − c · d`      (a small power term)
    private func buildExpression<R: RandomNumberGenerator>(difficulty: Difficulty,
                                                           band: Band,
                                                           using rng: inout R) -> Built {
        let a = draw(band, using: &rng)
        let b = draw(band, using: &rng)
        let c = draw(band, using: &rng)
        let d = draw(band, using: &rng)

        switch difficulty {
        case .introductory:
            return Built(
                infix: "\(a) + \(b)*\(c)",
                tree: "[Plus \(a) [Times \(b) \(c)]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "form": "a + b*c"])

        case .standard:
            return Built(
                infix: "(\(a))*(\(b)) - (\(c))",
                tree: "[Plus [Times \(a) \(b)] [Times -1 \(c)]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "form": "a*b - c"])

        case .advanced:
            return Built(
                infix: "((\(a)) + (\(b)))*(\(c)) - (\(d))",
                tree: "[Plus [Times [Plus \(a) \(b)] \(c)] [Times -1 \(d)]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)",
                         "form": "(a + b)*c - d"])

        case .challenge:
            // Keep the power tiny so the result stays int64-safe: base in 2…4,
            // exponent in 2…3. Drawn independently of the additive band.
            let base = Int.random(in: 2...4, using: &rng)
            let k = Int.random(in: 2...3, using: &rng)
            return Built(
                infix: "(\(base))^\(k) - (\(c))*(\(d))",
                tree: "[Plus [Power \(base) \(k)] [Times -1 [Times \(c) \(d)]]]",
                params: ["base": "\(base)", "k": "\(k)", "c": "\(c)", "d": "\(d)",
                         "form": "base^k - c*d"])
        }
    }
}

#if DEBUG
extension IntArithGenerator {
    /// Lightweight self-test: across every difficulty band, generate several items
    /// and assert each canonical answer reduces to a NON-INERT integer atom. Catches
    /// int64 overflow / degenerate params (an inert reply silently breaks grading).
    static func selfTest(cas: CASEvaluator) async -> Bool {
        let gen = IntArithGenerator()
        for diff in Difficulty.allCases {
            for seed in UInt64(0)..<8 {
                var rng = SeededRNG(seed: seed &* 31 &+ UInt64(diff.rawValue))
                guard let inst = await gen.generate(difficulty: diff, using: &rng, cas: cas)
                else { return false }
                let r = inst.canonicalAnswerCAS.trimmingCharacters(in: .whitespacesAndNewlines)
                // Non-inert integer arithmetic reduces to a single integer atom.
                if CASExpr.isError(r) || r.isEmpty || Int(r) == nil { return false }
            }
        }
        return true
    }
}
#endif
