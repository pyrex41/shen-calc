import Foundation
#if canImport(MLXLMCommon)
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM
import MLXHuggingFace          // #hubDownloader / #huggingFaceTokenizerLoader macros
import HuggingFace             // HubClient (used by the macro expansion)
import Tokenizers              // swift-transformers (used by the macro expansion)
import CoreImage

// VERSION NOTE — verified against mlx-swift-lm 3.31.3. The model-load call is the
// one line that tracks the package version; the ChatSession / respond shape is
// stable. Required Swift packages (add both in Xcode):
//   • https://github.com/ml-explore/mlx-swift-lm   (pin 3.31.3)
//     products: MLXLLM, MLXVLM, MLXLMCommon, MLXHuggingFace
//   • https://github.com/huggingface/swift-transformers (pin 1.3.x)
//     products: Hub, Tokenizers          (provides the HuggingFace/Tokenizers modules)
// If your pinned version's loader differs, copy the load call from the package's
// LLMEval example. Build to a REAL device — mlx-swift needs Metal (no simulator).

/// On-device interpreter: an MLX-hosted Gemma model translates English (or a
/// photo of math) into shen-cas's bracket syntax. The model only parses intent;
/// the CAS does the math, so a wrong answer is impossible — at worst the model
/// emits syntax the CAS rejects.
@MainActor
final class MLXInterpreter: ObservableObject, MathInterpreter {
    @Published var status: String = "idle"

    // MLX-community model repos (download on first use).
    //   text:   gemma-3-1b-it-qat-4bit  (~733 MB) fits a FREE account (no memory
    //           entitlement) on any modern iPhone — best default.
    //   vision: gemma-4-e4b-it-4bit     (~5.2 GB, multimodal) needs a PAID account
    //           + the increased-memory-limit entitlement + an 8 GB iPhone.
    //           For a lighter vision model use mlx-community/gemma-3-4b-it-4bit (~3.4 GB).
    let textModelId: String
    let visionModelId: String

    private var textSession: ChatSession?
    private var visionSession: ChatSession?

    init(textModelId: String = "mlx-community/gemma-3-1b-it-qat-4bit",
         visionModelId: String = "mlx-community/gemma-4-e4b-it-4bit") {
        self.textModelId = textModelId
        self.visionModelId = visionModelId
        // Bound the KV cache so long sessions don't run into the jetsam limit.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
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
                let model = try await loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id: visionModelId)
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
                let model = try await loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id: textModelId)
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
