import Foundation
// MLX needs Metal, so it is device-only. Even though the package links for the
// simulator, exclude this file there (the model can't run, and the macros don't
// expand) so simulator builds stay clean for CAS testing.
#if canImport(MLXLMCommon) && !targetEnvironment(simulator)
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

/// On-device interpreter: an MLX-hosted model translates English (or a photo of
/// math) into shen-cas's bracket syntax. The model only parses intent; the CAS
/// does the math, so a wrong answer is impossible — at worst the model emits
/// syntax the CAS rejects.
///
/// This is now a thin adapter over `MLXProvider` (the generic `LLMProvider` in
/// OnDeviceProvider.swift): it builds the CAS tool-call transcript, delegates the
/// completion to the shared provider, and runs the reply through `CASTools.parse`.
/// One MLX session implementation, two front doors — the `MathInterpreter` seam
/// (here) and the `LLMProvider` seam (for `VerifiedTutor`).
@MainActor
final class MLXInterpreter: ObservableObject, MathInterpreter {
    @Published var status: String = "idle"

    let textModelId: String
    let visionModelId: String

    private let provider: MLXProvider

    init(textModelId: String = "mlx-community/gemma-3-1b-it-qat-4bit",
         visionModelId: String = "mlx-community/gemma-4-e4b-it-4bit") {
        self.textModelId = textModelId
        self.visionModelId = visionModelId
        self.provider = MLXProvider(textModelId: textModelId, visionModelId: visionModelId)
    }

    var requiresModel: Bool { true }

    /// Tool-call menu + grammar, generated from the shared CAS tool registry so
    /// the model always knows every operation the CAS can actually evaluate.
    private var systemPrompt: String { CASTools.systemPrompt }

    func toCAS(text: String, imageData: Data?) async throws -> String {
        status = provider.status
        let reply = try await provider.complete(
            [.system(systemPrompt), .user(text, image: imageData)],
            GenerationOptions(maxTokens: 64))
        status = provider.status
        return CASTools.parse(reply)
    }
}
#endif
