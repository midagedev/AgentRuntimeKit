import AgentRuntimeCore
import Foundation

/// Streaming adapter for OpenAI Chat Completions and compatible `/chat/completions` APIs.
/// Customize the endpoint, identifier, authorization header, and token parameter for local
/// or third-party OpenAI-compatible servers.
public struct OpenAIChatCompletionsProvider: ModelProvider, Sendable {
    public let identifier: String
    public let capabilities: ProviderCapabilities = [
        .streaming, .tools, .parallelTools, .vision, .structuredOutput, .reasoning,
    ]

    private let endpoint: URL
    private let authentication: ProviderHeaderAuthentication?
    private let httpClient: any StreamingHTTPClient
    private let authorizationHeader: String
    private let authorizationPrefix: String
    private let maxOutputTokensParameter: String
    private let includeUsageInStream: Bool
    private let additionalHeaders: [String: String]
    private let retryPolicy: ProviderRetryPolicy

    public init(
        identifier: String = "openai",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        credentialResolver: (any ProviderCredentialResolving)? = nil,
        authorizationHeader: String = "authorization",
        authorizationPrefix: String = "Bearer ",
        maxOutputTokensParameter: String = "max_completion_tokens",
        includeUsageInStream: Bool = true,
        additionalHeaders: [String: String] = [:],
        retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(),
        httpClient: any StreamingHTTPClient = URLSessionStreamingHTTPClient()
    ) {
        self.identifier = identifier
        self.endpoint = endpoint
        self.authentication = credentialResolver.map {
            ProviderHeaderAuthentication(
                resolver: $0,
                headerName: authorizationHeader,
                prefix: authorizationPrefix
            )
        }
        self.authorizationHeader = authorizationHeader
        self.authorizationPrefix = authorizationPrefix
        self.maxOutputTokensParameter = maxOutputTokensParameter
        self.includeUsageInStream = includeUsageInStream
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

            let payload = try makeChatCompletionsRequest(request)
            let response = try await performProviderRequest(StreamingHTTPRequest(
                url: endpoint,
                headers: headers,
                body: try jsonBody(payload)
            ), using: httpClient, retryPolicy: retryPolicy)
            let rateLimit = normalizedRateLimit(from: response)
            if !rateLimit.isEmpty {
                continuation.yield(.metadata(["rateLimit": rateLimit.metadataValue]))
            }

            var state = OpenAIChatStreamState(providerIdentifier: identifier)
            try await processSSE(response) { event in
                guard event.data != "[DONE]" else { return }
                let json = try parseEventJSON(event, provider: identifier)
                for normalized in try state.consume(json) {
                    continuation.yield(normalized)
                }
            }
            for normalized in try state.finishIfNeeded() {
                continuation.yield(normalized)
            }
        }
    }

    private func makeChatCompletionsRequest(_ request: ModelRequest) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(try request.messages.flatMap(openAIChatMessages)),
            "stream": .bool(true),
        ]
        if includeUsageInStream {
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if let maxTokens = request.maxOutputTokens {
            body[maxOutputTokensParameter] = .number(Double(maxTokens))
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { descriptor in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(descriptor.name),
                        "description": .string(descriptor.description),
                        "parameters": descriptor.inputSchema,
                    ]),
                ])
            })
            body["parallel_tool_calls"] = .bool(true)
        }
        if let schema = request.responseSchema {
            let name = request.providerMetadata["response_schema_name"]?.stringValue
                ?? "agent_response"
            body["response_format"] = .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string(name),
                    "strict": .bool(true),
                    "schema": schema,
                ]),
            ])
        }
        return .object(body)
    }

    private func openAIChatMessages(_ message: AgentMessage) throws -> [JSONValue] {
        if message.role == .tool {
            return message.content.compactMap { content -> JSONValue? in
                guard case .toolResult(let result) = content else { return nil }
                return .object([
                    "role": .string("tool"),
                    "tool_call_id": .string(result.toolCallID),
                    "content": .string(contentString(result.content)),
                ])
            }
        }

        let role = message.role.rawValue
        if role == "system" {
            return [.object(["role": .string(role), "content": .string(message.text)])]
        }

        if role == "assistant" {
            var object: [String: JSONValue] = ["role": .string(role)]
            object["content"] = message.text.isEmpty ? .null : .string(message.text)
            let calls = message.toolCalls
            if !calls.isEmpty {
                object["tool_calls"] = .array(try calls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string(try call.arguments.encodedString(sortedKeys: false)),
                        ]),
                    ])
                })
            }
            return [.object(object)]
        }

        var blocks: [JSONValue] = []
        var toolMessages: [JSONValue] = []
        for content in message.content {
            switch content {
            case .text(let text):
                blocks.append(.object(["type": .string("text"), "text": .string(text)]))
            case .image(let image):
                let url: String
                switch image.source {
                case .url(let sourceURL):
                    url = sourceURL.absoluteString
                case .base64(let mediaType, let data):
                    url = "data:\(mediaType);base64,\(data)"
                }
                var imageURL: [String: JSONValue] = ["url": .string(url)]
                if let detail = image.detail { imageURL["detail"] = .string(detail) }
                blocks.append(.object([
                    "type": .string("image_url"),
                    "image_url": .object(imageURL),
                ]))
            case .toolCall:
                break // Tool calls are represented on assistant messages above.
            case .toolResult(let result):
                toolMessages.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(result.toolCallID),
                    "content": .string(contentString(result.content)),
                ]))
            }
        }
        var result: [JSONValue] = []
        if !blocks.isEmpty {
            result.append(.object(["role": .string(role), "content": .array(blocks)]))
        }
        result.append(contentsOf: toolMessages)
        return result
    }
}

