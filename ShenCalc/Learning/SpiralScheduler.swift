import Foundation

/// The adaptive Saxon-spiral scheduler.
///
/// Saxon math works by *incremental* introduction of new material plus *heavy
/// mixed cumulative review* — every session you meet a little that's new and a
/// lot you saw before. The classic textbook fixes that review mix in print for the
/// average student. We do better: grading runs through shen-cas, so we know per
/// skill exactly how solid each learner is, and the mix is driven by *that
/// learner's* mastery over a prerequisite DAG instead of a one-size page number.
///
/// This is a **pure function** of persisted state + the static graph:
///
///     buildSession(graph:learner:now:size:) -> [ProblemSlot]
///
/// It emits ordered *slots* — each names a skill node and an intent. A separate
/// generation pass turns each slot into a concrete problem via that node's
/// parametric generator. The scheduler never calls the CAS; it only reads the
/// mastery telemetry that grading writes. Same state in, same session out.
///
/// Unlock uses two predicates (see `Mastery.swift`): a node enters the frontier
/// when its prereqs are *provisionally* learned (`learnedEnough`, decay-
/// independent) so new material flows within a session; durable FSRS mastery
/// (`isMastered`) only down-weights review. That split is what stops a new learner
/// from being calendar-gated behind three-week stability before tier two opens.
///
/// Depends on the data model in this module:
///   - `KnowledgeGraph` / `SkillNode`     (KnowledgeGraph.swift)
///   - `NodeState` / `LearnerState` / FSRS (Mastery.swift, LearnerState.swift)

// MARK: - Output

/// Why a slot is in the session. The generator and UI both branch on this:
/// `placement` is framed as "let's see where you are", `remediation` drops to a
/// prerequisite and is framed as shoring up a gap, `new`/`review` are normal.
enum SlotIntent: String, Codable {
    case new          // first-class new material (a frontier node)
    case review       // cumulative spiral review of a touched node
    case remediation  // a prereq of a node the learner keeps failing
    case placement    // a calibration probe for a brand-new learner
}

/// One unit of work in a session: practice `node` with the given `intent`.
struct ProblemSlot: Identifiable, Codable, Equatable {
    var id: String { "\(node)#\(intent.rawValue)" }
    let node: NodeID
    let intent: SlotIntent
}

// MARK: - Scheduler

/// Namespace for the spiral-scheduling policy. All knobs live here as named
/// constants so the pedagogy is legible and tunable in one place.
enum SpiralScheduler {

    // MARK: Tunable policy constants

    /// Default session length (problem count).
    static let defaultSize = 24

    /// Saxon cadence: at most this many *brand-new* skills per session once there
    /// is a review backlog. When the review pool is thin (e.g. just after
    /// placement) the spill logic temporarily admits more, so a learner isn't
    /// starved of material on day one.
    static let maxNewPerSession = 2

    /// Review-priority blend. `dueUrgency` dominates — the spiral's whole job is to
    /// catch material right at the edge of forgetting; `weakness` resurfaces a
    /// shakily-held node more than a solid one; `difficulty` (graph depth) gives
    /// deeper skills a touch more airtime.
    static let wDue  = 0.6
    static let wWeak = 0.3
    static let wDiff = 0.1

    /// How many slots a single struggling node may claim for remediation, and the
    /// hard ceiling on *total* remediation as a fraction of the session — so a
    /// cluster of weak spots can never crowd out review/consolidation entirely.
    static let remedSlotsPerNode = 2
    static let remedSessionFraction = 0.5

    /// Quantum for comparing `Double` priorities, so ordering is deterministic
    /// across platforms (bit-different-but-equal scores tiebreak on topo order).
    private static let priorityQuantum = 1_000_000.0

    // MARK: Entry point

    /// Build an ordered session for `learner` against `graph` as of `now`.
    ///
    /// A brand-new learner (`placed == false`) gets a placement probe — we have no
    /// telemetry to schedule against yet; the app grades it and calls
    /// `LearnerState.completePlacement`. Every other session is: a capped block of
    /// remediation (spread, not front-loaded), a Saxon-cadence trickle of new
    /// material, and the rest cumulative review — led by a warm-up and interleaved
    /// so the learner never faces a wall of hard problems.
    static func buildSession(graph: KnowledgeGraph,
                             learner: LearnerState,
                             now: Date = Date(),
                             size: Int = defaultSize) -> [ProblemSlot] {
        guard size > 0 else { return [] }

        // Brand-new learner: calibrate, don't schedule.
        if !learner.placed {
            return Array(placementProbe(graph).prefix(size))
        }

        // 1. Remediation — capped so it can never consume the whole session.
        let remedBudget = max(1, Int((Double(size) * remedSessionFraction).rounded(.down)))
        let remediation = remediationSlots(graph, learner, now: now, budget: remedBudget)
        let remaining = size - remediation.count
        guard remaining > 0 else { return spread(remediation, into: []) }

        // 2. New material — Saxon cadence, reconciled against availability.
        let frontierNodes = frontier(graph, learner, now: now)
        var newCount = min(maxNewPerSession, frontierNodes.count, remaining)

        let newIDs = Array(frontierNodes.prefix(newCount))
        let excluded = focusSet(remediation).union(newIDs)
        let reviewPool = reviewCandidates(graph, learner, excluding: excluded)
        var reviewCount = max(0, remaining - newCount)

        // Spill: if the review pool is thin (early sessions), pour the slack into
        // new material so the session is always full when work exists.
        if reviewCount > reviewPool.count {
            let slack = reviewCount - reviewPool.count
            reviewCount = reviewPool.count
            newCount = min(newCount + slack, frontierNodes.count, remaining)
        }

        let newSlots = frontierNodes.prefix(newCount)
            .map { ProblemSlot(node: $0, intent: .new) }

        let reviewSlots = topReview(reviewPool, graph, learner, now: now, count: reviewCount)
            .map { ProblemSlot(node: $0, intent: .review) }

        // 3. Assemble: a warm-up review leads (affect), remediation is spread
        //    through the review stream rather than clustered up front, and new
        //    material is threaded across the whole thing.
        let support = spread(remediation, into: warmUpFirst(reviewSlots, graph, learner, now: now))
        return thread(newSlots, into: support)
    }

