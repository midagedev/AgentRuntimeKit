import Foundation

public struct MCPToolAdapterConfiguration: Sendable, Hashable {
    public var defaultRisk: AgentToolRisk
    public var defaultSideEffect: AgentToolSideEffect
    public var elevateDestructiveTools: Bool
    public var trustSideEffectAnnotations: Bool
    public var timeout: Duration
    public var tags: Set<String>

    public init(
        defaultRisk: AgentToolRisk = .sensitive,
        defaultSideEffect: AgentToolSideEffect = .nonIdempotent,
        elevateDestructiveTools: Bool = true,
        trustSideEffectAnnotations: Bool = false,
        timeout: Duration = .seconds(30),
        tags: Set<String> = ["mcp"]
    ) {
        self.defaultRisk = defaultRisk
        self.defaultSideEffect = defaultSideEffect
        self.elevateDestructiveTools = elevateDestructiveTools
        self.trustSideEffectAnnotations = trustSideEffectAnnotations
        self.timeout = timeout
        self.tags = tags
    }
}

/// Adapts a remotely advertised MCP tool to AgentRuntimeCore's ``AgentTool`` contract.
public struct MCPToolAdapter: AgentTool, Sendable {
    public let descriptor: AgentToolDescriptor

    private let remoteName: String
    private let client: MCPStreamableHTTPClient

    public init(
        definition: MCPToolDefinition,
        client: MCPStreamableHTTPClient,
        configuration: MCPToolAdapterConfiguration = MCPToolAdapterConfiguration()
    ) {
        remoteName = definition.name
        self.client = client

        var risk = configuration.defaultRisk
        if configuration.elevateDestructiveTools,
           definition.annotations?.destructiveHint == true
        {
            risk = .restricted
        }

        let sideEffect: AgentToolSideEffect
        if configuration.trustSideEffectAnnotations,
           definition.annotations?.readOnlyHint == true
        {
            sideEffect = .none
        } else if configuration.trustSideEffectAnnotations,
                  definition.annotations?.idempotentHint == true
        {
            sideEffect = .idempotent
        } else {
            sideEffect = configuration.defaultSideEffect
        }

        descriptor = AgentToolDescriptor(
            name: definition.name,
            description: definition.description
                ?? definition.title
                ?? definition.annotations?.title
                ?? "Remote MCP tool \(definition.name).",
            inputSchema: definition.inputSchema,
            risk: risk,
            sideEffect: sideEffect,
            timeout: configuration.timeout,
            tags: configuration.tags
        )
    }

    public func execute(
        arguments: JSONValue,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolOutput {
        try Task.checkCancellation()
        let result = try await client.callTool(name: remoteName, arguments: arguments)

        var metadata: [String: JSONValue] = ["mcp": .bool(true)]
        if let remoteMetadata = result.metadata {
            metadata["mcpMetadata"] = remoteMetadata
        }
        return AgentToolOutput(
            content: result.structuredContent ?? .array(result.content),
            summary: textSummary(from: result.content),
            isError: result.isError,
            metadata: metadata
        )
    }

    private func textSummary(from content: [JSONValue]) -> String? {
        let text = content.compactMap { item -> String? in
            guard item["type"]?.stringValue == "text" else { return nil }
            return item["text"]?.stringValue
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

public extension MCPStreamableHTTPClient {
    /// Fetches the remote catalog and creates Core-compatible tool adapters.
    func toolAdapters(
        configuration: MCPToolAdapterConfiguration = MCPToolAdapterConfiguration()
    ) async throws -> [MCPToolAdapter] {
        try await listTools().map {
            MCPToolAdapter(definition: $0, client: self, configuration: configuration)
        }
    }
}
