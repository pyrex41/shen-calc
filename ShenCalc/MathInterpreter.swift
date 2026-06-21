import Foundation

/// Translates fuzzy user input (English, or a photo of math) into shen-cas's
/// formal bracket syntax (e.g. "D[Sin[x], x]"). The CAS then does the actual
/// math, so the interpreter never has to be correct about *values* — only about
/// intent. Phase 2 plugs an on-device Gemma model in here (see MLXInterpreter).
protocol MathInterpreter {
    /// Whether this interpreter needs the heavyweight model loaded.
    var requiresModel: Bool { get }
    /// Translate `text` (and optional image data) into a CAS expression string.
    func toCAS(text: String, imageData: Data?) async throws -> String
}

/// Phase-1 interpreter: the user types shen-cas syntax directly, so input is
/// passed through unchanged. Lets the app work fully without any model.
struct PassthroughInterpreter: MathInterpreter {
    var requiresModel: Bool { false }
    func toCAS(text: String, imageData: Data?) async throws -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An on-device text model the user can pick between at runtime. Because the CAS
/// validates every model output, trying a smaller/faster model is low-risk — the
/// worst case is rejected syntax, never a wrong answer — so we expose the choice
/// rather than hard-coding one. Defined outside the MLX `#if` so the picker still
/// renders (and persists a choice) on the simulator, where the engine can't run.
struct TextModel: Identifiable, Hashable {
    let id: String      // Hugging Face repo id (mlx-community/…), passed to the loader
    let name: String    // short label for the picker
    let size: String    // approximate on-disk download / memory footprint

    /// Smallest → largest. All are 4-bit and fit a free account (no memory
    /// entitlement); the smaller two trade accuracy for a much lighter download.
    static let all: [TextModel] = [
        TextModel(id: "mlx-community/gemma-3-270m-it-4bit",   name: "Gemma 3 270m", size: "~0.2 GB"),
        TextModel(id: "mlx-community/Qwen3-0.6B-4bit",        name: "Qwen3 0.6B",   size: "~0.4 GB"),
        TextModel(id: "mlx-community/gemma-3-1b-it-qat-4bit", name: "Gemma 3 1B",   size: "~0.7 GB"),
    ]

    /// Default to the lighter Qwen3-0.6B: ~2× faster than gemma-3-1b on Apple
    /// silicon and the strongest tool-grammar follower for its size. The picker
    /// still offers the smaller gemma-3-270m and the heavier gemma-3-1b.
    static let defaultId = "mlx-community/Qwen3-0.6B-4bit"

    static func named(_ id: String) -> TextModel {
        all.first { $0.id == id } ?? all.first { $0.id == defaultId } ?? all[2]
    }
}

/// Resolves the natural-language / image interpreter. Present only when the
/// MLX package is linked (Phase 2) AND on a device that can run it.
enum NLEngine {
    static var available: Bool {
        #if canImport(MLXLMCommon) && !targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    static func make(textModelId: String = TextModel.defaultId) -> MathInterpreter? {
        #if canImport(MLXLMCommon) && !targetEnvironment(simulator)
        return MLXInterpreter(textModelId: textModelId)
        #else
        return nil
        #endif
    }
}
