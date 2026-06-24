import Foundation
import SwiftUI

// MARK: - Generator registry

/// Resolves a `NodeID` to the parametric `ProblemGenerator` that authors its
/// problems. The session depends on the `ProblemGenerator` *protocol*, never on a
/// concrete generator type — concrete generators (written in parallel under
/// `Learning/Generators/`) register themselves here, so adding a skill never
/// touches the session loop.
///
/// Keyed by `skill` (the generator's own declared `NodeID`); last registration for
/// a skill wins, which keeps overriding a generator in tests trivial.
struct GeneratorRegistry {
    private var byID: [NodeID: ProblemGenerator]

    init(_ generators: [ProblemGenerator] = []) {
        byID = Dictionary(generators.map { ($0.skill, $0) },
                          uniquingKeysWith: { _, last in last })
    }

    /// The generator for `skill`, or `nil` if none is registered yet.
    func generator(for skill: NodeID) -> ProblemGenerator? { byID[skill] }

    /// Register (or replace) a generator under its declared `skill`.
    mutating func register(_ generator: ProblemGenerator) {
        byID[generator.skill] = generator
    }

    var registeredSkills: [NodeID] { Array(byID.keys) }

    /// The default registry wired to every concrete generator the app ships — one
    /// per MVP skill node (see `Learning/Generators/`). Each conforms to
    /// `ProblemGenerator`; the session only ever talks to the protocol, so swapping
    /// or adding a generator here is the single touch-point.
    ///
    /// TODO: keep this list in sync with `KnowledgeGraph.mvp` as new skill nodes (and
    /// their generators) land — `start()` silently skips a slot whose skill has no
    /// registered generator, so a gap degrades gracefully rather than crashing.
    static let `default` = GeneratorRegistry([
        IntArithGenerator(),                    // alg-int-arith
        RationalArithGenerator(),               // alg-rational-arith
        LinearExprGenerator(),                  // alg-linear-expr
        EvalSubstituteGenerator(),              // alg-eval-substitute
        LinearEquationOneStepGenerator(),       // alg-linear-eq-1step
        LinearEquationMultiStepGenerator(),     // alg-linear-eq-multistep
        PolyArithGenerator(),                   // alg-poly-arith
        ExpandSpecialProductGenerator(),        // alg-poly-special-products
        LinearSystem2x2Generator(),             // alg-linear-systems-2x2
        LinearInequalityGenerator(),            // alg-linear-inequality
        GCFFactorGenerator(),                   // alg-gcf-factor
        FactorQuadraticGenerator(),             // alg-factor-quadratic
        QuadraticSolveGenerator(),              // alg-quadratic-solve
    ])
}

// MARK: - Session phase (drives the UI)

/// What the runner view should be showing. A plain enum so the view switches on it
/// without reaching into the view-model's internals.
enum SessionPhase: Equatable {
    /// Building the session / generating the first problem.
    case loading
    /// A problem is on screen awaiting input.
    case presenting
    /// The current answer was graded; `result` carries the feedback to show before
    /// the learner advances.
    case graded(GradeResult.Verdict)
    /// Every slot in the session is done.
    case finished
    /// Something went wrong (no generator for a slot, engine error producing the
    /// very first problem, etc.) — `message` is user-facing.
    case failed(String)

    static func == (a: SessionPhase, b: SessionPhase) -> Bool {
        switch (a, b) {
        case (.loading, .loading), (.presenting, .presenting),
             (.finished, .finished):
            return true
        case let (.graded(x), .graded(y)): return x == y
        case let (.failed(x), .failed(y)): return x == y
        default: return false
        }
    }
}

// MARK: - The session view-model

/// The practice-session loop, as an observable view-model.
///
/// Lifecycle of one session:
///   1. `start()` asks `SpiralScheduler.buildSession(graph:learner:now:)` for the
///      ordered `[ProblemSlot]` (remediation → throttled new frontier material →
///      heavy cumulative review, interleaved). The scheduler is the *only* thing
///      that decides ordering and mix; this loop just walks its output.
///   2. For each slot it resolves a `ProblemGenerator` from the registry, picks a
///      difficulty band from the learner's mastery of that node, and generates a
///      concrete `ProblemInstance`.
///   3. It presents the prompt, accepts input, and grades via `CASClient`/`Grader`.
///   4. From the graded outcome plus tracked timing/tries it builds an
///      `AttemptSignal`, which `LearnerState.record` (through `LearnerStore.append`)
///      turns into a derived `Grade` and folds into FSRS — then flushes.
///   5. It surfaces any `unlocked(by:)` "you unlocked X" moments after a correct
///      mastery-credit answer, then advances to the next slot.
///
/// `@MainActor` because it owns the persistence store and publishes UI state.
@MainActor
final class LearningSession: ObservableObject {

    // MARK: Published UI state

