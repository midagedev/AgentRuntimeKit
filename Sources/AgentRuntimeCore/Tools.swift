import Foundation

public enum AgentToolRisk: String, Sendable, Codable, Hashable, Comparable {
    case safe
    case sensitive
    case restricted

    public static func < (lhs: AgentToolRisk, rhs: AgentToolRisk) -> Bool {
        let order: [AgentToolRisk] = [.safe, .sensitive, .restricted]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public enum AgentToolSideEffect: String, Sendable, Codable, Hashable {
    case none
    case idempotent
    case nonIdempotent
}

public struct AgentToolDescriptor: Sendable, Codable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var risk: AgentToolRisk
    public var sideEffect: AgentToolSideEffect
    public var timeout: Duration
    public var tags: Set<String>

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        risk: AgentToolRisk = .safe,
        sideEffect: AgentToolSideEffect = .none,
        timeout: Duration = .seconds(30),
        tags: Set<String> = []
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.risk = risk
        self.sideEffect = sideEffect
        self.timeout = timeout
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, risk, sideEffect, timeoutSeconds, tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        inputSchema = try container.decode(JSONValue.self, forKey: .inputSchema)
        risk = try container.decode(AgentToolRisk.self, forKey: .risk)
        sideEffect = try container.decode(AgentToolSideEffect.self, forKey: .sideEffect)
        timeout = .seconds(try container.decode(Double.self, forKey: .timeoutSeconds))
        tags = try container.decode(Set<String>.self, forKey: .tags)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encode(risk, forKey: .risk)
        try container.encode(sideEffect, forKey: .sideEffect)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        try container.encode(seconds, forKey: .timeoutSeconds)
        try container.encode(tags, forKey: .tags)
    }
}

public struct AgentToolExecutionContext: Sendable, Hashable {
    public var runID: UUID
    public var sessionID: String
    public var appID: String
    public var userID: String?
    public var agentID: String
    public var metadata: [String: JSONValue]

    public init(
        runID: UUID,
        sessionID: String,
        appID: String,
        userID: String?,
        agentID: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.runID = runID
        self.sessionID = sessionID
        self.appID = appID
        self.userID = userID
        self.agentID = agentID
        self.metadata = metadata
    }
}

public struct AgentToolOutput: Sendable, Codable, Hashable {
    public var content: JSONValue
    public var summary: String?
    public var isError: Bool
    public var metadata: [String: JSONValue]

    public init(
        content: JSONValue,
        summary: String? = nil,
        isError: Bool = false,
        metadata: [String: JSONValue] = [:]
    ) {
        self.content = content
        self.summary = summary
        self.isError = isError
        self.metadata = metadata
    }

    public init(text: String, summary: String? = nil, isError: Bool = false) {
        self.init(content: .string(text), summary: summary, isError: isError)
    }
}

public protocol AgentTool: Sendable {
    var descriptor: AgentToolDescriptor { get }
    func execute(arguments: JSONValue, context: AgentToolExecutionContext) async throws -> AgentToolOutput
}

/// Opt in only when an error message is deliberately safe to send back to a
/// remote model. Unknown native errors are generalized by the runtime.
public protocol AgentModelSafeError: Error, Sendable {
    var modelSafeMessage: String { get }
}

public actor AgentToolRegistry {
    private var tools: [String: any AgentTool] = [:]

    public init(tools: [any AgentTool] = []) throws {
        for tool in tools {
            try Self.validate(tool.descriptor)
            guard self.tools[tool.descriptor.name] == nil else {
                throw AgentRuntimeError.duplicateTool(tool.descriptor.name)
            }
            self.tools[tool.descriptor.name] = tool
        }
    }

    public func register(_ tool: any AgentTool) throws {
        let name = tool.descriptor.name
        try Self.validate(tool.descriptor)
        guard tools[name] == nil else { throw AgentRuntimeError.duplicateTool(name) }
        tools[name] = tool
    }

    public func replace(_ tool: any AgentTool) throws {
        let name = tool.descriptor.name
        try Self.validate(tool.descriptor)
        tools[name] = tool
    }

    public func remove(named name: String) { tools[name] = nil }

    public func tool(named name: String) -> (any AgentTool)? { tools[name] }

    public func descriptors(allowedNames: Set<String>? = nil) -> [AgentToolDescriptor] {
        tools.values
            .map(\.descriptor)
            .filter { allowedNames == nil || allowedNames!.contains($0.name) }
            .sorted { $0.name < $1.name }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
        }
    }

    private static func validate(_ descriptor: AgentToolDescriptor) throws {
        guard isValidName(descriptor.name) else {
            throw AgentRuntimeError.invalidToolName(descriptor.name)
        }
        try JSONSchemaValidator.validateSchema(descriptor.inputSchema)
    }
}

