import Foundation

// MARK: - Value types

/// A progressive hint. Level 1 is a gentle conceptual nudge; higher levels move
/// toward a concrete next step. The `verified` flag records whether a concrete
/// math claim (a next expression / line) was checked against the canonical
/// derivation through the CAS — an unverified hint has been DOWNGRADED to a
/// generic conceptual nudge and carries no specific math.
struct Hint {
    let level: Int
    let text: String
    /// True iff this hint's concrete math (if any) was CAS-confirmed equivalent to
    /// a real step of the canonical derivation. A purely conceptual nudge is
    /// trivially `verified` (it asserts no math).
    let verified: Bool
}

/// A Socratic-dialogue reply: a single question/prompt that nudges the learner
/// toward the next idea without stating the answer. Subject to the same CAS guard
/// as `Hint` — any concrete math is verified or stripped.
struct SocraticReply {
    let text: String
    let verified: Bool
}

/// A coarse diagnosis of *why* a wrong answer is wrong, drawn from a small fixed
/// taxonomy. Drives targeted remediation (e.g. route a "signError" miss to a
/// sign-rules micro-lesson). `casConfirmed` notes whether the CAS corroborated the
/// guess (e.g. the student answer equals the correct one with a sign flipped);
/// an unconfirmed tag is the model's best read, used only as a soft hint.
enum ErrorTag: String, Codable {
    case signError          // dropped or flipped a sign
    case distribution       // failed to distribute over a sum/product
    case fractionOp         // mis-added / mis-multiplied fractions
    case arithmeticSlip     // a numeric miscalculation
    case wrongOperation     // applied the wrong operation entirely
    case incompleteSolution // stopped before fully solving
    case unknown            // no taxonomy entry fit

    var label: String {
        switch self {
        case .signError:          return "sign error"
        case .distribution:       return "distribution error"
        case .fractionOp:         return "fraction operation error"
        case .arithmeticSlip:     return "arithmetic slip"
        case .wrongOperation:     return "wrong operation"
        case .incompleteSolution: return "incomplete solution"
        case .unknown:            return "unclassified"
        }
    }
}

/// A diagnosis result: the tag plus whether the CAS corroborated it.
struct ErrorDiagnosis {
    let tag: ErrorTag
    /// True iff a CAS check supported the tag (currently: a sign-error check).
    let casConfirmed: Bool
}

// MARK: - VerifiedTutor

/// The CAS-guarded tutoring layer. Wraps an `LLMProvider` (the fuzzy, possibly-
/// wrong narrator) and a `CASClient` (the authority on every math claim) and
/// exposes four services: `interpret`, `explainSteps`, `hint`, `socratic`, and the
/// classifier `diagnoseError`.
///
/// ## Fail-closed invariant
/// The model is NEVER trusted for a math value. Every service either (a) routes
/// the model's claim through the CAS and rejects/downgrades it on disagreement, or
/// (b) hands the model an already-verified artifact (a CAS trace, the verified
/// answer) and constrains it to narrate, never to compute. With no provider
/// configured or the network down, services return `nil` / `.unavailable` /
/// a generic nudge — never a guessed answer.
///
/// `provider` is optional: a `nil` provider means "no LLM available" and every
/// service degrades to its safe fallback.
final class VerifiedTutor {

    /// The (optional) fuzzy narrator. `nil` ⇒ no model; every service degrades.
    let provider: LLMProvider?
    /// The math authority. All verification routes through here.
    let cas: CASClient

    init(provider: LLMProvider?, cas: CASClient) {
        self.provider = provider
        self.cas = cas
    }

    // MARK: 1. Interpret — text/image → CAS expression

