import AgentRuntimeCore
import Foundation

/// Streaming adapter for OpenAI's Responses API.
public struct OpenAIResponsesProvider: ModelProvider, Sendable {
    public let identifier: String
    public let capabilities: ProviderCapabilities = [
        .streaming, .tools, .parallelTools, .vision, .structuredOutput, .reasoning, .promptCaching,
    ]

    private let endpoint: URL
    private let authentication: ProviderHeaderAuthentication?
    private let additionalHeaders: [String: String]
    private let retryPolicy: ProviderRetryPolicy
    private let httpClient: any StreamingHTTPClient
    private let storeResponses: Bool
    private let strictToolSchemas: Bool

    public init(
        identifier: String = "openai-responses",
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        credentialResolver: (any ProviderCredentialResolving)? = nil,
        authorizationHeader: String = "authorization",
        authorizationPrefix: String = "Bearer ",
        additionalHeaders: [String: String] = [:],
        storeResponses: Bool = false,
        strictToolSchemas: Bool = false,
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
        self.additionalHeaders = additionalHeaders
        self.storeResponses = storeResponses
        self.strictToolSchemas = strictToolSchemas
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
                url: endpoint,
                headers: headers,
                body: try jsonBody(try makeResponsesRequest(request))
            ), using: httpClient, retryPolicy: retryPolicy)
            let rateLimit = normalizedRateLimit(from: response)
            if !rateLimit.isEmpty {
                continuation.yield(.metadata(["rateLimit": rateLimit.metadataValue]))
            }

            var state = OpenAIResponsesStreamState(providerIdentifier: identifier)
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

    private func makeResponsesRequest(_ request: ModelRequest) throws -> JSONValue {
        let instructions = request.messages
            .filter { $0.role == .system }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "input": .array(try request.messages
                .filter { $0.role != .system }
                .flatMap(responsesInputItems)),
            "stream": .bool(true),
            "store": .bool(storeResponses),
            "include": .array([.string("reasoning.encrypted_content")]),
        ]
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if let maxTokens = request.maxOutputTokens {
            body["max_output_tokens"] = .number(Double(maxTokens))
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { descriptor in
                .object([
                    "type": .string("function"),
                    "name": .string(descriptor.name),
                    "description": .string(descriptor.description),
                    "parameters": descriptor.inputSchema,
                    "strict": .bool(strictToolSchemas),
                ])
            })
            body["parallel_tool_calls"] = .bool(true)
        }
        if let schema = request.responseSchema {
            let name = request.providerMetadata["response_schema_name"]?.stringValue
                ?? "agent_response"
            body["text"] = .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(name),
                    "strict": .bool(true),
                    "schema": schema,
                ]),
            ])
        }
        let stringMetadata = request.providerMetadata["metadata"]?.objectValue?
            .compactMapValues { $0.stringValue } ?? [:]
        if !stringMetadata.isEmpty {
            body["metadata"] = .object(stringMetadata.mapValues(JSONValue.string))
        }
        return .object(body)
    }

    private func responsesInputItems(_ message: AgentMessage) throws -> [JSONValue] {
        if message.role == .assistant,
           let continuation = message.providerContinuation,
           continuation.providerIdentifier == identifier,
           continuation.format == "openai.responses.output-items",
           continuation.formatVersion == 1,
           let items = continuation.payload.arrayValue {
            return items
        }
        if message.role == .tool {
            return message.content.compactMap { content -> JSONValue? in
                guard case .toolResult(let result) = content else { return nil }
                return .object([
                    "type": .string("function_call_output"),
                    "call_id": .string(result.toolCallID),
                    "output": .string(contentString(result.content)),
                ])
            }
        }

        var contentItems: [JSONValue] = []
        var standaloneItems: [JSONValue] = []
        let isAssistant = message.role == .assistant

        for content in message.content {
            switch content {
            case .text(let text):
                contentItems.append(.object([
                    "type": .string(isAssistant ? "output_text" : "input_text"),
                    "text": .string(text),
                ]))
            case .image(let image):
                let url: String
                switch image.source {
                case .url(let sourceURL):
                    url = sourceURL.absoluteString
                case .base64(let mediaType, let data):
                    url = "data:\(mediaType);base64,\(data)"
                }
                var item: [String: JSONValue] = [
                    "type": .string("input_image"),
                    "image_url": .string(url),
                ]
                if let detail = image.detail { item["detail"] = .string(detail) }
                contentItems.append(.object(item))
            case .toolCall(let call):
                standaloneItems.append(.object([
                    "type": .string("function_call"),
                    "call_id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": .string(try call.arguments.encodedString(sortedKeys: false)),
                ]))
            case .toolResult(let result):
                standaloneItems.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(result.toolCallID),
                    "output": .string(contentString(result.content)),
                ]))
            }
        }

        var result: [JSONValue] = []
        if !contentItems.isEmpty {
            result.append(.object([
                "role": .string(message.role.rawValue),
                "content": .array(contentItems),
            ]))
        }
        result.append(contentsOf: standaloneItems)
        return result
    }
}

