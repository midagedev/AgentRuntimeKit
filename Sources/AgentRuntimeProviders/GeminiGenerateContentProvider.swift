import AgentRuntimeCore
import Foundation

/// Streaming adapter for Gemini `streamGenerateContent` using SSE (`alt=sse`).
public struct GeminiGenerateContentProvider: ModelProvider, Sendable {
    public let identifier: String
    public let capabilities: ProviderCapabilities = [
        .streaming, .tools, .parallelTools, .vision, .structuredOutput, .reasoning, .promptCaching,
    ]

    private let baseURL: URL
    private let authentication: ProviderHeaderAuthentication?
    private let additionalHeaders: [String: String]
    private let retryPolicy: ProviderRetryPolicy
    private let httpClient: any StreamingHTTPClient

    public init(
        identifier: String = "gemini",
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        credentialResolver: (any ProviderCredentialResolving)? = nil,
        credentialHeaderName: String = "x-goog-api-key",
        credentialPrefix: String = "",
        additionalHeaders: [String: String] = [:],
        retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(),
        httpClient: any StreamingHTTPClient = URLSessionStreamingHTTPClient()
    ) {
        self.identifier = identifier
        self.baseURL = baseURL
        self.authentication = credentialResolver.map {
            ProviderHeaderAuthentication(
                resolver: $0,
                headerName: credentialHeaderName,
                prefix: credentialPrefix
            )
        }
        self.additionalHeaders = additionalHeaders
        self.retryPolicy = retryPolicy
        self.httpClient = httpClient
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        makeModelEventStream { continuation in
            var headers = additionalHeaders
            headers["content-type"] = "application/json"
            headers["accept"] = "text/event-stream"
            if let authentication {
                try await authentication.apply(to: &headers, providerIdentifier: identifier)
            }

            let response = try await performProviderRequest(StreamingHTTPRequest(
                url: try endpoint(for: request.model),
                headers: headers,
                body: try jsonBody(try makeGeminiRequest(request))
            ), using: httpClient, retryPolicy: retryPolicy)
            let rateLimit = normalizedRateLimit(from: response)
            if !rateLimit.isEmpty {
                continuation.yield(.metadata(["rateLimit": rateLimit.metadataValue]))
            }

            var state = GeminiStreamState(providerIdentifier: identifier)
            try await processSSE(response) { event in
                guard event.data != "[DONE]" else { return }
                let json = try parseEventJSON(event, provider: identifier)
                for normalized in try state.consume(json) {
                    continuation.yield(normalized)
                }
            }
            for normalized in state.finishIfNeeded() {
                continuation.yield(normalized)
            }
        }
    }

    private func endpoint(for model: String) throws -> URL {
        let normalizedModel = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        guard !normalizedModel.isEmpty,
              !normalizedModel.contains("/"),
              !normalizedModel.contains("?"),
              !normalizedModel.contains("#") else {
            throw AgentRuntimeError.invalidProviderResponse("Gemini model identifier is invalid.")
        }
        let endpoint = baseURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("\(normalizedModel):streamGenerateContent")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AgentRuntimeError.invalidProviderResponse("Gemini endpoint URL is invalid.")
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "alt" }
        items.append(URLQueryItem(name: "alt", value: "sse"))
        components.queryItems = items
        guard let url = components.url else {
            throw AgentRuntimeError.invalidProviderResponse("Gemini endpoint URL is invalid.")
        }
        return url
    }

    private func makeGeminiRequest(_ request: ModelRequest) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "contents": .array(try request.messages
                .filter { $0.role != .system }
                .map(geminiContent)),
        ]

        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            body["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(systemText)])]),
            ])
        }
        if !request.tools.isEmpty {
            body["tools"] = .array([
                .object([
                    "functionDeclarations": .array(request.tools.map { descriptor in
                        .object([
                            "name": .string(descriptor.name),
                            "description": .string(descriptor.description),
                            "parameters": descriptor.inputSchema,
                        ])
                    }),
                ]),
            ])
        }

        var generationConfig: [String: JSONValue] = [:]
        if let temperature = request.temperature {
            generationConfig["temperature"] = .number(temperature)
        }
        if let maxTokens = request.maxOutputTokens {
            generationConfig["maxOutputTokens"] = .number(Double(maxTokens))
        }
        if let schema = request.responseSchema {
            generationConfig["responseMimeType"] = .string("application/json")
            generationConfig["responseJsonSchema"] = schema
        }
        if !generationConfig.isEmpty { body["generationConfig"] = .object(generationConfig) }
        return .object(body)
    }

    private func geminiContent(_ message: AgentMessage) throws -> JSONValue {
        if message.role == .assistant,
           let continuation = message.providerContinuation,
           continuation.providerIdentifier == identifier,
           continuation.format == "gemini.content",
           continuation.formatVersion == 1,
           continuation.payload["parts"]?.arrayValue != nil {
            return continuation.payload
        }
        let role = message.role == .assistant ? "model" : "user"
        var parts: [JSONValue] = []
        for content in message.content {
            switch content {
            case .text(let text):
                parts.append(.object(["text": .string(text)]))
            case .image(let image):
                switch image.source {
                case .url(let url):
                    parts.append(.object([
                        "fileData": .object(["fileUri": .string(url.absoluteString)]),
                    ]))
                case .base64(let mediaType, let data):
                    parts.append(.object([
                        "inlineData": .object([
                            "mimeType": .string(mediaType),
                            "data": .string(data),
                        ]),
                    ]))
                }
            case .toolCall(let call):
                parts.append(.object([
                    "functionCall": .object([
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "args": call.arguments,
                    ]),
                ]))
            case .toolResult(let result):
                let response: JSONValue
                if case .object = result.content {
                    response = result.content
                } else {
                    response = .object(["result": result.content])
                }
                parts.append(.object([
                    "functionResponse": .object([
                        "id": .string(result.toolCallID),
                        "name": .string(result.toolName),
                        "response": response,
                    ]),
                ]))
            }
        }
        return .object(["role": .string(role), "parts": .array(parts)])
    }
}

