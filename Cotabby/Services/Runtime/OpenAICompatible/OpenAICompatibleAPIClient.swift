import Combine
import Foundation

/// Sampling values shared by the completions and chat-completions request shapes.
nonisolated struct OpenAICompatibleGenerationOptions: Equatable, Sendable {
    let maxPredictionTokens: Int
    let temperature: Double
    let topP: Double
}

enum OpenAICompatibleClientError: LocalizedError, Equatable {
    case invalidResponse
    case server(statusCode: Int, message: String?)
    case rateLimited(retryAfterSeconds: Double?, message: String?)
    case malformedResponse
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The endpoint returned an invalid HTTP response."
        case .server(let code, let message?): return "The endpoint returned HTTP \(code): \(message)"
        case .server(let code, nil): return "The endpoint returned HTTP \(code)."
        case .rateLimited(let retryAfter?, _):
            return "The endpoint is rate limiting requests. Retrying in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil, _): return "The endpoint is rate limiting requests."
        case .malformedResponse: return "The endpoint returned an invalid OpenAI-compatible response."
        case .streamError(let message): return "The endpoint reported an error: \(message)"
        }
    }
}

/// Stateless HTTP boundary for OpenAI-compatible local servers.
///
/// `URLSession` owns socket work off the main actor. This object stays main-actor isolated so the
/// cumulative partial callback can feed Cotabby's UI-facing generation pipeline directly.
@MainActor
final class OpenAICompatibleAPIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Receives the provider's rate-limit headers after every generation response so a budget can
    /// track the server's own view of remaining capacity. Servers without those headers never call it.
    var onRateLimitSnapshot: (@MainActor (OpenAICompatibleRateLimitSnapshot) -> Void)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchModels(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?
    ) async throws -> [OpenAICompatibleModelOption] {
        var request = URLRequest(url: configuration.apiURL(path: "models"), timeoutInterval: 10)
        applyHeaders(to: &request, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, body: data)
        let payload = try decoder.decode(ModelListResponse.self, from: data)
        return payload.data
            .filter { configuration.provider.acceptsDiscoveredModel($0.id) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Loads the selected model through Ollama's native API without tying that cold start to a
    /// cancellable autocomplete request. Returning `false` means the configured endpoint is not
    /// Cotabby's known local Ollama default, so callers can treat warmup as an intentional no-op.
    func preloadDefaultOllamaModel(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?
    ) async throws -> Bool {
        guard !configuration.modelName.isEmpty else {
            throw OpenAICompatibleEndpointError.emptyModelName
        }
        guard let url = configuration.defaultOllamaGenerateURL else { return false }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request, apiKey: apiKey)
        request.httpBody = try encoder.encode(OllamaPreloadRequest(model: configuration.modelName))

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, body: data)
        return true
    }

    /// `systemPrompt` replaces the built-in continuation instruction for chat requests. Callers that
    /// render their own system/user split pass it; nil keeps the single-user-message contract.
    func generate(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?,
        prompt: String,
        systemPrompt: String? = nil,
        options: OpenAICompatibleGenerationOptions,
        onPartialRawText: (@MainActor (String) -> Void)?
    ) async throws -> String {
        guard !configuration.modelName.isEmpty else {
            throw OpenAICompatibleEndpointError.emptyModelName
        }

        var request = URLRequest(
            url: configuration.apiURL(path: configuration.apiMode.route),
            timeoutInterval: 120
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyHeaders(to: &request, apiKey: apiKey)
        request.httpBody = try requestBody(
            configuration: configuration,
            prompt: prompt,
            systemPrompt: systemPrompt,
            options: options
        )

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse {
            if let snapshot = OpenAICompatibleRateLimitSnapshot(headers: http) {
                onRateLimitSnapshot?(snapshot)
            }
            if !(200..<300).contains(http.statusCode) {
                try Self.validate(response, body: try await Self.prefix(of: bytes, maxBytes: 4_096))
            }
        }
        try Self.validate(response, body: nil)

        var accumulated = ""
        var sawEvent = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch try OpenAICompatibleSSEDecoder.decode(line, mode: configuration.apiMode) {
            case .ignore:
                continue
            case .done:
                sawEvent = true
                return accumulated
            case .text(let text):
                sawEvent = true
                accumulated += text
                onPartialRawText?(accumulated)
            case .error(let message):
                throw OpenAICompatibleClientError.streamError(message)
            }
        }

        guard sawEvent else { throw OpenAICompatibleClientError.malformedResponse }
        return accumulated
    }

    /// One non-streaming, schema-constrained request that returns the writer's sentence with
    /// spelling and grammar fixed, plus the individual edits and the model's confidence in each.
    /// Returns nil when the model changed nothing.
    func checkSentence(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?,
        sentence: String,
        precedingContext: String,
        knownTerms: String?
    ) async throws -> SentenceCheckResult? {
        guard !configuration.modelName.isEmpty else {
            throw OpenAICompatibleEndpointError.emptyModelName
        }
        var request = URLRequest(url: configuration.apiURL(path: "chat/completions"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request, apiKey: apiKey)
        request.httpBody = try encoder.encode(SentenceCheckRequest(
            configuration: configuration,
            sentence: sentence,
            precedingContext: precedingContext,
            knownTerms: knownTerms
        ))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, let snapshot = OpenAICompatibleRateLimitSnapshot(headers: http) {
            onRateLimitSnapshot?(snapshot)
        }
        try Self.validate(response, body: data)
        let envelope = try decoder.decode(SentenceCheckEnvelope.self, from: data)
        guard let content = envelope.choices.first?.message.content,
              let payload = content.data(using: .utf8) else {
            throw OpenAICompatibleClientError.malformedResponse
        }
        let result = try decoder.decode(SentenceCheckResult.self, from: payload)
        let unchanged = result.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            == sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return unchanged || result.edits.isEmpty ? nil : result
    }

    private func applyHeaders(to request: inout URLRequest, apiKey: String?) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func requestBody(
        configuration: OpenAICompatibleEndpointConfiguration,
        prompt: String,
        systemPrompt: String?,
        options: OpenAICompatibleGenerationOptions
    ) throws -> Data {
        switch configuration.apiMode {
        case .completions:
            return try encoder.encode(CompletionRequest(
                model: configuration.modelName,
                prompt: prompt,
                options: options
            ))
        case .chatCompletions:
            return try encoder.encode(ChatCompletionRequest(
                configuration: configuration,
                prompt: prompt,
                systemPrompt: systemPrompt,
                options: options
            ))
        }
    }

    private static func prefix(of bytes: URLSession.AsyncBytes, maxBytes: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBytes { break }
        }
        return data
    }

    /// Non-2xx responses carry the server's own explanation (for example Groq's
    /// "`reasoning_effort` must be one of…"); surfacing it turns an opaque HTTP code into a fix.
    static func validate(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidResponse
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = body.flatMap(ErrorEnvelope.message(from:))
        if http.statusCode == 429 {
            throw OpenAICompatibleClientError.rateLimited(
                retryAfterSeconds: OpenAICompatibleRateLimitSnapshot.retryAfterSeconds(headers: http),
                message: message
            )
        }
        throw OpenAICompatibleClientError.server(statusCode: http.statusCode, message: message)
    }
}

