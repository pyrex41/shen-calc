import Foundation

// MARK: - Mastery / spaced-repetition memory model
//
// Canonical model is FSRS-6 DSR (Difficulty, Stability, Retrievability).
//
//   D ∈ [1, 10]   intrinsic-ish difficulty of recalling THIS node for THIS learner
//   S > 0         stability, measured in days: the elapsed time at which R falls to 0.9
//   R ∈ (0, 1]    retrievability — probability of recall right now
//
// R is NEVER stored. It is computed on demand from `S` and the elapsed time since
// the last review, so mastery decays continuously and the sequencer always reads
// *current* recall. Every transition is a pure function of (state, grade, R), so
// the whole model is unit-testable and replayable.
//
// Two distinct predicates ride on this state (see the extension near the bottom):
//   • `learnedEnough(now:)`  — PROVISIONAL: "the learner has demonstrated this at
//     least once and isn't currently failing it." Decay-independent and sticky.
//     Gates UNLOCK of dependents and graduation off the new-material frontier, so
//     new material flows within a session instead of being calendar-gated.
//   • `isMastered(now:)`     — DURABLE: FSRS retrievability + stability thresholds.
//     Decay-aware. Used only to DE-PRIORITISE review (a durable node resurfaces
//     less often), never to block progress.
//
// Style follows ShenCAS.swift: value structs, `///` doc comments, no external deps.

// MARK: - Identifiers and grading input

/// Stable identity of a skill node in the DAG (matches `SkillNode.id`).
typealias NodeID = String

/// Outcome of one graded attempt, produced by CAS-equivalence grading
/// (correct ⇔ the difference reduces to zero) plus timing/hint signals. This is
/// the in-memory signal the FSRS update consumes; `AttemptRecord` is its
/// persisted, append-only twin.
struct AttemptSignal {
    let correct: Bool         // CAS-equivalent to the answer
    let elapsed: TimeInterval // wall-clock solve time, seconds
    let hintsUsed: Int        // hints revealed before final answer
    let tries: Int            // submissions before correct (1 = first try)
    let at: Date              // when the attempt was graded
}

/// FSRS 1..4 grade. The tutor never asks the learner to self-rate;
/// the grade is DERIVED from `AttemptSignal` (see `Grade.from`).
enum Grade: Int {
    case again = 1, hard = 2, good = 3, easy = 4
}

/// One graded answer, persisted append-only in `LearnerState.attempts`. The log is
/// the source of truth: per-node `NodeState` is a fold over these and can be
/// re-derived wholesale if the memory model changes. `Codable` for on-device JSON.
struct AttemptRecord: Codable, Equatable {
    let nodeID: NodeID
    let correct: Bool
    let elapsed: TimeInterval
    let hintsUsed: Int
    let tries: Int
    let timestamp: Date

    init(nodeID: NodeID, correct: Bool, elapsed: TimeInterval = 0,
         hintsUsed: Int = 0, tries: Int = 1, timestamp: Date = Date()) {
        self.nodeID = nodeID
        self.correct = correct
        self.elapsed = elapsed
        self.hintsUsed = hintsUsed
        self.tries = tries
        self.timestamp = timestamp
    }

    /// The in-memory signal this record represents.
    var signal: AttemptSignal {
        AttemptSignal(correct: correct, elapsed: elapsed,
                      hintsUsed: hintsUsed, tries: tries, at: timestamp)
    }
}

// MARK: - Per-node memory state

/// Per-(learner, node) memory state. One row per node the learner has touched.
/// `Codable` for on-device persistence (one JSON blob per learner).
struct NodeState: Codable {
    var nodeID: NodeID

    // --- DSR triple ---
    var D: Double          // difficulty   ∈ [1, 10]
    var S: Double          // stability    > 0 (days for R: 1.0 → 0.9)
    // R is NOT stored — computed from S and (now − lastReview).

