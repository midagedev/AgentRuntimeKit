@_exported import AgentRuntimeCore
import Foundation

public actor ScriptedModelProvider: ModelProvider {
    public nonisolated let identifier: String
    public nonisolated let capabilities: ProviderCapabilities
    private var scripts: [[ModelStreamEvent]]
    public private(set) var requests: [ModelRequest] = []

    public init(
        identifier: String = "scripted",
        capabilities: ProviderCapabilities = [.streaming, .tools],
        scripts: [[ModelStreamEvent]]
    ) {
        self.identifier = identifier
        self.capabilities = capabilities
        self.scripts = scripts
    }

    public nonisolated func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let events = try await self.takeScript(for: request)
                    for event in events {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func takeScript(for request: ModelRequest) throws -> [ModelStreamEvent] {
        requests.append(request)
        guard !scripts.isEmpty else {
            throw AgentRuntimeError.invalidProviderResponse("Scripted provider has no response left")
        }
        return scripts.removeFirst()
    }
}

public struct ClosureAgentTool: AgentTool, Sendable {
    public var descriptor: AgentToolDescriptor
    private let body: @Sendable (JSONValue, AgentToolExecutionContext) async throws -> AgentToolOutput

    public init(
        descriptor: AgentToolDescriptor,
        execute: @escaping @Sendable (JSONValue, AgentToolExecutionContext) async throws -> AgentToolOutput
    ) {
        self.descriptor = descriptor
        self.body = execute
    }

    public func execute(
        arguments: JSONValue,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolOutput {
        try await body(arguments, context)
    }
}

public actor InMemorySecretStore: AgentSecretStore {
    private var values: [String: String]

    public init(values: [String: String] = [:]) { self.values = values }

    public func loadSecret(namespace: String, account: String) -> String? {
        values[Self.key(namespace: namespace, account: account)]
    }

    public func saveSecret(_ value: String, namespace: String, account: String) {
        values[Self.key(namespace: namespace, account: account)] = value
    }

    public func deleteSecret(namespace: String, account: String) {
        values[Self.key(namespace: namespace, account: account)] = nil
    }

    private static func key(namespace: String, account: String) -> String {
        "\(namespace)\u{1F}\(account)"
    }
}

public struct FixedToolApprovalHandler: AgentToolApprovalHandler, Sendable {
    public var decision: AgentToolApprovalDecision
    public init(_ decision: AgentToolApprovalDecision) { self.decision = decision }
    public func requestApproval(_ request: AgentToolApprovalRequest) async -> AgentToolApprovalDecision {
        decision
    }
}
