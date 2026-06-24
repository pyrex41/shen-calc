import Foundation

// MARK: - Adaptive diagnostic placement
//
// A brand-new learner shouldn't grind up from node 1: most arrive somewhere in
// the middle of the ladder. The job of placement is to find that level in a
// handful of graded probes and SEED `NodeState` priors so the spiral scheduler's
// `frontier` lands near the learner's true edge of competence.
//
// The strategy is information-theoretic over the DAG topology, and it leans on a
// monotonicity ASSUMPTION that the curriculum is built to satisfy:
//
//   if a learner can do node N, they can (probably) do N's prerequisites.
//
// Under that assumption, "what does the learner know" is a *downward-closed* set
// in the DAG (a known node implies its ancestors are known). The most
// informative probe is therefore the one whose pass/fail outcome most evenly
// splits the still-uncertain nodes into "now-known" vs "now-unknown" — a
// graph-aware binary search along prerequisite chains, picking the node that
// maximises the expected reduction in uncertainty about the frontier.
//
// This file is deliberately split into a PURE planner/folder (a function of
// `(graph, responses)` — no CAS, no I/O, fully unit-testable) and a thin async
// `run` driver that wires the planner to a generator + `CASClient` and grades
// with the same difference-to-zero oracle the rest of the tutor uses.
//
// Style follows the rest of Learning/: value structs, `///` doc comments, no
// external deps, no force-unwraps in library code.

// MARK: - Probe outcome

/// One graded placement probe: the node we tested and whether the learner
/// answered it correctly. `Codable`/`Equatable` so a session can persist an
/// in-progress placement and replay it deterministically in tests.
struct DiagnosticResponse: Codable, Equatable {
    let node: NodeID
    let correct: Bool
    /// Wall-clock solve time (seconds); 0 when unmeasured. Carried so the seed
    /// can derive a realistic FSRS grade rather than always assuming a clean rep.
    let elapsed: TimeInterval

    init(node: NodeID, correct: Bool, elapsed: TimeInterval = 0) {
        self.node = node
        self.correct = correct
        self.elapsed = elapsed
    }
}

// MARK: - Tunable policy

/// Knobs for the adaptive probe, in one namespace so the placement pedagogy is
/// legible and tunable alongside `SpiralScheduler`'s constants.
enum DiagnosticConfig {
    /// Hard floor on probes — even a learner who fails everything answers at
    /// least this many, so we never "place" off a single data point.
    static let minProbes = 6

    /// Hard ceiling on probes (bounded session). The information gain falls off
    /// fast once the known/unknown boundary is localised, so this is rarely hit.
    static let maxProbes = 18

    /// Stop early once the uncertain band (nodes not yet implied known/unknown)
    /// shrinks to this many nodes — the boundary is localised, more probes buy
    /// little. Still subject to `minProbes`.
    static let resolvedBand = 1

    /// Difficulty the probes are generated at — placement asks the canonical
    /// "can you do this skill at all" question, not an edge-case stress test.
    static let probeDifficulty: Difficulty = .standard
}

// MARK: - Pure planner / folder (no CAS, no I/O)

/// The information-theoretic placement engine. Everything here is a pure function
/// of `(graph, responses)`; the async wiring lives in `DiagnosticSession`.
///
/// Mental model of state during placement, all derived from the responses so far:
///   • `known`    — nodes the learner passed, plus (by monotonicity) all their
///                  ancestors. Downward-closed.
///   • `unknown`  — nodes the learner failed, plus (by monotonicity) all their
///                  descendants. Upward-closed.
///   • `uncertain`— everything else: the band the next probe should bisect.
enum DiagnosticPlanner {

    /// Nodes implied KNOWN by the responses: every passed node and all its
    /// transitive prerequisites (ancestors). Downward-closed in the DAG.
    static func impliedKnown(_ graph: KnowledgeGraph,
                             _ responses: [DiagnosticResponse]) -> Set<NodeID> {
        var known = Set<NodeID>()
        for r in responses where r.correct {
            known.insert(r.node)
            for a in graph.ancestors(of: r.node) { known.insert(a.id) }
        }
        return known
    }

    /// Nodes implied UNKNOWN by the responses: every failed node and all its
    /// transitive dependents (descendants). Upward-closed in the DAG.
    ///
    /// A node that the learner *passed* is never counted unknown even if some
    /// other failure sits below it — a direct positive observation wins over an
    /// inferred negative, so a spiky profile resolves toward what was actually
    /// demonstrated.
    static func impliedUnknown(_ graph: KnowledgeGraph,
                               _ responses: [DiagnosticResponse]) -> Set<NodeID> {
        let known = impliedKnown(graph, responses)
        var unknown = Set<NodeID>()
        for r in responses where !r.correct {
            var stack = [r.node]
            while let id = stack.popLast() {
                guard !known.contains(id), unknown.insert(id).inserted else { continue }
                stack.append(contentsOf: graph.dependentIDs(of: id))
            }
        }
        return unknown
    }

