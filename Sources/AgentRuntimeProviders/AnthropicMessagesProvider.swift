import AgentRuntimeCore
import Foundation

/// Streaming adapter for Anthropic's Messages API.
public struct AnthropicMessagesProvider: ModelProvider, Sendable {
    public let identifier: String
    public let capabilities: ProviderCapabilities = [
        .streaming, .tools, .parallelTools, .vision, .structuredOutput, .reasoning, .promptCaching,
    ]

    private let endpoint: URL
    private let apiVersion: String
    private let defaultMaxOutputTokens: Int
    private let additionalHeaders: [String: String]
    private let authentication: ProviderHeaderAuthentication?
    private let httpClient: any StreamingHTTPClient
    private let retryPolicy: ProviderRetryPolicy

    public init(
        identifier: String = "anthropic",
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        apiVersion: String = "2023-06-01",
        defaultMaxOutputTokens: Int = 4_096,
        additionalHeaders: [String: String] = [:],
        credentialResolver: (any ProviderCredentialResolving)? = nil,
        credentialHeaderName: String = "x-api-key",
        credentialPrefix: String = "",
        retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(),
        httpClient: any StreamingHTTPClient = URLSessionStreamingHTTPClient()
    ) {
        self.identifier = identifier
        self.endpoint = endpoint
        self.apiVersion = apiVersion
        self.defaultMaxOutputTokens = max(1, defaultMaxOutputTokens)
        self.additionalHeaders = additionalHeaders
        self.authentication = credentialResolver.map {
            ProviderHeaderAuthentication(
                resolver: $0,
                headerName: credentialHeaderName,
                prefix: credentialPrefix
            )
        }
        self.retryPolicy = retryPolicy
        self.httpClient = httpClient
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        makeModelEventStream { continuation in
            let payload = try makeAnthropicRequest(request)
            var headers = additionalHeaders
            headers["content-type"] = "application/json"
            headers["accept"] = "text/event-stream"
            headers["anthropic-version"] = apiVersion
            if let authentication {
                try await authentication.apply(to: &headers, providerIdentifier: identifier)
            }

            let response = try await performProviderRequest(StreamingHTTPRequest(
                url: endpoint,
                headers: headers,
                body: try jsonBody(payload)
            ), using: httpClient, retryPolicy: retryPolicy)
            let rateLimit = normalizedRateLimit(from: response)
            if !rateLimit.isEmpty {
                continuation.yield(.metadata(["rateLimit": rateLimit.metadataValue]))
            }

            var state = AnthropicStreamState(providerIdentifier: identifier)
            try await processSSE(response) { event in
                guard event.data != "[DONE]" else { return }
                let json = try parseEventJSON(event, provider: identifier)
                for normalized in try state.consume(json, eventName: event.event) {
                    continuation.yield(normalized)
                }
            }
            for normalized in try state.finishIfNeeded() {
                continuation.yield(normalized)
            }
        }
    }

