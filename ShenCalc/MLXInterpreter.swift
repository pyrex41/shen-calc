import Foundation
#if canImport(MLXLMCommon)
import MLXLMCommon
import MLXLLM
import MLXVLM
import MLXHuggingFace          // loadModel(...) + tokenizer loader convenience
import CoreImage

// NOTE ON VERSIONS: mlx-swift-lm's model-loading entry point has been in flux.
// This file targets the package's *documented* ChatSession API:
//
//   let model   = try await loadModel(using: TokenizersLoader(), id: "<hf-id>")
//   let session = ChatSession(model, instructions: systemPrompt)
//   let reply   = try await session.respond(to: prompt, image: .ciImage(ci))
//
// Pin mlx-swift-lm to a RELEASE TAG (not `main`) and, if the loader call differs
// in your version, follow that release's README (the ChatSession + respond shape
// is stable; only the `loadModel(...)` argument list moves). Build to a real
// device — mlx-swift needs Metal and does not run on the simulator.

/// On-device interpreter: an MLX-hosted Gemma model translates English (or a
/// photo of math) into shen-cas's bracket syntax. The model only parses intent;
/// the CAS does the math, so a wrong answer is impossible — at worst the model
/// emits syntax the CAS rejects.
@MainActor
final class MLXInterpreter: ObservableObject, MathInterpreter {
    @Published var status: String = "idle"

    /// MLX-community model repos. Swap in any MLX-converted Gemma 4 build.
    let textModelId: String
    let visionModelId: String

    private var textSession: ChatSession?
    private var visionSession: ChatSession?

    init(textModelId: String = "mlx-community/gemma-3-1b-it-4bit",
         visionModelId: String = "mlx-community/gemma-3-4b-it-4bit") {
        self.textModelId = textModelId
        self.visionModelId = visionModelId
    }

    var requiresModel: Bool { true }

    /// System prompt that pins the model to shen-cas's grammar.
    private var systemPrompt: String {
        """
        You convert math questions into a strict bracket syntax for a computer
        algebra system. Output ONLY the expression — no prose, no explanation,
        no markdown, no equals sign.

        Grammar:
        - numbers and variables as-is: 2, 42, x, y
        - infix arithmetic: a + b, a - b, a * b, a / b, a^b
        - functions in brackets: Sin[x], Cos[x], Exp[x], Log[x], Sqrt[x]
        - derivative of f w.r.t. v: D[f, v]
        - simplification: Simplify[expr]

        Examples:
        "derivative of sin x"        -> D[Sin[x], x]
        "what is two plus three"     -> 2 + 3
        "differentiate x cubed"      -> D[x^3, x]
        "e to the x, differentiated" -> D[Exp[x], x]
        "simplify a plus a"          -> Simplify[a + a]
        """
    }

    func toCAS(text: String, imageData: Data?) async throws -> String {
        if imageData != nil {
            if visionSession == nil {
                status = "loading vision model…"
                let model = try await loadModel(using: TokenizersLoader(), id: visionModelId)
                visionSession = ChatSession(model, instructions: systemPrompt)
                status = "ready"
            }
            guard let session = visionSession else { throw err("vision model unavailable") }
            let prompt = text.isEmpty ? "Convert the math shown in the image." : text
            let reply: String
            if let data = imageData, let ci = CIImage(data: data) {
                reply = try await session.respond(to: prompt, image: .ciImage(ci))
            } else {
                reply = try await session.respond(to: prompt)
            }
            return Self.cleanup(reply)
        } else {
            if textSession == nil {
                status = "loading model…"
                let model = try await loadModel(using: TokenizersLoader(), id: textModelId)
                textSession = ChatSession(model, instructions: systemPrompt)
                status = "ready"
            }
            guard let session = textSession else { throw err("model unavailable") }
            return Self.cleanup(try await session.respond(to: text))
        }
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "MLXInterpreter", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }

    /// Keep only the first non-empty line; strip code fences / stray prose.
    static func cleanup(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "Output:", with: "")
        let line = t.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? t
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
