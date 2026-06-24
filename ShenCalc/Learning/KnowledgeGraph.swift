import Foundation

/// The prerequisite knowledge graph that drives the Saxon-style spiral.
///
/// Each `SkillNode` is one parametric *generator* worth of math: a single skill
/// the CAS can both instantiate (params + computed answer + trace) and grade by
/// equivalence (`reduce(Simplify[student - answer]) == 0`). The nodes form a
/// genuine prerequisite DAG — every node's generator reuses the CAS heads its
/// ancestors mastered — so the graph doubles as the curriculum order *and* the
/// data the tutor walks to decide what to review and what to unlock next.
///
/// This file is intentionally CAS-free: it is pure topology + metadata so it
/// compiles standalone and can be reasoned about (and tested) without booting
/// the engine. `casOps` names the heads each generator relies on, kept here as
/// documentation and as the hook a generator/runtime layer dispatches on.

/// One skill in the ladder: an answer-generable, CAS-gradable unit of practice.
struct SkillNode: Identifiable, Hashable {
    /// Stable slug, e.g. "alg-linear-eq-1step". Used as the prerequisite key and
    /// as the mastery-store key, so it must never change once shipped.
    let id: String
    /// Human-readable skill name shown in the UI.
    let name: String
    /// Ids of the skills a learner must master before this one unlocks. An empty
    /// list marks a root (entry point) of the DAG.
    let prerequisites: [String]
    /// The shen-cas heads this skill's generator/grader exercises (e.g. "Solve",
    /// "Expand", "Factor"). Documentation today; dispatch hook for the runtime.
    let casOps: [String]

