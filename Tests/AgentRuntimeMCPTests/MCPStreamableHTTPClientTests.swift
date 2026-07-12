import AgentRuntimeMCP
import XCTest

final class MCPStreamableHTTPClientTests: XCTestCase {
    func testInsecureHTTPEndpointRequiresExplicitOptIn() throws {
        let endpoint = URL(string: "http://127.0.0.1:8080/mcp")!
        XCTAssertThrowsError(try MCPStreamableHTTPClient(
            configuration: .init(
                endpoint: endpoint,
                clientInfo: MCPImplementationInfo(name: "tests", version: "1")
            ),
            transport: QueueMCPTransport(responses: [])
        )) { error in
            XCTAssertEqual(error as? MCPClientError, .invalidEndpoint)
        }

        XCTAssertNoThrow(try MCPStreamableHTTPClient(
            configuration: .init(
                endpoint: endpoint,
                clientInfo: MCPImplementationInfo(name: "tests", version: "1"),
                allowsInsecureHTTP: true
            ),
            transport: QueueMCPTransport(responses: [])
        ))
    }

    func testInitializeAndPaginatedToolListUseSessionProtocolAndAuthHeaders() async throws {
        let transport = QueueMCPTransport(responses: [
            try rpcResponse(
                id: 1,
                result: initializeResult,
                headers: ["mCp-SeSsIoN-Id": "session-123"]
            ),
            MCPHTTPResponse(statusCode: 202),
            try rpcResponse(
                id: 2,
                result: .object([
                    "tools": .array([toolJSON(name: "read_file")]),
                    "nextCursor": .string("page-2"),
                ])
            ),
            try sseResponse(
                id: 3,
                result: .object(["tools": .array([toolJSON(name: "write_file")])])
            ),
        ])
        let client = try makeClient(transport: transport)

        let initialized = try await client.initialize()
        let tools = try await client.listTools()

        XCTAssertEqual(initialized.serverInfo.name, "test-server")
        let sessionID = await client.sessionID
        XCTAssertEqual(sessionID, "session-123")
        XCTAssertEqual(tools.map(\.name), ["read_file", "write_file"])

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(try requestMethod(in: requests[0]), "initialize")
        XCTAssertEqual(try requestMethod(in: requests[1]), "notifications/initialized")
        XCTAssertEqual(try requestMethod(in: requests[2]), "tools/list")
        XCTAssertEqual(requests[0].header(named: "Authorization"), "Bearer private-token")
        XCTAssertEqual(requests[0].header(named: "X-Client"), "tests")
        XCTAssertNil(requests[0].header(named: "Mcp-Session-Id"))
        XCTAssertEqual(requests[1].header(named: "Mcp-Session-Id"), "session-123")
        XCTAssertEqual(
            requests[1].header(named: "MCP-Protocol-Version"),
            MCPProtocolVersion.streamableHTTP
        )
        XCTAssertEqual(try bodyObject(requests[3])["params"]?["cursor"], .string("page-2"))
        XCTAssertEqual(String(describing: MCPAuthentication.bearer(token: "do-not-print")),
                       "MCPAuthentication([REDACTED])")
    }