private struct OpenAIResponsesStreamState {
    struct PendingTool {
        var id: String
        var name: String
        var arguments: String
    }

    let providerIdentifier: String
    var pendingTools: [String: PendingTool] = [:]
    var emittedToolIDs: Set<String> = []
    var usage: AgentTokenUsage?
    var emittedUsage = false
    var finishReason: ModelFinishReason?
    var didFinish = false
    var continuationItems: [Int: JSONValue] = [:]

    mutating func consume(_ json: JSONValue, eventName: String?) throws -> [ModelStreamEvent] {
        let type = json["type"]?.stringValue ?? eventName ?? ""
        switch type {
        case "error", "response.failed":
            let error = json["error"] ?? json["response"]?["error"] ?? json
            throw ProviderStreamError(
                providerIdentifier: providerIdentifier,
                message: error["message"]?.stringValue ?? "OpenAI Responses stream failed",
                code: error["code"]?.stringValue ?? error["type"]?.stringValue
            )
        case "response.created", "response.in_progress":
            let response = json["response"] ?? json
            var metadata: [String: JSONValue] = [:]
            if let id = response["id"] { metadata["id"] = id }
            if let model = response["model"] { metadata["model"] = model }
            return metadata.isEmpty ? [] : [.metadata(metadata)]
        case "response.output_text.delta":
            return json["delta"]?.stringValue.map { [.textDelta($0)] } ?? []
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            return json["delta"]?.stringValue.map { [.reasoningDelta($0)] } ?? []
        case "response.refusal.delta":
            finishReason = .contentFilter
            return json["delta"]?.stringValue.map { [.textDelta($0)] } ?? []
        case "response.output_item.added":
            if let item = json["item"], item["type"]?.stringValue == "function_call" {
                upsertTool(item, fallbackKey: eventKey(json))
            }
            return []
        case "response.function_call_arguments.delta":
            let key = eventKey(json)
            var tool = pendingTools[key] ?? PendingTool(
                id: json["call_id"]?.stringValue ?? key,
                name: json["name"]?.stringValue ?? "",
                arguments: ""
            )
            tool.arguments += json["delta"]?.stringValue ?? ""
            pendingTools[key] = tool
            return []
        case "response.function_call_arguments.done":
            let key = eventKey(json)
            var tool = pendingTools[key] ?? PendingTool(
                id: json["call_id"]?.stringValue ?? key,
                name: json["name"]?.stringValue ?? "",
                arguments: ""
            )
            if let arguments = json["arguments"]?.stringValue { tool.arguments = arguments }
            if let name = json["name"]?.stringValue { tool.name = name }
            if let callID = json["call_id"]?.stringValue { tool.id = callID }
            pendingTools[key] = tool
            return []
        case "response.output_item.done":
            guard let item = json["item"] else { return [] }
            continuationItems[json["output_index"]?.intValue ?? continuationItems.count] = item
            guard item["type"]?.stringValue == "function_call" else { return [] }
            let key = eventKey(json, item: item)
            upsertTool(item, fallbackKey: key)
            return try emitTool(key: key)
        case "response.completed":
            let response = json["response"] ?? json
            if let output = response["output"]?.arrayValue {
                continuationItems = Dictionary(uniqueKeysWithValues: output.enumerated().map {
                    ($0.offset, $0.element)
                })
            }
            updateUsage(response["usage"])
            var events = try collectResponseTools(response)
            if !continuationItems.isEmpty {
                events.append(continuationEvent())
            }
            if let usage, !emittedUsage {
                events.append(.usage(usage))
                emittedUsage = true
            }
            let hasTools = !emittedToolIDs.isEmpty || !pendingTools.isEmpty
            events.append(.finish(finishReason ?? (hasTools ? .toolCalls : .stop)))
            didFinish = true
            return events
        case "response.incomplete":
            let response = json["response"] ?? json
            updateUsage(response["usage"])
            let reason = response["incomplete_details"]?["reason"]?.stringValue
            finishReason = reason == "content_filter" ? .contentFilter : .length
            return try finishIfNeeded()
        case "response.cancelled":
            finishReason = .cancelled
            return try finishIfNeeded()
        default:
            return []
        }
    }

