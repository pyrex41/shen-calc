import Foundation

// MARK: - FIRe: Free Implicit Review (prerequisite-credit propagation)
//
// FSRS schedules each node in isolation: reviewing node N tells the model nothing
// about N's prerequisites. But in a genuine prerequisite DAG, solving N is also
// EVIDENCE about its ancestors — you cannot factor a quadratic without exercising
// the polynomial arithmetic underneath it. Re-drilling those prerequisites
// explicitly would waste session budget on skills the learner just demonstrated
// implicitly.
//
// FIRe ("Free Implicit Review") closes that gap: when a node reaches durable
// mastery, it grants a small FRACTIONAL review credit to each direct prerequisite
// — a partial stability nudge, NOT a full `applyReview`. The credit is:
//
//   • fractional   — a fraction of a clean rep's stability growth, so an implicit
//                    signal never counts as much as actually solving the prereq.
//   • non-resetting — it nudges `S` (and `lastReview`, so the forgetting clock
//                     restarts) but does NOT touch `reps`/`lapses`/`consecutiveWrong`.
//                     A free credit must never fabricate a "rep" that would, e.g.,
//                     trip `learnedEnough` for a node never actually attempted.
//   • prior-safe   — it only credits prerequisites the learner has ALREADY touched.
//                     Never-attempted priors are left untouched (an implicit signal
//                     isn't enough to claim a brand-new skill is learned).
//   • idempotent-ish — gated on a one-time "mastery crossed" trigger by the caller,
//                     so a node sitting at mastery for weeks doesn't keep paying out.
//
// IMPORTANT: this file does NOT alter the FSRS formulas in `Mastery.swift`. It
// reuses `FSRS.stabilityOnSuccess` and `FSRS.retrievability` and applies a damped
// fraction of the resulting growth. All formula authority stays in `Mastery.swift`.
//
// Style follows the rest of Learning/: value structs, `///` doc comments, no
// external deps, no force-unwraps in library code.

// MARK: - Tunable policy

/// Knobs for prerequisite-credit propagation. One namespace so the FIRe pedagogy
/// is legible and tunable beside the FSRS and scheduler constants.
enum FIReConfig {
    /// Fraction of a clean `.good` rep's stability GROWTH granted to a direct
    /// prerequisite when a node masters. `0` disables FIRe; `1` would treat the
    /// implicit signal as a full review (deliberately well below that).
    static let creditFraction: Double = 0.30

    /// Per-edge decay of the credit as it propagates further up the DAG: a
    /// grandparent gets `creditFraction · decayPerHop` of a rep, and so on. Keeps
    /// deep ancestors from being over-credited by one downstream success.
    static let decayPerHop: Double = 0.5

    /// How many hops up the DAG the credit propagates. `1` = direct prerequisites
    /// only (the conservative default); higher reaches transitive ancestors with
    /// `decayPerHop` damping.
    static let maxHops: Int = 1

    /// Only credit prerequisites whose current retrievability is at/below this —
    /// a prereq already near-perfectly recalled gains nothing from a nudge, so we
    /// skip it and avoid runaway stability inflation.
    static let creditCeilingR: Double = 0.95
}

// MARK: - The credit operation

/// Prerequisite-credit propagation. Stateless namespace; every entry point is a
/// pure function of `(graph, state, now)` aside from mutating the passed `states`.
enum FIRe {

    /// Apply a fractional review credit to a single node's `NodeState`, in place.
    ///
    /// Mechanism: compute the stability the node WOULD reach after a clean `.good`
    /// success at its current `R` (via the existing `FSRS.stabilityOnSuccess`),
    /// then move `S` only `fraction` of the way toward that target. Restart the
    /// forgetting clock (`lastReview = now`) so the credit actually buys recall
    /// time. Do NOT touch `reps`/`lapses`/`consecutiveWrong`/`D` — this is a
    /// stability nudge, not a graded attempt.
    ///
    /// No-ops on a never-attempted prior (nothing to reinforce yet) or when the
    /// node is already recalled above `creditCeilingR`.
    static func creditNode(_ state: inout NodeState, fraction: Double, now: Date) {
        guard state.isTouched else { return }
        guard fraction > 0 else { return }

        let R = FSRS.retrievability(state, now: now)
        guard R <= FIReConfig.creditCeilingR else { return }

        let target = FSRS.stabilityOnSuccess(state.S, state.D, R, .good)
        guard target > state.S else { return }   // never shrink S on a credit

        let f = FSRS.clamp(fraction, 0, 1)
        state.S = state.S + (target - state.S) * f
        state.lastReview = now
    }

    /// Direct-prerequisite credit for a node that just mastered. Mutates the
    /// matching `NodeState`s in `states` in place (touched prerequisites only).
    /// Returns the ids that actually received credit (for logging / a "kept sharp"
    /// UI note). Pure aside from the `states` mutation.
    ///
    /// `propagate(maxHops:)` generalises this up the DAG; `creditPrerequisites`
    /// is the hop-1 special case the session loop calls by default.
    @discardableResult
    static func creditPrerequisites(of masteredNode: NodeID,
                                    in states: inout [NodeID: NodeState],
                                    graph: KnowledgeGraph,
                                    now: Date) -> [NodeID] {
        propagate(from: masteredNode, in: &states, graph: graph,
                  maxHops: 1, now: now)
    }