    func testToolAdapterMapsAnnotationsArgumentsAndStructuredResult() async throws {
        let transport = QueueMCPTransport(responses: [
            try rpcResponse(id: 1, result: initializeResult),
            MCPHTTPResponse(statusCode: 202),
            try rpcResponse(
                id: 2,
                result: .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("created")]),
                    ]),
                    "structuredContent": .object(["identifier": .number(42)]),
                    "isError": .bool(false),
                    "_meta": .object(["trace": .string("remote")]),
                ])
            ),
        ])
        let client = try makeClient(transport: transport)
        _ = try await client.initialize()
        let definition = MCPToolDefinition(
            name: "create_item",
            description: "Creates an item",
            inputSchema: .object(["type": .string("object")]),
            annotations: MCPToolAnnotations(
                destructiveHint: true,
                idempotentHint: true
            )
        )
        let adapter = MCPToolAdapter(
            definition: definition,
            client: client,
            configuration: MCPToolAdapterConfiguration(trustSideEffectAnnotations: true)
        )

        let output = try await adapter.execute(
            arguments: .object(["title": .string("Example")]),
            context: executionContext
        )

        XCTAssertEqual(adapter.descriptor.risk, .restricted)
        XCTAssertEqual(adapter.descriptor.sideEffect, .idempotent)
        XCTAssertEqual(output.content, .object(["identifier": .number(42)]))
        XCTAssertEqual(output.summary, "created")
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.metadata["mcpMetadata"]?["trace"], .string("remote"))

        let requests = await transport.requests
        let call = try bodyObject(requests[2])
        XCTAssertEqual(call["method"], .string("tools/call"))
        XCTAssertEqual(call["params"]?["name"], .string("create_item"))
        XCTAssertEqual(call["params"]?["arguments"]?["title"], .string("Example"))
    }

    func testRemoteJSONRPCErrorIsMappedWithoutLosingStructuredData() async throws {
        let transport = QueueMCPTransport(responses: [
            try rpcResponse(id: 1, result: initializeResult),
            MCPHTTPResponse(statusCode: 202),
            try rpcErrorResponse(
                id: 2,
                code: -32_602,
                message: "Invalid params",
                data: .object(["field": .string("path")])
            ),
        ])
        let client = try makeClient(transport: transport)
        _ = try await client.initialize()

        do {
            _ = try await client.callTool(name: "read_file", arguments: .object([:]))
            XCTFail("Expected a JSON-RPC error")
        } catch let error as MCPClientError {
            XCTAssertEqual(
                error,
                .remoteError(
                    code: -32_602,
                    message: "Invalid params",
                    data: .object(["field": .string("path")])
                )
            )
        }
    }

    func testUnauthorizedHTTPResponseMapsToAuthenticationErrorAndResetsInitialization() async throws {
        let transport = QueueMCPTransport(responses: [MCPHTTPResponse(statusCode: 401)])
        let client = try makeClient(transport: transport)

        do {
            _ = try await client.initialize()
            XCTFail("Expected authentication failure")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .unauthorized(status: 401))
        }
        let isInitialized = await client.isInitialized
        let sessionID = await client.sessionID
        XCTAssertFalse(isInitialized)
        XCTAssertNil(sessionID)
    }

    func testCancellingRequestCancelsTransportAndSendsMCPNotification() async throws {
        let transport = CancellationMCPTransport()
        let client = try makeClient(transport: transport)
        _ = try await client.initialize()

        let task = Task { try await client.listTools() }
        var requestWaitAttempts = 0
        while await transport.requestCount < 3, requestWaitAttempts < 200 {
            requestWaitAttempts += 1
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation remains CancellationError for AgentRuntime.
        }

        for _ in 0..<200 {
            if await transport.containsMethod("notifications/cancelled") { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let containsCancellation = await transport.containsMethod("notifications/cancelled")
        let cancellationRequest = await transport.request(method: "notifications/cancelled")
        XCTAssertTrue(containsCancellation)
        let cancellation = try XCTUnwrap(cancellationRequest)
        XCTAssertEqual(try bodyObject(cancellation)["params"]?["requestId"], .number(2))
    }

    func testInitializeReturnsFromOpenEventStreamAsSoonAsMatchingResponseArrives() async throws {
        let transport = OpenEventStreamMCPTransport()
        let client = try makeClient(transport: transport)

        let result = try await withThrowingTaskGroup(of: MCPInitializeResult.self) { group in
            group.addTask { try await client.initialize() }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw TestTransportError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        XCTAssertEqual(result.serverInfo.name, "test-server")
        for _ in 0..<100 where !(await transport.wasCancelled) {
            try await Task.sleep(for: .milliseconds(2))
        }
        let wasCancelled = await transport.wasCancelled
        XCTAssertTrue(wasCancelled, "The client must cancel an open SSE body after the match")
    }
}

private let initializeResult: JSONValue = .object([
    "protocolVersion": .string(MCPProtocolVersion.streamableHTTP),
    "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
    "serverInfo": .object([
        "name": .string("test-server"),
        "version": .string("1.0"),
    ]),
])

private let executionContext = AgentToolExecutionContext(
    runID: UUID(),
    sessionID: "agent-session",
    appID: "tests",
    userID: nil,
    agentID: "agent"
)

private func makeClient(transport: any MCPHTTPTransport) throws -> MCPStreamableHTTPClient {
    try MCPStreamableHTTPClient(
        configuration: MCPStreamableHTTPConfiguration(
            endpoint: URL(string: "https://mcp.example.test/rpc")!,
            clientInfo: MCPImplementationInfo(name: "tests", version: "1"),
            authentication: .bearer(token: "private-token"),
            additionalHeaders: ["X-Client": "tests"]
        ),
        transport: transport
    )
}

private func toolJSON(name: String) -> JSONValue {
    .object([
        "name": .string(name),
        "description": .string("Tool \(name)"),
        "inputSchema": .object(["type": .string("object")]),
    ])
}

private func rpcResponse(
    id: Int,
    result: JSONValue,
    headers: [String: String] = [:]
) throws -> MCPHTTPResponse {
    MCPHTTPResponse(
        statusCode: 200,
        headers: headers,
        body: try JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "result": result,
        ]).encodedData()
    )
}

