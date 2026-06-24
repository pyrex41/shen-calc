import Foundation

// MARK: - Gamification: XP, streaks, and skill levels
//
// A thin motivational layer on top of the FSRS mastery model. It deliberately
// owns NONE of the pedagogy: scheduling, unlocking, and mastery decay all live in
// `SpiralScheduler` / `Mastery.swift`. Gamification only TRANSLATES that ground
// truth into rewards a learner sees:
//
//   • XP        — earned per solved problem, scaled by difficulty + a first-try
//                 bonus. A running total + a derived account level.
//   • streak    — the consecutive-day streak `LearnerState` already tracks, surfaced
//                 here with milestone framing (we don't duplicate the day math).
//   • skill levels — Apprentice → Practitioner → Expert → Mastered, derived purely
//                 from `NodeState.mastery(now:)` so the badge can never drift from
//                 the real memory state.
//
// All scoring is PURE functions of inputs (no I/O), so it is unit-testable and the
// store is just a small Codable bag persisted alongside `LearnerState`. The store
// is intentionally minimal — anything derivable from `LearnerState` (streak, skill
// levels) is DERIVED, not stored, so the two can never disagree. Only the XP
// ledger (which is not otherwise reconstructable without expected-time calibration
// at award time) is persisted.
//
// Style follows the rest of Learning/: value structs, `///` doc comments, no
// external deps, no force-unwraps in library code.

// MARK: - XP scoring (pure)

/// XP scoring policy. One namespace so the reward curve is legible and tunable.
enum XPRules {
    /// Base XP for a correct answer at `.introductory`. The difficulty multiplier
    /// scales up from here.
    static let base = 10

    /// Multiplier per `Difficulty` (index by `rawValue`): introductory → challenge.
    /// Harder problems are worth proportionally more, rewarding reach.
    static let difficultyMultiplier: [Double] = [1.0, 1.4, 1.9, 2.5]

    /// Flat fraction of the (post-difficulty) award added when the learner nailed
    /// it on the first try with no hints — the "clean solve" bonus.
    static let firstTryBonus = 0.5

    /// XP needed to clear level L→L+1 grows quadratically so early levels come
    /// fast and later ones feel earned: `threshold(L) = perLevel · L²`.
    static let perLevel = 100

    /// A wrong (but well-formed) attempt still earns a sliver — effort credit, so
    /// a struggling session isn't a total XP shutout. Malformed input earns 0.
    static let effortXP = 2

    /// XP awarded for one graded attempt.
    ///
    /// - `correct`: `base · difficultyMultiplier[d]`, plus `firstTryBonus` of that
    ///   when `cleanFirstTry`. Rounded to the nearest Int.
    /// - not `correct` but `wellFormed`: `effortXP`.
    /// - malformed (`wellFormed == false`): `0` (a typo isn't an attempt).
    static func award(difficulty: Difficulty,
                      correct: Bool,
                      cleanFirstTry: Bool,
                      wellFormed: Bool = true) -> Int {
        guard wellFormed else { return 0 }
        guard correct else { return effortXP }

        let idx = min(max(difficulty.rawValue, 0), difficultyMultiplier.count - 1)
        let scaled = Double(base) * difficultyMultiplier[idx]
        let withBonus = cleanFirstTry ? scaled * (1.0 + firstTryBonus) : scaled
        return Int(withBonus.rounded())
    }

    /// The account level for a cumulative XP total. Inverts the quadratic
    /// threshold: `level = floor( sqrt(totalXP / perLevel) )`, starting at 0.
    static func level(forTotalXP xp: Int) -> Int {
        guard xp > 0 else { return 0 }
        return Int((Double(xp) / Double(perLevel)).squareRoot().rounded(.down))
    }

    /// Total XP required to have REACHED `level` (the floor of that level).
    static func xpThreshold(forLevel level: Int) -> Int {
        guard level > 0 else { return 0 }
        return perLevel * level * level
    }

    /// Progress within the current level as `(earnedIntoLevel, neededForNext)`,
    /// for a progress bar. `neededForNext` is the span of the current level.
    static func levelProgress(totalXP xp: Int) -> (earned: Int, needed: Int) {
        let lvl = level(forTotalXP: xp)
        let floorXP = xpThreshold(forLevel: lvl)
        let nextXP = xpThreshold(forLevel: lvl + 1)
        return (max(0, xp - floorXP), max(1, nextXP - floorXP))
    }
}

