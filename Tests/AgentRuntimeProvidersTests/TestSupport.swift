import AgentRuntimeCore
import AgentRuntimeProviders
import Foundation

enum ProviderTestError: Error, Sendable, Equatable {
    case noFixture
    case fixtureFailure
}

struct FixtureHTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var chunks: [Data]

    init(statusCode: Int = 200, headers: [String: String] = [:], chunks: [Data]) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks
    }
}

actor FixtureHTTPClient: StreamingHTTPClient {
    private var fixtures: [FixtureHTTPResponse]
    private var capturedRequests: [StreamingHTTPRequest] = []

    init(_ fixtures: [FixtureHTTPResponse]) {
        self.fixtures = fixtures
    }

    func stream(_ request: StreamingHTTPRequest) async throws -> StreamingHTTPResponse {
        capturedRequests.append(request)
        guard !fixtures.isEmpty else { throw ProviderTestError.noFixture }
        let fixture = fixtures.removeFirst()
        let chunks = fixture.chunks
        return StreamingHTTPResponse(
            statusCode: fixture.statusCode,
            headers: fixture.headers,
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }

    func requests() -> [StreamingHTTPRequest] { capturedRequests }
}

actor TestSecretStore: AgentSecretStore {
    private var values: [String: String] = [:]

    func loadSecret(namespace: String, account: String) -> String? {
        values["\(namespace)|\(account)"]
    }

    func saveSecret(_ value: String, namespace: String, account: String) {
        values["\(namespace)|\(account)"] = value
    }

    func deleteSecret(namespace: String, account: String) {
        values["\(namespace)|\(account)"] = nil
    }
}

struct StubModelProvider: ModelProvider, Sendable {
    var identifier: String
    var capabilities: ProviderCapabilities
    var events: [ModelStreamEvent]
    var failure: ProviderTestError?

    init(
        identifier: String,
        capabilities: ProviderCapabilities = [.streaming, .tools],
        events: [ModelStreamEvent] = [],
        failure: ProviderTestError? = nil
    ) {
        self.identifier = identifier
        self.capabilities = capabilities
        self.events = events
        self.failure = failure
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

func loadFixture(_ name: String) throws -> Data {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return try Data(contentsOf: testDirectory.appendingPathComponent(".Fixtures/\(name)"))
}

func chunked(_ data: Data, sizes: [Int] = [1, 2, 5, 3, 13, 8]) -> [Data] {
    precondition(!sizes.isEmpty && sizes.allSatisfy { $0 > 0 })
    var chunks: [Data] = []
    var offset = 0
    var sizeIndex = 0
    while offset < data.count {
        let count = min(sizes[sizeIndex % sizes.count], data.count - offset)
        chunks.append(data.subdata(in: offset..<(offset + count)))
        offset += count
        sizeIndex += 1
    }
    return chunks
}

func collectEvents(
    _ stream: AsyncThrowingStream<ModelStreamEvent, Error>
) async throws -> [ModelStreamEvent] {
    var events: [ModelStreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

func textOutput(_ events: [ModelStreamEvent]) -> String {
    events.compactMap { event in
        guard case .textDelta(let text) = event else { return nil }
        return text
    }.joined()
}

func reasoningOutput(_ events: [ModelStreamEvent]) -> String {
    events.compactMap { event in
        guard case .reasoningDelta(let text) = event else { return nil }
        return text
    }.joined()
}

func toolCalls(_ events: [ModelStreamEvent]) -> [AgentToolCall] {
    events.compactMap { event in
        guard case .toolCall(let call) = event else { return nil }
        return call
    }
}

func finalUsage(_ events: [ModelStreamEvent]) -> AgentTokenUsage? {
    events.reversed().compactMap { event -> AgentTokenUsage? in
        guard case .usage(let usage) = event else { return nil }
        return usage
    }.first
}

func finalReason(_ events: [ModelStreamEvent]) -> ModelFinishReason? {
    events.reversed().compactMap { event -> ModelFinishReason? in
        guard case .finish(let reason) = event else { return nil }
        return reason
    }.first
}

func finalContinuation(_ events: [ModelStreamEvent]) -> ProviderContinuation? {
    events.reversed().compactMap { event -> ProviderContinuation? in
        guard case .providerContinuation(let continuation) = event else { return nil }
        return continuation
    }.first
}

func header(_ name: String, in request: StreamingHTTPRequest) -> String? {
    request.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}

func bodyJSON(_ request: StreamingHTTPRequest) throws -> JSONValue {
    try JSONValue.parse(request.body ?? Data())
}

let fixtureTool = AgentToolDescriptor(
    name: "weather",
    description: "Get weather",
    inputSchema: [
        "type": "object",
        "properties": ["city": ["type": "string"]],
        "required": ["city"],
    ]
)

func fixtureRequest(model: String = "fixture-model") -> ModelRequest {
    ModelRequest(
        model: model,
        messages: [
            AgentMessage(role: .system, text: "Be concise."),
            AgentMessage(role: .user, content: [
                .text("Weather?"),
                .image(AgentImage(source: .base64(mediaType: "image/png", data: "aGVsbG8="))),
            ]),
        ],
        tools: [fixtureTool],
        temperature: 0.25,
        maxOutputTokens: 128,
        responseSchema: [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ],
        metadata: ["local_health_context_id": "must-not-leave-device"],
        providerMetadata: [
            "response_schema_name": "fixture_response",
            "metadata": .object(["test_run": .string("fixture")]),
        ]
    )
}
