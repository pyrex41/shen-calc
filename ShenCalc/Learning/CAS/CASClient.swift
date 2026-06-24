import Foundation

// MARK: - CAS facade

/// The single CAS facade the whole tutor depends on. Wraps a `CASEvaluator`
/// (the engine, or a test stub) and exposes the two operations every caller
/// needs: CAS-equivalence *grading* of a typed answer, and (later) a worked-step
/// *trace*. Generators continue to talk to the raw `CASEvaluator`; everything
/// that grades or explains goes through here.
///
/// `CASClient` itself conforms to `CASEvaluator` (it forwards `reduce`), so it
/// can be passed anywhere a raw evaluator is expected and so it composes with
/// the existing `CASGrader` / generator code without an adapter.
///
/// Concurrency: the embedded engine is **serial** — exactly one `reduce` may be
/// in flight at a time. Every method here issues its CAS calls with sequential
/// `await`; it NEVER fans out concurrent reduces (no `async let`, no task group).
final class CASClient: CASEvaluator {

    /// The underlying evaluator. Injectable so tests can stub the engine; in the
    /// app this is the live `ShenCAS` (which conforms to `CASEvaluator`).
    private let engine: CASEvaluator

    /// Capability flag for the worked-step trace. OFF by default: `shen_cas_trace`
    /// is not wired yet (Part D). `trace(_:)` returns `nil` while this is false,
    /// and the parser in `WorkedSolution.swift` is a no-op stub. Flipping this to
    /// `true` (once the FFI lands) enables tracing with NO caller changes — every
    /// caller already handles a `nil` result as "no steps available".
    let traceEnabled: Bool

    init(engine: CASEvaluator, traceEnabled: Bool = false) {
        self.engine = engine
        self.traceEnabled = traceEnabled
    }

    // MARK: CASEvaluator conformance

    /// Forward a raw reduce to the engine. Lets `CASClient` stand in for the
    /// engine anywhere a `CASEvaluator` is needed (generators, `CASGrader`, …).
    func reduce(_ input: String) async -> String {
        await engine.reduce(input)
    }

    // MARK: Verdict

    /// Result of `grade(student:against:)`. Distinct from `GradeResult.Verdict`
    /// (which carries UI feedback): this is the pure CAS judgement.
    ///
    /// - `correct`: equivalent under the primary, narrow oracle.
    /// - `equivalentButFlagged`: judged equal only after a wider normalization
    ///   pass (`Together`/`Expand`/`Cancel`). Value is right; the form may differ
    ///   from canonical, so callers can nudge without marking it wrong.
    /// - `incorrect`: parseable but not equivalent under any pass.
    /// - `unparseable`: the CAS rejected the input (a typo, not a wrong answer) —
    ///   callers should NOT burn a mastery attempt on this.
    enum Verdict: Equatable {
        case correct
        case equivalentButFlagged
        case incorrect
        case unparseable
    }

    // MARK: Grading

    /// Grade `student` against `answer` by CAS equivalence, dispatching on the
    /// answer's mathematical shape. Never string-matches answers — it asks the
    /// CAS whether a *difference reduces to zero* (expressions) or whether
    /// *reduced root multisets match* (solution sets).
    ///
    /// All CAS calls are issued sequentially (serial engine).
    func grade(student rawStudent: String, against answer: AnswerKind,
               canonicalAnswerCAS: String) async -> Verdict {

        let student = CASTools.normalizeExpr(rawStudent)
        guard !student.isEmpty else { return .unparseable }

        switch answer {
        case .expression, .list:
            return await gradeExpression(student, canonicalAnswerCAS: canonicalAnswerCAS)
        case .solutionSet(let v):
            return await gradeSolutionSet(student, variable: v,
                                          canonicalAnswerCAS: canonicalAnswerCAS)
        case .factorization(let original):
            return await gradeExpression(student, canonicalAnswerCAS: original)
        }
    }

    /// `.expression`: correct iff `Simplify[(student) - (answer)]` reduces to `0`.
    ///
    /// `Simplify` is deliberately narrow (it collects like terms but does not
    /// expand products), so before declaring `.incorrect` we try wider
    /// normalization passes — `Together` (common denominator), `Expand`
    /// (flatten products), and `Cancel` (rational reduction). A pass that
    /// flattens to zero means the value is right even though `Simplify` alone
    /// couldn't see it → `.equivalentButFlagged`.
    private func gradeExpression(_ student: String,
                                 canonicalAnswerCAS answer: String) async -> Verdict {
        let diff = "(\(student)) - (\(answer))"

        // Primary, narrow oracle.
        let simplified = await reduce("Simplify[\(diff)]")
        if CASExpr.isError(simplified) { return .unparseable }
        if CASExpr.isZero(simplified) { return .correct }

        // Wider normalization passes (serial — one await each, never concurrent).
        // Order: Together (denominators) → Expand (products) → Cancel (rationals).
        for wrap in ["Together", "Expand", "Cancel"] {
            let reduced = await reduce("\(wrap)[\(diff)]")
            if CASExpr.isError(reduced) { continue }
            if CASExpr.isZero(reduced) { return .equivalentButFlagged }
        }

        return .incorrect
    }

    /// `.solutionSet`: reduce each student root and each canonical root, then
    /// compare as order-independent normalized multisets.
    private func gradeSolutionSet(_ student: String, variable v: String,
                                  canonicalAnswerCAS answer: String) async -> Verdict {
        let studentRoots = CASExpr.rootsFromStudent(student, variable: v)
        let correctRoots = CASExpr.rootsFromSolveReply(answer)
        guard !studentRoots.isEmpty else { return .unparseable }

        let s = await reduceEach(studentRoots)
        if s.contains(where: { CASExpr.isError($0) }) { return .unparseable }
        let c = await reduceEach(correctRoots)

        return Multiset(s) == Multiset(c) ? .correct : .incorrect
    }

    /// Reduce a list of expressions sequentially (serial engine — never
    /// concurrently) and normalize whitespace on each reply.
    private func reduceEach(_ exprs: [String]) async -> [String] {
        var out: [String] = []
        for e in exprs {
            let r = await reduce(e)
            out.append(r.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    // MARK: Trace (Part D)

    /// Produce a verified worked solution (rewrite steps) for `input`.
    ///
    /// Returns `nil` when tracing is unavailable — which is ALWAYS the case until
    /// Part D wires `shen_cas_trace`, gated by `traceEnabled`. Callers must treat
    /// `nil` as "no steps available" and fall back to the single-line solution.
    /// When the flag flips on, this method will reduce-with-trace and hand the raw
    /// trace to `WorkedSolution.parse(trace:input:cas:)` — no caller change needed.
    func trace(_ input: String) async -> WorkedSolution? {
        guard traceEnabled else { return nil }
        // Part D: invoke shen_cas_trace via the engine, then
        //   return await WorkedSolution.parse(trace: raw, input: input, cas: self)
        // Until the FFI lands there is no trace channel, so report unavailable.
        return nil
    }
}
