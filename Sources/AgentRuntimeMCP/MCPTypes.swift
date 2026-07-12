import Foundation

public enum MCPProtocolVersion {
    /// The supported revision used by default for the core Streamable HTTP tool flow.
    public static let streamableHTTP = "2025-06-18"
    /// The revision that originally introduced Streamable HTTP.
    public static let initialStreamableHTTP = "2025-03-26"
}

public struct MCPImplementationInfo: Sendable, Codable, Hashable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPInitializeResult: Sendable, Codable, Hashable {
    public var protocolVersion: String
    public var capabilities: JSONValue
    public var serverInfo: MCPImplementationInfo
    public var instructions: String?

    public init(
        protocolVersion: String,
        capabilities: JSONValue,
        serverInfo: MCPImplementationInfo,
        instructions: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

public struct MCPToolAnnotations: Sendable, Codable, Hashable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

public struct MCPToolDefinition: Sendable, Codable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: MCPToolAnnotations?
    public var metadata: JSONValue?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        annotations: MCPToolAnnotations? = nil,
        metadata: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, description, inputSchema, outputSchema, annotations
        case metadata = "_meta"
    }
}

public struct MCPToolListPage: Sendable, Codable, Hashable {
    public var tools: [MCPToolDefinition]
    public var nextCursor: String?

    public init(tools: [MCPToolDefinition], nextCursor: String? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }
}

public struct MCPToolCallResult: Sendable, Codable, Hashable {
    public var content: [JSONValue]
    public var structuredContent: JSONValue?
    public var isError: Bool
    public var metadata: JSONValue?

    public init(
        content: [JSONValue] = [],
        structuredContent: JSONValue? = nil,
        isError: Bool = false,
        metadata: JSONValue? = nil
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case content, structuredContent, isError
        case metadata = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode([JSONValue].self, forKey: .content)
        structuredContent = try container.decodeIfPresent(JSONValue.self, forKey: .structuredContent)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }
}

/// Static authentication headers. Its textual representations intentionally omit values.
public struct MCPAuthentication: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    let values: [String: String]

    public init(headers: [String: String]) {
        values = headers
    }

    public static func bearer(token: String) -> MCPAuthentication {
        MCPAuthentication(headers: ["Authorization": "Bearer \(token)"])
    }

    public static func basic(username: String, password: String) -> MCPAuthentication {
        let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
        return MCPAuthentication(headers: ["Authorization": "Basic \(encoded)"])
    }

    public var description: String { "MCPAuthentication([REDACTED])" }
    public var debugDescription: String { description }
}

public struct MCPStreamableHTTPConfiguration: Sendable, Hashable {
    public var endpoint: URL
    public var clientInfo: MCPImplementationInfo
    public var protocolVersion: String
    public var capabilities: JSONValue
    public var authentication: MCPAuthentication?
    public var additionalHeaders: [String: String]
    public var requestTimeout: TimeInterval
    public var allowsInsecureHTTP: Bool

    public init(
        endpoint: URL,
        clientInfo: MCPImplementationInfo,
        protocolVersion: String = MCPProtocolVersion.streamableHTTP,
        capabilities: JSONValue = .object([:]),
        authentication: MCPAuthentication? = nil,
        additionalHeaders: [String: String] = [:],
        requestTimeout: TimeInterval = 60,
        allowsInsecureHTTP: Bool = false
    ) {
        self.endpoint = endpoint
        self.clientInfo = clientInfo
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.authentication = authentication
        self.additionalHeaders = additionalHeaders
        self.requestTimeout = max(1, requestTimeout)
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
}

public enum MCPClientError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case initializationInProgress
    case notInitialized
    case transportFailure
    case requestTimedOut
    case nonHTTPResponse
    case unauthorized(status: Int)
    case httpStatus(Int)
    case sessionExpired
    case invalidResponse(String)
    case protocolVersionMismatch(requested: String, received: String)
    case remoteError(code: Int, message: String, data: JSONValue?)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The MCP endpoint must use HTTPS unless insecure HTTP is explicitly enabled."
        case .initializationInProgress:
            "MCP initialization is already in progress."
        case .notInitialized:
            "The MCP client must be initialized first."
        case .transportFailure:
            "The MCP HTTP transport failed."
        case .requestTimedOut:
            "The MCP request timed out."
        case .nonHTTPResponse:
            "The MCP endpoint did not return an HTTP response."
        case .unauthorized(let status):
            "The MCP endpoint rejected authentication (HTTP \(status))."
        case .httpStatus(let status):
            "The MCP endpoint returned HTTP \(status)."
        case .sessionExpired:
            "The MCP server expired the active session; initialize a new session before retrying."
        case .invalidResponse(let reason):
            "The MCP endpoint returned an invalid response: \(reason)"
        case .protocolVersionMismatch(let requested, let received):
            "The MCP server selected protocol version '\(received)' instead of '\(requested)'."
        case .remoteError(let code, let message, _):
            "MCP JSON-RPC error \(code): \(message)"
        }
    }
}
