import Foundation

// MARK: - Generator: alg-linear-eq-1step
//
// One-step linear equations of the form  a·x + b = 0. The single root x = −b/a
// is computed by the engine via `Solve` — provably correct because shen-cas
// substitutes every root back and requires it reduce to 0, else returns inert.
// Graded as a solution set so any equivalent student form (fraction, decomposed,
// …) is accepted.
//
// casOps (per KnowledgeGraph.mvp): reduce, Solve, Plus, Times.
//
// Engine limits honored (docs/tutor/COVERAGE.md):
//   • exact rationals over Q only — never emit a float; the −b/a root is a CAS
//     rational kept exact by Solve / make-rat.
//   • int64 only — coefficients are banded small; the product a·root stays
//     int64-safe.
//   • avoid degenerate params — a is never 0 (would erase the variable); the root
//     is never 0 (the trivial answer).

/// Solve a one-step linear equation `a·x + b = 0` for x. Answer is the single
/// root, graded as a `.solutionSet`.
struct LinearEquationOneStepGenerator: ProblemGenerator {
    let skill: NodeID = "alg-linear-eq-1step"
    let prerequisites: [NodeID] = ["alg-eval-substitute"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        // Leading coefficient — never 0 (the equation must contain x).
        var a = draw(band, using: &rng)
        if a == 0 { a = band.range.lowerBound }

        let b: Int
        switch difficulty {
        case .introductory, .standard:
            // Integer root: choose the root, then b = −a·root (kept int64-safe by
            // the small band). Root may be negative at `standard`, never 0.
            let rootBand = Band(range: 1...max(2, band.range.upperBound),
                                allowNegative: band.allowNegative, allowZero: false)
            let root = draw(rootBand, using: &rng)
            b = -a &* root
        case .advanced, .challenge:
            var bb = draw(band, using: &rng)
            if bb == 0 { bb = band.range.lowerBound }   // avoid the trivial x = 0
            b = bb
        }

        // Equation a·x + b == 0  (`==` parses to Equal in shen-cas).
        let lhsInfix = "(\(a))*x + (\(b))"
        let answerExpr = "Solve[\(lhsInfix) == 0, x]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        let prompt = "Solve  " + MathPretty.render(lhsTree(a: a, b: b)) + " = 0"

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

    /// Bracket tree for the prompt: `a·x + b` (b folded only when nonzero).
    private func lhsTree(a: Int, b: Int) -> String {
        var parts = ["[Times \(a) x]"]
        if b != 0 { parts.append("\(b)") }
        return "[Plus " + parts.joined(separator: " ") + "]"
    }
}

#if DEBUG
extension LinearEquationOneStepGenerator {
    /// Self-test: generate one item per difficulty band and assert each canonical
    /// answer reduces NON-INERT (catches int64 overflow / degenerate params that
    /// would silently break grading). Delegates to the shared scaffold.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(LinearEquationOneStepGenerator(), cas: cas)
    }
}
#endif