    // MARK: Frontier (new-material candidates)

    /// The legal next things to learn: not-yet-provisionally-learned nodes whose
    /// every prerequisite *is* provisionally learned. Gentlest first (shallowest
    /// graph depth, then topo order) so new material unlocks in pedagogical order.
    /// A node seen but not yet learned stays here — it keeps drawing `new` slots
    /// until it graduates. (Roots have no prereqs, so a freshly-placed learner with
    /// no state still gets the roots as frontier.)
    static func frontier(_ g: KnowledgeGraph, _ s: LearnerState, now: Date) -> [NodeID] {
        g.topoOrder.filter { id in
            guard let node = g.node(id) else { return false }
            guard !s.state(id).learnedEnough(now: now) else { return false }
            return node.prerequisites.allSatisfy { s.state($0).learnedEnough(now: now) }
        }
        .sorted { a, b in
            let da = g.depth(of: a), db = g.depth(of: b)
            if da != db { return da < db }
            return g.topoIndex(a) < g.topoIndex(b)
        }
    }

    // MARK: Review pool and priority

    /// Every node the learner has touched that isn't already spoken for this session
    /// (a remediation focus or a new pick). This is the cumulative spiral pool.
    static func reviewCandidates(_ g: KnowledgeGraph, _ s: LearnerState,
                                 excluding focus: Set<NodeID>) -> [NodeID] {
        g.topoOrder.filter { id in
            guard g.node(id) != nil, !focus.contains(id) else { return false }
            return s.state(id).isTouched
        }
    }

    /// Higher = more urgent. Blends due-ness (forgetting curve), weakness
    /// (continuous mastery), and intrinsic difficulty (normalized graph depth).
    /// This is the personalized spiral: two learners at the same curriculum
    /// position get different review mixes.
    static func reviewPriority(_ st: NodeState, depth: Int, maxDepth: Int,
                               now: Date) -> Double {
        let r = FSRS.retrievability(st, now: now)
        let dueUrgency = 1 - r                       // lower retrievability ⇒ more due
        let weakness   = 1 - st.mastery(now: now)    // shakier ⇒ more practice
        let diffNorm   = maxDepth > 0 ? Double(depth) / Double(maxDepth) : 0
        return wDue * dueUrgency + wWeak * weakness + wDiff * diffNorm
    }

    /// The `count` most-urgent review nodes, highest priority first. Ties break on
    /// topo order (quantized priority keeps the comparison deterministic).
    static func topReview(_ pool: [NodeID], _ g: KnowledgeGraph,
                          _ s: LearnerState, now: Date, count: Int) -> [NodeID] {
        guard count > 0 else { return [] }
        let maxDepth = g.maxDepth
        return pool.sorted { a, b in
            let pa = quantize(reviewPriority(s.state(a), depth: g.depth(of: a),
                                             maxDepth: maxDepth, now: now))
            let pb = quantize(reviewPriority(s.state(b), depth: g.depth(of: b),
                                             maxDepth: maxDepth, now: now))
            if pa != pb { return pa > pb }
            return g.topoIndex(a) < g.topoIndex(b)
        }
        .prefix(count)
        .map { $0 }
    }

    // MARK: Placement

    /// First-session calibration: probe a small spread of the graph rather than all
    /// V nodes. We take the most-depended-on node in each depth band (high
    /// out-degree ⇒ an important prerequisite). The app grades the probe and calls
    /// `completePlacement`, which seeds "presumed known" down the DAG — so the next
    /// session's frontier lands near the learner's true level. O(probes), not O(V).
    static func placementProbe(_ g: KnowledgeGraph) -> [ProblemSlot] {
        let byDepth = Dictionary(grouping: g.nodes, by: { g.depth(of: $0.id) })
        let probes = byDepth.keys.sorted().compactMap { depth -> SkillNode? in
            byDepth[depth]?.sorted { a, b in
                let da = g.dependentIDs(of: a.id).count, db = g.dependentIDs(of: b.id).count
                if da != db { return da > db }
                return g.topoIndex(a.id) < g.topoIndex(b.id)
            }.first
        }
        return probes.map { ProblemSlot(node: $0.id, intent: .placement) }
    }

