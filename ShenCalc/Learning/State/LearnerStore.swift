import Foundation

/// On-device persistence for one learner's progress.
///
/// `LearnerState` already knows how to encode/decode itself; this type owns the
/// *policy* around that: where the blob lives, when it is flushed, and the
/// append-only discipline that keeps the store re-derivable. The split mirrors the
/// data model's own invariant — `attempts` is the **source of truth** and per-node
/// `NodeState` is a fold over it — so the public surface here is deliberately just
/// `load` / `append` / `save`: callers add graded attempts, the store folds + flushes.
///
/// Storage location: the app's **Application Support** directory (not Documents).
/// This is learner-private derived state, not a user-facing document, and Apple's
/// guidance is that app data the user doesn't directly manage belongs in
/// Application Support. It is still backed up (so progress survives reinstall via
/// device backup) and the JSON shape carries **no device-specific fields**, so the
/// same blob round-trips to a future CloudKit / iCloud-document sync unchanged.
///
/// Concurrency: marked `@MainActor` so the view-model can mutate and flush without
/// data races. Writes are atomic (temp-file-then-rename via `Data.write(.atomic)`),
/// so a crash mid-flush can never truncate the store.
@MainActor
final class LearnerStore {

    /// The live, in-memory learner. Mutations go through `append`/`save` so the log
    /// and its derived `NodeState` fold stay flushed together.
    private(set) var learner: LearnerState

    /// On-disk filename inside Application Support.
    let fileName: String

    private let fileManager: FileManager

    /// Wrap an already-loaded learner (use `loadOrCreate` to read from disk).
    init(learner: LearnerState,
         fileName: String = LearnerStore.defaultFileName,
         fileManager: FileManager = .default) {
        self.learner = learner
        self.fileName = fileName
        self.fileManager = fileManager
    }

    // MARK: - Loading

    /// Default on-disk filename. Distinct from `LearnerState.defaultFileName` only
    /// in intent: this is the Application-Support copy this store manages.
    /// `nonisolated` so it can serve as a default argument from the non-isolated
    /// location/coder helpers below without crossing the actor boundary.
    nonisolated static let defaultFileName = "LearnerState.json"

    /// Load the persisted learner from Application Support, or create-and-flush a
    /// fresh one on first launch. The store is usable immediately either way.
    static func loadOrCreate(displayName: String = "",
                             graphVersion: String = "",
                             fileName: String = defaultFileName,
                             fileManager: FileManager = .default) throws -> LearnerStore {
        let url = try storeURL(fileName: fileName, fileManager: fileManager)
        if fileManager.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let learner = try decoder.decode(LearnerState.self, from: data)
                return LearnerStore(learner: learner, fileName: fileName, fileManager: fileManager)
            } catch {
                throw LearnerState.PersistenceError.corruptStore(underlying: error)
            }
        }
        let fresh = LearnerState(displayName: displayName, graphVersion: graphVersion)
        let store = LearnerStore(learner: fresh, fileName: fileName, fileManager: fileManager)
        try store.save()
        return store
    }

    // MARK: - Appending (the source-of-truth write path)

    /// Append one graded attempt to the log, fold it into the node's FSRS state
    /// (via `LearnerState.record`), and flush atomically. This is the single
    /// mutation entry point the session loop uses — it keeps the append-only log
    /// and its derived `NodeState` in lockstep on disk.
    ///
    /// `expectedTime` is the node's calibrated solve time, used to derive the FSRS
    /// grade from timing; `now` feeds the daily-streak math.
    @discardableResult
    func append(_ attempt: AttemptRecord,
                expectedTime: TimeInterval = 0,
                now: Date = Date()) throws -> AttemptRecord {
        learner.record(attempt, expectedTime: expectedTime, now: now)
        try save()
        return attempt
    }

    /// Record the outcome of the one-time placement probe and flush. Seeds the
    /// correctly-answered nodes plus their transitive prerequisites, then marks the
    /// learner placed so subsequent sessions schedule normally.
    func completePlacement(correctNodes: [NodeID],
                           graph: KnowledgeGraph,
                           now: Date = Date()) throws {
        learner.completePlacement(correctNodes: correctNodes, graph: graph, now: now)
        try save()
    }

    // MARK: - Flushing

    /// Persist the current learner atomically. Callers normally don't call this
    /// directly — `append` / `completePlacement` flush for you — but it's exposed
    /// for explicit checkpoints (e.g. app background).
    func save() throws {
        let url = try LearnerStore.storeURL(fileName: fileName, fileManager: fileManager)
        let data = try LearnerStore.encoder.encode(learner)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the persisted store and reset the in-memory learner to a fresh one
    /// (a "reset progress" action). Re-flushes the empty learner so the on-disk and
    /// in-memory state stay consistent.
    func reset(displayName: String = "", graphVersion: String = "") throws {
        let url = try LearnerStore.storeURL(fileName: fileName, fileManager: fileManager)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        learner = LearnerState(displayName: displayName, graphVersion: graphVersion)
        try save()
    }

    // MARK: - Location

    /// Resolve the store URL in the app's Application Support directory, creating
    /// the directory if it doesn't exist (it isn't guaranteed to on first launch).
    nonisolated static func storeURL(fileName: String = defaultFileName,
                                     fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else {
            throw LearnerState.PersistenceError.noDocumentsDirectory
        }
        if !fileManager.fileExists(atPath: support.path) {
            try fileManager.createDirectory(at: support,
                                            withIntermediateDirectories: true)
        }
        return support.appendingPathComponent(fileName)
    }

    // MARK: - Coders

    // Shared coders configured for stable, debuggable, cloud-portable JSON. Matches
    // `LearnerState`'s own coder config exactly so a blob written by either path is
    // readable by the other.
    nonisolated private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    nonisolated private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
