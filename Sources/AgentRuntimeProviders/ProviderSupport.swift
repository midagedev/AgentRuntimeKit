import AgentRuntimeCore
import Foundation

public struct ProviderHTTPError: LocalizedError, Sendable, Equatable {
    public var statusCode: Int
    public var category: ProviderFailureCategory
    public var message: String
    public var requestID: String?
    public var rateLimit: ProviderRateLimit

    public init(
        statusCode: Int,
        category: ProviderFailureCategory? = nil,
        message: String,
        requestID: String? = nil,
        rateLimit: ProviderRateLimit = ProviderRateLimit()
    ) {
        self.statusCode = statusCode
        self.category = category ?? Self.category(for: statusCode)
        self.message = message
        self.requestID = requestID
        self.rateLimit = rateLimit
    }

    public var isRetryable: Bool {
        statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
    }

    public var errorDescription: String? {
        var description = "Provider request failed with HTTP \(statusCode): \(message)"
        if let requestID, !requestID.isEmpty {
            description += " (request ID: \(requestID))"
        }
        return description
    }

    private static func category(for statusCode: Int) -> ProviderFailureCategory {
        switch statusCode {
        case 401: .authentication
        case 403: .permission
        case 429: .rateLimited
        case 400..<500: .invalidRequest
        case 502, 503, 504: .unavailable
        case 500...599: .server
        default: .unknown
        }
    }
}

public struct ProviderStreamError: LocalizedError, Sendable, Equatable {
    public var providerIdentifier: String
    public var message: String
    public var code: String?

    public init(providerIdentifier: String, message: String, code: String? = nil) {
        self.providerIdentifier = providerIdentifier
        self.message = message
        self.code = code
    }

    public var errorDescription: String? {
        if let code {
            "Provider '\(providerIdentifier)' stream failed (\(code)): \(message)"
        } else {
            "Provider '\(providerIdentifier)' stream failed: \(message)"
        }
    }
}

typealias ModelEventContinuation = AsyncThrowingStream<ModelStreamEvent, Error>.Continuation

func makeModelEventStream(
    _ operation: @escaping @Sendable (ModelEventContinuation) async throws -> Void
) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await operation(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
    }
}

func validateSuccessfulResponse(
    _ response: StreamingHTTPResponse,
    bodyLimit: Int = 64 * 1_024
) async throws {
    guard !(200..<300).contains(response.statusCode) else { return }

    var data = Data()
    for try await chunk in response.body {
        if data.count + chunk.count > bodyLimit {
            let remaining = max(0, bodyLimit - data.count)
            data.append(chunk.prefix(remaining))
            break
        }
        data.append(chunk)
    }
    let body = data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    let parsed = body.flatMap { try? JSONValue.parse($0) }
    let message = parsed?.providerErrorMessage
        ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
    let requestID = response.header(named: "x-request-id")
        ?? response.header(named: "request-id")
    throw ProviderHTTPError(
        statusCode: response.statusCode,
        message: message,
        requestID: requestID,
        rateLimit: normalizedRateLimit(from: response)
    )
}

func processSSE(
    _ response: StreamingHTTPResponse,
    handler: (ServerSentEvent) throws -> Void
) async throws {
    var parser = ServerSentEventsParser()
    for try await chunk in response.body {
        try Task.checkCancellation()
        for event in parser.feed(chunk) {
            try handler(event)
        }
    }
    for event in parser.finish() {
        try handler(event)
    }
}

func jsonBody(_ value: JSONValue) throws -> Data {
    try value.encodedData(sortedKeys: false)
}

func parseEventJSON(_ event: ServerSentEvent, provider: String) throws -> JSONValue {
    do {
        return try JSONValue.parse(event.data)
    } catch {
        throw AgentRuntimeError.invalidProviderResponse(
            "\(provider) returned malformed SSE JSON for event '\(event.event ?? "message")': \(error.localizedDescription)"
        )
    }
}

func parseToolArguments(_ value: String, provider: String, toolName: String) throws -> JSONValue {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return .object([:]) }
    do {
        return try JSONValue.parse(normalized)
    } catch {
        throw AgentRuntimeError.invalidProviderResponse(
            "\(provider) returned invalid JSON arguments for tool '\(toolName)': \(error.localizedDescription)"
        )
    }
}

func contentString(_ value: JSONValue) -> String {
    if case .string(let text) = value { return text }
    return (try? value.encodedString(sortedKeys: false)) ?? String(describing: value)
}

func openAIFinishReason(_ value: String?) -> ModelFinishReason {
    switch value {
    case "stop": .stop
    case "tool_calls", "function_call": .toolCalls
    case "length", "max_tokens": .length
    case "content_filter": .contentFilter
    case nil: .unknown
    default: .unknown
    }
}

extension JSONValue {
    var intValue: Int? {
        switch self {
        case .number(let value) where value.isFinite:
            return Int(exactly: value)
        case .integer(let value):
            return Int(exactly: value)
        case .unsignedInteger(let value):
            return Int(exactly: value)
        case .decimal(let value):
            let number = NSDecimalNumber(decimal: value)
            let integer = number.int64Value
            return Decimal(integer) == value ? Int(exactly: integer) : nil
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        case .unsignedInteger(let value): Double(value)
        case .decimal(let value): NSDecimalNumber(decimal: value).doubleValue
        default: nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var providerErrorMessage: String? {
        if let message = self["message"]?.stringValue { return message }
        if let error = self["error"] {
            if let message = error["message"]?.stringValue { return message }
            if let text = error.stringValue { return text }
        }
        return nil
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    mutating func set(_ key: String, _ value: JSONValue?) {
        if let value { self[key] = value }
    }
}
