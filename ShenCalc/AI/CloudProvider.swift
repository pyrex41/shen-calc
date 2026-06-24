import Foundation

// MARK: - Keychain helper

/// Minimal Keychain wrapper for storing a single cloud API key per provider.
/// Inline (no dependency) — the app links no networking/secrets SPM packages, so
/// a thin Security.framework shim is the right size. Keys are stored as generic
/// passwords under the app's default keychain, accessible after first unlock.
enum Keychain {
    private static let service = "com.shencalc.llm"

    /// Store (or overwrite) `value` under `account`. Passing `nil`/empty deletes
    /// the entry. Returns true on success.
    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // idempotent overwrite
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            return true   // delete-only path
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Read the key for `account`, or `nil` if absent.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyStatus(query, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // SecItemCopyMatching takes an inout CFTypeRef?; wrap it so call sites stay clean.
    private static func SecItemCopyStatus(_ query: [String: Any], _ out: inout AnyObject?) -> OSStatus {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        out = result
        return status
    }
}

// MARK: - Cloud provider

/// A cloud `LLMProvider` over plain `URLSession` (no SPM deps). Two flavors,
/// selected by `Config.style`:
///   • `.anthropic` — the Claude Messages API (`/v1/messages`), the default.
///   • `.openAICompatible` — any OpenAI-style `/v1/chat/completions` endpoint
///     (OpenAI itself, or a self-hosted gateway), for flexibility.
///
/// `isLocal = false`. `supportsVision` is configurable (off by default — wire the
/// per-style image block before enabling). The API key is read from the Keychain
/// at request time, so the provider is constructible without one; if no key is
/// present, `complete` throws and the tutor degrades gracefully.
final class CloudProvider: LLMProvider {

    /// Wire format for the request/response shaping.
    enum Style: String {
        case anthropic
        case openAICompatible
    }

    /// Endpoint + model configuration. The default Claude model id is a NAMED
    /// constant (`Config.defaultClaudeModel`) with a verify-against-the-reference
    /// note — do NOT hardcode a guessed id deep in request logic.
    struct Config {
        let style: Style
        /// Base URL, e.g. "https://api.anthropic.com" or an OpenAI-compatible host.
        let baseURL: URL
        /// Model id (e.g. the Claude model below, or "gpt-4o-mini" for OpenAI).
        let model: String
        /// Keychain account under which this provider's API key is stored.
        let keychainAccount: String
        /// Whether to send image blocks. Off until the per-style image encoding is
        /// exercised — leaving it false keeps a misconfigured provider text-only
        /// rather than silently dropping/mangling an image.
        let supportsVision: Bool

        /// The default Claude model id. VERIFY the latest id against the
        /// `claude-api` reference / Anthropic docs before shipping — model ids
        /// change with each release. As of this writing the current flagship is
        /// `claude-opus-4-8`; pick a cheaper tier (e.g. `claude-haiku-4-5`) for
        /// latency-/cost-sensitive tutoring if desired.
        static let defaultClaudeModel = "claude-opus-4-8"

        /// Anthropic API version header value. Pinned; bump when adopting a newer
        /// Messages API revision (see the claude-api reference).
        static let anthropicVersion = "2023-06-01"

        /// Claude (Anthropic) defaults.
        static let claudeDefault = Config(
            style: .anthropic,
            baseURL: URL(string: "https://api.anthropic.com")!,
            model: defaultClaudeModel,
            keychainAccount: "anthropic.apiKey",
            supportsVision: false
        )

        /// Overlay non-default fields from `other` onto `self`. Used by the
        /// registry so a caller can tweak the model / base URL without restating
        /// the whole config. Here it simply returns `other` (the caller-supplied
        /// config wins); kept as a hook for future field-wise merging.
        func merging(_ other: Config) -> Config { other }
    }

    let config: Config
    private let session: URLSession

    init(config: Config = .claudeDefault, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: LLMProvider

    var id: String { config.model }
    var supportsVision: Bool { config.supportsVision }
    var isLocal: Bool { false }

    func complete(_ messages: [ChatMessage], _ options: GenerationOptions) async throws -> String {
        guard let key = Keychain.get(config.keychainAccount), !key.isEmpty else {
            throw err("no API key configured for \(config.keychainAccount)")
        }
        switch config.style {
        case .anthropic:        return try await completeAnthropic(messages, options, key: key)
        case .openAICompatible: return try await completeOpenAI(messages, options, key: key)
        }
    }

    // MARK: Anthropic (Claude) Messages API

    private func completeAnthropic(_ messages: [ChatMessage],
                                   _ options: GenerationOptions,
                                   key: String) async throws -> String {
        // Claude carries the system prompt as a top-level field, not a message.
        let systemText = messages.filter { $0.role == .system }.map(\.text)
            .joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }.map { msg -> [String: Any] in
            ["role": msg.role.rawValue, "content": msg.text]
        }

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "messages": turns,
        ]
        if !systemText.isEmpty { body["system"] = systemText }
        if !options.stop.isEmpty { body["stop_sequences"] = options.stop }

        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Config.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await postJSON(req)
        // { "content": [ { "type": "text", "text": "..." }, ... ] }
        guard let content = json["content"] as? [[String: Any]] else {
            throw err("unexpected Claude response shape")
        }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: OpenAI-compatible Chat Completions API

    private func completeOpenAI(_ messages: [ChatMessage],
                                _ options: GenerationOptions,
                                key: String) async throws -> String {
        let turns = messages.map { msg -> [String: Any] in
            ["role": msg.role.rawValue, "content": msg.text]
        }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "messages": turns,
        ]
        if !options.stop.isEmpty { body["stop"] = options.stop }

        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await postJSON(req)
        // { "choices": [ { "message": { "content": "..." } } ] }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw err("unexpected OpenAI-compatible response shape")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTTP

    /// POST and decode a JSON object, surfacing a readable error on non-2xx.
    private func postJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw err("HTTP \(http.statusCode): \(detail)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw err("response was not a JSON object")
        }
        return json
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "CloudProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