    private func makeAnthropicRequest(_ request: ModelRequest) throws -> JSONValue {
        let system = request.messages
            .filter { $0.role == .system }
            .flatMap(\.content)
            .compactMap { content -> String? in
                guard case .text(let text) = content else { return nil }
                return text
            }
            .joined(separator: "\n\n")

        let messages = try request.messages
            .filter { $0.role != .system }
            .map(anthropicMessage)

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "max_tokens": .number(Double(request.maxOutputTokens ?? defaultMaxOutputTokens)),
            "stream": .bool(true),
        ]
        if !system.isEmpty { body["system"] = .string(system) }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                ])
            })
        }
        if let schema = request.responseSchema {
            body["output_config"] = .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "schema": schema,
                ]),
            ])
        }
        if let userID = request.providerMetadata["user_id"]?.stringValue {
            body["metadata"] = .object(["user_id": .string(userID)])
        }
        return .object(body)
    }

    private func anthropicMessage(_ message: AgentMessage) throws -> JSONValue {
        let role = message.role == .assistant ? "assistant" : "user"
        if message.role == .assistant,
           let continuation = message.providerContinuation,
           continuation.providerIdentifier == identifier,
           continuation.format == "anthropic.content-blocks",
           continuation.formatVersion == 1,
           continuation.payload.arrayValue != nil {
            return .object([
                "role": .string(role),
                "content": continuation.payload,
            ])
        }
        var blocks: [JSONValue] = []

        for content in message.content {
            switch content {
            case .text(let text):
                blocks.append(.object(["type": .string("text"), "text": .string(text)]))
            case .image(let image):
                let source: JSONValue
                switch image.source {
                case .url(let url):
                    source = .object(["type": .string("url"), "url": .string(url.absoluteString)])
                case .base64(let mediaType, let data):
                    source = .object([
                        "type": .string("base64"),
                        "media_type": .string(mediaType),
                        "data": .string(data),
                    ])
                }
                blocks.append(.object(["type": .string("image"), "source": source]))
            case .toolCall(let call):
                blocks.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "input": call.arguments,
                ]))
            case .toolResult(let result):
                blocks.append(.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(result.toolCallID),
                    "content": .string(contentString(result.content)),
                    "is_error": .bool(result.isError),
                ]))
            }
        }
        return .object(["role": .string(role), "content": .array(blocks)])
    }
}

private struct AnthropicStreamState {
    struct PendingTool {
        var id: String
        var name: String
        var initialArguments: JSONValue?
        var argumentFragments = ""
    }

    let providerIdentifier: String
    var pendingTools: [Int: PendingTool] = [:]
    var usage = AgentTokenUsage()
    var hasUsage = false
    var finishReason: ModelFinishReason?
    var didFinish = false
    var continuationBlocks: [Int: JSONValue] = [:]
    var emittedToolCount = 0