private func rpcErrorResponse(
    id: Int,
    code: Int,
    message: String,
    data: JSONValue?
) throws -> MCPHTTPResponse {
    var error: [String: JSONValue] = [
        "code": .number(Double(code)),
        "message": .string(message),
    ]
    if let data { error["data"] = data }
    return MCPHTTPResponse(
        statusCode: 200,
        body: try JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "error": .object(error),
        ]).encodedData()
    )
}

private func sseResponse(id: Int, result: JSONValue) throws -> MCPHTTPResponse {
    let json = try JSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": .number(Double(id)),
        "result": result,
    ]).encodedString()
    return MCPHTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "text/event-stream"],
        body: Data("id: prime\ndata:\n\nevent: message\ndata: \(json)\n\n".utf8)
    )
}

private func bodyObject(_ request: MCPHTTPRequest) throws -> JSONValue {
    try JSONValue.parse(try XCTUnwrap(request.body))
}

private func requestMethod(in request: MCPHTTPRequest) throws -> String {
    try XCTUnwrap(try bodyObject(request)["method"]?.stringValue)
}

private extension MCPHTTPRequest {
    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private enum TestTransportError: Error {
    case noResponse
    case timedOut
}

private actor OpenEventStreamMCPTransport: MCPHTTPTransport {
    private(set) var wasCancelled = false

    func send(_ request: MCPHTTPRequest) async throws -> MCPHTTPResponse {
        guard try requestMethod(in: request) == "notifications/initialized" else {
            throw TestTransportError.noResponse
        }
        return MCPHTTPResponse(statusCode: 202)
    }

    func stream(_ request: MCPHTTPRequest) async throws -> MCPHTTPStreamingResponse {
        guard try requestMethod(in: request) == "initialize" else {
            throw TestTransportError.noResponse
        }
        let json = try JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "result": initializeResult,
        ]).encodedString()
        let midpoint = json.index(json.startIndex, offsetBy: json.count / 2)
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        pair.continuation.yield(Data("event: message\ndata: \(json[..<midpoint])".utf8))
        pair.continuation.yield(Data("\(json[midpoint...])\n\n".utf8))
        // Deliberately leave the body open like a real long-lived SSE connection.
        return MCPHTTPStreamingResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: pair.stream,
            cancellation: { Task { await self.recordCancellation() } }
        )
    }

    private func recordCancellation() {
        wasCancelled = true
    }
}

private actor QueueMCPTransport: MCPHTTPTransport {
    private var responses: [MCPHTTPResponse]
    private(set) var requests: [MCPHTTPRequest] = []

    init(responses: [MCPHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: MCPHTTPRequest) async throws -> MCPHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw TestTransportError.noResponse }
        return responses.removeFirst()
    }
}

private actor CancellationMCPTransport: MCPHTTPTransport {
    private var requests: [MCPHTTPRequest] = []

    var requestCount: Int { requests.count }

    func send(_ request: MCPHTTPRequest) async throws -> MCPHTTPResponse {
        requests.append(request)
        let method = try requestMethod(in: request)
        switch method {
        case "initialize":
            return try rpcResponse(id: 1, result: initializeResult)
        case "notifications/initialized", "notifications/cancelled":
            return MCPHTTPResponse(statusCode: 202)
        case "tools/list":
            try await Task.sleep(for: .seconds(30))
            throw TestTransportError.noResponse
        default:
            throw TestTransportError.noResponse
        }
    }

    func containsMethod(_ name: String) -> Bool {
        requests.contains { (try? requestMethod(in: $0)) == name }
    }

    func request(method name: String) -> MCPHTTPRequest? {
        requests.first { (try? requestMethod(in: $0)) == name }
    }
}
