import Foundation

// MARK: - Generator: alg-linear-inequality   (PARTIAL)
//
// A one-variable linear inequality  a·x + b  ▷  0   (▷ ∈ {<, ≤, >, ≥}).
//
// PARTIAL per docs/tutor/COVERAGE.md: the shipped parser has NO relational
// operators, so the inequality itself is never handed to the CAS. Instead the
// engine does the two pieces it CAN do soundly:
//   1. the boundary — `Solve[a·x + b == 0, x]` gives the critical value x₀
//      (provably correct: Solve substitutes the root back to 0), and
//   2. the sign — `Positive[a]` decides whether multiplying/dividing by a flips
//      the inequality direction.
// The solved direction (and whether the boundary is included) is computed here
// and recorded in `parameters` for the app layer to assemble the final solution
// set "x ▷ x₀" — the contract's "solve the boundary + sign reasoning in app code".
//
// The canonical answer stored on the instance is the BOUNDARY value, graded as a
// `.solutionSet` (the engine can grade the boundary by equivalence; the inequality
// direction is checked in app code against the recorded `solvedRelation`).
//
// casOps (per KnowledgeGraph.mvp): reduce, Solve, Positive, Plus, Times.
//
// Engine limits honored:
//   • exact rationals over Q only — the boundary −b/a is a CAS rational.
//   • int64 only — small banded coefficients.
//   • avoid degenerate params — a ≠ 0 (an inequality with no x has no boundary).

/// Solve a linear inequality `a·x + b ▷ 0`. The engine supplies the boundary and
/// the flip decision; the assembled solution direction lives in `parameters`.
struct LinearInequalityGenerator: ProblemGenerator {
    let skill: NodeID = "alg-linear-inequality"
    let prerequisites: [NodeID] = ["alg-linear-eq-multistep"]

    /// The four orderings, in the surface syntax shown to the learner.
    private enum Relation: String, CaseIterable {
        case lt = "<", le = "≤", gt = ">", ge = "≥"

        /// Whether the boundary value itself is part of the solution set.
        var includesBoundary: Bool { self == .le || self == .ge }

        /// The ordering after multiplying/dividing both sides by a NEGATIVE number
        /// (the direction flips; strictness is preserved).
        var flipped: Relation {
            switch self {
            case .lt: return .gt
            case .le: return .ge
            case .gt: return .lt
            case .ge: return .le
            }
        }
    }

    func generate<R: RandomNumberGenerator>(difficulty: Difficulty,
                                            using rng: inout R,
                                            cas: CASEvaluator) async -> ProblemInstance? {
        let band = difficulty.band

        var a = draw(band, using: &rng)
        if a == 0 { a = band.range.lowerBound }       // need an x to bound
        let b = draw(band, using: &rng)

        // Pick the relation by band: strict-only at the easy end, all four later.
        let rel: Relation
        switch difficulty {
        case .introductory: rel = Bool.random(using: &rng) ? .lt : .gt
        case .standard:     rel = Bool.random(using: &rng) ? .le : .ge
        case .advanced, .challenge:
            rel = Relation.allCases[Int.random(in: 0..<Relation.allCases.count, using: &rng)]
        }

        // 1. Boundary x₀ = −b/a, via Solve (sound: substitutes back to 0).
        let lhsInfix = "(\(a))*x + (\(b))"
        let answerExpr = "Solve[\(lhsInfix) == 0, x]"
        let canonical = await cas.reduce(answerExpr)
        if CASExpr.isError(canonical) { return nil }
        if canonical.contains("Solve") { return nil }   // inert — re-draw

        // 2. Sign of a → does the direction flip when we isolate x? Ask the engine
        //    (`Positive[a]` is True/False) rather than trusting the Swift sign.
        let positive = await cas.reduce("Positive[\(a)]")
        if CASExpr.isError(positive) { return nil }
        let flips = (positive.trimmingCharacters(in: .whitespacesAndNewlines) == "False")
        let solvedRelation = flips ? rel.flipped : rel

        // Prompt: a·x + b ▷ 0   (relation rendered textually — the CAS never sees it).
        let prompt = "Solve  " + MathPretty.render(lhsTree(a: a, b: b)) + " \(rel.rawValue) 0"

        return ProblemInstance(
            id: UUID(),
            skill: skill,
            difficulty: difficulty,
            prompt: prompt,
            directive: "Solve for x",
            answerExpr: answerExpr,
            canonicalAnswerCAS: canonical,           // the boundary value
            canonicalAnswerPretty: MathPretty.render(canonical),
            answerKind: .solutionSet(variable: "x"), // boundary graded by equivalence
            steps: [],
            parameters: [
                "a": "\(a)", "b": "\(b)",
                "relation": rel.rawValue,                  // as posed
                "solvedRelation": solvedRelation.rawValue, // x ▷ x₀ (post-isolation)
                "flips": flips ? "true" : "false",
                "includesBoundary": rel.includesBoundary ? "true" : "false",
            ])
    }

    /// Bracket tree for the prompt LHS: `a·x + b` (b folded only when nonzero).
    private func lhsTree(a: Int, b: Int) -> String {
        var parts = ["[Times \(a) x]"]
        if b != 0 { parts.append("\(b)") }
        return "[Plus " + parts.joined(separator: " ") + "]"
    }
}

#if DEBUG
extension LinearInequalityGenerator {
    /// Self-test: one item per band, asserting a live (non-inert) boundary value.
    static func selfTest(cas: CASEvaluator) async -> [ProblemInstance] {
        await GeneratorSelfTest.run(LinearInequalityGenerator(), cas: cas)
    }
}
#endif
