import Foundation

// MARK: - alg-poly-arith — polynomial add / subtract / multiply
//
// Maps 1:1 to MVP node `alg-poly-arith`. Build two integer-coefficient
// polynomials in x and ask the learner to add, subtract, or multiply them; the
// canonical answer is the `Expand`ed polynomial normal form. Graded scalar
// (`Expand[student − correct] == 0`), accepting any equivalent student form.
//
// Engine limits respected: integer coefficients only (exact, int64-safe — bands
// keep magnitudes and degree small so products stay inside int64), no floats, no
// divide-by-zero (multiply/add/subtract only). Leading coefficients are forced
// non-zero so the operand degree is well-defined.

/// Generates polynomial-arithmetic problems (sum / difference / product of two
/// polynomials) for the `alg-poly-arith` skill.
struct PolyArithGenerator: ProblemGenerator {
    let skill: NodeID = "alg-poly-arith"
    let prerequisites: [NodeID] = ["alg-linear-expr"]

    /// The arithmetic operation the learner performs on the two polynomials.
    private enum Op { case add, subtract, multiply }

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        // Operation by band: easy bands stay additive (degree-preserving); harder
        // bands multiply (degree grows, but kept int64-safe by the small bands).
        let op: Op
        switch difficulty {
        case .introductory: op = .add
        case .standard:     op = .subtract
        case .advanced, .challenge: op = .multiply
        }

        // Operand degree: keep products small so coefficients stay int64-safe.
        let degree = (op == .multiply) ? (difficulty == .challenge ? 2 : 1) : 2
        let p = randomPoly(degree: degree, band: band, using: &rng)
        let q = randomPoly(degree: degree, band: band, using: &rng)

        let (symbol, casOp): (String, String)
        switch op {
        case .add:      (symbol, casOp) = ("+", "(\(p)) + (\(q))")
        case .subtract: (symbol, casOp) = ("−", "(\(p)) - (\(q))")
        case .multiply: (symbol, casOp) = ("·", "(\(p)) * (\(q))")
        }

        let answerExpr = "Expand[\(casOp)]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        let prompt = render(p) + " " + symbol + " " + render(q)

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: prompt,
            directive: directive(for: op),
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .expression,
            steps: [],
            parameters: ["op": "\(op)", "degree": "\(degree)", "p": p, "q": q])
    }

    // MARK: parameter sampling

    /// A polynomial in x of the given degree with banded integer coefficients and
    /// a forced non-zero leading coefficient. Returned as infix CAS the reader
    /// accepts, e.g. `(3)*x^2 + (-2)*x + (5)`.
    private func randomPoly<R: RandomNumberGenerator>(degree: Int, band: Band,
                                                      using rng: inout R) -> String {
        var terms: [String] = []
        for power in stride(from: degree, through: 0, by: -1) {
            var coef = draw(band, using: &rng)
            if power == degree && coef == 0 { coef = band.range.lowerBound }   // leading ≠ 0
            if coef == 0 { continue }
            switch power {
            case 0:  terms.append("(\(coef))")
            case 1:  terms.append("(\(coef))*x")
            default: terms.append("(\(coef))*x^\(power)")
            }
        }
        if terms.isEmpty { terms.append("(\(band.range.lowerBound))") }   // never empty
        return terms.joined(separator: " + ")
    }

    /// Pretty-render an infix polynomial by routing it through the CAS-tree path
    /// MathPretty already understands. We reduce nothing here — just wrap the
    /// operand so display matches the term order the learner sees in the prompt.
    private func render(_ poly: String) -> String {
        "(" + MathPretty.render(treeify(poly)) + ")"
    }

    /// Turn the infix operand into the bracket S-expr `MathPretty.render` reads,
    /// preserving the authored term order (so the prompt isn't silently
    /// re-sorted). Coefficients/powers came from `randomPoly`, so the shape is
    /// known: a `+`-joined list of `(c)`, `(c)*x`, `(c)*x^k`.
    private func treeify(_ poly: String) -> String {
        let parts = poly.components(separatedBy: " + ")
        let nodes: [String] = parts.map { term in
            let t = term.replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            if let r = t.range(of: "*x^") {
                let c = String(t[t.startIndex..<r.lowerBound])
                let k = String(t[r.upperBound...])
                return "[Times \(c) [Power x \(k)]]"
            }
            if t.hasSuffix("*x") {
                let c = String(t.dropLast(2))
                return "[Times \(c) x]"
            }
            return t   // bare constant
        }
        return "[Plus " + nodes.joined(separator: " ") + "]"
    }

    private func directive(for op: Op) -> String {
        switch op {
        case .add:      return "Add and simplify"
        case .subtract: return "Subtract and simplify"
        case .multiply: return "Multiply and simplify"
        }
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
extension PolyArithGenerator {
    /// Self-test: every band must yield a live (non-inert, non-overflow) answer.
    /// Delegates to the shared scaffold.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(PolyArithGenerator(), cas: cas)
    }
}
#endif
