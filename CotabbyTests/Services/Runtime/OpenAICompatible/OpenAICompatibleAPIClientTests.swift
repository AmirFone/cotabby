import Foundation
import XCTest
@testable import Cotabby

/// Locks the generic endpoint wire contract without requiring a local server. URL policy and SSE
/// parsing are pure; URLProtocol stubs exercise the real URLSession request paths and headers.
@MainActor
final class OpenAICompatibleAPIClientTests: XCTestCase {
    func test_modelSelectionResolver_choosesFirstDiscoveredModelForEmptySelection() {
        let models = [
            OpenAICompatibleModelOption(id: "alpha"),
            OpenAICompatibleModelOption(id: "beta")
        ]

        XCTAssertEqual(
            OpenAICompatibleModelSelectionResolver.preferredSelection(
                currentSelection: "",
                discoveredModels: models
            ),
            "alpha"
        )
    }

    func test_modelSelectionResolver_preservesAvailableSelection() {
        let models = [
            OpenAICompatibleModelOption(id: "alpha"),
            OpenAICompatibleModelOption(id: "beta")
        ]

        XCTAssertEqual(
            OpenAICompatibleModelSelectionResolver.preferredSelection(
                currentSelection: "beta",
                discoveredModels: models
            ),
            "beta"
        )
    }

    func test_modelSelectionResolver_replacesStaleSelectionWithFirstDiscoveredModel() {
        let models = [
            OpenAICompatibleModelOption(id: "alpha"),
            OpenAICompatibleModelOption(id: "beta")
        ]

        XCTAssertEqual(
            OpenAICompatibleModelSelectionResolver.preferredSelection(
                currentSelection: "removed-model",
                discoveredModels: models
            ),
            "alpha"
        )
    }

    func test_modelSelectionResolver_preservesManualSelectionForEmptyCatalog() {
        XCTAssertNil(
            OpenAICompatibleModelSelectionResolver.preferredSelection(
                currentSelection: "manual-model",
                discoveredModels: []
            )
        )
    }

    override func tearDown() {
        EndpointStubURLProtocol.handler = nil
        EndpointStubURLProtocol.holdRequests = false
        EndpointStubURLProtocol.onStart = nil
        EndpointStubURLProtocol.onStop = nil
        super.tearDown()
    }

    func test_configuration_normalizesRootURLAndClassifiesHosts() throws {
        let loopback = try configuration(baseURL: " http://127.0.0.1:11434/ ")
        XCTAssertEqual(loopback.baseURL.absoluteString, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(loopback.apiURL(path: "models").absoluteString, "http://127.0.0.1:11434/v1/models")
        XCTAssertEqual(loopback.defaultOllamaGenerateURL?.absoluteString, "http://127.0.0.1:11434/api/generate")
        XCTAssertEqual(loopback.hostScope, .loopback)
        XCTAssertNil(loopback.privacyWarning)

        let lan = try configuration(baseURL: "http://192.168.1.50:8000/v1/")
        XCTAssertEqual(lan.baseURL.absoluteString, "http://192.168.1.50:8000/v1")
        XCTAssertNil(lan.defaultOllamaGenerateURL)
        XCTAssertEqual(lan.hostScope, .localNetwork)
        XCTAssertNotNil(lan.privacyWarning)

        let mdns = try configuration(baseURL: "http://ollama.local:11434/v1")
        XCTAssertEqual(mdns.hostScope, .localNetwork)

        let publicHTTPS = try configuration(baseURL: "https://models.example.com/custom/v1")
        XCTAssertEqual(publicHTTPS.hostScope, .publicInternet)
        XCTAssertNotNil(publicHTTPS.privacyWarning)

        let singleLabelHTTPS = try configuration(baseURL: "https://internal-llm:11434/v1")
        XCTAssertEqual(singleLabelHTTPS.hostScope, .publicInternet)
    }

    func test_configuration_rejectsInsecurePublicHTTPAndInvalidComponents() {
        for insecure in [
            "http://models.example.com/v1",
            "http://internal-llm:11434/v1",
            "http://[2001:4860:4860::8888]/v1"
        ] {
            XCTAssertThrowsError(try configuration(baseURL: insecure), insecure) { error in
                XCTAssertEqual(error as? OpenAICompatibleEndpointError, .insecurePublicHTTP)
            }
        }
        for invalid in ["localhost:11434", "file:///tmp/model", "https://host/v1?token=secret"] {
            XCTAssertThrowsError(try configuration(baseURL: invalid), invalid)
        }
    }

    func test_sseDecoder_handlesCompletionChatCommentsErrorsAndDone() throws {
        XCTAssertEqual(
            try OpenAICompatibleSSEDecoder.decode(
                #"data: {"choices":[{"text":" hel"}]}"#,
                mode: .completions
            ),
            .text(" hel")
        )
        XCTAssertEqual(
            try OpenAICompatibleSSEDecoder.decode(
                #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
                mode: .chatCompletions
            ),
            .text("lo")
        )
        XCTAssertEqual(try OpenAICompatibleSSEDecoder.decode(": keep-alive", mode: .completions), .ignore)
        XCTAssertEqual(try OpenAICompatibleSSEDecoder.decode("data: [DONE]", mode: .completions), .done)
        XCTAssertEqual(
            try OpenAICompatibleSSEDecoder.decode(
                #"data: {"error":{"message":"model missing"}}"#,
                mode: .completions
            ),
            .error("model missing")
        )
    }

    func test_fetchModels_usesModelsRouteAndBearerAuthorization() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/models")
            XCTAssertEqual(request.timeoutInterval, 10)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return Self.response(
                request: request,
                body: #"{"object":"list","data":[{"id":"zeta"},{"id":"alpha","owned_by":"library"}]}"#
            )
        }