// MARK: - Skill levels (derived from mastery)

/// A learner-facing badge for one skill, derived from its continuous mastery
/// scalar. This is presentation only — it never gates progress (that's
/// `learnedEnough` / `isMastered` in `Mastery.swift`).
enum SkillLevel: Int, Codable, CaseIterable, Comparable {
    /// Not yet touched, or touched but still shaky.
    case apprentice = 0
    /// Demonstrated competence; in active rotation.
    case practitioner = 1
    /// Reliably recalled; high mastery scalar.
    case expert = 2
    /// Durable FSRS mastery (decay-aware) — the gold badge.
    case mastered = 3

    static func < (a: SkillLevel, b: SkillLevel) -> Bool { a.rawValue < b.rawValue }

    /// Human label for the UI.
    var title: String {
        switch self {
        case .apprentice:   return "Apprentice"
        case .practitioner: return "Practitioner"
        case .expert:       return "Expert"
        case .mastered:     return "Mastered"
        }
    }
}

/// Thresholds mapping `NodeState.mastery(now:)` to a `SkillLevel`. Kept beside the
/// badge so the mapping is tunable in one place.
enum SkillLevelRules {
    /// Mastery scalar at/above which a touched node is `practitioner`.
    static let practitioner = 0.45
    /// Mastery scalar at/above which a touched node is `expert`.
    static let expert = 0.75

    /// Derive the badge for a node. `mastered` is gated on the DURABLE predicate
    /// (`NodeState.isMastered`) so the gold badge means real, decay-aware mastery —
    /// not just a momentarily high scalar. Below that, the continuous scalar picks
    /// apprentice/practitioner/expert. An untouched node is always `apprentice`.
    static func level(for state: NodeState, now: Date) -> SkillLevel {
        guard state.isTouched else { return .apprentice }
        if state.isMastered(now: now) { return .mastered }
        let m = state.mastery(now: now)
        if m >= expert { return .expert }
        if m >= practitioner { return .practitioner }
        return .apprentice
    }
}

// MARK: - Streak milestones (derived; day math stays in LearnerState)

/// Streak milestones for celebratory framing. The streak COUNT itself is owned by
/// `LearnerState.dailyStreak` (which does the calendar math on `record`); this
/// only decides when to throw confetti.
enum StreakMilestones {
    /// Day counts worth celebrating.
    static let milestones: [Int] = [3, 7, 14, 30, 60, 100, 365]

    /// Whether `streak` exactly hit a milestone (fire a one-time reward).
    static func isMilestone(_ streak: Int) -> Bool { milestones.contains(streak) }

    /// The next milestone strictly above `streak`, or `nil` past the last one.
    static func next(after streak: Int) -> Int? { milestones.first { $0 > streak } }
}

// MARK: - Persisted store

/// The small, persisted gamification bag. Holds only what cannot be re-derived
/// from `LearnerState`: the XP ledger. Streak and skill levels are computed on
/// demand from `LearnerState` so they can never drift.
///
/// Persisted as its own JSON file alongside `LearnerState.json`, mirroring that
/// file's atomic-write + iso8601 conventions.
struct GamificationState: Codable, Equatable {

    /// Lifetime cumulative XP. Append-only in spirit (only grows on award).
    private(set) var totalXP: Int

    /// XP earned today, for a daily-goal ring. Reset by `rollOverDay` when the
    /// calendar day changes.
    private(set) var xpToday: Int

    /// Start-of-day the `xpToday` counter belongs to, so a new day zeroes it.
    private(set) var xpTodayDay: Date?

    /// The highest account level the learner has reached, so a level-up can be
    /// detected even across app launches.
    private(set) var highestLevelSeen: Int

    init(totalXP: Int = 0,
         xpToday: Int = 0,
         xpTodayDay: Date? = nil,
         highestLevelSeen: Int = 0) {
        self.totalXP = totalXP
        self.xpToday = xpToday
        self.xpTodayDay = xpTodayDay
        self.highestLevelSeen = highestLevelSeen
    }

    // MARK: Derived

    /// Current account level from cumulative XP.
    var level: Int { XPRules.level(forTotalXP: totalXP) }

    /// `(earnedIntoLevel, neededForNext)` for a progress bar.
    var levelProgress: (earned: Int, needed: Int) { XPRules.levelProgress(totalXP: totalXP) }

    // MARK: Mutation

