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
    /// STUB: tracing is gated behind `CASClient.traceEnabled`, which is OFF until
    /// Part D wires the `shen_cas_trace` FFI. Until then there is no trace format
    /// to parse, so this is a no-op that returns `nil` ("no steps available").
    ///
    /// When Part D lands, this will:
    ///  1. Parse `trace` — expected shape is a list of `[Before After Why]`
    ///     records in the same bracket S-expr dialect `CASExpr.parse` already
    ///     reads.
    ///  2. Map each record to `Step(beforePretty: MathPretty.render(before),
    ///     afterPretty: MathPretty.render(after), why: <label>)`.
    ///  3. Assert the faithfulness invariant documented on `WorkedSolution`
    ///     (start == render(input), end == render(reduce(input)), contiguous),
    ///     reducing `input` via `cas` for the end-state check.
    ///  4. Return `nil` if the trace is empty or fails the invariant.
    ///
    /// The signature is final so flipping `traceEnabled` later needs no caller or
    /// signature change.
    static func parse(trace raw: String,
                      input: String,
                      cas: CASEvaluator) async -> WorkedSolution? {
        // No trace channel yet (Part D). Treat any input as "unavailable".
        _ = (raw, input, cas)
        return nil
    }
}