    mutating func consume(_ json: JSONValue, eventName: String?) throws -> [ModelStreamEvent] {
        let type = json["type"]?.stringValue ?? eventName
        switch type {
        case "ping":
            return []
        case "error":
            let error = json["error"] ?? json
            throw ProviderStreamError(
                providerIdentifier: providerIdentifier,
                message: sanitizedProviderErrorMessage(
                    error["message"]?.stringValue ?? "Unknown Anthropic stream error",
                    fallback: "Unknown Anthropic stream error"
                ),
                code: sanitizedProviderDiagnosticIdentifier(error["type"]?.stringValue)
            )
        case "message_start":
            if let message = json["message"] {
                updateUsage(message["usage"])
                var metadata: [String: JSONValue] = [:]
                if let id = message["id"] { metadata["id"] = id }
                if let model = message["model"] { metadata["model"] = model }
                if !metadata.isEmpty { return [.metadata(metadata)] }
            }
            return []
        case "content_block_start":
            guard let index = json["index"]?.intValue,
                  let block = json["content_block"] else { return [] }
            continuationBlocks[index] = block
            if block["type"]?.stringValue == "tool_use" {
                pendingTools[index] = PendingTool(
                    id: block["id"]?.stringValue ?? "tool_\(index)",
                    name: block["name"]?.stringValue ?? "",
                    initialArguments: block["input"]
                )
            } else if block["type"]?.stringValue == "text",
                      let text = block["text"]?.stringValue,
                      !text.isEmpty {
                return [.textDelta(text)]
            } else if block["type"]?.stringValue == "thinking",
                      let thinking = block["thinking"]?.stringValue,
                      !thinking.isEmpty {
                return [.reasoningDelta(thinking)]
            }
            return []
        case "content_block_delta":
            let delta = json["delta"]
            switch delta?["type"]?.stringValue {
            case "text_delta":
                if let index = json["index"]?.intValue,
                   let text = delta?["text"]?.stringValue {
                    append(text, to: "text", blockAt: index)
                }
                return delta?["text"]?.stringValue.map { [.textDelta($0)] } ?? []
            case "thinking_delta":
                if let index = json["index"]?.intValue,
                   let thinking = delta?["thinking"]?.stringValue {
                    append(thinking, to: "thinking", blockAt: index)
                }
                return delta?["thinking"]?.stringValue.map { [.reasoningDelta($0)] } ?? []
            case "signature_delta":
                if let index = json["index"]?.intValue,
                   let signature = delta?["signature"]?.stringValue {
                    append(signature, to: "signature", blockAt: index)
                }
                return []
            case "input_json_delta":
                if let index = json["index"]?.intValue,
                   let fragment = delta?["partial_json"]?.stringValue {
                    pendingTools[index]?.argumentFragments += fragment
                }
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let index = json["index"]?.intValue,
                  let tool = pendingTools.removeValue(forKey: index) else { return [] }
            let call = try makeToolCall(tool)
            if var block = continuationBlocks[index]?.objectValue {
                block["input"] = call.arguments
                continuationBlocks[index] = .object(block)
            }
            emittedToolCount += 1
            return [.toolCall(call)]
        case "message_delta":
            updateUsage(json["usage"])
            if let stopReason = json["delta"]?["stop_reason"]?.stringValue {
                finishReason = anthropicFinishReason(stopReason)
            }
            return []
        case "message_stop":
            return try finishIfNeeded()
        default:
            return []
        }
    }

    mutating func finishIfNeeded() throws -> [ModelStreamEvent] {
        guard !didFinish else { return [] }
        didFinish = true
        var events: [ModelStreamEvent] = []
        for index in pendingTools.keys.sorted() {
            if let tool = pendingTools[index] {
                let call = try makeToolCall(tool)
                if var block = continuationBlocks[index]?.objectValue {
                    block["input"] = call.arguments
                    continuationBlocks[index] = .object(block)
                }
                events.append(.toolCall(call))
                emittedToolCount += 1
            }
        }
        pendingTools.removeAll()
        if !continuationBlocks.isEmpty {
            events.append(.providerContinuation(ProviderContinuation(
                providerIdentifier: providerIdentifier,
                format: "anthropic.content-blocks",
                payload: .array(continuationBlocks.keys.sorted().compactMap {
                    continuationBlocks[$0]
                })
            )))
        }
        if hasUsage { events.append(.usage(usage)) }
        events.append(.finish(finishReason ?? (emittedToolCount > 0 ? .toolCalls : .unknown)))
        return events
    }

    private mutating func append(_ fragment: String, to field: String, blockAt index: Int) {
        guard var block = continuationBlocks[index]?.objectValue else { return }
        block[field] = .string((block[field]?.stringValue ?? "") + fragment)
        continuationBlocks[index] = .object(block)
    }

    private func makeToolCall(_ tool: PendingTool) throws -> AgentToolCall {
        let arguments: JSONValue
        if !tool.argumentFragments.isEmpty {
            arguments = try parseToolArguments(
                tool.argumentFragments,
                provider: providerIdentifier,
                toolName: tool.name
            )
        } else {
            arguments = tool.initialArguments ?? .object([:])
        }
        return AgentToolCall(id: tool.id, name: tool.name, arguments: arguments)
    }

    private mutating func updateUsage(_ value: JSONValue?) {
        guard let value else { return }
        if let input = value["input_tokens"]?.intValue {
            usage.inputTokens = input
            hasUsage = true
        }
        if let output = value["output_tokens"]?.intValue {
            usage.outputTokens = output
            hasUsage = true
        }
        if let cached = value["cache_read_input_tokens"]?.intValue {
            usage.cachedInputTokens = cached
            hasUsage = true
        }
    }

    private func anthropicFinishReason(_ value: String) -> ModelFinishReason {
        switch value {
        case "end_turn", "stop_sequence", "pause_turn": .stop
        case "tool_use": .toolCalls
        case "max_tokens": .length
        case "refusal": .contentFilter
        default: .unknown
        }
    }
}
