import Foundation

// MARK: - Generator: alg-rational-arith
//
// Second node in the MVP ladder. Exact rational arithmetic over Q: add, subtract,
// multiply, and divide fractions, with the result reduced to lowest terms. The CAS
// `make-rat` auto-normalizes (lowest terms, positive denominator) and doubles as
// the answer key.
//
// casOps (per KnowledgeGraph.mvp): reduce, Plus, Minus, Times, Divide, make-rat,
// Together.
//
// Engine limits honored: exact rationals only (NO floats/decimals); int64 only,
// so numerators/denominators stay small enough that the cross-multiplied result
// can't overflow to an inert form. Denominators are always drawn ≥ 2 (never 0),
// and division uses a non-zero divisor.

/// Combine two (or three) fractions into a single reduced fraction.
///
/// The canonical answer is `Together[expr]` reduced to its lowest-terms rational
/// normal form, graded as a scalar `.expression` (`Expand[student − correct] == 0`,
/// with the grader's `Simplify`/`Together`/`Cancel` fallbacks covering form).
struct RationalArithGenerator: ProblemGenerator {
    let skill: NodeID = "alg-rational-arith"
    let prerequisites: [NodeID] = ["alg-int-arith"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let built = buildExpression(difficulty: difficulty, using: &rng)

        // Together folds the sum/difference of fractions into one reduced fraction;
        // it is the rational answer key the grader compares against.
        let answerExpr = "Together[\(built.infix)]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: "Simplify  " + MathPretty.render(built.tree),
            directive: "Write as a single fraction in lowest terms",
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .expression,
            steps: [],   // populated when shen_cas_trace ships
            parameters: built.params)
    }

    // MARK: - Expression construction

    private struct Built {
        let infix: String
        let tree: String
        let params: [String: String]
    }

    /// Sample a band-appropriate rational expression. Operand size grows with band;
    /// every denominator is drawn ≥ 2 and every divisor is non-zero, keeping the
    /// cross-multiplied result int64-safe and the problem non-degenerate.
    ///   - introductory: `a/b + c/d`              (positive, small)
    ///   - standard:     `a/b − c/d`              (signed numerators)
    ///   - advanced:     `a/b · c/d`              (product of fractions)
    ///   - challenge:    `a/b ÷ c/d` (= a/b · d/c) (division, non-zero divisor)
    private func buildExpression<R: RandomNumberGenerator>(difficulty: Difficulty,
                                                          using rng: inout R) -> Built {
        let numBand = difficulty.band                                   // numerators
        let denBand = Band(range: 2...max(2, difficulty.band.range.upperBound),
                           allowNegative: false, allowZero: false)      // denominators ≥ 2

        let a = draw(numBand, using: &rng)
        let b = draw(denBand, using: &rng)
        var c = draw(numBand, using: &rng)
        let d = draw(denBand, using: &rng)

        switch difficulty {
        case .introductory, .standard:
            let op = (difficulty == .introductory) ? "+" : "-"
            let head = (op == "+") ? "Plus" : "Minus"
            return Built(
                infix: "(\(a))/(\(b)) \(op) (\(c))/(\(d))",
                tree: "[\(head) [Divide \(a) \(b)] [Divide \(c) \(d)]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)", "op": op])

        case .advanced:
            return Built(
                infix: "((\(a))/(\(b))) * ((\(c))/(\(d)))",
                tree: "[Times [Divide \(a) \(b)] [Divide \(c) \(d)]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)", "op": "*"])

        case .challenge:
            // Division: the divisor's numerator must be non-zero so the quotient
            // is well-defined (a/b ÷ c/d = a/b · d/c).
            if c == 0 { c = numBand.range.lowerBound }
            return Built(
                infix: "((\(a))/(\(b))) / ((\(c))/(\(d)))",
                tree: "[Divide [Divide \(a) \(b)] [Divide \(c) \(d)]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)", "op": "/"])
        }
    }
}

#if DEBUG
extension RationalArithGenerator {
    /// Lightweight self-test: across every difficulty band, generate several items
    /// and assert each canonical answer reduces NON-INERT (no `error:`, non-empty,
    /// and not the unevaluated input echoed back). Catches int64 overflow and the
    /// degenerate zero-denominator / zero-divisor cases before they ship.
    static func selfTest(cas: CASEvaluator) async -> Bool {
        let gen = RationalArithGenerator()
        for diff in Difficulty.allCases {
            for seed in UInt64(0)..<8 {
                var rng = SeededRNG(seed: seed &* 53 &+ UInt64(diff.rawValue))
                guard let inst = await gen.generate(difficulty: diff, using: &rng, cas: cas)
                else { return false }
                let r = inst.canonicalAnswerCAS.trimmingCharacters(in: .whitespacesAndNewlines)
                if CASExpr.isError(r) || r.isEmpty { return false }
                // The reduced rational must not still carry a Together head (inert).
                if r.contains("Together") { return false }
            }
        }
        return true
    }
}
#endif