    // --- bookkeeping ---
    var lastReview: Date?  // nil ⇒ never attempted (state is a prior, not real)
    var reps: Int          // count of successful reviews (G ≥ 2)
    var lapses: Int        // count of failures (G = 1)

    /// Current run of consecutive wrong answers. Resets to 0 on any correct.
    /// This is the remediation signal the scheduler reads (a long run ⇒ a real
    /// prerequisite gap, not a pacing knob).
    var consecutiveWrong: Int = 0

    /// True once this node's prerequisites were satisfied and it entered rotation.
    /// Informational; the scheduler recomputes the frontier from prereqs each
    /// session rather than trusting a cached flag.
    var unlocked: Bool

    /// A never-attempted prior for a node: neutral difficulty, tiny stability,
    /// locked. `lastReview == nil` marks it a prior rather than a real observation.
    static func prior(_ id: NodeID) -> NodeState {
        NodeState(nodeID: id,
                  D: 5.0,
                  S: FSRS.w.w2,   // ≈ a fresh "good" stability
                  lastReview: nil,
                  reps: 0,
                  lapses: 0,
                  consecutiveWrong: 0,
                  unlocked: false)
    }
}

// MARK: - FSRS-6 weights

/// FSRS-6 default weight vector. Held in one struct so the model is parameterised
/// and a fitted-per-learner vector can be swapped in without touching the formulas.
struct FSRSWeights: Codable {
    let w0, w1, w2, w3, w4, w5, w6, w7, w8, w9: Double
    let w10, w11, w12, w13, w14, w15, w16, w17, w18, w19: Double
    let w20: Double

    /// FSRS-6 published defaults.
    static let `default` = FSRSWeights(
        w0: 0.2120, w1: 1.2931, w2: 2.3065, w3: 8.2956, w4: 6.4133,
        w5: 0.8334, w6: 0.1437, w7: 0.0500, w8: 1.4604, w9: 0.0046,
        w10: 1.5460, w11: 0.0656, w12: 0.1700, w13: 0.1100, w14: 0.4400,
        w15: 0.4100, w16: 1.4900, w17: 0.2700, w18: 0.4700, w19: 0.0000,
        w20: 0.1542
    )
}

// MARK: - Retrievability decay (computed, never stored)

/// FSRS-6 forgetting curve, update rule, and grade derivation. Stateless namespace.
enum FSRS {
    static let w = FSRSWeights.default

    /// Power-law decay exponent (w20).
    static var DECAY: Double { w.w20 }

    /// Curve constant fixed so that `R(S, S) == 0.9` exactly: by definition one
    /// stability-unit of elapsed days drops recall to 0.9.
    static var FACTOR: Double { pow(0.9, -1.0 / DECAY) - 1.0 }

    /// Days elapsed since the last review (clamped ≥ 0).
    static func elapsedDays(_ s: NodeState, now: Date) -> Double {
        guard let last = s.lastReview else { return 0 }
        return max(0, now.timeIntervalSince(last) / 86_400)
    }

    /// Retrievability `R(t, S) ∈ (0, 1]` — probability of recall right now.
    ///
    ///     R(t, S) = (1 + FACTOR · t/S)^(−DECAY)
    ///
    /// Returns 0 for a never-attempted prior (nothing to recall yet).
    static func retrievability(_ s: NodeState, now: Date) -> Double {
        guard s.lastReview != nil, s.S > 0 else { return 0 }
        let t = elapsedDays(s, now: now)
        return pow(1.0 + FACTOR * t / s.S, -DECAY)
    }

    /// Inverse of the curve: interval (days) until `R` decays to target retention `Rd`.
    ///
    ///     I(Rd, S) = (S / FACTOR) · (Rd^(−1/DECAY) − 1)
    ///
    /// At `Rd = 0.9` this returns `S`, by construction of `FACTOR`.
    static func interval(toRetention Rd: Double, _ s: NodeState) -> Double {
        (s.S / FACTOR) * (pow(Rd, -1.0 / DECAY) - 1.0)
    }
}

// MARK: - Update rule on a graded attempt

