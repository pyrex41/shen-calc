import Foundation

// MARK: - Chat primitives

/// One message in a chat exchange with an `LLMProvider`. Provider-agnostic: an
/// on-device MLX session and a cloud Claude request both consume the same shape,
/// so the tutor layer never special-cases the backend. Vision is carried as raw
/// image `Data` (PNG/JPEG bytes) on a message, mirroring how `MathInterpreter`
/// already threads `imageData` through `toCAS`.
struct ChatMessage {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    let role: Role
    let text: String
    /// Optional image bytes (PNG/JPEG). Only meaningful on a `.user` message and
    /// only honored by providers whose `supportsVision` is true.
    let image: Data?

    init(role: Role, text: String, image: Data? = nil) {
        self.role = role
        self.text = text
        self.image = image
    }

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, text: text) }
    static func user(_ text: String, image: Data? = nil) -> ChatMessage {
        ChatMessage(role: .user, text: text, image: image)
    }
    static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, text: text) }
}

/// Generation knobs shared across backends. Each provider maps these onto its own
/// API (MLX caps tokens via its generate config; Claude maps them to `max_tokens`
/// / `temperature` / `stop_sequences`). Defaults are deliberately small — the
/// tutor wants short, focused completions (one CAS line, one hint, one nudge).
struct GenerationOptions {
    let maxTokens: Int
    let temperature: Double
    /// Stop sequences. The provider truncates the completion at the first match
    /// (best-effort; on-device backends may ignore unsupported entries).
    let stop: [String]

    init(maxTokens: Int = 256, temperature: Double = 0.2, stop: [String] = []) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stop = stop
    }

    /// The tutor default: short, low-variance completions.
    static let `default` = GenerationOptions()
}

// MARK: - The provider seam

/// The single pluggability seam for language-model backends. Anything that can
/// turn a chat transcript into a string completion conforms — the on-device MLX
/// provider, a cloud Claude provider, a generic OpenAI-compatible provider, or a
/// test stub. `VerifiedTutor` depends ONLY on this protocol, so swapping the
/// backend (or running with none) never changes the tutor's CAS-guarded logic.
///
/// A class protocol (`AnyObject`) because the concrete providers hold mutable
/// session/connection state (lazy-loaded MLX sessions, URLSession config) and are
/// shared by reference, mirroring `MLXInterpreter` / `ShenCAS`.
protocol LLMProvider: AnyObject {
    /// Stable identifier for logging / the model picker (e.g. the HF repo id or
    /// the Claude model id).
    var id: String { get }
    /// Whether this provider can consume image bytes on a `.user` message.
    var supportsVision: Bool { get }
    /// True for on-device backends (no network, no API key). The factory prefers
    /// these by default — privacy first, and no key required.
    var isLocal: Bool { get }

    /// Run one completion over `messages` and return the assistant text. Throws on
    /// transport / load failure; callers in the tutor treat a throw as "model
    /// unavailable" and degrade gracefully (never surface a guessed answer).
    func complete(_ messages: [ChatMessage], _ options: GenerationOptions) async throws -> String
}

extension LLMProvider {
    /// Convenience: complete with the tutor default options.
    func complete(_ messages: [ChatMessage]) async throws -> String {
        try await complete(messages, .default)
    }
}

// MARK: - Optional streaming

/// Providers that can emit the completion incrementally conform additionally to
/// this. Optional so a backend without streaming (or a test stub) need not
/// implement it; callers feature-detect with `as? StreamingLLMProvider`. The
/// tutor's CAS guards run on the *final* string, so streaming is a UX nicety
/// (live typing), never a correctness path.
protocol StreamingLLMProvider: LLMProvider {
    /// Yield completion deltas (text chunks) as they arrive; the concatenation of
    /// all chunks equals the non-streaming `complete` result. Finishes the stream
    /// on completion; throws (terminates the stream) on failure.
    func stream(_ messages: [ChatMessage], _ options: GenerationOptions) -> AsyncThrowingStream<String, Error>
}

extension StreamingLLMProvider {
    /// Default `complete` for streaming providers: accumulate the stream. A
    /// provider may still override `complete` with a one-shot request if cheaper.
    func complete(_ messages: [ChatMessage], _ options: GenerationOptions) async throws -> String {
        var out = ""
        for try await chunk in stream(messages, options) { out += chunk }
        return out
    }
}

// MARK: - Registry / factory

/// Which backend the app should use. Persisted via `@AppStorage` (see
/// `LLMProviderRegistry.selectionKey`), mirroring the existing
/// `shencalc.textModelId` pattern. Defaults to `.onDevice` — privacy first, and
/// it works with no API key on a real device.
enum ProviderKind: String, CaseIterable, Identifiable {
    case onDevice
    case claude
    case openAICompatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDevice:         return "On-device"
        case .claude:           return "Claude (cloud)"
        case .openAICompatible: return "OpenAI-compatible (cloud)"
        }
    }
}

/// Resolves the currently-selected `LLMProvider`, mirroring the `NLEngine` factory
/// pattern. Reads the persisted `ProviderKind` (and, for cloud, the configured
/// base URL / model id from `CloudProvider.Config`); returns `nil` when no usable
/// provider exists (e.g. on-device requested on the simulator, or a cloud
/// provider with no API key in the Keychain). A `nil` result must degrade
/// gracefully at every call site — the tutor returns "unavailable", never a guess.
enum LLMProviderRegistry {
    /// `@AppStorage` key for the selected backend (matches the `shencalc.*`
    /// namespace already used for `textModelId`).
    static let selectionKey = "shencalc.llmProvider"

    /// Default backend: on-device. Keeps the no-key, offline-capable path the
    /// default and the cloud providers strictly opt-in.
    static let defaultKind: ProviderKind = .onDevice

    /// Build the provider for `kind`. `textModelId` selects the on-device model
    /// (reuses the `TextModel` catalog); cloud providers read their endpoint/model
    /// from `cloud` and their key from the Keychain.
    @MainActor
    static func make(_ kind: ProviderKind = current(),
                     textModelId: String = TextModel.defaultId,
                     cloud: CloudProvider.Config = .claudeDefault) -> LLMProvider? {
        switch kind {
        case .onDevice:
            return OnDeviceProvider.make(textModelId: textModelId)
        case .claude:
            return CloudProvider(config: .claudeDefault.merging(cloud))
        case .openAICompatible:
            return CloudProvider(config: cloud)
        }
    }

    /// The persisted selection, falling back to `defaultKind` for an unset / stale
    /// value. Reads `UserDefaults` directly so non-View code (the tutor, tests)
    /// can resolve the provider without an `@AppStorage` wrapper.
    static func current(defaults: UserDefaults = .standard) -> ProviderKind {
        guard let raw = defaults.string(forKey: selectionKey),
              let kind = ProviderKind(rawValue: raw) else { return defaultKind }
        return kind
    }
}