    /// Propagate fractional credit up to `maxHops` levels of prerequisites,
    /// damping by `FIReConfig.decayPerHop` each hop. BFS over ancestors, crediting
    /// each touched node once at the strongest (nearest) fraction that reaches it.
    /// Returns the credited ids in BFS order.
    @discardableResult
    static func propagate(from masteredNode: NodeID,
                          in states: inout [NodeID: NodeState],
                          graph: KnowledgeGraph,
                          maxHops: Int = FIReConfig.maxHops,
                          now: Date = Date()) -> [NodeID] {
        guard maxHops > 0, FIReConfig.creditFraction > 0 else { return [] }

        var credited: [NodeID] = []
        var seen: Set<NodeID> = [masteredNode]
        // (node, hopDistance) frontier, nearest hops first so each node is credited
        // at its strongest applicable fraction.
        var frontier: [(id: NodeID, hop: Int)] =
            graph.prerequisites(of: masteredNode).map { ($0.id, 1) }

        var i = 0
        while i < frontier.count {
            let (id, hop) = frontier[i]; i += 1
            guard hop <= maxHops, seen.insert(id).inserted else { continue }

            let fraction = FIReConfig.creditFraction
                * pow(FIReConfig.decayPerHop, Double(hop - 1))

            if var st = states[id] {        // touched-only: priors stay absent
                let before = st.S
                creditNode(&st, fraction: fraction, now: now)
                if st.S != before || st.lastReview != states[id]?.lastReview {
                    states[id] = st
                    credited.append(id)
                }
            }

            if hop < maxHops {
                for p in graph.prerequisites(of: id) where !seen.contains(p.id) {
                    frontier.append((p.id, hop + 1))
                }
            }
        }
        return credited
    }
}

// MARK: - LearnerState hook

extension LearnerState {

    /// Grant FIRe prerequisite credit triggered by `masteredNode` reaching durable
    /// mastery. Thin wrapper over `FIRe.propagate` that mutates this learner's
    /// `states` in place. Returns the credited ids (for a "kept sharp" UI note).
    ///
    /// Call this from the session loop ONLY on the transition into mastery — see
    /// `recordAndCredit` below, which detects the crossing for you.
    @discardableResult
    func grantPrerequisiteCredit(for masteredNode: NodeID,
                                 graph: KnowledgeGraph,
                                 now: Date = Date()) -> [NodeID] {
        FIRe.propagate(from: masteredNode, in: &states, graph: graph, now: now)
    }

    /// Record a graded attempt AND fire FIRe credit if that attempt pushed the
    /// node across the durable-mastery threshold. This is the single call the
    /// session loop should use in place of bare `record(_:)` when it wants implicit
    /// prerequisite review.
    ///
    /// Crossing detection: snapshot `isMastered` BEFORE folding the attempt, fold
    /// via the existing `record(_:expectedTime:now:)` (which owns all FSRS + streak
    /// math — untouched here), then if the node is NOW mastered and WASN'T before,
    /// propagate credit. The one-time edge guard means a node sitting at mastery
    /// doesn't keep paying out on every subsequent review.
    ///
    /// Returns the prerequisite ids that received credit (empty if no crossing).
    @discardableResult
    func recordAndCredit(_ attempt: AttemptRecord,
                         graph: KnowledgeGraph,
                         expectedTime: TimeInterval = 0,
                         now: Date = Date()) -> [NodeID] {
        let wasMastered = state(attempt.nodeID).isMastered(now: attempt.timestamp)
        record(attempt, expectedTime: expectedTime, now: now)
        let isMasteredNow = state(attempt.nodeID).isMastered(now: attempt.timestamp)

        guard isMasteredNow && !wasMastered else { return [] }
        return grantPrerequisiteCredit(for: attempt.nodeID, graph: graph, now: now)
    }
}

// MARK: - Session-loop integration notes
//
// The session loop grades an answer, records it, and (optionally) reaps implicit
// review. Two equivalent integration points:
//
//   A) One-call form (recommended). Replace the bare `record` with `recordAndCredit`:
//
//        let credited = learner.recordAndCredit(attempt, graph: .mvp,
//                                                expectedTime: expectedTime)
//        if !credited.isEmpty {
//            // optional UI: "kept your earlier skills sharp: <names>"
//        }
//        try? learner.save()
//
//   B) Manual form, if the loop already records elsewhere and only needs the
//      crossing → credit step:
//
//        let before = learner.state(id).isMastered(now: now)
//        learner.record(attempt, expectedTime: expectedTime)
//        if !before && learner.state(id).isMastered(now: now) {
//            learner.grantPrerequisiteCredit(for: id, graph: .mvp)
//        }
//
// Ordering: credit AFTER `record`, because the crossing is defined by the folded
// state. Persist (`learner.save()`) once, after crediting, since FIRe mutates
// `states`. FIRe never appends to `attempts` (the source-of-truth log stays a pure
// record of real graded answers) — it only nudges the derived FSRS fold, exactly
// like a re-derivation step. If `attempts` is ever replayed to rebuild `states`,
// re-run FIRe at each mastery crossing during the replay to reproduce the nudges.