extension FSRS {

    /// Initial stability after the FIRST review, per grade: `S0(G) = w[G−1]`.
    static func initialStability(_ g: Grade) -> Double {
        switch g {
        case .again: return w.w0
        case .hard:  return w.w1
        case .good:  return w.w2
        case .easy:  return w.w3
        }
    }

    /// Initial difficulty: `D0(G) = w4 − exp(w5·(G−1)) + 1`, clamped to `[1, 10]`.
    static func initialDifficulty(_ g: Grade) -> Double {
        clamp(w.w4 - exp(w.w5 * Double(g.rawValue - 1)) + 1.0, 1, 10)
    }

    /// Difficulty update: linear step damped near `D = 10`, then mean-revert to `D0(Easy)`.
    static func nextDifficulty(_ D: Double, _ g: Grade) -> Double {
        let dD = -w.w6 * Double(g.rawValue - 3)
        let linear = D + dD * (10 - D) / 9
        let reverted = w.w7 * initialDifficulty(.easy) + (1 - w.w7) * linear
        return clamp(reverted, 1, 10)
    }

    /// Stability after a SUCCESSFUL review (`G ≥ 2`) at current retrievability `R`.
    ///
    ///     S' = S · (1 + e^{w8}·(11−D)·S^{−w9}·(e^{w10·(1−R)} − 1)·h·b)
    ///
    /// `h < 1` penalises "hard"; `b > 1` rewards "easy".
    static func stabilityOnSuccess(_ S: Double, _ D: Double, _ R: Double, _ g: Grade) -> Double {
        let h = (g == .hard) ? w.w15 : 1.0
        let b = (g == .easy) ? w.w16 : 1.0
        let growth = exp(w.w8) * (11 - D) * pow(S, -w.w9)
                   * (exp(w.w10 * (1 - R)) - 1) * h * b
        return S * (1 + growth)
    }

    /// Stability after a LAPSE (`G = 1`). Never exceeds prior `S` (the min clamp).
    ///
    ///     S'_f = min( w11·D^{−w12}·((S+1)^{w13} − 1)·e^{w14·(1−R)},  S )
    static func stabilityOnLapse(_ S: Double, _ D: Double, _ R: Double) -> Double {
        let post = w.w11 * pow(D, -w.w12) * (pow(S + 1, w.w13) - 1) * exp(w.w14 * (1 - R))
        return min(post, S)
    }

    /// Same-day re-review (`t ≈ 0`, multiple attempts in one session).
    ///
    ///     S' = S · e^{w17·(G−3+w18)} · S^{−w19}
    static func stabilitySameDay(_ S: Double, _ g: Grade) -> Double {
        S * exp(w.w17 * (Double(g.rawValue) - 3 + w.w18)) * pow(S, -w.w19)
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }
}

// MARK: - The driver

extension NodeState {

    /// Apply one graded attempt. Pure aside from reading `now`.
    /// `sameDay == true` ⇒ this is a repeat rep within the same study session.
    mutating func applyReview(grade g: Grade, now: Date, sameDay: Bool = false) {
        let firstEver = (lastReview == nil)

        if firstEver {
            S = FSRS.initialStability(g)
            D = FSRS.initialDifficulty(g)
        } else {
            let R = FSRS.retrievability(self, now: now)
            D = FSRS.nextDifficulty(D, g)
            switch (sameDay, g) {
            case (true,  _):      S = FSRS.stabilitySameDay(S, g)
            case (false, .again): S = FSRS.stabilityOnLapse(S, D, R)
            case (false, _):      S = FSRS.stabilityOnSuccess(S, D, R, g)
            }
        }

        if g == .again {
            lapses += 1
            consecutiveWrong += 1
        } else {
            reps += 1
            consecutiveWrong = 0
        }
        lastReview = now
        unlocked = true
    }
}

// MARK: - Mastery predicates, thresholds, and grade derivation