/// Observable model catalog shared by Settings and the Home status card.
/// A refresh generation prevents a slow response for an old URL from replacing a newer catalog.
@MainActor
final class OpenAICompatibleConnectionModel: ObservableObject {
    @Published private(set) var models: [OpenAICompatibleModelOption] = []
    @Published private(set) var state: OpenAICompatibleConnectionState = .idle

    private let client: OpenAICompatibleAPIClient
    private var refreshGeneration: UInt64 = 0

    init(client: OpenAICompatibleAPIClient) {
        self.client = client
    }

    func invalidate() {
        refreshGeneration &+= 1
        models = []
        state = .idle
    }

    func setFailure(_ message: String) {
        refreshGeneration &+= 1
        models = []
        state = .failed(message)
    }

    func refresh(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?
    ) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .connecting
        do {
            let fetched = try await client.fetchModels(configuration: configuration, apiKey: apiKey)
            guard refreshGeneration == generation else { return }
            models = fetched
            state = .ready(modelCount: fetched.count)
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == generation else { return }
            models = []
            state = .failed(error.localizedDescription)
        }
    }
}

nonisolated enum OpenAICompatibleSSEEvent: Equatable {
    case ignore
    case done
    case text(String)
    case error(String)
}

/// Pure line decoder for OpenAI's data-only SSE streams.
nonisolated enum OpenAICompatibleSSEDecoder {
    static func decode(
        _ line: String,
        mode: OpenAICompatibleAPIMode,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> OpenAICompatibleSSEEvent {
        var payload = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return .ignore }
        if isMetadataLine(payload) {
            return .ignore
        }
        if payload.hasPrefix("data:") {
            payload.removeFirst("data:".count)
            payload = payload.trimmingCharacters(in: .whitespaces)
        }
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8) else {
            throw OpenAICompatibleClientError.malformedResponse
        }
        return event(from: try streamChunk(from: data, decoder: decoder), mode: mode)
    }

    private static func streamChunk(from data: Data, decoder: JSONDecoder) throws -> StreamChunk {
        do {
            return try decoder.decode(StreamChunk.self, from: data)
        } catch {
            throw OpenAICompatibleClientError.malformedResponse
        }
    }

    private static func event(
        from chunk: StreamChunk,
        mode: OpenAICompatibleAPIMode
    ) -> OpenAICompatibleSSEEvent {
        if let message = chunk.error?.message, !message.isEmpty { return .error(message) }
        guard let choice = chunk.choices?.first else { return .ignore }
        let text: String? = switch mode {
        case .completions: choice.text
        case .chatCompletions: choice.delta?.content ?? choice.message?.content
        }
        guard let text, !text.isEmpty else { return .ignore }
        return .text(text)
    }

    private static func isMetadataLine(_ payload: String) -> Bool {
        [":", "event:", "id:", "retry:"].contains { payload.hasPrefix($0) }
    }
}