    // MARK: Remediation

    /// A node failed repeatedly isn't a scheduling problem, it's a prerequisite
    /// gap: drop to its weakest not-yet-learned prerequisite and practice *that*
    /// instead — you can't fix two-step equations by drilling them if the gap is
    /// integer arithmetic. Foundational (shallower) gaps are remediated first, and
    /// the whole block is budgeted so it can't crowd out the spiral.
    static func remediationSlots(_ g: KnowledgeGraph, _ s: LearnerState,
                                 now: Date, budget: Int) -> [ProblemSlot] {
        guard budget > 0 else { return [] }

        let stuck = g.topoOrder
            .filter { s.state($0).needsRemediation }
            .sorted { a, b in
                let ca = s.state(a).consecutiveWrong, cb = s.state(b).consecutiveWrong
                if ca != cb { return ca > cb }            // most-stuck first
                if g.depth(of: a) != g.depth(of: b) { return g.depth(of: a) < g.depth(of: b) } // then shallowest (foundational) first
                return g.topoIndex(a) < g.topoIndex(b)
            }

        var slots: [ProblemSlot] = []
        var used = Set<NodeID>()
        for node in stuck {
            guard slots.count < budget else { break }
            for t in remediationTargets(g, s, node: node, now: now) {
                guard slots.count < budget else { break }
                guard used.insert(t).inserted else { continue }
                slots.append(ProblemSlot(node: t, intent: .remediation))
            }
        }
        return slots
    }

    /// Up to `remedSlotsPerNode` targets for a stuck `node`: its not-yet-learned
    /// prerequisites, weakest (lowest retrievability, then lowest mastery) first.
    /// Falls back to re-drilling the node itself when every prereq is already solid
    /// (the gap is in the node, not below it).
    private static func remediationTargets(_ g: KnowledgeGraph, _ s: LearnerState,
                                           node: NodeID, now: Date) -> [NodeID] {
        let prereqs = g.node(node)?.prerequisites ?? []
        let shaky = prereqs
            .filter { !s.state($0).learnedEnough(now: now) }
            .sorted { a, b in
                let ra = FSRS.retrievability(s.state(a), now: now)
                let rb = FSRS.retrievability(s.state(b), now: now)
                if ra != rb { return ra < rb }
                return s.state(a).mastery(now: now) < s.state(b).mastery(now: now)
            }
        let targets = shaky.isEmpty ? [node] : shaky
        return Array(targets.prefix(remedSlotsPerNode))
    }

    // MARK: Assembly helpers

    /// Reorder review slots so the *easiest* (highest current retrievability) leads
    /// — a confidence-building warm-up — with the rest left in urgency order.
    private static func warmUpFirst(_ review: [ProblemSlot], _ g: KnowledgeGraph,
                                    _ s: LearnerState, now: Date) -> [ProblemSlot] {
        guard review.count > 1 else { return review }
        let easiestIdx = review.indices.max { a, b in
            FSRS.retrievability(s.state(review[a].node), now: now)
                < FSRS.retrievability(s.state(review[b].node), now: now)
        }
        guard let i = easiestIdx else { return review }
        var out = review
        let warm = out.remove(at: i)
        out.insert(warm, at: 0)
        return out
    }

    /// Thread `sparse` items evenly through `dense`, offset so they never lead — the
    /// Saxon "mixed practice" feel and the way remediation/new material get spread
    /// across a session instead of clustered. Drains any remainder at the end.
    static func thread(_ sparse: [ProblemSlot], into dense: [ProblemSlot]) -> [ProblemSlot] {
        guard !sparse.isEmpty else { return dense }
        guard !dense.isEmpty else { return sparse }

        let total = sparse.count + dense.count
        let stride = Double(total) / Double(sparse.count)
        var out: [ProblemSlot] = []
        out.reserveCapacity(total)

        var si = 0, di = 0
        var nextSparseAt = stride / 2           // offset so we don't lead with one
        for pos in 0..<total {
            if si < sparse.count && Double(pos) >= nextSparseAt {
                out.append(sparse[si]); si += 1
                nextSparseAt += stride
            } else if di < dense.count {
                out.append(dense[di]); di += 1
            } else if si < sparse.count {        // dense exhausted — drain sparse
                out.append(sparse[si]); si += 1
            }
        }
        return out
    }

    /// Spread (alias of `thread`) remediation through the review backbone.
    private static func spread(_ extra: [ProblemSlot], into base: [ProblemSlot]) -> [ProblemSlot] {
        thread(extra, into: base)
    }

    // MARK: Misc

    private static func quantize(_ x: Double) -> Double {
        (x * priorityQuantum).rounded() / priorityQuantum
    }

    /// The set of nodes already assigned a slot, for exclusion from the review pool.
    private static func focusSet(_ slots: [ProblemSlot]) -> Set<NodeID> {
        Set(slots.map(\.node))
    }
}