/// Tunable thresholds for the continuous mastery scalar, the provisional and
/// durable predicates, and grade derivation. Kept in one namespace.
enum MasteryConfig {
    // --- durable mastery (DE-PRIORITISES review; never blocks progress) ---
    static let Rmaster: Double = 0.90   // current-recall floor to count as durable
    static let Smaster: Double = 21.0   // durability floor (≈ holds 3 weeks)
    static let kMinReps: Int   = 2      // must have stuck ≥ twice

    // --- provisional learning (UNLOCKS dependents; decay-independent) ---
    static let provisionalMinReps: Int = 1   // demonstrated at least once

    // --- continuous-blend coefficients (for `mastery`) ---
    static let a: Double = 0.35
    static let c: Double = 1.50

    // --- remediation ---
    /// Consecutive wrong answers that flag a node as a prerequisite gap.
    static let remedThreshold: Int = 3
}

extension NodeState {

    /// Continuous mastery scalar `∈ [0, 1]` — used for review WEIGHTING and selection.
    ///
    ///     M = σ( a·ln(S) + c·(R_now − 0.5) )
    ///
    /// Blends durability (`S`) with current recall (`R`), so a node that is durable
    /// but momentarily decayed still scores partial mastery.
    func mastery(now: Date) -> Double {
        let R = FSRS.retrievability(self, now: now)
        let z = MasteryConfig.a * log(max(S, 1e-6)) + MasteryConfig.c * (R - 0.5)
        return 1.0 / (1.0 + exp(-z))
    }

    /// PROVISIONAL predicate — gates UNLOCK of dependents and graduation off the
    /// new-material frontier.
    ///
    ///     learnedEnough ⇔ attempted ∧ reps ≥ provisionalMinReps ∧ not currently failing
    ///
    /// Deliberately decay-INDEPENDENT and sticky: once a learner has demonstrated a
    /// skill, its dependents stay open even as the skill itself decays (we don't
    /// re-lock the curriculum). This is what lets new material flow within a session
    /// instead of being calendar-gated behind 3-week durable stability.
    func learnedEnough(now: Date) -> Bool {
        lastReview != nil
            && reps >= MasteryConfig.provisionalMinReps
            && consecutiveWrong == 0
    }

    /// DURABLE predicate — used only to DE-PRIORITISE review.
    ///
    ///     mastered ⇔ R_now ≥ Rmaster ∧ S ≥ Smaster ∧ reps ≥ k
    ///
    /// Reads live `R`, so a durable node can fall back below `Rmaster` from decay
    /// and re-surface for review — but it never re-locks dependents (that's
    /// `learnedEnough`'s job).
    func isMastered(now: Date) -> Bool {
        guard lastReview != nil else { return false }
        let R = FSRS.retrievability(self, now: now)
        return R >= MasteryConfig.Rmaster
            && S >= MasteryConfig.Smaster
            && reps >= MasteryConfig.kMinReps
    }

    /// Whether this node is in a repeated-failure state worth remediating.
    var needsRemediation: Bool { consecutiveWrong >= MasteryConfig.remedThreshold }

    /// Whether the learner has ever attempted this node (vs. it being a prior).
    var isTouched: Bool { lastReview != nil }
}

// MARK: - Deriving the FSRS grade from CAS grading (no self-rating)

extension Grade {

    /// Map CAS outcome + timing/hints to an FSRS grade.
    ///
    /// - again: wrong.
    /// - hard:  correct but assisted (hints / retries) or slow (> 1.8·T).
    /// - good:  clean.
    /// - easy:  fast clean first-try (< 0.5·T).
    ///
    /// `T` is the per-node expected solve time, calibrated from the generator.
    static func from(_ s: AttemptSignal, expectedTime T: TimeInterval) -> Grade {
        guard s.correct else { return .again }
        if s.hintsUsed > 0 || s.tries > 1 || (T > 0 && s.elapsed > 1.8 * T) { return .hard }
        if T > 0 && s.elapsed < 0.5 * T && s.tries == 1 { return .easy }
        return .good
    }
}
