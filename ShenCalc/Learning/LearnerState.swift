import Foundation

/// The mutable half of the learning model: everything about ONE learner that the
/// authored knowledge graph (the immutable half) does not know.
///
/// Two facts drive the data shape:
///   1. `attempts` is the **source of truth** — an append-only log of every graded
///      answer. Per-node `NodeState` (the FSRS-6 memory in `Mastery.swift`) is a
///      *fold* over that log, kept live so the scheduler reads mastery cheaply
///      without replaying history. Because the log is retained, a future
///      memory-model change can be re-derived by replaying `attempts`.
///   2. The spiral scheduler constantly reads "the memory state for node N", so
///      states are keyed by `NodeID` for O(1) upsert/lookup.
///
/// Persistence is Codable to a single JSON file in the app's Documents directory,
/// written atomically so a crash mid-session can't truncate the store. The object
/// is the natural unit for a future iCloud-document / CloudKit sync.
final class LearnerState: Codable {

    /// App-level identity. Stable across sessions; the key a sync layer merges on.
    let learnerID: UUID

    var displayName: String

    /// Which graph version this state was built against, so a future graph bump can
    /// migrate/re-gate rather than silently mismatching node ids.
    var graphVersion: String

    let createdAt: Date

    /// Whether the learner has completed the one-time placement probe. Until then,
    /// the scheduler emits placement sessions instead of normal ones, and there is
    /// no telemetry to schedule against. Set once by `completePlacement`.
    var placed: Bool

    // ── Streaks ──────────────────────────────────────────────────────────────

    /// Consecutive calendar days with at least one completed session.
    var dailyStreak: Int

    /// Start-of-day of the most recent session, for streak continuation/reset.
    var lastSessionDay: Date?

    // ── Per-learner progress ────────────────────────────────────────────────

    /// FSRS memory state per skill node, keyed by `NodeID`. Only nodes the learner
    /// has touched (or had seeded by placement) appear; absence ⇒ a never-attempted
    /// prior (`NodeState.prior`).
    var states: [NodeID: NodeState]

    /// Append-only history of graded answers, oldest first.
    var attempts: [AttemptRecord]

    init(
        learnerID: UUID = UUID(),
        displayName: String = "",
        graphVersion: String = "",
        createdAt: Date = Date(),
        placed: Bool = false,
        dailyStreak: Int = 0,
        lastSessionDay: Date? = nil,
        states: [NodeID: NodeState] = [:],
        attempts: [AttemptRecord] = []
    ) {
        self.learnerID = learnerID
        self.displayName = displayName
        self.graphVersion = graphVersion
        self.createdAt = createdAt
        self.placed = placed
        self.dailyStreak = dailyStreak
        self.lastSessionDay = lastSessionDay
        self.states = states
        self.attempts = attempts
    }

    // ── Memory-state access ───────────────────────────────────────────────────

    /// The memory state for a node, falling back to a never-attempted prior. Read
    /// path for the scheduler — never mutates the store.
    func state(_ nodeID: NodeID) -> NodeState {
        states[nodeID] ?? .prior(nodeID)
    }

    /// Continuous mastery scalar in 0…1 for a node (0 for untouched).
    func score(forNode nodeID: NodeID, now: Date = Date()) -> Double {
        states[nodeID]?.mastery(now: now) ?? 0
    }

    /// Whether the learner has demonstrated a node well enough to unlock dependents
    /// (provisional, decay-independent — see `NodeState.learnedEnough`).
    func hasLearned(_ nodeID: NodeID, now: Date = Date()) -> Bool {
        states[nodeID]?.learnedEnough(now: now) ?? false
    }

    // ── Recording attempts ───────────────────────────────────────────────────

    /// Append a graded attempt and fold it into the node's FSRS state. This is the
    /// single mutation point that keeps the log and the derived state in step.
    ///
    /// `expectedTime` is the generator's calibrated solve time, used to derive the
    /// FSRS grade from timing; `now` is injectable for testable streak math.
    func record(_ attempt: AttemptRecord,
                expectedTime: TimeInterval = 0,
                now: Date = Date()) {
        attempts.append(attempt)

        let grade = Grade.from(attempt.signal, expectedTime: expectedTime)
        var s = states[attempt.nodeID] ?? .prior(attempt.nodeID)
        s.applyReview(grade: grade, now: attempt.timestamp)
        states[attempt.nodeID] = s

        updateDailyStreak(sessionAt: now)
    }

    // ── Placement ──────────────────────────────────────────────────────────────