    mutating func finishIfNeeded() throws -> [ModelStreamEvent] {
        guard !didFinish else { return [] }
        var events: [ModelStreamEvent] = []
        for key in pendingTools.keys.sorted() {
            events.append(contentsOf: try emitTool(key: key))
        }
        if let usage, !emittedUsage {
            events.append(.usage(usage))
            emittedUsage = true
        }
        if !continuationItems.isEmpty {
            events.append(continuationEvent())
        }
        events.append(.finish(finishReason ?? (emittedToolIDs.isEmpty ? .unknown : .toolCalls)))
        didFinish = true
        return events
    }

    private mutating func upsertTool(_ item: JSONValue, fallbackKey: String) {
        let key = item["id"]?.stringValue ?? fallbackKey
        var tool = pendingTools[key] ?? pendingTools[fallbackKey] ?? PendingTool(
            id: item["call_id"]?.stringValue ?? key,
            name: item["name"]?.stringValue ?? "",
            arguments: ""
        )
        if let id = item["call_id"]?.stringValue { tool.id = id }
        if let name = item["name"]?.stringValue { tool.name = name }
        if let arguments = item["arguments"]?.stringValue, !arguments.isEmpty {
            tool.arguments = arguments
        }
        pendingTools[fallbackKey] = nil
        pendingTools[key] = tool
    }

    private mutating func emitTool(key: String) throws -> [ModelStreamEvent] {
        guard let tool = pendingTools.removeValue(forKey: key),
              !emittedToolIDs.contains(tool.id) else { return [] }
        emittedToolIDs.insert(tool.id)
        return [.toolCall(AgentToolCall(
            id: tool.id,
            name: tool.name,
            arguments: try parseToolArguments(
                tool.arguments,
                provider: providerIdentifier,
                toolName: tool.name
            )
        ))]
    }

    private mutating func collectResponseTools(_ response: JSONValue) throws -> [ModelStreamEvent] {
        var events: [ModelStreamEvent] = []
        for (index, item) in (response["output"]?.arrayValue ?? []).enumerated()
            where item["type"]?.stringValue == "function_call" {
            let key = item["id"]?.stringValue ?? "output_\(index)"
            upsertTool(item, fallbackKey: key)
            events.append(contentsOf: try emitTool(key: key))
        }
        return events
    }

    private mutating func updateUsage(_ value: JSONValue?) {
        guard let value else { return }
        usage = AgentTokenUsage(
            inputTokens: value["input_tokens"]?.intValue ?? 0,
            outputTokens: value["output_tokens"]?.intValue ?? 0,
            cachedInputTokens: value["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        )
    }

    private func continuationEvent() -> ModelStreamEvent {
        .providerContinuation(ProviderContinuation(
            providerIdentifier: providerIdentifier,
            format: "openai.responses.output-items",
            payload: .array(continuationItems.keys.sorted().compactMap {
                continuationItems[$0]
            })
        ))
    }

    private func eventKey(_ json: JSONValue, item: JSONValue? = nil) -> String {
        item?["id"]?.stringValue
            ?? json["item_id"]?.stringValue
            ?? json["call_id"]?.stringValue
            ?? "output_\(json["output_index"]?.intValue ?? 0)"
    }
}
