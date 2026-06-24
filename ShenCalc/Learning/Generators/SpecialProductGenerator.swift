import Foundation

// MARK: - alg-poly-special-products — expand a special product
//
// Maps 1:1 to MVP node `alg-poly-special-products`. Expand a square, a difference
// of squares, a scaled-linear square, or a binomial cube — all confirmed-working
// in the shipped CAS slice. Answer is a single polynomial, graded scalar
// (`Expand[student − correct] == 0`).
//
// Engine limits respected: integer coefficients only (int64-safe — the cube band
// caps the leading coefficient so `(a·x + b)^3` stays inside int64), no floats,
// no divide-by-zero. `b` is forced non-zero so the product is genuinely a
// "special product" (not a bare monomial square).

/// Generates special-product expansion problems for the
/// `alg-poly-special-products` skill.
struct ExpandSpecialProductGenerator: ProblemGenerator {
    let skill: NodeID = "alg-poly-special-products"
    let prerequisites: [NodeID] = ["alg-poly-arith"]

    private enum Form { case square, differenceOfSquares, linearSquare, binomialCube }

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band
        let form: Form
        switch difficulty {
        case .introductory: form = .square
        case .standard:     form = .differenceOfSquares
        case .advanced:     form = .linearSquare
        case .challenge:    form = .binomialCube
        }

        var a = max(2, abs(draw(band, using: &rng)))     // leading coeff (≥ 2)
        var b = draw(band, using: &rng)
        if b == 0 { b = 1 }

        let answerExpr: String
        let display: String
        switch form {
        case .square:
            answerExpr = "Expand[(x + (\(b)))^2]"
            display = "(x \(signed(b)))²"
        case .differenceOfSquares:
            let bb = abs(b)
            answerExpr = "Expand[(x + (\(bb)))*(x - (\(bb)))]"
            display = "(x + \(bb))(x − \(bb))"
        case .linearSquare:
            answerExpr = "Expand[((\(a))*x + (\(b)))^2]"
            display = "(\(a)x \(signed(b)))²"
        case .binomialCube:
            a = max(2, min(a, 4))                          // keep the cube small
            answerExpr = "Expand[((\(a))*x + (\(b)))^3]"
            display = "(\(a)x \(signed(b)))³"
        }

        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: "Expand  " + display,
            directive: "Expand completely",
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .expression,
            steps: [],
            parameters: ["a": "\(a)", "b": "\(b)", "form": "\(form)"])
    }

    /// "+ 3" / "− 3" for display (Unicode minus).
    private func signed(_ n: Int) -> String { n >= 0 ? "+ \(n)" : "− \(-n)" }

    // MARK: grading

    /// Grade a typed answer for this skill, delegating to `CASClient` (never
    /// string-matches). See `ProblemInstance.grade(_:using:)`.
    func grade(_ studentInput: String, for instance: ProblemInstance,
               using client: CASClient) async -> GradeResult {
        await instance.grade(studentInput, using: client)
    }
}

#if DEBUG
extension ExpandSpecialProductGenerator {
    /// Self-test: every band must yield a live (non-inert, non-overflow) answer.
    /// Delegates to the shared scaffold.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(ExpandSpecialProductGenerator(), cas: cas)
    }
}
#endif
