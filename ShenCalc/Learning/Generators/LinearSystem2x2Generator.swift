import Foundation

// MARK: - Generator: alg-linear-systems-2x2
//
// A 2×2 linear system
//     a·x + b·y = e
//     c·x + d·y = f
// solved for the ordered pair (x, y). The shipped CAS slice's `Solve` is
// *univariate only* (a system call returns inert — verified against cas-all.kl),
// so the answer is computed by Cramer elimination expressed as two single-
// variable rational quotients the engine evaluates exactly:
//     x = (e·d − f·b) / det,   y = (a·f − c·e) / det,   det = a·d − b·c.
// The canonical answer is the reduced ordered pair `List[x, y]` (the engine
// normalizes the fractions to lowest terms), graded as a `.list`.
//
// casOps (per KnowledgeGraph.mvp): reduce, Solve, Plus, Times.
//
// Engine limits honored (docs/tutor/COVERAGE.md):
//   • exact rationals over Q only — x, y are CAS rationals (Cramer quotients);
//     never floats.
//   • int64 only — small banded coefficients keep det and the numerators
//     int64-safe (products of two banded ints, summed).
//   • avoid degenerate params — det = a·d − b·c is forced nonzero (a singular
//     system has no unique solution and would make the quotients inert /
//     divide-by-zero).

/// Solve a 2×2 linear system for the ordered pair (x, y). Answer graded as a
/// `.list` (the reduced `List[x, y]`).
struct LinearSystem2x2Generator: ProblemGenerator {
    let skill: NodeID = "alg-linear-systems-2x2"
    let prerequisites: [NodeID] = ["alg-linear-eq-multistep"]

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        // Coefficient matrix [[a b][c d]] — drawn small, with a nonzero determinant.
        let a = nonzero(draw(band, using: &rng), band)
        let b = draw(band, using: &rng)
        let c = draw(band, using: &rng)
        let d = nonzero(draw(band, using: &rng), band)
        let det = a &* d &- b &* c
        if det == 0 { return nil }   // singular — re-draw

        // Pick the integer solution (px, py) first, then set the right-hand sides
        // so the system is satisfied exactly. Keeps the numbers small & int64-safe.
        let solBand = Band(range: 1...max(2, band.range.upperBound),
                           allowNegative: band.allowNegative, allowZero: difficulty >= .advanced)
        let px = draw(solBand, using: &rng)
        let py = draw(solBand, using: &rng)
        let e = a &* px &+ b &* py
        let f = c &* px &+ d &* py

        // Canonical answer via Cramer's rule — evaluated by the engine, not trusted
        // from (px, py): x = (e·d − f·b)/det, y = (a·f − c·e)/det.
        let xNum = e &* d &- f &* b
        let yNum = a &* f &- c &* e
        let answerExpr = "List[(\(xNum)) / (\(det)), (\(yNum)) / (\(det))]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }

        let prompt = "Solve the system  " +
            MathPretty.render(eqTree(a, b)) + " = \(e)" + ",   " +
            MathPretty.render(eqTree(c, d)) + " = \(f)"

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: prompt,
            directive: "Solve for x and y",
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .list,   // ordered pair (x, y); graded by difference-to-zero
            steps: [],
            parameters: ["a": "\(a)", "b": "\(b)", "c": "\(c)", "d": "\(d)",
                         "e": "\(e)", "f": "\(f)", "det": "\(det)",
                         "px": "\(px)", "py": "\(py)"])
    }

    /// `coeffX·x + coeffY·y` as a bracket tree for the prompt (terms folded only
    /// when their coefficient is nonzero; bare ±1 still shows the variable).
    private func eqTree(_ coeffX: Int, _ coeffY: Int) -> String {
        var parts: [String] = []
        if coeffX != 0 { parts.append("[Times \(coeffX) x]") }
        if coeffY != 0 { parts.append("[Times \(coeffY) y]") }
        if parts.isEmpty { parts.append("0") }
        return "[Plus " + parts.joined(separator: " ") + "]"
    }

    /// Replace a zero draw with the band's lower bound (a coefficient of 0 thins
    /// the matrix toward singularity / drops a variable).
    private func nonzero(_ v: Int, _ band: Band) -> Int {
        v == 0 ? band.range.lowerBound : v
    }
}

#if DEBUG
extension LinearSystem2x2Generator {
    /// Self-test: one item per band, asserting a live (non-inert) reduced pair.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(LinearSystem2x2Generator(), cas: cas)
    }
}
#endif
