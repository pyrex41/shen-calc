import Foundation

// MARK: - Worked solution

/// A verified, step-by-step rewrite of an expression to its normal form — the
/// thing the tutor reveals on a miss. Each `Step` is one rewrite (from-expr, rule
/// label, to-expr); the whole solution is the ordered chain from the input to the
/// reduced result.
///
/// Reuses the existing `Step` model from `ProblemGenerator.swift` (do not
/// redefine it): `Step(beforePretty:afterPretty:why:)`, all three rendered for
/// display via `MathPretty.render`.
///
/// ## Faithfulness invariant
/// The trace must be *faithful*: replaying the steps reproduces the engine's own
/// reduction. Concretely, once `shen_cas_trace` ships (Part D), the parser will
/// assert:
///
/// 1. `steps.first?.beforePretty == MathPretty.render(input)` — the chain starts
///    at the given input, and
/// 2. `steps.last?.afterPretty  == MathPretty.render(reduce(input))` — the chain
///    ends at the engine's normal form, and
/// 3. each step is contiguous: `steps[i].afterPretty == steps[i+1].beforePretty`.
///
/// A parsed solution that violates any of these is rejected (returns `nil`)
/// rather than shown — a wrong explanation is worse than none.
struct WorkedSolution {
    /// The original expression that was traced (raw CAS string).
    let input: String
    /// The engine's normal form (raw CAS string) — equals `reduce(input)`.
    let result: String
    /// Ordered rewrite chain. Empty ⇒ no trace available (single-line fallback).
    let steps: [Step]

    /// True iff there is a non-empty, displayable rewrite chain.
    var hasSteps: Bool { !steps.isEmpty }
}

extension WorkedSolution {

    // MARK: Parser stub (Part D)

    /// Parse the raw `shen_cas_trace` reply into a faithful `WorkedSolution`.
    ///
    /// Wire format (from the `shen_cas_trace` C ABI): one rewrite step per line,
    /// three fields separated by US (0x1f) — `before<US>after<US>why`. `before`/
    /// `after` are bracket S-expr strings (the same dialect `reduce` returns), so
    /// they render through `MathPretty.render` exactly like a reduced answer.
    ///
    /// Faithfulness (a wrong explanation is worse than none — fail closed to `nil`):
    ///  1. the chain ends at the engine's normal form: last `after` == reduce(input),
    ///  2. the chain is contiguous: each step's `after` == the next step's `before`.
    /// (The Rust side guarantees both by construction — it appends a final
    /// canonical step landing on `reduce(input)` — but we re-check here so a future
    /// format drift can never surface an unfaithful derivation.)
    static func parse(trace raw: String,
                      input: String,
                      cas: CASEvaluator) async -> WorkedSolution? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        var steps: [Step] = []
        var lastAfterRaw = ""
        for line in lines {
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 3 else { return nil }   // malformed → fail closed
            lastAfterRaw = f[1]
            steps.append(Step(beforePretty: MathPretty.render(f[0]),
                              afterPretty: MathPretty.render(f[1]),
                              why: f[2]))
        }
        guard !steps.isEmpty else { return nil }

        // (2) contiguity.
        for i in 0..<(steps.count - 1) where steps[i].afterPretty != steps[i + 1].beforePretty {
            return nil
        }
        // (1) the chain lands on the engine's proven normal form.
        let answer = await cas.reduce(input)
        guard !CASExpr.isError(answer) else { return nil }
        guard MathPretty.render(lastAfterRaw) == MathPretty.render(answer) else { return nil }

        return WorkedSolution(input: input, result: answer, steps: steps)
    }
}