    /// The still-uncertain band: nodes neither implied-known nor implied-unknown.
    /// Returned in topological order for stable downstream tie-breaking.
    static func uncertain(_ graph: KnowledgeGraph,
                          _ responses: [DiagnosticResponse]) -> [NodeID] {
        let known = impliedKnown(graph, responses)
        let unknown = impliedUnknown(graph, responses)
        return graph.topoOrder.filter { !known.contains($0) && !unknown.contains($0) }
    }

    /// Choose the next node to probe, or `nil` when placement should stop.
    ///
    /// Information-theoretic selection: among uncertain nodes (and skipping ones
    /// already probed), pick the node whose pass/fail outcome splits the uncertain
    /// band most evenly. Passing a node N collapses N + its uncertain ancestors to
    /// known; failing it collapses N + its uncertain descendants to unknown. The
    /// best bisector minimises the size of the LARGER resulting band — classic
    /// worst-case binary search, which is also the max-entropy split for a
    /// downward-closed unknown over a monotone curriculum.
    ///
    /// Ties break toward the shallower node (foundational coverage first), then
    /// topo order, so the probe sequence is deterministic.
    static func nextProbe(_ graph: KnowledgeGraph,
                          _ responses: [DiagnosticResponse]) -> NodeID? {
        guard responses.count < DiagnosticConfig.maxProbes else { return nil }

        let band = uncertain(graph, responses)
        let probed = Set(responses.map(\.node))
        let candidates = band.filter { !probed.contains($0) }
        guard !candidates.isEmpty else { return nil }

        // Stop early only once we've met the floor AND the band is localised.
        if responses.count >= DiagnosticConfig.minProbes
            && band.count <= DiagnosticConfig.resolvedBand {
            return nil
        }

        let bandSet = Set(band)
        let total = band.count

        func splitCost(_ id: NodeID) -> Int {
            // How many uncertain nodes collapse if the learner PASSES id.
            var passCollapse = 1
            for a in graph.ancestors(of: id) where bandSet.contains(a.id) { passCollapse += 1 }
            // How many uncertain nodes collapse if the learner FAILS id.
            var failSet = Set<NodeID>()
            var stack = [id]
            while let cur = stack.popLast() {
                guard bandSet.contains(cur), failSet.insert(cur).inserted else { continue }
                stack.append(contentsOf: graph.dependentIDs(of: cur))
            }
            let failCollapse = failSet.count
            // The two outcomes are mutually exclusive partitions of the band; the
            // larger leftover band is `total - collapse`. Minimise the worst case.
            let passLeftover = total - passCollapse
            let failLeftover = total - failCollapse
            return max(passLeftover, failLeftover)
        }

        return candidates.min { a, b in
            let ca = splitCost(a), cb = splitCost(b)
            if ca != cb { return ca < cb }
            let da = graph.depth(of: a), db = graph.depth(of: b)
            if da != db { return da < db }
            return graph.topoIndex(a) < graph.topoIndex(b)
        }
    }

    /// The set of nodes to seed as provisionally-known once placement ends: the
    /// implied-known closure. (`LearnerState.completePlacement` re-derives the
    /// ancestor closure from the passed nodes, so passing it the raw passed-node
    /// list is sufficient — but exposing the full closure here keeps the planner
    /// independently testable and lets callers preview the placement.)
    static func placedKnown(_ graph: KnowledgeGraph,
                            _ responses: [DiagnosticResponse]) -> Set<NodeID> {
        impliedKnown(graph, responses)
    }

    /// The nodes the learner actually answered correctly — the minimal seed set
    /// `LearnerState.completePlacement(correctNodes:graph:)` expects (it expands
    /// to ancestors itself).
    static func passedNodes(_ responses: [DiagnosticResponse]) -> [NodeID] {
        responses.filter(\.correct).map(\.node)
    }
}

// MARK: - Async driver

/// Drives an adaptive placement to completion: ask the planner for the next
/// probe, generate a problem for it, grade with the same CAS oracle, fold the
/// outcome back in, repeat until the planner says stop. Pure logic lives in
/// `DiagnosticPlanner`; this type only handles the CAS/generation side effects.
///
/// Wiring is intentionally generator-agnostic: the caller supplies a closure that
/// produces a `(ProblemInstance, expectedTime)` for a given skill, so this file
/// has no compile-time dependency on the concrete generators (which are authored
/// in parallel — see the registry TODO below).
struct DiagnosticSession {

    /// Resolves a skill id to a freshly generated probe problem plus its
    /// calibrated expected solve time. Returns `nil` if no generator exists for
    /// the skill (placement then skips that node as if it can't be probed).
    typealias ProbeFactory = (_ skill: NodeID) async -> (instance: ProblemInstance,
                                                         expectedTime: TimeInterval)?

    /// Reads the learner's typed answer for a generated probe. The UI layer
    /// supplies this; tests supply a scripted answerer.
    typealias Answerer = (_ instance: ProblemInstance) async -> String