    /// Finish the one-time placement probe. For each node the learner answered
    /// correctly we seed it AND its transitive prerequisites as provisionally
    /// learned — "if you can do this, you can do what it's built on" — so the
    /// frontier lands near the learner's true level instead of at grade zero. This
    /// is what keeps placement O(probes) rather than O(V). Idempotent: sets
    /// `placed = true` exactly once.
    func completePlacement(correctNodes: [NodeID],
                           graph: KnowledgeGraph,
                           now: Date = Date()) {
        var toSeed = Set<NodeID>()
        for id in correctNodes {
            toSeed.insert(id)
            for ancestor in graph.ancestors(of: id) { toSeed.insert(ancestor.id) }
        }
        for id in toSeed where states[id] == nil || states[id]?.isTouched == false {
            states[id] = LearnerState.seeded(id, now: now)
        }
        placed = true
    }

    /// A presumed-known seed state: one clean "good" rep as of `now`, so the node
    /// reads as provisionally learned (unlocks dependents) but still earns its
    /// durable stability through real spaced review.
    private static func seeded(_ id: NodeID, now: Date) -> NodeState {
        var s = NodeState.prior(id)
        s.applyReview(grade: .good, now: now)
        return s
    }

    // ── Scheduler-facing queries ───────────────────────────────────────────────

    /// Attempts within the last `days`, newest first — for analytics / dashboards.
    func recentAttempts(days: Int, now: Date = Date()) -> [AttemptRecord] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return attempts
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }
    }

    // ── Streak bookkeeping ───────────────────────────────────────────────────

    /// Advance the daily streak based on the calendar gap since `lastSessionDay`:
    /// same day ⇒ unchanged, next day ⇒ +1, any larger gap ⇒ reset to 1.
    private func updateDailyStreak(sessionAt now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let last = lastSessionDay else {
            dailyStreak = 1
            lastSessionDay = today
            return
        }
        let lastDay = calendar.startOfDay(for: last)
        let gap = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
        switch gap {
        case 0:  break                       // already counted today
        case 1:  dailyStreak += 1            // consecutive day
        default: dailyStreak = 1             // missed a day (or clock moved back) ⇒ restart
        }
        lastSessionDay = today
    }

    // ── Codable ──────────────────────────────────────────────────────────────
    // Explicit keys keep the on-disk JSON stable if properties are reordered or a
    // future sync layer needs to reason about the wire format.

    private enum CodingKeys: String, CodingKey {
        case learnerID, displayName, graphVersion, createdAt, placed
        case dailyStreak, lastSessionDay, states, attempts
    }
}

// MARK: - Persistence

extension LearnerState {

    /// Errors distinct enough to surface a useful message rather than a generic
    /// decode failure (e.g. "store is corrupt" vs. "no Documents directory").
    enum PersistenceError: Error {
        case noDocumentsDirectory
        case corruptStore(underlying: Error)
    }

    /// Default on-disk filename in the Documents directory.
    static let defaultFileName = "LearnerState.json"

    /// Resolve the store URL in the app's Documents directory. Documents (not
    /// Caches/tmp) because this is user progress that must survive eviction and is
    /// the directory iCloud document sync would later mirror.
    static func storeURL(
        fileName: String = defaultFileName,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PersistenceError.noDocumentsDirectory
        }
        return docs.appendingPathComponent(fileName)
    }

    /// Load the persisted learner, or `nil` if no store exists yet (first launch).
    /// A present-but-undecodable store throws `corruptStore` rather than silently
    /// discarding progress.
    static func load(
        fileName: String = defaultFileName,
        fileManager: FileManager = .default
    ) throws -> LearnerState? {
        let url = try storeURL(fileName: fileName, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(LearnerState.self, from: data)
        } catch {
            throw PersistenceError.corruptStore(underlying: error)
        }
    }

    /// Load the persisted learner or create-and-persist a fresh one on first launch.
    static func loadOrCreate(
        displayName: String = "",
        graphVersion: String = "",
        fileName: String = defaultFileName,
        fileManager: FileManager = .default
    ) throws -> LearnerState {
        if let existing = try load(fileName: fileName, fileManager: fileManager) {
            return existing
        }
        let fresh = LearnerState(displayName: displayName, graphVersion: graphVersion)
        try fresh.save(fileName: fileName, fileManager: fileManager)
        return fresh
    }

    /// Persist atomically. `.atomic` writes to a temp file then renames, so a crash
    /// never leaves a half-written store. Callers should `save()` after each
    /// recorded attempt (the log is the source of truth).
    func save(
        fileName: String = LearnerState.defaultFileName,
        fileManager: FileManager = .default
    ) throws {
        let url = try LearnerState.storeURL(fileName: fileName, fileManager: fileManager)
        let data = try Self.encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the persisted store (e.g. a "reset progress" action). No-op if absent.
    static func deleteStore(
        fileName: String = defaultFileName,
        fileManager: FileManager = .default
    ) throws {
        let url = try storeURL(fileName: fileName, fileManager: fileManager)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // Shared coders configured for stable, debuggable JSON.
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