private struct GeminiStreamState {
    let providerIdentifier: String
    var usage: AgentTokenUsage?
    var finishReason: ModelFinishReason?
    var emittedToolIDs: Set<String> = []
    var emittedMetadata = false
    var didFinish = false
    var continuationParts: [JSONValue] = []

    mutating func consume(_ json: JSONValue) throws -> [ModelStreamEvent] {
        if let error = json["error"] {
            throw ProviderStreamError(
                providerIdentifier: providerIdentifier,
                message: sanitizedProviderErrorMessage(
                    error["message"]?.stringValue ?? "Gemini stream failed",
                    fallback: "Gemini stream failed"
                ),
                code: sanitizedProviderDiagnosticIdentifier(
                    error["status"]?.stringValue ?? error["code"]?.intValue.map(String.init)
                )
            )
        }

        var events: [ModelStreamEvent] = []
        if !emittedMetadata {
            var metadata: [String: JSONValue] = [:]
            if let responseID = json["responseId"] { metadata["id"] = responseID }
            if let modelVersion = json["modelVersion"] { metadata["model"] = modelVersion }
            if !metadata.isEmpty {
                events.append(.metadata(metadata))
                emittedMetadata = true
            }
        }

        if let usageJSON = json["usageMetadata"] {
            usage = AgentTokenUsage(
                inputTokens: usageJSON["promptTokenCount"]?.intValue ?? 0,
                outputTokens: (usageJSON["candidatesTokenCount"]?.intValue ?? 0)
                    + (usageJSON["thoughtsTokenCount"]?.intValue ?? 0),
                cachedInputTokens: usageJSON["cachedContentTokenCount"]?.intValue ?? 0
            )
        }

        guard let candidates = json["candidates"]?.arrayValue,
              let candidate = candidates.first(where: { $0["index"]?.intValue == 0 }) ?? candidates.first else {
            return events
        }
        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
            recordContinuationPart(part)
            if let text = part["text"]?.stringValue, !text.isEmpty {
                if part["thought"]?.boolValue == true {
                    events.append(.reasoningDelta(text))
                } else {
                    events.append(.textDelta(text))
                }
            }
            if let call = part["functionCall"] {
                let name = call["name"]?.stringValue ?? ""
                var id = call["id"]?.stringValue
                if let existingID = id, emittedToolIDs.contains(existingID) {
                    continue
                }
                if id == nil || id?.isEmpty == true {
                    id = "gemini_tool_\(UUID().uuidString.lowercased())"
                }
                let callID = id!
                emittedToolIDs.insert(callID)
                events.append(.toolCall(AgentToolCall(
                    id: callID,
                    name: name,
                    arguments: call["args"] ?? .object([:])
                )))
            }
        }
        if let reason = candidate["finishReason"]?.stringValue {
            finishReason = geminiFinishReason(reason)
        }
        return events
    }

    mutating func finishIfNeeded() -> [ModelStreamEvent] {
        guard !didFinish else { return [] }
        didFinish = true
        var events: [ModelStreamEvent] = []
        if !continuationParts.isEmpty {
            events.append(.providerContinuation(ProviderContinuation(
                providerIdentifier: providerIdentifier,
                format: "gemini.content",
                payload: .object([
                    "role": .string("model"),
                    "parts": .array(continuationParts),
                ])
            )))
        }
        if let usage { events.append(.usage(usage)) }
        let reason: ModelFinishReason
        if !emittedToolIDs.isEmpty, finishReason == nil || finishReason == .stop {
            reason = .toolCalls
        } else {
            reason = finishReason ?? .unknown
        }
        events.append(.finish(reason))
        return events
    }

    private mutating func recordContinuationPart(_ part: JSONValue) {
        // Preserve every streamed part verbatim. In particular, Google forbids
        // merging a part that carries a thought signature with any other part.
        continuationParts.append(part)
    }

    private func geminiFinishReason(_ value: String) -> ModelFinishReason {
        switch value {
        case "STOP": .stop
        case "MAX_TOKENS": .length
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII": .contentFilter
        default: .unknown
        }
    }
}

public typealias GeminiProvider = GeminiGenerateContentProvider
public typealias GoogleGeminiProvider = GeminiGenerateContentProvider