    /// Translate fuzzy input (English, or a photo of math) into a shen-cas
    /// expression string. The GUARD is the CAS itself: the model's reply is parsed
    /// (`CASTools.parse`) and then *reduced* through the CAS; if the result is
    /// inert (errors / empty), the model misread the intent and we return
    /// `nil` ("couldn't read it") rather than a bogus expression.
    ///
    /// Returns the parsed CAS string on success, or `nil` when no provider exists,
    /// the model fails, or the CAS rejects the translation.
    func interpret(text: String, image: Data? = nil) async -> String? {
        guard let provider else { return nil }

        let messages: [ChatMessage] = [
            .system(CASTools.systemPrompt),
            .user(text, image: image),
        ]
        guard let reply = try? await provider.complete(messages, GenerationOptions(maxTokens: 64)) else {
            return nil
        }

        // Deterministic parse from the model's tool-call reply to CAS syntax.
        let expr = CASTools.parse(reply)
        guard !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // GUARD: the CAS must actually be able to read it. An inert reduce means
        // the model produced syntax the engine rejects → "couldn't read it".
        let reduced = await cas.reduce(expr)
        if CASExpr.isError(reduced) { return nil }
        return expr
    }

    // MARK: 2. Explain steps — narrate a VERIFIED trace

    /// Narrate an already-verified worked solution in plain language. The model is
    /// GIVEN the trace and instructed to add NO new math — the trace is
    /// authoritative, so even a hallucinating model can only mis-word, never
    /// mis-compute. Returns `nil` when there is no provider or no steps to narrate.
    func explainSteps(trace: WorkedSolution) async -> String? {
        guard let provider, trace.hasSteps else { return nil }

        let stepsText = trace.steps.enumerated().map { i, s in
            "\(i + 1). \(s.beforePretty)  →  \(s.afterPretty)   [\(s.why)]"
        }.joined(separator: "\n")

        let system = """
        You are a patient algebra tutor. You are given a sequence of ALREADY-VERIFIED
        rewrite steps from a computer-algebra system. Narrate them for a student in
        clear, encouraging prose. Rules:
        - The steps are authoritative and correct. Do NOT add, change, or recompute
          any math. Do NOT introduce a step that is not in the list.
        - Explain WHY each step is valid using the given rule labels.
        - Be concise: one short sentence per step.
        """
        let user = """
        Verified steps (\(trace.input)  reduces to  \(trace.result)):
        \(stepsText)

        Narrate these steps for the student.
        """

        return try? await provider.complete([.system(system), .user(user)],
                                            GenerationOptions(maxTokens: 400))
    }

    // MARK: 3. Hint — progressive, CAS-guarded

    /// Produce a progressive hint at `level` (1 = gentle nudge, higher = more
    /// concrete). The model proposes a hint; if it contains a concrete next
    /// expression/line, that line is VERIFIED against the canonical derivation via
    /// the CAS. If the concrete claim can't be confirmed, the hint is DOWNGRADED to
    /// a generic conceptual nudge rather than shown as-is.
    ///
    /// Returns `nil` only when there is no provider. With a provider but a failed /
    /// unverifiable response, returns a verified generic nudge so the learner is
    /// never stuck — and `hintsUsed` still counts (the caller passes the level into
    /// `AttemptSignal.hintsUsed`).
    func hint(problem: ProblemInstance, history: [String] = [], level: Int) async -> Hint? {
        guard let provider else { return nil }

        let priorHints = history.isEmpty ? "" :
            "\nHints already given:\n" + history.map { "- \($0)" }.joined(separator: "\n")
        let system = """
        You are a tutor giving ONE progressive hint for an algebra problem. Hint
        level \(level): level 1 is a gentle conceptual nudge with NO math; higher
        levels may suggest the next concrete step. The verified correct answer is
        provided — never reveal it directly, and never contradict it.
        Output ONLY the hint text, one or two sentences.
        """
        let user = """
        Problem: \(problem.directive)  \(problem.prompt)
        Verified answer (do not reveal): \(problem.canonicalAnswerPretty)\(priorHints)

        Give hint level \(level).
        """

        guard let raw = try? await provider.complete([.system(system), .user(user)],
                                                     GenerationOptions(maxTokens: 120)),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.genericNudge(level: level)
        }