    static func == (lhs: SkillNode, rhs: SkillNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The DAG of skills plus the queries the spiral needs: lookup, ancestry, and
/// the mastery-driven frontier/unlock helpers that decide what comes next.
struct KnowledgeGraph {
    /// All nodes in authored (roughly topological) order.
    let nodes: [SkillNode]

    private let byId: [String: SkillNode]

    /// Reverse adjacency: id -> ids that list it as a prerequisite. Precomputed so
    /// the scheduler's dependent / out-degree lookups are O(1), not O(V) scans.
    let dependentsByID: [String: [String]]

    /// A stable topological order of the nodes (authored order breaks ties) and a
    /// position index into it. Computed once at load; the scheduler sorts and
    /// tiebreaks on `topoIndex` instead of rescanning, and a cycle in the authored
    /// graph traps *here* (a programming error) rather than looping at schedule time.
    let topoOrder: [String]
    private let topoIndexByID: [String: Int]

    /// Longest-path depth from a root (roots = 0). Used as a proxy for grade band
    /// (placement) and for intrinsic difficulty (frontier ordering, review weight),
    /// so we don't have to hand-author a difficulty/grade on every node.
    private let depthByID: [String: Int]

    init(nodes: [SkillNode]) {
        self.nodes = nodes
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        self.byId = byId

        // Reverse adjacency (only edges whose endpoints both exist).
        var deps: [String: [String]] = [:]
        for n in nodes {
            for p in n.prerequisites where byId[p] != nil {
                deps[p, default: []].append(n.id)
            }
        }
        self.dependentsByID = deps

        // Kahn topological sort, seeded and extended in authored order so the
        // result is deterministic (needed for reproducible sessions/tests).
        var indegree: [String: Int] = [:]
        for n in nodes { indegree[n.id] = n.prerequisites.filter { byId[$0] != nil }.count }
        var order: [String] = []
        order.reserveCapacity(nodes.count)
        var ready = nodes.filter { (indegree[$0.id] ?? 0) == 0 }.map { $0.id }
        var head = 0
        while head < ready.count {
            let u = ready[head]; head += 1
            order.append(u)
            for v in deps[u] ?? [] {
                indegree[v]! -= 1
                if indegree[v]! == 0 { ready.append(v) }
            }
        }
        precondition(order.count == nodes.count,
                     "KnowledgeGraph: prerequisite graph is not a DAG (cycle or dangling cycle detected)")
        self.topoOrder = order
        self.topoIndexByID = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

        // Longest-path depth, computed in topo order (every prereq precedes a node).
        var depth: [String: Int] = [:]
        for id in order {
            let prereqs = byId[id]?.prerequisites.filter { byId[$0] != nil } ?? []
            depth[id] = prereqs.isEmpty ? 0 : 1 + (prereqs.map { depth[$0] ?? 0 }.max() ?? 0)
        }
        self.depthByID = depth
    }

    // MARK: Derived indices (precomputed)

    /// Position in the stable topological order; unknown ids sort last.
    func topoIndex(_ id: String) -> Int { topoIndexByID[id] ?? Int.max }

    /// Longest-path depth from a root (roots = 0); unknown ids = 0.
    func depth(of id: String) -> Int { depthByID[id] ?? 0 }

    /// The deepest chain in the graph (≥ 0), for normalizing depth-as-difficulty.
    var maxDepth: Int { depthByID.values.max() ?? 0 }

    /// Ids that list `id` among their prerequisites (O(1) via the reverse index).
    func dependentIDs(of id: String) -> [String] { dependentsByID[id] ?? [] }

    // MARK: Lookup

    /// The node with `id`, or nil if there is no such skill.
    func node(_ id: String) -> SkillNode? { byId[id] }

    subscript(_ id: String) -> SkillNode? { byId[id] }

    /// Direct prerequisites of `id` (one hop up the DAG). Unknown ids -> [].
    func prerequisites(of id: String) -> [SkillNode] {
        (byId[id]?.prerequisites ?? []).compactMap { byId[$0] }
    }

    /// Direct dependents of `id` (one hop down the DAG): nodes that list `id`
    /// among their prerequisites.
    func dependents(of id: String) -> [SkillNode] {
        nodes.filter { $0.prerequisites.contains(id) }
    }

    /// The roots of the DAG (skills with no prerequisites) — the entry points a
    /// brand-new learner starts from.
    var roots: [SkillNode] { nodes.filter { $0.prerequisites.isEmpty } }

    /// All transitive prerequisites of `id`, nearest-first-ish (BFS order),
    /// excluding `id` itself. Useful for "what must I review to support this".
    func ancestors(of id: String) -> [SkillNode] {
        var seen = Set<String>()
        var order: [SkillNode] = []
        var queue = byId[id]?.prerequisites ?? []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted, let p = byId[pid] else { continue }
            order.append(p)
            queue.append(contentsOf: p.prerequisites)
        }
        return order
    }

    // MARK: Frontier / unlock

    /// Whether every direct prerequisite of `id` is mastered. A skill with no
    /// prerequisites is always unlocked. Unknown ids are treated as not unlocked.
    func isUnlocked(_ id: String, mastered: Set<String>) -> Bool {
        guard let node = byId[id] else { return false }
        return node.prerequisites.allSatisfy { mastered.contains($0) }
    }

    /// The *frontier*: skills the learner has unlocked (all prereqs mastered) but
    /// not yet mastered. These are the candidates for new-material instruction —
    /// the "incremental new material" half of the Saxon spiral.
    func frontier(mastered: Set<String>) -> [SkillNode] {
        nodes.filter { !mastered.contains($0.id) && isUnlocked($0.id, mastered: mastered) }
    }

    /// Skills newly unlocked by mastering `justMastered`, given the prior mastery
    /// set: dependents that were locked before and are unlocked now. Drives the
    /// "you unlocked X" moment after a learner clears a node.
    func unlocked(by justMastered: String, mastered: Set<String>) -> [SkillNode] {
        var before = mastered
        before.remove(justMastered)
        let after = mastered.union([justMastered])
        return dependents(of: justMastered).filter {
            !after.contains($0.id) &&
            !isUnlocked($0.id, mastered: before) &&
            isUnlocked($0.id, mastered: after)
        }
    }

    /// The cumulative review pool: every skill the learner has mastered that
    /// supports the current frontier (i.e. is an ancestor of some frontier node),
    /// plus the mastered frontier-adjacent skills themselves. This is the "heavy
    /// mixed cumulative review" half of the spiral; a scheduler samples from it
    /// weighted by how stale / shaky each node's mastery is.
    func reviewPool(mastered: Set<String>) -> [SkillNode] {
        let front = frontier(mastered: mastered)
        var support = Set<String>()
        for f in front {
            for a in ancestors(of: f.id) where mastered.contains(a.id) {
                support.insert(a.id)
            }
        }
        // If there's no frontier yet (e.g. nothing mastered, or everything
        // mastered), fall back to all mastered nodes so review never goes empty.
        if support.isEmpty { support = mastered }
        return nodes.filter { support.contains($0.id) }
    }
}

extension KnowledgeGraph {
    /// The shipped MVP curriculum: the Algebra Spine, a CAS-strong ladder where
    /// every node is answer-generable AND gradable by the difference-to-zero
    /// oracle against the tree-shaken shen-cas slice. The spine runs
    ///   rationals -> linear equations -> systems -> inequalities
    ///             -> polynomials -> factoring -> quadratics.
    static let mvp = KnowledgeGraph(nodes: [

        SkillNode(
            id: "alg-int-arith",
            name: "Integer arithmetic & order of operations (PEMDAS)",
            prerequisites: [],
            casOps: ["reduce", "Plus", "Times", "Minus", "Power", "parser-precedence"]),

        SkillNode(
            id: "alg-rational-arith",
            name: "Exact rational arithmetic (fraction +,-,*,/, lowest terms)",
            prerequisites: ["alg-int-arith"],
            casOps: ["reduce", "Plus", "Minus", "Times", "Divide", "make-rat", "Together"]),

        SkillNode(
            id: "alg-linear-expr",
            name: "Simplify linear expressions (combine like terms, distribute)",
            prerequisites: ["alg-rational-arith"],
            casOps: ["reduce", "Simplify", "Expand", "Plus", "Times"]),

        SkillNode(
            id: "alg-eval-substitute",
            name: "Evaluate expressions at a value (substitution)",
            prerequisites: ["alg-linear-expr"],
            casOps: ["reduce", "Plus", "Times", "Power"]),

        SkillNode(
            id: "alg-linear-eq-1step",
            name: "One- and two-step linear equations in one variable",
            prerequisites: ["alg-eval-substitute"],
            casOps: ["reduce", "Solve", "Plus", "Times"]),

        SkillNode(
            id: "alg-linear-eq-multistep",
            name: "Multi-step linear equations (variables on both sides, distribution)",
            prerequisites: ["alg-linear-eq-1step"],
            casOps: ["reduce", "Solve", "Expand", "Simplify", "Plus", "Times"]),

        SkillNode(
            id: "alg-linear-systems-2x2",
            name: "Systems of two linear equations in two variables",
            prerequisites: ["alg-linear-eq-multistep"],
            casOps: ["reduce", "Solve", "Plus", "Times"]),

        SkillNode(
            id: "alg-linear-inequality",
            name: "Linear inequalities in one variable (solve & sign)",
            prerequisites: ["alg-linear-eq-multistep"],
            casOps: ["reduce", "Solve", "Positive", "Plus", "Times"]),

        SkillNode(
            id: "alg-poly-arith",
            name: "Add, subtract, and multiply polynomials",
            prerequisites: ["alg-linear-expr"],
            casOps: ["reduce", "Expand", "Simplify", "Plus", "Times", "Power"]),

        SkillNode(
            id: "alg-poly-special-products",
            name: "Special products ((a+b)^2, (a+b)(a-b), (a+b)^3)",
            prerequisites: ["alg-poly-arith"],
            casOps: ["reduce", "Expand", "Simplify", "Power", "Times", "Plus"]),

        SkillNode(
            id: "alg-gcf-factor",
            name: "Factor out the greatest common factor / polynomial GCD",
            prerequisites: ["alg-poly-arith"],
            casOps: ["reduce", "Factor", "PolynomialGCD", "Expand"]),

        SkillNode(
            id: "alg-factor-quadratic",
            name: "Factor quadratic and factorable polynomial expressions",
            prerequisites: ["alg-gcf-factor", "alg-poly-special-products"],
            casOps: ["reduce", "Factor", "Expand", "Simplify"]),

        SkillNode(
            id: "alg-quadratic-solve",
            name: "Solve quadratic equations (factoring & quadratic formula)",
            prerequisites: ["alg-factor-quadratic", "alg-linear-eq-1step"],
            casOps: ["reduce", "Solve", "Factor", "Power", "Sqrt"]),
    ])
}