    @Published private(set) var phase: SessionPhase = .loading
    /// The problem currently on screen (nil while loading / finished).
    @Published private(set) var current: ProblemInstance?
    /// The learner's in-progress typed answer; bound to the input field.
    @Published var input: String = ""
    /// The feedback for the most recently graded answer (nil until first grade).
    @Published private(set) var lastResult: GradeResult?
    /// Skills that just became available, for a "you unlocked X" banner. Cleared on
    /// advance.
    @Published private(set) var justUnlocked: [SkillNode] = []
    /// 1-based index of the current slot, for a progress indicator.
    @Published private(set) var slotNumber: Int = 0
    /// Total slots in the session.
    @Published private(set) var slotCount: Int = 0
    /// Running count of mastery-credit (correct) answers this session.
    @Published private(set) var correctCount: Int = 0

    // MARK: Collaborators

    private let graph: KnowledgeGraph
    private let store: LearnerStore
    private let cas: CASClient
    private let grader: Grader
    private let registry: GeneratorRegistry

    // MARK: Loop state

    private var slots: [ProblemSlot] = []
    private var slotIndex = 0
    /// Wall-clock start of the *current* presentation, for elapsed timing.
    private var presentedAt: Date = .distantPast
    /// Submissions on the current problem (1 = first try). Reset per slot.
    private var triesOnCurrent = 0
    /// Hints revealed on the current problem. Reset per slot. (Hint UI is a later
    /// part; tracked here so the FSRS grade already reflects assistance.)
    private var hintsOnCurrent = 0
    /// Seed counter so each generated item is reproducible yet distinct.
    private var rngCounter: UInt64 = 0

    /// `learner` is the live model the store owns; exposed read-only for the
    /// progress map and headers.
    var learner: LearnerState { store.learner }

    init(graph: KnowledgeGraph = .mvp,
         store: LearnerStore,
         cas: CASClient,
         grader: Grader = CASGrader(),
         registry: GeneratorRegistry = .default) {
        self.graph = graph
        self.store = store
        self.cas = cas
        self.grader = grader
        self.registry = registry
    }

    // MARK: - Session lifecycle

    /// Build the session and present its first problem. Safe to call once per
    /// session instance; re-calling rebuilds from the current learner state.
    func start(now: Date = Date(), size: Int = SpiralScheduler.defaultSize) async {
        phase = .loading
        slots = SpiralScheduler.buildSession(graph: graph, learner: learner,
                                             now: now, size: size)
        slotIndex = 0
        slotCount = slots.count
        correctCount = 0
        guard !slots.isEmpty else { phase = .finished; return }
        await presentCurrentSlot()
    }

    /// Generate and present the problem for the slot at `slotIndex`. Skips slots
    /// whose generator is missing or whose generation fails after a few retries, so
    /// a single unimplemented skill can't wedge the whole session.
    private func presentCurrentSlot() async {
        input = ""
        lastResult = nil
        justUnlocked = []
        triesOnCurrent = 0
        hintsOnCurrent = 0

        while slotIndex < slots.count {
            let slot = slots[slotIndex]
            slotNumber = slotIndex + 1

            guard let generator = registry.generator(for: slot.node) else {
                // No generator registered for this skill yet — skip rather than fail
                // the session. (Generators land incrementally under Generators/.)
                slotIndex += 1
                continue
            }

            let difficulty = difficulty(for: slot)
            if let instance = await generate(generator, difficulty: difficulty) {
                current = instance
                presentedAt = Date()
                phase = .presenting
                return
            }
            // Generation kept returning degenerate draws — move on.
            slotIndex += 1
        }

        // Ran off the end skipping unrunnable slots.
        current = nil
        phase = .finished
    }

    /// Try a generator up to a few times (it may return nil on a degenerate draw),
    /// each with a fresh deterministic seed so items are reproducible but varied.
    private func generate(_ generator: ProblemGenerator,
                          difficulty: Difficulty,
                          attempts: Int = 4) async -> ProblemInstance? {
        for _ in 0..<attempts {
            rngCounter &+= 1
            var rng = SeededRNG(seed: seed(for: generator.skill, salt: rngCounter))
            if let instance = await generator.generate(difficulty: difficulty,
                                                       using: &rng, cas: cas) {
                return instance
            }
        }
        return nil
    }

    // MARK: - Grading & recording

