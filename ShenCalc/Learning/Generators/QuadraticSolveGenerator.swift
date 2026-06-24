import Foundation

// MARK: - alg-quadratic-solve — solve a quadratic equation
//
// Maps 1:1 to MVP node `alg-quadratic-solve`. Build the quadratic from rational
// roots so `Solve`'s substitute-back gate is satisfied (every returned root
// reduces to 0 on back-substitution → provably correct), then ask the learner to
// solve `a·x² + b·x + c = 0`. The canonical answer is the engine's `Solve` reply.
// Graded as a solution set (reduced-root multiset equality), accepting any
// equivalent student form / ordering.
//
// Engine limits respected: exact rationals only — no floats; roots are integers
// (monic) or `p/q` rationals (non-monic via the leading coefficient), so the
// discriminant is a perfect rational square and Solve can PROVE the roots. All
// coefficients are int64-safe (small bands keep a·r·s inside int64). No
// degenerate params: leading coefficient ≠ 0, and on non-challenge bands the two
// roots are forced distinct (avoids a silent double root if undesired).

/// Generates quadratic-equation solving problems for the `alg-quadratic-solve`
/// skill.
struct QuadraticSolveGenerator: ProblemGenerator {
    let skill: NodeID = "alg-quadratic-solve"
    let prerequisites: [NodeID] = ["alg-factor-quadratic", "alg-linear-eq-1step"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        // Two integer roots r, s. The quadratic a·(x − r)(x − s) has integer
        // coefficients and roots r, s — Solve substitutes back to exact 0.
        let r = draw(band, using: &rng)
        var s = draw(band, using: &rng)
        if r == s && difficulty != .challenge {
            s = (s == band.range.upperBound) ? s - 1 : s + 1
        }

        // Leading coefficient: monic on easy bands; on harder bands a non-unit
        // `a` makes the ROOTS rational (r/a-style) while keeping coefficients
        // integer — Solve still proves them because they are exact rationals.
        let a: Int
        switch difficulty {
        case .introductory, .standard: a = 1
        case .advanced:                a = max(2, min(abs(draw(band, using: &rng)), 3))
        case .challenge:               a = max(2, min(abs(draw(band, using: &rng)), 4))
        }

        // a·(x − r)(x − s) = a·x² − a·(r+s)·x + a·r·s.
        let bCoef = -a * (r + s)
        let cConst = a * r * s

        let lhs = polynomial(a: a, b: bCoef, c: cConst)
        let answerExpr = "Solve[\(lhs) == 0, x]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        // Solve returns inert (or no roots) if it cannot prove them — never ship
        // such an item to a "solve" skill. Require a non-empty proven root list.
        if CASExpr.rootsFromSolveReply(canonical).isEmpty { return nil }

        let prompt = "Solve  " + MathPretty.render(canonicalTree(a: a, b: bCoef, c: cConst)) + " = 0"

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
            parameters: ["a": "\(a)", "r": "\(r)", "s": "\(s)",
                         "b": "\(bCoef)", "c": "\(cConst)"])
    }

    /// Infix quadratic for the CAS reader: a·x² + b·x + c (signed coefficients).
    private func polynomial(a: Int, b: Int, c: Int) -> String {
        var terms = ["(\(a))*x^2"]
        if b != 0 { terms.append("(\(b))*x") }
        if c != 0 { terms.append("(\(c))") }
        return terms.joined(separator: " + ")
    }

    /// Bracket tree for MathPretty (so the prompt renders as 2·x² − 5·x + 3 = 0).
    private func canonicalTree(a: Int, b: Int, c: Int) -> String {
        var parts = a == 1 ? ["[Power x 2]"] : ["[Times \(a) [Power x 2]]"]
        if b != 0 { parts.append("[Times \(b) x]") }
        if c != 0 { parts.append("\(c)") }
        return "[Plus " + parts.joined(separator: " ") + "]"
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
extension QuadraticSolveGenerator {
    /// Self-test: every band must yield a live (non-inert, non-overflow) answer
    /// with a non-empty proven root list. Delegates to the shared scaffold.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(QuadraticSolveGenerator(), cas: cas)
    }
}
#endif