private nonisolated struct ModelListResponse: Decodable {
    let data: [OpenAICompatibleModelOption]
}

/// Ollama treats an empty, non-streaming generate request as a model load. `keep_alive = -1`
/// keeps the weights resident until Ollama is stopped or explicitly asked to unload them.
private nonisolated struct OllamaPreloadRequest: Encodable {
    let model: String
    let prompt = ""
    let stream = false
    let keepAlive = -1

    private enum CodingKeys: String, CodingKey {
        case model, prompt, stream
        case keepAlive = "keep_alive"
    }
}

private nonisolated struct CompletionRequest: Encodable {
    let model: String
    let prompt: String
    let stream = true
    let maxTokens: Int
    let temperature: Double
    let topP: Double

    init(model: String, prompt: String, options: OpenAICompatibleGenerationOptions) {
        self.model = model
        self.prompt = prompt
        maxTokens = options.maxPredictionTokens
        temperature = options.temperature
        topP = options.topP
    }

    private enum CodingKeys: String, CodingKey {
        case model, prompt, stream, temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
    }
}

private nonisolated struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    /// Instruction shared by providers that receive Cotabby's base-model prompt unchanged.
    static let continuationInstruction = "Continue the text at the end of the context. Reply with only new continuation " +
        "text; do not repeat or quote existing text."

    /// gpt-oss spends a handful of hidden reasoning tokens even at `low` effort, and Groq counts
    /// them against `max_tokens`. Without headroom a 5–20 token autocomplete budget returns empty.
    static let reasoningTokenHeadroom = 64

    let model: String
    let messages: [Message]
    let stream = true
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    /// Autocomplete needs visible continuation tokens immediately. Reasoning-capable local models
    /// can otherwise spend Cotabby's entire short token budget on an invisible thinking channel.
    /// Groq rejects `none` for gpt-oss (only low/medium/high), so that family gets `low`.
    let reasoningEffort: String
    /// Groq-only: keeps the hidden reasoning channel out of the stream entirely.
    let includeReasoning: Bool?

    init(
        configuration: OpenAICompatibleEndpointConfiguration,
        prompt: String,
        systemPrompt: String?,
        options: OpenAICompatibleGenerationOptions
    ) {
        model = configuration.modelName
        temperature = options.temperature
        topP = options.topP

        let usesMandatoryReasoning = configuration.provider == .groq && configuration.modelName.hasPrefix("openai/gpt-oss")
        reasoningEffort = usesMandatoryReasoning ? "low" : "none"
        maxTokens = options.maxPredictionTokens + (usesMandatoryReasoning ? Self.reasoningTokenHeadroom : 0)
        includeReasoning = configuration.provider == .groq ? false : nil

        switch (configuration.provider, systemPrompt) {
        case (_, let systemPrompt?):
            messages = [Message(role: "system", content: systemPrompt), Message(role: "user", content: prompt)]
        case (.groq, nil):
            // A real system turn keeps the instruction out of the user text, so Groq's prefix cache
            // matches across keystrokes and the model treats the user turn purely as context.
            messages = [
                Message(role: "system", content: Self.continuationInstruction),
                Message(role: "user", content: prompt)
            ]
        case (.custom, nil):
            // The shared prompt is shaped as a base-model continuation and intentionally ends at the
            // caret. Chat models otherwise tend to answer by repeating that final line, which Cotabby
            // correctly normalizes away and makes the user wait for a suggestion that never appears.
            // A short instruction in the same user message preserves the single-message wire contract
            // while making the expected output explicit for instruction-tuned endpoint models.
            messages = [Message(role: "user", content: Self.continuationInstruction + "\n\n" + prompt)]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case reasoningEffort = "reasoning_effort"
        case includeReasoning = "include_reasoning"
    }
}