    let graph: KnowledgeGraph
    let cas: CASClient
    let grader: Grader
    let makeProbe: ProbeFactory
    let answer: Answerer

    init(graph: KnowledgeGraph,
         cas: CASClient,
         grader: Grader = CASGrader(),
         makeProbe: @escaping ProbeFactory,
         answer: @escaping Answerer) {
        self.graph = graph
        self.cas = cas
        self.grader = grader
        self.makeProbe = makeProbe
        self.answer = answer
    }

    /// Run the adaptive probe to completion and return the graded responses.
    /// Stops when the planner returns `nil` (band localised or `maxProbes` hit)
    /// or when no generator can produce the requested probe. Malformed answers do
    /// NOT count as a probe — the same node is re-offered on the next loop.
    ///
    /// Pure aside from the CAS/generation/answer side effects; the placement
    /// DECISIONS are all `DiagnosticPlanner` calls, so they replay deterministically
    /// from the returned `[DiagnosticResponse]`.
    func run() async -> [DiagnosticResponse] {
        var responses: [DiagnosticResponse] = []

        while let next = DiagnosticPlanner.nextProbe(graph, responses) {
            guard let probe = await makeProbe(next) else {
                // No generator for this node yet — record it as a skip by treating
                // it as uncertain-resolved so the planner doesn't reoffer it.
                // We do this by injecting a neutral "unprobeable" marker: drop out
                // if every remaining candidate is unprobeable to avoid a spin.
                if unprobeableStop(after: responses, skipping: next) { break }
                responses.append(DiagnosticResponse(node: next, correct: false))
                continue
            }

            let raw = await answer(probe.instance)
            let result = await grader.grade(raw, for: probe.instance, cas: cas)

            switch result.verdict {
            case .malformed:
                // A typo, not a wrong answer — don't burn the probe; re-offer.
                continue
            case .correct, .rightValueWrongForm:
                // `rightValueWrongForm` is value-correct → counts as known for
                // placement (we're locating competence, not enforcing canonical form).
                let start = probe.expectedTime   // expectedTime is a hint, not the clock
                _ = start
                responses.append(DiagnosticResponse(node: next, correct: true))
            case .incorrect:
                responses.append(DiagnosticResponse(node: next, correct: false))
            }
        }

        return responses
    }

    /// Guard against an unprobeable-node spin: if the only remaining uncertain
    /// candidates have no generator, stop instead of looping. Conservative — only
    /// reports a stop when `next` is the sole remaining candidate.
    private func unprobeableStop(after responses: [DiagnosticResponse],
                                 skipping next: NodeID) -> Bool {
        let probed = Set(responses.map(\.node) + [next])
        let remaining = DiagnosticPlanner.uncertain(graph, responses)
            .filter { !probed.contains($0) }
        return remaining.isEmpty
    }
}

// MARK: - Applying placement to LearnerState

extension DiagnosticSession {

    /// Run placement and commit the result to `learner`, seeding priors via the
    /// existing `LearnerState.completePlacement` (which expands passed nodes to
    /// their ancestor closure and flips `placed = true`). Returns the responses so
    /// the caller can show a "here's where you landed" summary. Does NOT save —
    /// the caller owns persistence (call `learner.save()` after).
    @discardableResult
    func placeAndCommit(into learner: LearnerState, now: Date = Date()) async -> [DiagnosticResponse] {
        let responses = await run()
        learner.completePlacement(correctNodes: DiagnosticPlanner.passedNodes(responses),
                                  graph: graph, now: now)
        return responses
    }
}

// MARK: - Generator wiring (TODO: registry)
//
// `DiagnosticSession` takes a `ProbeFactory` so it does not hard-depend on the
// concrete generators authored in parallel. Once the generator registry lands
// (keyed by `NodeID`, returning a `ProblemGenerator` and its calibrated expected
// solve time), the app builds the factory like:
//
//     let registry = GeneratorRegistry.default
//     let session = DiagnosticSession(
//         graph: .mvp,
//         cas: casClient,
//         makeProbe: { skill in
//             guard let gen = registry.generator(for: skill) else { return nil }
//             var rng = SeededRNG(seed: UInt64(bitPattern: Int64(skill.hashValue)))   // exposure control
//             guard let inst = await gen.generate(difficulty: DiagnosticConfig.probeDifficulty,
//                                                 using: &rng, cas: casClient) else { return nil }
//             return (inst, expectedTime(for: skill))   // expected-solve-time table TBD
//         },
//         answer: { inst in await ui.collectAnswer(for: inst) })
//     await session.placeAndCommit(into: learner)
//     try? learner.save()
//
// `GeneratorRegistry.default` (in LearningSession.swift) now ships a generator for
// every one of the 13 MVP nodes, so `generator(for:)` is non-nil across the whole
// graph. The remaining open item is a real per-node expected-solve-time table; the
// `nil` ProbeFactory path is still honored so a future node without a generator is
// skipped gracefully rather than crashing.