    /// Result of awarding XP — what the UI animates.
    struct Award: Equatable {
        let xpGained: Int
        let newTotal: Int
        /// The level if the learner crossed a threshold on this award, else `nil`.
        let leveledUpTo: Int?
    }

    /// Award XP for one graded attempt and roll the daily counter if the day
    /// changed. Returns the `Award` (including any level-up) for UI feedback.
    /// Pure aside from reading `now`; no I/O (caller persists).
    @discardableResult
    mutating func awardXP(difficulty: Difficulty,
                          correct: Bool,
                          cleanFirstTry: Bool,
                          wellFormed: Bool = true,
                          now: Date = Date(),
                          calendar: Calendar = .current) -> Award {
        rollOverDay(now: now, calendar: calendar)

        let gained = XPRules.award(difficulty: difficulty,
                                   correct: correct,
                                   cleanFirstTry: cleanFirstTry,
                                   wellFormed: wellFormed)
        let before = level
        totalXP += gained
        xpToday += gained

        let after = level
        let leveledUpTo: Int? = after > before ? after : nil
        if after > highestLevelSeen { highestLevelSeen = after }

        return Award(xpGained: gained, newTotal: totalXP, leveledUpTo: leveledUpTo)
    }

    /// Zero `xpToday` when the calendar day has advanced since `xpTodayDay`.
    /// Idempotent within a day.
    mutating func rollOverDay(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let day = xpTodayDay else {
            xpTodayDay = today
            return
        }
        if calendar.startOfDay(for: day) != today {
            xpToday = 0
            xpTodayDay = today
        }
    }
}

// MARK: - Derived snapshots from LearnerState (pure read model)

extension GamificationState {

    /// A read-only badge for one skill, combining the persisted-free derivation
    /// from `LearnerState` with the node's name. For a grid/list UI.
    struct SkillBadge: Identifiable {
        let id: NodeID
        let name: String
        let level: SkillLevel
        let mastery: Double
    }

    /// Build skill badges for every node in `graph` from `learner`'s live states.
    /// Pure: derives entirely from `NodeState` + the graph, so badges always match
    /// the real memory model.
    static func skillBadges(graph: KnowledgeGraph,
                            learner: LearnerState,
                            now: Date = Date()) -> [SkillBadge] {
        graph.nodes.map { node in
            let st = learner.state(node.id)
            return SkillBadge(id: node.id,
                              name: node.name,
                              level: SkillLevelRules.level(for: st, now: now),
                              mastery: st.isTouched ? st.mastery(now: now) : 0)
        }
    }

    /// Count of nodes at each `SkillLevel` (for a progress summary). Indexed by the
    /// level's `rawValue`.
    static func levelCounts(graph: KnowledgeGraph,
                            learner: LearnerState,
                            now: Date = Date()) -> [SkillLevel: Int] {
        var counts: [SkillLevel: Int] = [:]
        for l in SkillLevel.allCases { counts[l] = 0 }
        for node in graph.nodes {
            let l = SkillLevelRules.level(for: learner.state(node.id), now: now)
            counts[l, default: 0] += 1
        }
        return counts
    }
}

// MARK: - Persistence (mirrors LearnerState's conventions)

extension GamificationState {

    /// Default on-disk filename, beside `LearnerState.json` in Documents.
    static let defaultFileName = "GamificationState.json"

    /// Load the persisted gamification bag, or `nil` if none exists yet. A
    /// present-but-corrupt store returns `nil` rather than throwing — gamification
    /// is non-critical, so a decode failure resets rewards instead of blocking the
    /// app. (Progress/mastery live in `LearnerState`, which is the strict store.)
    static func load(fileName: String = defaultFileName,
                     fileManager: FileManager = .default) -> GamificationState? {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let url = docs.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(GamificationState.self, from: data)
        else { return nil }
        return state
    }

    /// Load or create a fresh bag. Never throws — a fresh bag is always valid.
    static func loadOrCreate(fileName: String = defaultFileName,
                             fileManager: FileManager = .default) -> GamificationState {
        load(fileName: fileName, fileManager: fileManager) ?? GamificationState()
    }

    /// Persist atomically, mirroring `LearnerState.save`. Callers should save after
    /// awarding XP at the end of a problem.
    func save(fileName: String = defaultFileName,
              fileManager: FileManager = .default) throws {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw LearnerState.PersistenceError.noDocumentsDirectory }
        let url = docs.appendingPathComponent(fileName)
        let data = try GamificationState.encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

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