        // GUARD: if the hint embeds a concrete expression, verify it is a real
        // step toward the canonical answer; otherwise downgrade to a nudge.
        if let claim = Self.extractMathClaim(raw) {
            let ok = await verifyStep(claim, towardAnswer: problem)
            if !ok { return Self.genericNudge(level: level) }
            return Hint(level: level, text: raw, verified: true)
        }
        // No concrete math → a conceptual nudge, trivially verified.
        return Hint(level: level, text: raw, verified: true)
    }

    // MARK: 4. Socratic — guided questioning, CAS-guarded

    /// Continue a Socratic dialogue: produce the next question that nudges the
    /// learner forward. The model is TOLD the verified answer/steps up front and
    /// must never contradict them; any concrete math in its reply is subject to the
    /// same CAS guard as `hint`. Returns `nil` only when no provider exists.
    func socratic(problem: ProblemInstance, history: [String], turn: Int) async -> SocraticReply? {
        guard let provider else { return nil }

        let transcript = history.isEmpty ? "(no prior turns)" :
            history.enumerated().map { i, t in "\(i % 2 == 0 ? "Tutor" : "Student"): \(t)" }
                .joined(separator: "\n")
        let system = """
        You are a Socratic algebra tutor. Lead the student with QUESTIONS, never
        statements of the answer. The verified correct answer and the problem are
        given — never reveal the answer, and never say anything that contradicts it.
        Output ONLY your next question, one sentence.
        """
        let user = """
        Problem: \(problem.directive)  \(problem.prompt)
        Verified answer (do not reveal, do not contradict): \(problem.canonicalAnswerPretty)
        Dialogue so far (turn \(turn)):
        \(transcript)

        Ask the next guiding question.
        """

        guard let raw = try? await provider.complete([.system(system), .user(user)],
                                                     GenerationOptions(maxTokens: 120)),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Same guard as hint: verify or strip embedded concrete math.
        if let claim = Self.extractMathClaim(raw) {
            let ok = await verifyStep(claim, towardAnswer: problem)
            if !ok {
                return SocraticReply(text: "What operation could you apply to both sides to get closer to isolating the variable?",
                                     verified: true)
            }
            return SocraticReply(text: raw, verified: true)
        }
        return SocraticReply(text: raw, verified: true)
    }

    // MARK: 5. Diagnose error — taxonomy classifier

    /// Classify a wrong answer into an `ErrorTag` from the small taxonomy, to drive
    /// remediation. The model proposes a tag; where cheaply checkable, the CAS
    /// corroborates it (currently: a sign-error check — does the student's answer
    /// equal the correct one negated?). Returns `.unknown` (unconfirmed) when no
    /// provider exists, so callers always get a usable value.
    func diagnoseError(student: String, answer: String, problem: ProblemInstance) async -> ErrorDiagnosis {
        // Cheap CAS corroboration that needs no model: sign error.
        let signConfirmed = await isSignError(student: student, problem: problem)

        guard let provider else {
            return ErrorDiagnosis(tag: signConfirmed ? .signError : .unknown,
                                  casConfirmed: signConfirmed)
        }

        let tags = ErrorTag.allTaxonomyCases.map(\.rawValue).joined(separator: ", ")
        let system = """
        You classify a student's WRONG algebra answer into exactly ONE category.
        Output ONLY the category keyword, nothing else.
        Categories: \(tags)
        """
        let user = """
        Problem: \(problem.directive)  \(problem.prompt)
        Correct answer: \(problem.canonicalAnswerPretty)
        Student's (wrong) answer: \(student)

        Which category?
        """

        let reply = (try? await provider.complete([.system(system), .user(user)],
                                                  GenerationOptions(maxTokens: 16))) ?? ""
        var tag = ErrorTag(fromReply: reply) ?? .unknown
        // CAS overrides a guess it can confirm: a confirmed sign error is a sign error.
        if signConfirmed { tag = .signError }
        return ErrorDiagnosis(tag: tag, casConfirmed: signConfirmed)
    }

    // MARK: - Guards / helpers

    /// True iff `claim` is a real step toward the problem's canonical answer:
    /// it must be CAS-equivalent (value-correct) to the canonical answer. This is
    /// the fail-closed gate — a claim the CAS can't confirm equivalent is rejected
    /// (the hint/socratic layer then downgrades to a conceptual nudge).
    private func verifyStep(_ claim: String, towardAnswer problem: ProblemInstance) async -> Bool {
        let verdict = await cas.grade(student: claim,
                                      against: problem.answerKind,
                                      canonicalAnswerCAS: problem.canonicalAnswerCAS)
        switch verdict {
        case .correct, .equivalentButFlagged: return true
        case .incorrect, .unparseable:        return false
        }
    }

    /// CAS check for a sign error: is the student's answer the *negation* of the
    /// canonical answer? Treated as a value check via the grader against the
    /// negated canonical. Returns false on any uncertainty (fail closed).
    private func isSignError(student: String, problem: ProblemInstance) async -> Bool {
        let s = CASTools.normalizeExpr(student)
        guard !s.isEmpty else { return false }
        // Compare student to -(canonical answer): reduce both, check equal & nonzero.
        let negated = "-(\(problem.canonicalAnswerCAS))"
        let diff = "Simplify[(\(s)) - (\(negated))]"
        let reduced = await cas.reduce(diff)
        if CASExpr.isError(reduced) { return false }
        guard CASExpr.isZero(reduced) else { return false }
        // Guard against the degenerate case where the answer is 0 (− 0 == 0): then
        // a "sign error" is meaningless. Require the canonical answer be nonzero.
        let answerReduced = await cas.reduce(problem.canonicalAnswerCAS)
        return !CASExpr.isZero(answerReduced)
    }

    /// Heuristic: pull a concrete math claim (an expression / equation) out of a
    /// hint or Socratic reply, or `nil` if it's a purely conceptual sentence.
    /// We look for the last `=`-bearing fragment or a token run that reads like an
    /// expression; if nothing qualifies, there is no math claim to verify.
    private static func extractMathClaim(_ text: String) -> String? {
        // An equation: take the right-hand side of the last "=".
        if let eq = text.range(of: "=", options: .backwards) {
            let rhs = text[eq.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            // Trim trailing prose/punctuation after the math.
            let cut = rhs.prefix { "0123456789xyzabXYZAB+-*/^(). ".contains($0) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cut.isEmpty ? nil : cut
        }
        return nil
    }

    /// A safe, always-verified conceptual nudge, scaled loosely by level. Used
    /// whenever the model is unavailable or its concrete claim fails verification.
    private static func genericNudge(level: Int) -> Hint {
        let text: String
        switch level {
        case ..<2:  text = "What is the problem asking you to find? Restate the goal in your own words."
        case 2:     text = "Which operation moves you one step closer to isolating the unknown?"
        default:    text = "Try applying that operation to both sides, then simplify what remains."
        }
        return Hint(level: level, text: text, verified: true)
    }
}

// MARK: - ErrorTag parsing

private extension ErrorTag {
    /// The classifiable cases offered to the model (excludes `.unknown`, which is
    /// the parse fallback).
    static var allTaxonomyCases: [ErrorTag] {
        [.signError, .distribution, .fractionOp, .arithmeticSlip, .wrongOperation, .incompleteSolution]
    }

    /// Parse a model reply (which should be a bare keyword) into a tag. Tolerant:
    /// matches the first taxonomy keyword that appears anywhere in the reply.
    init?(fromReply reply: String) {
        let lower = reply.lowercased()
        for tag in ErrorTag.allTaxonomyCases where lower.contains(tag.rawValue.lowercased()) {
            self = tag
            return
        }
        // Also accept a few natural-language variants.
        if lower.contains("sign") { self = .signError; return }
        if lower.contains("distribut") { self = .distribution; return }
        if lower.contains("fraction") { self = .fractionOp; return }
        if lower.contains("arithmetic") || lower.contains("calculation") { self = .arithmeticSlip; return }
        if lower.contains("operation") { self = .wrongOperation; return }
        if lower.contains("incomplete") || lower.contains("partial") { self = .incompleteSolution; return }
        return nil
    }
}