private struct OpenAIChatStreamState {
    struct PendingTool {
        var id = ""
        var name = ""
        var arguments = ""
    }

    let providerIdentifier: String
    var pendingTools: [Int: PendingTool] = [:]
    var usage: AgentTokenUsage?
    var finishReason: ModelFinishReason?
    var emittedMetadata = false
    var didFinish = false

    mutating func consume(_ json: JSONValue) throws -> [ModelStreamEvent] {
        if let error = json["error"] {
            throw ProviderStreamError(
                providerIdentifier: providerIdentifier,
                message: sanitizedProviderErrorMessage(
                    error["message"]?.stringValue ?? "OpenAI-compatible stream failed",
                    fallback: "OpenAI-compatible stream failed"
                ),
                code: sanitizedProviderDiagnosticIdentifier(
                    error["code"]?.stringValue ?? error["type"]?.stringValue
                )
            )
        }

        var events: [ModelStreamEvent] = []
        if !emittedMetadata {
            var metadata: [String: JSONValue] = [:]
            if let id = json["id"] { metadata["id"] = id }
            if let model = json["model"] { metadata["model"] = model }
            if !metadata.isEmpty {
                events.append(.metadata(metadata))
                emittedMetadata = true
            }
        }

        if let usageJSON = json["usage"] {
            usage = AgentTokenUsage(
                inputTokens: usageJSON["prompt_tokens"]?.intValue ?? 0,
                outputTokens: usageJSON["completion_tokens"]?.intValue ?? 0,
                cachedInputTokens: usageJSON["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
            )
        }

        guard let choices = json["choices"]?.arrayValue,
              let choice = choices.first(where: { $0["index"]?.intValue == 0 }) ?? choices.first else {
            return events
        }
        let delta = choice["delta"]
        if let text = delta?["content"]?.stringValue, !text.isEmpty {
            events.append(.textDelta(text))
        } else if let parts = delta?["content"]?.arrayValue {
            for part in parts {
                if let text = part["text"]?.stringValue, !text.isEmpty {
                    events.append(.textDelta(text))
                }
            }
        }
        if let reasoning = delta?["reasoning_content"]?.stringValue
            ?? delta?["reasoning"]?.stringValue,
           !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let calls = delta?["tool_calls"]?.arrayValue {
            for call in calls {
                let index = call["index"]?.intValue ?? 0
                var pending = pendingTools[index] ?? PendingTool()
                if let id = call["id"]?.stringValue { pending.id = id }
                if let name = call["function"]?["name"]?.stringValue { pending.name += name }
                if let arguments = call["function"]?["arguments"]?.stringValue {
                    pending.arguments += arguments
                }
                pendingTools[index] = pending
            }
        }
        if let reason = choice["finish_reason"]?.stringValue {
            finishReason = openAIFinishReason(reason)
        }
        return events
    }

    mutating func finishIfNeeded() throws -> [ModelStreamEvent] {
        guard !didFinish else { return [] }
        didFinish = true
        var events: [ModelStreamEvent] = []
        for index in pendingTools.keys.sorted() {
            guard let pending = pendingTools[index] else { continue }
            events.append(.toolCall(AgentToolCall(
                id: pending.id.isEmpty ? "tool_\(index)" : pending.id,
                name: pending.name,
                arguments: try parseToolArguments(
                    pending.arguments,
                    provider: providerIdentifier,
                    toolName: pending.name
                )
            )))
        }
        if let usage { events.append(.usage(usage)) }
        events.append(.finish(finishReason ?? (pendingTools.isEmpty ? .unknown : .toolCalls)))
        return events
    }
}

/// Descriptive alias for hosts using a third-party or local compatible endpoint.
public typealias OpenAICompatibleChatCompletionsProvider = OpenAIChatCompletionsProvider
