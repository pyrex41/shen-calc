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

/// Resolves the natural-language / image interpreter. Present only when the
/// MLX package is linked (Phase 2) AND on a device that can run it.
enum NLEngine {
    static var available: Bool {
        #if canImport(MLXLMCommon)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    static func make() -> MathInterpreter? {
        #if canImport(MLXLMCommon)
        return MLXInterpreter()
        #else
        return nil
        #endif
    }
}
