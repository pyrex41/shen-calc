import Foundation

// MARK: - alg-factor-quadratic — factor a quadratic
//
// Maps 1:1 to MVP node `alg-factor-quadratic`. Build the quadratic from integer
// roots so it factors over the integers; on harder bands scale by a non-unit
// leading coefficient so the answer is `a·(x − r)(x − s)`-shaped. The canonical
// answer is `Factor`ed by the engine (Expand-round-trip self-checked). Graded as
// a factorization (value by expansion-equality, plus an "is actually factored"
// form guard).
//
// Engine limits respected: integer coefficients only (int64-safe — bands keep
// r, s, and the leading coefficient small so a·r·s stays inside int64), no
// floats. Built FROM integer roots so Factor's substitute-back gate is satisfied
// and the result is provably correct. We confirm the engine actually factored
// (didn't return the input inert) before shipping, re-drawing otherwise.

/// Generates quadratic-factoring problems for the `alg-factor-quadratic` skill.
struct FactorQuadraticGenerator: ProblemGenerator {
    let skill: NodeID = "alg-factor-quadratic"
    let prerequisites: [NodeID] = ["alg-gcf-factor", "alg-poly-special-products"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        // Build from roots so the quadratic factors over the integers:
        //   a·(x − r)(x − s) = a·x² − a·(r+s)·x + a·r·s
        let r = draw(band, using: &rng)
        var s = draw(band, using: &rng)
        if r == s && difficulty != .challenge {
            s = (s == band.range.upperBound) ? s - 1 : s + 1
        }

        // Leading coefficient: monic on easy bands, small non-unit on harder ones
        // (keeps a·r·s int64-safe).
        let a: Int
        switch difficulty {
        case .introductory, .standard: a = 1
        case .advanced:                a = max(2, min(abs(draw(band, using: &rng)), 3))
        case .challenge:               a = max(2, min(abs(draw(band, using: &rng)), 4))
        }

        let bCoef = -a * (r + s)
        let cConst = a * r * s

        let original = polynomial(a: a, b: bCoef, c: cConst)
        let answerExpr = "Factor[\(original)]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        // Degenerate guard: if the CAS couldn't factor (returned the input form),
        // re-draw rather than ship an unfactorable item to a "factor" skill.
        let inputReduced = await cas.reduce(original)
        if !CASExpr.isError(inputReduced),
           normalized(canonical) == normalized(inputReduced) {
            return nil
        }

        let prompt = "Factor  " + MathPretty.render(canonicalTree(a: a, b: bCoef, c: cConst))

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: prompt,
            directive: "Factor completely",
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .factorization(of: original),
            steps: [],
            parameters: ["a": "\(a)", "r": "\(r)", "s": "\(s)",
                         "b": "\(bCoef)", "c": "\(cConst)"])
    }

    /// Infix quadratic for the CAS reader: a·x² + b·x + c (a, b, c may be signed).
    private func polynomial(a: Int, b: Int, c: Int) -> String {
        var terms = ["(\(a))*x^2"]
        if b != 0 { terms.append("(\(b))*x") }
        if c != 0 { terms.append("(\(c))") }
        return terms.joined(separator: " + ")
    }

    /// Bracket tree for MathPretty (so the prompt renders as 2·x² − 5·x + 3).
    private func canonicalTree(a: Int, b: Int, c: Int) -> String {
        var parts = a == 1 ? ["[Power x 2]"] : ["[Times \(a) [Power x 2]]"]
        if b != 0 { parts.append("[Times \(b) x]") }
        if c != 0 { parts.append("\(c)") }
        return "[Plus " + parts.joined(separator: " ") + "]"
    }

    private func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: grading

    /// Grade a typed answer for this skill, delegating to `CASClient` (never
    /// string-matches). See `ProblemInstance.grade(_:using:)`.
    func grade(_ studentInput: String, for instance: ProblemInstance,
               using client: CASClient) async -> GradeResult {
        await instance.grade(studentInput, using: client)
    }
}

#if DEBUG
extension FactorQuadraticGenerator {
    /// Self-test: every band must yield a live (non-inert, non-overflow) answer.
    /// Delegates to the shared scaffold.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(FactorQuadraticGenerator(), cas: cas)
    }
}
#endif