/// The corrected sentence and the edits the model made, as returned by `checkSentence`.
nonisolated struct SentenceCheckResult: Decodable, Equatable, Sendable {
    struct Edit: Decodable, Equatable, Sendable {
        let from: String
        let to: String
        let confidence: Double
    }

    let corrected: String
    let edits: [Edit]
}

private nonisolated struct SentenceCheckEnvelope: Decodable {
    struct Choice: Decodable {
        let message: SentenceCheckMessageContent
    }
    let choices: [Choice]
}

private nonisolated struct SentenceCheckMessageContent: Decodable {
    let content: String?
}

/// Chat request with a strict JSON schema, so the response is always machine-readable and the
/// model cannot answer with commentary.
private nonisolated struct SentenceCheckRequest: Encodable {
    static let instructions = """
        You proofread one sentence for a dyslexic writer. Fix spelling, words used in place of \
        similar-sounding ones (their/there, form/from), swapped or missing small words, and clear \
        grammar mistakes. Keep the writer's meaning, voice, word choice, capitalization style, and \
        punctuation style. Do not rephrase, formalize, or shorten. If nothing needs fixing, return \
        the sentence unchanged with no edits. Give each edit a confidence from 0 to 1.
        """

    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature = 0.0
    let maxTokens = 400
    let reasoningEffort: String
    let includeReasoning: Bool?
    let responseFormat = SentenceCheckResponseFormat()

    init(configuration: OpenAICompatibleEndpointConfiguration, sentence: String, precedingContext: String, knownTerms: String?) {
        model = configuration.modelName
        let reasons = configuration.modelName.hasPrefix("openai/gpt-oss")
        reasoningEffort = reasons ? "low" : "none"
        includeReasoning = configuration.provider == .groq ? false : nil
        var system = Self.instructions
        if let knownTerms, !knownTerms.isEmpty {
            system += "\nSpell these names and terms exactly as given: \(knownTerms)"
        }
        var user = ""
        if !precedingContext.isEmpty {
            user += "Earlier text (context only, do not edit):\n\(precedingContext)\n\n"
        }
        user += "Sentence to proofread:\n\(sentence)"
        messages = [Message(role: "system", content: system), Message(role: "user", content: user)]
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
        case includeReasoning = "include_reasoning"
        case responseFormat = "response_format"
    }
}

private nonisolated struct SentenceCheckResponseFormat: Encodable {
    let type = "json_schema"
    let jsonSchema = SentenceCheckSchema()

    private enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

private nonisolated struct SentenceCheckSchema: Encodable {
    let name = "sentence_fix"
    let strict = true
    let schema: [String: AnyEncodableValue] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["corrected", "edits"],
        "properties": [
            "corrected": ["type": "string"],
            "edits": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["from", "to", "confidence"],
                    "properties": [
                        "from": ["type": "string"],
                        "to": ["type": "string"],
                        "confidence": ["type": "number"]
                    ]
                ]
            ]
        ]
    ]
}

/// Minimal JSON value so the fixed schema can be written as a literal.
private nonisolated indirect enum AnyEncodableValue: Encodable, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case string(String)
    case bool(Bool)
    case array([AnyEncodableValue])
    case object([String: AnyEncodableValue])

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: AnyEncodableValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, AnyEncodableValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value): try value.encode(to: encoder)
        case .bool(let value): try value.encode(to: encoder)
        case .array(let values): try values.encode(to: encoder)
        case .object(let values): try values.encode(to: encoder)
        }
    }
}

/// Decodes the `{"error":{"message":…}}` envelope OpenAI-compatible servers return on failure.
private nonisolated struct ErrorEnvelope: Decodable {
    struct Payload: Decodable { let message: String }
    let error: Payload

    static func message(from data: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        let text = (String(bytes: data.prefix(300), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private nonisolated struct StreamChunk: Decodable {
    struct Choice: Decodable {
        let text: String?
        let delta: StreamContent?
        let message: StreamContent?
    }
    struct ErrorPayload: Decodable { let message: String }

    let choices: [Choice]?
    let error: ErrorPayload?
}

private nonisolated struct StreamContent: Decodable {
    let content: String?
}