public struct AgentToolPolicyRequest: Sendable, Hashable {
    public var call: AgentToolCall
    public var descriptor: AgentToolDescriptor
    public var context: AgentToolExecutionContext

    public init(call: AgentToolCall, descriptor: AgentToolDescriptor, context: AgentToolExecutionContext) {
        self.call = call
        self.descriptor = descriptor
        self.context = context
    }
}

public enum AgentToolPolicyDecision: Sendable, Hashable {
    case allow
    case deny(reason: String)
    case requireApproval(reason: String)
}

public protocol AgentToolPolicy: Sendable {
    func evaluate(_ request: AgentToolPolicyRequest) async -> AgentToolPolicyDecision
}

public struct DefaultAgentToolPolicy: AgentToolPolicy, Sendable {
    public var allowedRestrictedTools: Set<String>
    public var preapprovedSensitiveTools: Set<String>

    public init(
        allowedRestrictedTools: Set<String> = [],
        preapprovedSensitiveTools: Set<String> = []
    ) {
        self.allowedRestrictedTools = allowedRestrictedTools
        self.preapprovedSensitiveTools = preapprovedSensitiveTools
    }

    public func evaluate(_ request: AgentToolPolicyRequest) async -> AgentToolPolicyDecision {
        switch request.descriptor.risk {
        case .safe:
            return .allow
        case .sensitive:
            if preapprovedSensitiveTools.contains(request.descriptor.name) { return .allow }
            return .requireApproval(reason: "This tool can access or change sensitive data.")
        case .restricted:
            if allowedRestrictedTools.contains(request.descriptor.name) {
                return .requireApproval(reason: "This restricted tool requires explicit approval.")
            }
            return .deny(reason: "Restricted tool is not in the host application's allowlist.")
        }
    }
}

public struct AgentToolApprovalRequest: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var call: AgentToolCall
    public var descriptor: AgentToolDescriptor
    public var reason: String
    public var context: AgentToolExecutionContext

    public init(
        id: UUID = UUID(),
        call: AgentToolCall,
        descriptor: AgentToolDescriptor,
        reason: String,
        context: AgentToolExecutionContext
    ) {
        self.id = id
        self.call = call
        self.descriptor = descriptor
        self.reason = reason
        self.context = context
    }
}

public enum AgentToolApprovalDecision: Sendable, Hashable {
    case allowOnce
    case allowForSession
    case deny(reason: String)
}

public protocol AgentToolApprovalHandler: Sendable {
    func requestApproval(_ request: AgentToolApprovalRequest) async -> AgentToolApprovalDecision
}

public struct DenyAllToolApprovalHandler: AgentToolApprovalHandler, Sendable {
    public init() {}
    public func requestApproval(_ request: AgentToolApprovalRequest) async -> AgentToolApprovalDecision {
        .deny(reason: "No approval handler is installed.")
    }
}

/// Bridges runtime approval requests to SwiftUI or another host UI without
/// placing UI types or MainActor isolation in the core package.
public actor AgentToolApprovalBroker: AgentToolApprovalHandler {
    public nonisolated let requests: AsyncStream<AgentToolApprovalRequest>
    private let requestContinuation: AsyncStream<AgentToolApprovalRequest>.Continuation
    private var pending: [UUID: CheckedContinuation<AgentToolApprovalDecision, Never>] = [:]

    public init() {
        let pair = AsyncStream<AgentToolApprovalRequest>.makeStream()
        requests = pair.stream
        requestContinuation = pair.continuation
    }

    deinit {
        requestContinuation.finish()
        for continuation in pending.values {
            continuation.resume(returning: .deny(reason: "Approval broker was released."))
        }
    }

    public func requestApproval(_ request: AgentToolApprovalRequest) async -> AgentToolApprovalDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let previous = pending.updateValue(continuation, forKey: request.id) {
                    previous.resume(returning: .deny(reason: "A newer approval request replaced this one."))
                }
                requestContinuation.yield(request)
            }
        } onCancel: {
            Task { await self.cancel(requestID: request.id) }
        }
    }

    public func resolve(requestID: UUID, decision: AgentToolApprovalDecision) {
        pending.removeValue(forKey: requestID)?.resume(returning: decision)
    }

    public func cancel(requestID: UUID) {
        pending.removeValue(forKey: requestID)?.resume(
            returning: .deny(reason: "Approval request was cancelled.")
        )
    }

    public func cancelAll(reason: String = "Approval requests were cancelled.") {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(returning: .deny(reason: reason))
        }
    }
}
