import Foundation

// MARK: - Generator: alg-linear-eq-multistep
//
// Multi-step linear equations that require collecting variable terms on one side
// and constants on the other before isolating x. Two presentations by band:
//   • both-sides:   a·x + b = c·x + d           (move c·x over, then b)
//   • distributed:  p·(x + q) + b = c·x + d      (distribute first, then collect)
// The unique root is computed by `Solve`, so the answer is provably correct.
// Graded as a `.solutionSet`.
//
// casOps (per KnowledgeGraph.mvp): reduce, Solve, Expand, Simplify, Plus, Times.
//
// Engine limits honored (docs/tutor/COVERAGE.md):
//   • exact rationals over Q only — the root −(b−d)/(a−c) is a CAS rational kept
//     exact by Solve / make-rat; never a float.
//   • int64 only — small banded coefficients keep every product / sum int64-safe.
//   • avoid degenerate params — a ≠ c is enforced (equal slopes would give either
//     no solution or an identity, both inert under Solve).

/// Solve a multi-step linear equation (variable on both sides, possibly with a
/// distributed term) for x. Answer graded as a `.solutionSet`.
struct LinearEquationMultiStepGenerator: ProblemGenerator {
    let skill: NodeID = "alg-linear-eq-multistep"
    let prerequisites: [NodeID] = ["alg-linear-eq-1step"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        // Slopes on each side — must differ (a ≠ c) so the equation has a unique
        // root rather than collapsing to no-solution / identity (both inert).
        var a = draw(band, using: &rng); if a == 0 { a = band.range.lowerBound }
        var c = draw(band, using: &rng); if c == 0 { c = band.range.lowerBound }
        if a == c { c = (c == band.range.upperBound) ? c - 1 : c + 1 }
        if a == c { c = a &+ 2 }                       // belt-and-braces, still int64-safe

        let b = draw(band, using: &rng)
        let d = draw(band, using: &rng)

        // Distribute a leading factor at the harder bands; plain both-sides otherwise.
        let distributed = (difficulty == .advanced || difficulty == .challenge)

        let lhsInfix: String
        let lhsTree: String
        let params: [String: String]
        if distributed {
            var p = draw(band, using: &rng); if p == 0 { p = band.range.lowerBound }
            let q = draw(band, using: &rng)
            // p·(x + q) + b  on the left.
            lhsInfix = "(\(p))*(x + (\(q))) + (\(b))"
            lhsTree = "[Plus [Times \(p) [Plus x \(q)]] \(b)]"
            params = ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)",
                      "p": "\(p)", "q": "\(q)", "form": "p*(x+q)+b = c*x+d"]
        } else {
            // a·x + b  on the left.
            lhsInfix = "(\(a))*x + (\(b))"
            lhsTree = "[Plus [Times \(a) x] \(b)]"
            params = ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)",
                      "form": "a*x+b = c*x+d"]
        }

        let rhsInfix = "(\(c))*x + (\(d))"
        let rhsTree = "[Plus [Times \(c) x] \(d)]"

        let answerExpr = "Solve[(\(lhsInfix)) == (\(rhsInfix)), x]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }
        // A unique root reduces to a single value; an inert Solve reply (still
        // carrying the `Solve` head) means we hit a degenerate identity — re-draw.
        if canonical.contains("Solve") { return nil }

        let prompt = "Solve  " + MathPretty.render(lhsTree) + " = " + MathPretty.render(rhsTree)

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
            steps: [],
            parameters: params)
    }
}

#if DEBUG
extension LinearEquationMultiStepGenerator {
    /// Self-test: one item per band, asserting a live (non-inert) canonical root.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(LinearEquationMultiStepGenerator(), cas: cas)
    }
}
#endif