        let models = try await client.fetchModels(
            configuration: configuration(),
            apiKey: "secret"
        )

        XCTAssertEqual(models.map(\.id), ["alpha", "zeta"])
    }

    func test_completionGeneration_postsStandardPayloadAndAccumulatesSSE() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/completions")
            XCTAssertEqual(request.timeoutInterval, 120)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["model"] as? String, "gemma4:12b-mlx")
            XCTAssertEqual(json["prompt"] as? String, "Complete this")
            XCTAssertEqual(json["max_tokens"] as? Int, 12)
            XCTAssertNil(json["messages"])
            return Self.response(
                request: request,
                contentType: "text/event-stream",
                body: "data: {\"choices\":[{\"text\":\" hel\"}]}\n\n" +
                    "data: {\"choices\":[{\"text\":\"lo\"}]}\n\n" +
                    "data: [DONE]\n\n"
            )
        }
        var partials: [String] = []

        let output = try await client.generate(
            configuration: configuration(mode: .completions),
            apiKey: nil,
            prompt: "Complete this",
            options: .init(maxPredictionTokens: 12, temperature: 0.2, topP: 0.8),
            onPartialRawText: { partials.append($0) }
        )

        XCTAssertEqual(output, " hello")
        XCTAssertEqual(partials, [" hel", " hello"])
    }

    func test_defaultOllamaPreload_usesNativeRouteLongTimeoutAndKeepsModelResident() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/generate")
            XCTAssertEqual(request.timeoutInterval, 120)
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["model"] as? String, "gemma4:12b-mlx")
            XCTAssertEqual(json["prompt"] as? String, "")
            XCTAssertEqual(json["stream"] as? Bool, false)
            XCTAssertEqual(json["keep_alive"] as? Int, -1)
            return Self.response(request: request, body: #"{"done":true}"#)
        }

        let didPreload = try await client.preloadDefaultOllamaModel(
            configuration: configuration(),
            apiKey: nil
        )

        XCTAssertTrue(didPreload)
    }

    func test_nonDefaultEndpoint_doesNotReceiveOllamaPreloadRequest() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { _ in
            XCTFail("A generic endpoint must not receive Ollama's native preload request")
            throw URLError(.badServerResponse)
        }

        let didPreload = try await client.preloadDefaultOllamaModel(
            configuration: configuration(baseURL: "https://models.example.com/v1"),
            apiKey: nil
        )

        XCTAssertFalse(didPreload)
    }

    func test_chatGeneration_postsSingleUserMessageAndReadsDeltaContent() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
            let json = try Self.jsonBody(request)
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.first?["role"] as? String, "user")
            let content = try XCTUnwrap(messages.first?["content"] as? String)
            XCTAssertTrue(content.hasPrefix("Continue the text at the end of the context."))
            XCTAssertTrue(content.hasSuffix("\n\nContinue me"))
            XCTAssertEqual(json["reasoning_effort"] as? String, "none")
            XCTAssertNil(json["prompt"])
            return Self.response(
                request: request,
                contentType: "text/event-stream",
                body: "data: {\"choices\":[{\"delta\":{\"content\":\" next\"}}]}\n\n" +
                    "data: [DONE]\n\n"
            )
        }

        let output = try await client.generate(
            configuration: configuration(mode: .chatCompletions),
            apiKey: nil,
            prompt: "Continue me",
            options: .init(maxPredictionTokens: 8, temperature: 0.1, topP: 0.7),
            onPartialRawText: nil
        )

        XCTAssertEqual(output, " next")
    }

    func test_groqGptOssGeneration_usesSystemTurnLowReasoningAndTokenHeadroom() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-test")
            let json = try Self.jsonBody(request)
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
            XCTAssertEqual(messages.last?["content"] as? String, "Continue me")
            XCTAssertEqual(json["reasoning_effort"] as? String, "low")
            XCTAssertEqual(json["include_reasoning"] as? Bool, false)
            XCTAssertEqual(json["max_tokens"] as? Int, 8 + 64)
            return Self.response(
                request: request,
                contentType: "text/event-stream",
                body: "data: {\"choices\":[{\"delta\":{\"reasoning\":\"think\"}}]}\n\n" +
                    "data: {\"choices\":[{\"delta\":{\"content\":\" next\"}}]}\n\n" +
                    "data: [DONE]\n\n"
            )
        }

        let output = try await client.generate(
            configuration: groqConfiguration(model: "openai/gpt-oss-20b"),
            apiKey: "gsk-test",
            prompt: "Continue me",
            options: .init(maxPredictionTokens: 8, temperature: 0.1, topP: 0.7),
            onPartialRawText: nil
        )

        XCTAssertEqual(output, " next")
    }

    func test_groqNonReasoningModel_sendsNoneEffortWithoutHeadroom() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["reasoning_effort"] as? String, "none")
            XCTAssertEqual(json["max_tokens"] as? Int, 8)
            return Self.response(request: request, contentType: "text/event-stream", body: "data: [DONE]\n\n")
        }

        _ = try await client.generate(
            configuration: groqConfiguration(model: "qwen/qwen3.6-27b"),
            apiKey: "gsk-test",
            prompt: "Continue me",
            options: .init(maxPredictionTokens: 8, temperature: 0.1, topP: 0.7),
            onPartialRawText: nil
        )
    }

    func test_generation_mapsGroq429ToRateLimitedWithRetryAfter() async {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "retry-after": "2"]
            )!
            return (response, Data(#"{"error":{"message":"Rate limit reached"}}"#.utf8))
        }

        do {
            _ = try await client.generate(
                configuration: groqConfiguration(model: "openai/gpt-oss-20b"),
                apiKey: "gsk-test",
                prompt: "text",
                options: .init(maxPredictionTokens: 8, temperature: 0.1, topP: 0.7),
                onPartialRawText: nil
            )
            XCTFail("Expected rate limiting")
        } catch let error as OpenAICompatibleClientError {
            XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 2, message: "Rate limit reached"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_generation_publishesRateLimitSnapshotFromHeaders() async throws {
        let client = makeClient()
        var snapshots: [OpenAICompatibleRateLimitSnapshot] = []
        client.onRateLimitSnapshot = { snapshots.append($0) }
        EndpointStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/event-stream",
                    "x-ratelimit-limit-tokens": "250000",
                    "x-ratelimit-remaining-tokens": "249877",
                    "x-ratelimit-reset-tokens": "29ms"
                ]
            )!
            return (response, Data("data: [DONE]\n\n".utf8))
        }

        _ = try await client.generate(
            configuration: groqConfiguration(model: "openai/gpt-oss-20b"),
            apiKey: "gsk-test",
            prompt: "text",
            options: .init(maxPredictionTokens: 8, temperature: 0.1, topP: 0.7),
            onPartialRawText: nil
        )

        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.tokenLimit, 250_000)
        XCTAssertEqual(snapshot.remainingTokens, 249_877)
        XCTAssertEqual(try XCTUnwrap(snapshot.secondsUntilTokensReset), 0.029, accuracy: 0.000_1)
    }

    func test_fetchModels_groqHidesSpeechGuardAndAgenticModels() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            Self.response(
                request: request,
                body: #"{"data":[{"id":"whisper-large-v3"},{"id":"openai/gpt-oss-20b"},"# +
                    #"{"id":"meta-llama/llama-prompt-guard-2-22m"},{"id":"groq/compound"},"# +
                    #"{"id":"openai/gpt-oss-safeguard-20b"},{"id":"qwen/qwen3.6-27b"},{"id":"openai/gpt-oss-120b"}]}"#
            )
        }

        let models = try await client.fetchModels(
            configuration: groqConfiguration(model: "openai/gpt-oss-20b"),
            apiKey: "gsk-test"
        )

        XCTAssertEqual(models.map(\.id), ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.6-27b"])
    }

    func test_checkSentence_sendsStrictSchemaAndDecodesTheFix() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            let json = try Self.jsonBody(request)
            let format = try XCTUnwrap(json["response_format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertNil(json["stream"])
            XCTAssertEqual(json["temperature"] as? Double, 0)
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertTrue((messages[0]["content"] as? String)?.contains("Cotabby") == true, "known terms reach the system turn")
            let content = #"{\"corrected\":\"I received their email.\",\"edits\":[{\"from\":\"there\",\"to\":\"their\",\"confidence\":0.97}]}"#
            return Self.response(request: request, body: #"{"choices":[{"message":{"content":"\#(content)"}}]}"#)
        }

        let result = try await client.checkSentence(
            configuration: groqConfiguration(model: "openai/gpt-oss-20b"),
            apiKey: "gsk-test",
            sentence: "I recieved there email.",
            precedingContext: "",
            knownTerms: "Cotabby"
        )

        XCTAssertEqual(result?.corrected, "I received their email.")
        XCTAssertEqual(result?.edits.first?.confidence, 0.97)
    }

    func test_checkSentence_returnsNilWhenNothingChanged() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            let content = #"{\"corrected\":\"All good here.\",\"edits\":[]}"#
            return Self.response(request: request, body: #"{"choices":[{"message":{"content":"\#(content)"}}]}"#)
        }

        let result = try await client.checkSentence(
            configuration: groqConfiguration(model: "openai/gpt-oss-20b"),
            apiKey: nil,
            sentence: "All good here.",
            precedingContext: "",
            knownTerms: nil
        )

        XCTAssertNil(result)
    }

    func test_rateLimitDurationParser_handlesProviderFormats() {
        XCTAssertEqual(OpenAICompatibleRateLimitSnapshot.durationSeconds(from: "29ms") ?? -1, 0.029, accuracy: 0.000_1)
        XCTAssertEqual(OpenAICompatibleRateLimitSnapshot.durationSeconds(from: "7.66s") ?? -1, 7.66, accuracy: 0.000_1)
        XCTAssertEqual(OpenAICompatibleRateLimitSnapshot.durationSeconds(from: "1m2.5s") ?? -1, 62.5, accuracy: 0.000_1)
        XCTAssertEqual(OpenAICompatibleRateLimitSnapshot.durationSeconds(from: "2") ?? -1, 2, accuracy: 0.000_1)
        XCTAssertNil(OpenAICompatibleRateLimitSnapshot.durationSeconds(from: "soon"))
    }

    func test_generationMapsNonSuccessStatus() async {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 401, body: #"{"error":{"message":"unauthorized"}}"#)
        }

        do {
            _ = try await client.generate(
                configuration: configuration(),
                apiKey: nil,
                prompt: "text",
                options: .init(maxPredictionTokens: 8, temperature: 0.1, topP: 0.7),
                onPartialRawText: nil
            )
            XCTFail("Expected the HTTP error")
        } catch let error as OpenAICompatibleClientError {
            XCTAssertEqual(error, .server(statusCode: 401, message: "unauthorized"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_generationCancellationStopsTheUnderlyingRequest() async {
        let client = makeClient()
        let started = expectation(description: "endpoint request started")
        let stopped = expectation(description: "endpoint request stopped")
        EndpointStubURLProtocol.holdRequests = true
        EndpointStubURLProtocol.onStart = { started.fulfill() }
        EndpointStubURLProtocol.onStop = { stopped.fulfill() }

        let generation = Task { @MainActor in
            try await client.generate(
                configuration: configuration(),
                apiKey: nil,
                prompt: "text",
                options: .init(maxPredictionTokens: 8, temperature: 0.1, topP: 0.7),
                onPartialRawText: nil
            )
        }

        await fulfillment(of: [started], timeout: 1)
        generation.cancel()
        do {
            _ = try await generation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Foundation may surface cooperative cancellation directly.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [stopped], timeout: 1)
    }

    private func makeClient() -> OpenAICompatibleAPIClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EndpointStubURLProtocol.self]
        return OpenAICompatibleAPIClient(session: URLSession(configuration: sessionConfiguration))
    }

    private func configuration(
        baseURL: String = OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
        mode: OpenAICompatibleAPIMode = .chatCompletions
    ) throws -> OpenAICompatibleEndpointConfiguration {
        try OpenAICompatibleEndpointConfiguration(
            baseURLString: baseURL,
            modelName: "gemma4:12b-mlx",
            apiMode: mode
        )
    }

    private func groqConfiguration(model: String) throws -> OpenAICompatibleEndpointConfiguration {
        try OpenAICompatibleEndpointConfiguration(
            baseURLString: OpenAICompatibleProviderPreset.groqBaseURLString,
            modelName: model,
            apiMode: .chatCompletions,
            provider: .groq
        )
    }

    private static func response(
        request: URLRequest,
        statusCode: Int = 200,
        contentType: String = "application/json",
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        return (response, Data(body.utf8))
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class EndpointStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var holdRequests = false
    nonisolated(unsafe) static var onStart: (() -> Void)?
    nonisolated(unsafe) static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onStart?()
        if Self.holdRequests { return }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.onStop?()
    }
}