    /// Grade the current `input` against the current problem, fold the outcome into
    /// the learner model, and move the phase to `.graded`. A `.malformed` verdict is
    /// a typo, not a wrong answer: it does NOT burn a mastery attempt or record an
    /// `AttemptRecord` — the learner just tries again.
    func submit(now: Date = Date()) async {
        guard let instance = current, case .presenting = phase else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        triesOnCurrent += 1
        let result = await grader.grade(trimmed, for: instance, cas: cas)
        lastResult = result

        // A malformed/unparseable input is a typo — let the learner retry without
        // recording an attempt or advancing.
        if result.verdict == .malformed {
            phase = .presenting
            return
        }

        let elapsed = max(0, now.timeIntervalSince(presentedAt))
        let signal = AttemptSignal(correct: result.isMasteryCredit,
                                   elapsed: elapsed,
                                   hintsUsed: hintsOnCurrent,
                                   tries: triesOnCurrent,
                                   at: now)

        // Capture the prior mastered set so we can compute newly-unlocked skills
        // *after* recording (only meaningful on a correct mastery-credit answer).
        let masteredBefore = masteredSet(now: now)

        let record = AttemptRecord(nodeID: instance.skill,
                                   correct: signal.correct,
                                   elapsed: signal.elapsed,
                                   hintsUsed: signal.hintsUsed,
                                   tries: signal.tries,
                                   timestamp: now)
        do {
            try store.append(record, expectedTime: expectedTime(for: instance), now: now)
        } catch {
            phase = .failed("Couldn't save your progress: \(error.localizedDescription)")
            return
        }

        if result.isMasteryCredit {
            correctCount += 1
            justUnlocked = newlyUnlocked(node: instance.skill,
                                         masteredBefore: masteredBefore, now: now)
        }
        phase = .graded(result.verdict)
    }

    /// Reveal the next worked step / hint for the current problem (increments the
    /// assistance counter so the derived FSRS grade reflects it). Returns the steps
    /// available to show; empty until the trace FFI ships.
    @discardableResult
    func requestHint() -> [Step] {
        hintsOnCurrent += 1
        return current?.steps ?? []
    }

    /// Advance to the next slot after a graded answer. If the answer was wrong, the
    /// scheduler's remediation will resurface the skill in a future session; within
    /// this session we always move forward to keep momentum.
    func advance() async {
        guard case .graded = phase else { return }
        slotIndex += 1
        if slotIndex >= slots.count {
            current = nil
            phase = .finished
            return
        }
        await presentCurrentSlot()
    }

    // MARK: - Placement

    /// Finish a placement session: nodes answered correctly (gathered by the runner
    /// across the placement slots) seed the learner, after which normal scheduling
    /// begins. Flushes through the store.
    func completePlacement(correctNodes: [NodeID], now: Date = Date()) {
        try? store.completePlacement(correctNodes: correctNodes, graph: graph, now: now)
    }

    /// Whether the current session is a placement (calibration) session.
    var isPlacement: Bool {
        slots.contains { $0.intent == .placement }
    }

    // MARK: - Difficulty selection

    /// Pick a difficulty band for a slot from the learner's mastery of its node and
    /// the slot's intent. Remediation drops to the gentlest band (shore up the gap),
    /// new material starts gently, and review scales the band up with mastery so a
    /// solid skill gets a harder rep.
    private func difficulty(for slot: ProblemSlot) -> Difficulty {
        switch slot.intent {
        case .placement:   return .standard
        case .remediation: return .introductory
        case .new:         return .introductory
        case .review:
            let m = learner.score(forNode: slot.node)
            switch m {
            case ..<0.4:  return .introductory
            case ..<0.7:  return .standard
            case ..<0.9:  return .advanced
            default:      return .challenge
            }
        }
    }

    // MARK: - Unlock detection

    /// The set of node ids the learner has *durably* mastered as of `now`. Used to
    /// drive the topology-only `KnowledgeGraph.unlocked(by:)` query.
    private func masteredSet(now: Date) -> Set<NodeID> {
        Set(graph.nodes.map(\.id).filter { learner.state($0).isMastered(now: now) })
    }

    /// Skills that became available because `node` just crossed into the mastered
    /// set. Compares the post-record mastered set against the pre-record one through
    /// the graph's topology query.
    private func newlyUnlocked(node: NodeID,
                               masteredBefore: Set<NodeID>,
                               now: Date) -> [SkillNode] {
        let after = masteredSet(now: now)
        // Only a node that *crossed* into mastered this attempt can unlock anything.
        guard after.contains(node), !masteredBefore.contains(node) else { return [] }
        return graph.unlocked(by: node, mastered: after)
    }

    // MARK: - Per-node expected solve time

    /// Calibrated expected solve time (seconds) for a node, used to derive the FSRS
    /// grade from timing. A coarse depth-based heuristic until per-node calibration
    /// data exists: deeper skills are expected to take longer.
    private func expectedTime(for instance: ProblemInstance) -> TimeInterval {
        let base: TimeInterval = 20
        let perDepth: TimeInterval = 8
        return base + perDepth * TimeInterval(graph.depth(of: instance.skill))
    }

    // MARK: - Deterministic seeding

    /// A stable-but-distinct seed per (skill, draw): hashes the skill id with a
    /// salt so regenerating the same slot yields a fresh-yet-reproducible item.
    private func seed(for skill: NodeID, salt: UInt64) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325            // FNV-1a offset basis
        for byte in skill.utf8 {
            h = (h ^ UInt64(byte)) &* 0x100000001B3    // FNV-1a prime
        }
        return h ^ (salt &* 0x9E3779B97F4A7C15)
    }
}
