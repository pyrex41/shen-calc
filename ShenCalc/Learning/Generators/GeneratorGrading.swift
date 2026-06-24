import Foundation

// MARK: - Shared generator-side grading

/// Bridges the `CASClient` CAS judgement (`CASClient.Verdict`) to the tutor's
/// UI-facing `GradeResult`. Every generator in this directory grades the *same*
/// way — by delegating to `CASClient.grade(student:against:canonicalAnswerCAS:)`
/// rather than string-matching — so the mapping lives here once instead of being
/// re-implemented per file.
///
/// The `CASClient` is the single CAS facade (it conforms to `CASEvaluator`, so it
/// can also be the `cas` a generator computed its canonical answer with). All CAS
/// calls inside `grade` are issued sequentially by `CASClient` (serial engine).
extension ProblemInstance {

    /// Grade `studentInput` against this instance by CAS equivalence, delegating
    /// to `client`. Never string-matches: the verdict comes from a difference
    /// reducing to zero (expressions / factorizations) or reduced-root multiset
    /// equality (solution sets).
    func grade(_ studentInput: String, using client: CASClient) async -> GradeResult {
        let trimmed = studentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GradeResult(verdict: .malformed, residue: nil,
                               revealedSteps: steps, message: "Enter an answer.")
        }

        // Grade against a RE-PARSEABLE expression. `canonicalAnswerCAS` holds
        // reduce's OUTPUT form (e.g. "[Plus [Power x 2] ...]"), which is NOT valid
        // CAS *input* syntax — feeding it back into the engine errors. So for
        // expression/list/factorization we grade against `answerExpr` (the
        // input-syntax expression whose reduction IS the answer). Solution sets are
        // the exception: their grader parses the reduced "[List …]" output, so they
        // still need `canonicalAnswerCAS`.
        let against: String
        if case .solutionSet = answerKind { against = canonicalAnswerCAS }
        else { against = answerExpr }

        let verdict = await client.grade(student: studentInput,
                                         against: answerKind,
                                         canonicalAnswerCAS: against)

        switch verdict {
        case .correct:
            return GradeResult(verdict: .correct, residue: "0",
                               revealedSteps: [], message: "Correct.")
        case .equivalentButFlagged:
            // Value is right; for a factorization the form requirement wasn't met,
            // otherwise it's an accepted-but-noncanonical form.
            if case .factorization = answerKind {
                return GradeResult(
                    verdict: .rightValueWrongForm, residue: nil, revealedSteps: steps,
                    message: "Right value, but it isn't factored — write it as a product of factors.")
            }
            return GradeResult(verdict: .correct, residue: "0",
                               revealedSteps: [], message: "Correct.")
        case .incorrect:
            return GradeResult(verdict: .incorrect, residue: nil, revealedSteps: steps,
                               message: "Not quite — compare with the worked steps below.")
        case .unparseable:
            return GradeResult(verdict: .malformed, residue: nil, revealedSteps: steps,
                               message: "I couldn't read that — check your syntax.")
        }
    }
}

// MARK: - Self-test support

#if DEBUG
/// Shared scaffolding for the per-generator `#if DEBUG` self-tests. Each generator
/// exposes a `selfTest(cas:)` that drives `generate` across every `Difficulty`
/// band and asserts the canonical answer reduces NON-INERT (i.e. the chosen
/// params didn't overflow int64 or collapse to a degenerate / inert form that
/// would silently break grading).
enum GeneratorSelfTest {

    /// A reduced CAS reply is "live" (non-inert, usable as an answer key) iff it
    /// is neither an `error:` nor empty. Generators must never ship an item whose
    /// canonical answer fails this.
    static func isLive(_ reduced: String) -> Bool {
        let t = reduced.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !CASExpr.isError(t)
    }

    /// Drive `gen` across all difficulties with a fixed seed and assert each
    /// generated instance has a live canonical answer. Returns the produced
    /// instances so a caller can inspect them. `retries` covers the (rare) nil
    /// from a degenerate draw the generator itself rejected.
    static func run(_ gen: ProblemGenerator, cas: CASEvaluator,
                    seed: UInt64 = 0xC0FFEE, retries: Int = 8) async -> [ProblemInstance] {
        var out: [ProblemInstance] = []
        var rng = SeededRNG(seed: seed)
        for difficulty in Difficulty.allCases {
            var instance: ProblemInstance?
            var attempt = 0
            while instance == nil && attempt < retries {
                instance = await gen.generate(difficulty: difficulty, using: &rng, cas: cas)
                attempt += 1
            }
            guard let inst = instance else {
                assertionFailure("\(gen.skill): no instance for \(difficulty) after \(retries) tries")
                continue
            }
            assert(isLive(inst.canonicalAnswerCAS),
                   "\(gen.skill): inert/empty canonical answer for \(difficulty): " +
                   "\(inst.canonicalAnswerCAS) (params: \(inst.parameters))")
            out.append(inst)
        }
        return out
    }
}
#endif
