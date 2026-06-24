import Foundation

/// On-device `LLMProvider`, backed by an MLX-hosted model. This is the generic
/// chat seam underneath the existing `MLXInterpreter`: it takes a `[ChatMessage]`
/// transcript (instructions + turns, optional image) and returns the model's
/// completion. `MLXInterpreter` becomes a thin adapter over this (it builds a
/// system + user transcript and runs `CASTools.parse` on the reply).
///
/// `isLocal = true`: no network, no API key. The factory prefers it by default.
///
/// On the simulator (or when the MLX package isn't linked) the real
/// implementation is compiled out and `make` returns `nil`, exactly like
/// `NLEngine.make` — callers degrade gracefully.
enum OnDeviceProvider {
    /// Build the device provider for `textModelId`, or `nil` where MLX can't run
    /// (simulator / package not linked). Mirrors `NLEngine.make`.
    @MainActor
    static func make(textModelId: String = TextModel.defaultId) -> LLMProvider? {
        #if canImport(MLXLMCommon) && !targetEnvironment(simulator)
        return MLXProvider(textModelId: textModelId)
        #else
        return nil
        #endif
    }
}

// MARK: - MLX-backed implementation (device-only)

// Gated identically to MLXInterpreter.swift: MLX needs Metal, so it is
// device-only, and the macros don't expand on the simulator.
#if canImport(MLXLMCommon) && !targetEnvironment(simulator)
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM
import MLXHuggingFace          // #hubDownloader / #huggingFaceTokenizerLoader macros
import HuggingFace             // HubClient (used by the macro expansion)
import Tokenizers              // swift-transformers (used by the macro expansion)
import CoreImage

/// The MLX `ChatSession`-backed provider. Lazily loads the model on first use and
/// caches a text session and a vision session separately (image presence selects
/// which). The KV cache is bounded in `init` so long tutoring sessions don't hit
/// the jetsam limit. See MLXInterpreter.swift for the package version notes — the
/// load call is the one line that tracks the package version.
@MainActor
final class MLXProvider: ObservableObject, LLMProvider {
    @Published var status: String = "idle"

    let textModelId: String
    let visionModelId: String

    private var textSession: ChatSession?
    private var visionSession: ChatSession?

    init(textModelId: String = TextModel.defaultId,
         visionModelId: String = "mlx-community/gemma-4-e4b-it-4bit") {
        self.textModelId = textModelId
        self.visionModelId = visionModelId
        // Bound the KV cache so long sessions don't run into the jetsam limit.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
    }

    // MARK: LLMProvider

    var id: String { textModelId }
    var supportsVision: Bool { true }
    var isLocal: Bool { true }

    /// Run one completion. A `ChatSession` carries its own instructions and turn
    /// history, so we map the transcript onto it: the leading `.system` messages
    /// become the session instructions, and the trailing `.user` message is the
    /// prompt. (The tutor builds single-turn transcripts — system + one user — so
    /// this captures every case it needs without a second session per call.)
    ///
    /// `options` is accepted for protocol conformance; the lightweight on-device
    /// models run with the session's own decoding defaults (the CAS guard, not a
    /// token cap, is what bounds correctness here).
    func complete(_ messages: [ChatMessage], _ options: GenerationOptions) async throws -> String {
        _ = options
        let instructions = messages
            .filter { $0.role == .system }
            .map(\.text)
            .joined(separator: "\n\n")
        guard let prompt = messages.last(where: { $0.role == .user }) else {
            throw err("no user message to complete")
        }

        if let data = prompt.image, let ci = CIImage(data: data) {
            let session = try await visionSession(instructions: instructions)
            let text = prompt.text.isEmpty ? "Convert the math shown in the image." : prompt.text
            return try await session.respond(to: text, image: .ciImage(ci))
        } else {
            let session = try await textSession(instructions: instructions)
            return try await session.respond(to: prompt.text)
        }
    }

    // MARK: Lazy session loading

    private func textSession(instructions: String) async throws -> ChatSession {
        if let s = textSession { return s }
        status = "loading model…"
        let model = try await loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id: textModelId)
        let session = ChatSession(model, instructions: instructions)
        textSession = session
        status = "ready"
        return session
    }

    private func visionSession(instructions: String) async throws -> ChatSession {
        if let s = visionSession { return s }
        status = "loading vision model…"
        let model = try await loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id: visionModelId)
        let session = ChatSession(model, instructions: instructions)
        visionSession = session
        status = "ready"
        return session
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "MLXProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
#endif
