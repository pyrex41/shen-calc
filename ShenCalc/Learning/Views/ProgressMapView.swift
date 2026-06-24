import SwiftUI

/// A read-only map of the curriculum DAG, colored by the learner's progress.
///
/// Each node is classified as **mastered**, **frontier** (unlocked, in progress),
/// or **locked**, and shows a mastery bar from `NodeState.mastery`. Classification
/// uses the topology-only `KnowledgeGraph` queries fed the learner's *durably
/// mastered* set, matching how `LearningSession` reports `unlocked(by:)` moments —
/// so "you unlocked X" in the runner and X turning into a frontier node here agree.
///
/// Laid out by graph depth (each depth band is a row of cards in topo order), which
/// gives the prerequisite ladder its natural top-to-bottom reading without a full
/// graph-drawing engine.
struct ProgressMapView: View {

    let graph: KnowledgeGraph
    /// The live learner model (owned by `LearnerStore`); read-only here.
    let learner: LearnerState

    private let accent = Color(red: 0.45, green: 0.85, blue: 0.72)
    private let background = Color(red: 0.06, green: 0.07, blue: 0.09)

    init(graph: KnowledgeGraph = .mvp, learner: LearnerState) {
        self.graph = graph
        self.learner = learner
    }

    // MARK: - Classification

    private enum Status { case mastered, frontier, locked }

    /// The durably-mastered set, the same input `KnowledgeGraph.frontier(mastered:)`
    /// and `unlocked(by:)` expect.
    private var masteredIDs: Set<String> {
        Set(graph.nodes.map(\.id).filter { learner.state($0).isMastered(now: Date()) })
    }

    private func status(_ node: SkillNode, mastered: Set<String>) -> Status {
        if mastered.contains(node.id) { return .mastered }
        if graph.isUnlocked(node.id, mastered: mastered) { return .frontier }
        return .locked
    }

    // MARK: - Body

    var body: some View {
        let mastered = masteredIDs
        let byDepth = Dictionary(grouping: graph.nodes, by: { graph.depth(of: $0.id) })

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(byDepth.keys.sorted(), id: \.self) { depth in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Level \(depth + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(rowNodes(byDepth[depth] ?? [])) { node in
                            card(node, status: status(node, mastered: mastered))
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(background.ignoresSafeArea())
    }

    /// Nodes within a depth band, in stable topological order.
    private func rowNodes(_ nodes: [SkillNode]) -> [SkillNode] {
        nodes.sorted { graph.topoIndex($0.id) < graph.topoIndex($1.id) }
    }

    // MARK: - Node card

    @ViewBuilder
    private func card(_ node: SkillNode, status: Status) -> some View {
        let m = learner.score(forNode: node.id)
        HStack(spacing: 12) {
            Image(systemName: symbol(status))
                .foregroundStyle(tint(status))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(node.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(status == .locked ? Color.secondary : Color.white)
                    .fixedSize(horizontal: false, vertical: true)
                masteryBar(m, status: status)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint(status).opacity(status == .locked ? 0.05 : 0.12),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func masteryBar(_ m: Double, status: Status) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint(status))
                    .frame(width: max(0, min(1, m)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }

    private func symbol(_ s: Status) -> String {
        switch s {
        case .mastered: return "checkmark.seal.fill"
        case .frontier: return "circle.dashed"
        case .locked:   return "lock.fill"
        }
    }

    private func tint(_ s: Status) -> Color {
        switch s {
        case .mastered: return accent
        case .frontier: return .orange
        case .locked:   return .gray
        }
    }
}
