import Foundation

// MARK: - alg-gcf-factor — factor out the greatest common factor
//
// Maps 1:1 to MVP node `alg-gcf-factor`. Build a polynomial as g · (inner) where
// g is an integer/monomial GCF and (inner) is a primitive polynomial, then ask
// the learner to factor it. The canonical answer is `Factor`ed by the engine
// (Expand-round-trip self-checked). Graded as a factorization (value by
// expansion-equality to the original, plus an "is actually factored" form guard).
//
// Engine limits respected: integer coefficients only (int64-safe — small bands
// keep g · inner inside int64), no floats. The GCF is forced ≥ 2 (else there is
// nothing to factor) and the inner polynomial's leading coefficient is non-zero.
// We also confirm the engine actually factors the product (didn't return it
// inert) before shipping, re-drawing otherwise.

/// Generates GCF-factoring problems for the `alg-gcf-factor` skill.
struct GCFFactorGenerator: ProblemGenerator {
    let skill: NodeID = "alg-gcf-factor"
    let prerequisites: [NodeID] = ["alg-poly-arith"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        // Numeric GCF (≥ 2 so there is something to pull out).
        var g = abs(draw(band, using: &rng))
        if g < 2 { g = 2 }

        // A monomial-x factor on harder bands (so the GCF is g·x, not just g).
        let varPower: Int
        switch difficulty {
        case .introductory, .standard: varPower = 0
        case .advanced, .challenge:    varPower = 1
        }

        // Primitive inner polynomial in x (degree 1 or 2), leading coeff non-zero.
        let innerDegree = (difficulty == .introductory) ? 1 : 2
        let inner = primitivePoly(degree: innerDegree, band: band, using: &rng)

        // Original = g · x^varPower · inner.
        let gcfFactor = varPower == 0 ? "(\(g))" : "(\(g))*x"
        let original = "\(gcfFactor) * (\(inner))"

        let answerExpr = "Factor[Expand[\(original)]]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        // The grader compares the student's factorization to the EXPANDED original,
        // so capture that as the canonical "original polynomial" string.
        let expandedOriginal = await cas.reduce("Expand[\(original)]")
        if CASExpr.isError(expandedOriginal) { return nil }

        // Degenerate guard: if the engine couldn't factor (Factor == the expanded
        // input), there is no GCF item here — re-draw.
        if normalized(canonical) == normalized(expandedOriginal) { return nil }

        let prompt = "Factor  " + MathPretty.render(expandedOriginal)

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: prompt,
            directive: "Factor out the greatest common factor",
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .factorization(of: expandedOriginal),
            steps: [],
            parameters: ["g": "\(g)", "varPower": "\(varPower)",
                         "innerDegree": "\(innerDegree)", "inner": inner])
    }

    // MARK: parameter sampling

    /// A primitive (no common integer factor pulled out) polynomial in x of the
    /// given degree with a non-zero leading coefficient and a non-zero constant
    /// term (so a numeric GCF on the product is purely the intended `g`). Returned
    /// as infix CAS, e.g. `(2)*x + (3)`.
    private func primitivePoly<R: RandomNumberGenerator>(degree: Int, band: Band,
                                                         using rng: inout R) -> String {
        // Keep the inner coefficients odd-ish/small so they don't share a factor
        // with each other; force a constant term of ±1 to guarantee primitivity.
        var terms: [String] = []
        for power in stride(from: degree, through: 1, by: -1) {
            var coef = draw(band, using: &rng)
            if coef == 0 { coef = (power == degree) ? band.range.lowerBound : 1 }
            switch power {
            case 1:  terms.append("(\(coef))*x")
            default: terms.append("(\(coef))*x^\(power)")
            }
        }
        // Constant term ±1 keeps the inner polynomial primitive (gcd with the rest
        // is 1), so the product's only common factor is the intended `g`.
        let sign = Bool.random(using: &rng) ? 1 : -1
        terms.append("(\(sign))")
        return terms.joined(separator: " + ")
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
extension GCFFactorGenerator {
    /// Self-test: every band must yield a live (non-inert, non-overflow) answer.
    /// Delegates to the shared scaffold.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(GCFFactorGenerator(), cas: cas)
    }
}
#endif
