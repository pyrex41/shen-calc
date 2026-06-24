import Foundation

// MARK: - Generator: alg-linear-expr
//
// Third node in the MVP ladder. Simplify a linear expression in one variable:
// combine like terms and distribute a coefficient over a parenthesized sum. The
// result is a linear expression `m·x + k` (the CAS normal form is the answer key).
//
// casOps (per KnowledgeGraph.mvp): reduce, Simplify, Expand, Plus, Times.
//
// Engine limits honored: int64 only — coefficients stay small so the distributed
// products and combined coefficients can't overflow to an inert form. The leading
// coefficient is kept non-zero so the expression stays genuinely linear (a true
// "combine like terms" exercise, not a constant).

/// Simplify a linear expression in `x` (combine like terms / distribute).
///
/// The canonical answer is `Expand[expr]` in linear normal form, graded as a
/// scalar `.expression` (`Expand[student − correct] == 0`).
struct LinearExprGenerator: ProblemGenerator {
    let skill: NodeID = "alg-linear-expr"
    let prerequisites: [NodeID] = ["alg-rational-arith"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let built = buildExpression(difficulty: difficulty, using: &rng)

        // Expand distributes products and collects like terms into linear normal
        // form — the answer key the grader compares against.
        let answerExpr = "Expand[\(built.infix)]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: "Simplify  " + MathPretty.render(built.tree),
            directive: "Combine like terms",
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

    /// Sample a band-appropriate linear expression. Coefficient size grows with
    /// band; the `x`-coefficient is kept non-zero so the result stays linear.
    ///   - introductory: `a·x + b + c·x`              (collect like terms)
    ///   - standard:     `a·x + b − c·x + d`          (signed, collect)
    ///   - advanced:     `a·(x + b) + c·x`            (distribute, then collect)
    ///   - challenge:    `a·(b·x + c) − d·(x + e)`    (two distributions)
    private func buildExpression<R: RandomNumberGenerator>(difficulty: Difficulty,
                                                          using rng: inout R) -> Built {
        let band = difficulty.band
        let a = draw(band, using: &rng)
        let b = draw(band, using: &rng)
        let c = draw(band, using: &rng)
        let d = draw(band, using: &rng)
        let e = draw(band, using: &rng)

        switch difficulty {
        case .introductory:
            return Built(
                infix: "\(a)*x + \(b) + \(c)*x",
                tree: "[Plus [Times \(a) x] \(b) [Times \(c) x]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "form": "a*x + b + c*x"])

        case .standard:
            return Built(
                infix: "(\(a))*x + (\(b)) - (\(c))*x + (\(d))",
                tree: "[Plus [Times \(a) x] \(b) [Times -1 [Times \(c) x]] \(d)]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)",
                         "form": "a*x + b - c*x + d"])

        case .advanced:
            return Built(
                infix: "(\(a))*(x + (\(b))) + (\(c))*x",
                tree: "[Plus [Times \(a) [Plus x \(b)]] [Times \(c) x]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)",
                         "form": "a*(x + b) + c*x"])

        case .challenge:
            return Built(
                infix: "(\(a))*((\(b))*x + (\(c))) - (\(d))*(x + (\(e)))",
                tree: "[Plus [Times \(a) [Plus [Times \(b) x] \(c)]] "
                    + "[Times -1 [Times \(d) [Plus x \(e)]]]]",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)", "e": "\(e)",
                         "form": "a*(b*x + c) - d*(x + e)"])
        }
    }
}

#if DEBUG
extension LinearExprGenerator {
    /// Lightweight self-test: across every difficulty band, generate several items
    /// and assert each canonical answer reduces NON-INERT (no `error:`, non-empty).
    /// Catches int64 overflow / degenerate params before they ship.
    static func selfTest(cas: CASEvaluator) async -> Bool {
        let gen = LinearExprGenerator()
        for diff in Difficulty.allCases {
            for seed in UInt64(0)..<8 {
                var rng = SeededRNG(seed: seed &* 71 &+ UInt64(diff.rawValue))
                guard let inst = await gen.generate(difficulty: diff, using: &rng, cas: cas)
                else { return false }
                let r = inst.canonicalAnswerCAS.trimmingCharacters(in: .whitespacesAndNewlines)
                if CASExpr.isError(r) || r.isEmpty { return false }
            }
        }
        return true
    }
}
#endif
