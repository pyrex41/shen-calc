import Foundation

// MARK: - Generator: alg-eval-substitute
//
// Fourth node in the MVP ladder. Evaluate an expression at a given value of the
// variable: substitute `x = v` and compute the resulting number.
//
// casOps (per KnowledgeGraph.mvp): reduce, Plus, Times, Power.
//
// Substitution note (COVERAGE.md): the engine has NO `Subst`/`ReplaceAll` head.
// Substitution is done at the app layer by string-interpolating the value into the
// expression before it is reduced — then the CAS performs a *verified numeric
// fold*. So the answerExpr already contains `v` in place of `x`; reducing it yields
// the exact value, which is the answer key.
//
// Engine limits honored: exact arithmetic only (rational `v` allowed, NO floats);
// int64 only — the value and coefficients stay small and any `x²` term uses a
// small base so the folded result can't overflow to an inert form.

/// Evaluate an expression `f(x)` at `x = v` (substitute-and-fold).
///
/// The canonical answer is the reduced numeric (integer or rational) value, graded
/// as a scalar `.expression` (`Expand[student − correct] == 0`).
struct EvalSubstituteGenerator: ProblemGenerator {
    let skill: NodeID = "alg-eval-substitute"
    let prerequisites: [NodeID] = ["alg-linear-expr"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let built = buildExpression(difficulty: difficulty, using: &rng)

        // Substitution is app-layer string interpolation (no Subst head): the value
        // is already spliced into `built.substituted`, so reducing it folds to the
        // exact answer. The unsubstituted display tree is shown in the prompt.
        let answerExpr = built.substituted
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        let prompt = "Evaluate  " + MathPretty.render(built.tree)
            + "   at  x = " + built.valuePretty

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: prompt,
            directive: "Evaluate at x = " + built.valuePretty,
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .expression,
            steps: [],   // populated when shen_cas_trace ships
            parameters: built.params)
    }

    // MARK: - Expression construction

    private struct Built {
        /// Display tree (with the symbolic `x`) for MathPretty.
        let tree: String
        /// Infix form with `v` already substituted for `x` — reduced for the answer.
        let substituted: String
        /// The substitution value rendered for the prompt (e.g. "-3" or "1/2").
        let valuePretty: String
        let params: [String: String]
    }

    /// Sample a band-appropriate expression and a value to evaluate at. Magnitudes
    /// grow with band; the quadratic term (challenge) uses a small value so the fold
    /// stays int64-safe.
    ///   - introductory: `a·x + b`               at integer v
    ///   - standard:     `a·x + b`               at signed integer v
    ///   - advanced:     `a·x² + b·x + c`        at small integer v
    ///   - challenge:    `a·x² + b·x + c`        at a rational v = p/q
    private func buildExpression<R: RandomNumberGenerator>(difficulty: Difficulty,
                                                          using rng: inout R) -> Built {
        let band = difficulty.band
        let a = draw(band, using: &rng)
        let b = draw(band, using: &rng)
        let c = draw(band, using: &rng)

        switch difficulty {
        case .introductory, .standard:
            // Linear: a*x + b, evaluated at an integer value.
            let v = draw(band, using: &rng)
            let vStr = "(\(v))"
            return Built(
                tree: "[Plus [Times \(a) x] \(b)]",
                substituted: "(\(a))*\(vStr) + (\(b))",
                valuePretty: "\(v)",
                params: ["a": "\(a)", "b": "\(b)", "v": "\(v)", "form": "a*x + b"])

        case .advanced:
            // Quadratic at a small integer value to keep x² int64-safe.
            let v = Int.random(in: -4...4, using: &rng)
            let vStr = "(\(v))"
            return Built(
                tree: "[Plus [Times \(a) [Power x 2]] [Times \(b) x] \(c)]",
                substituted: "(\(a))*(\(vStr))^2 + (\(b))*\(vStr) + (\(c))",
                valuePretty: "\(v)",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "v": "\(v)",
                         "form": "a*x^2 + b*x + c"])

        case .challenge:
            // Quadratic at a rational value v = p/q (exact, no floats). q ≥ 2 so the
            // value is a genuine fraction; p small so p²·a stays int64-safe.
            let p = Int.random(in: 1...5, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            let q = Int.random(in: 2...5, using: &rng)
            let vStr = "((\(p))/(\(q)))"
            return Built(
                tree: "[Plus [Times \(a) [Power x 2]] [Times \(b) x] \(c)]",
                substituted: "(\(a))*(\(vStr))^2 + (\(b))*\(vStr) + (\(c))",
                valuePretty: "\(p)/\(q)",
                params: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "p": "\(p)", "q": "\(q)",
                         "form": "a*x^2 + b*x + c"])
        }
    }
}

#if DEBUG
extension EvalSubstituteGenerator {
    /// Lightweight self-test: across every difficulty band, generate several items
    /// and assert each canonical answer reduces NON-INERT to a numeric value (no
    /// `error:`, non-empty, and the variable `x` no longer appears — proving the
    /// substitute-and-fold actually evaluated). Catches int64 overflow / degenerate
    /// params before they ship.
    static func selfTest(cas: CASEvaluator) async -> Bool {
        let gen = EvalSubstituteGenerator()
        for diff in Difficulty.allCases {
            for seed in UInt64(0)..<8 {
                var rng = SeededRNG(seed: seed &* 97 &+ UInt64(diff.rawValue))
                guard let inst = await gen.generate(difficulty: diff, using: &rng, cas: cas)
                else { return false }
                let r = inst.canonicalAnswerCAS.trimmingCharacters(in: .whitespacesAndNewlines)
                if CASExpr.isError(r) || r.isEmpty { return false }
                // A fully folded numeric answer contains no symbolic variable.
                if r.contains("x") { return false }
            }
        }
        return true
    }
}
#endif
