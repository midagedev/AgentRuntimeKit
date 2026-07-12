import Foundation

public enum AgentAuditKind: String, Sendable, Codable, Hashable {
    case runStarted
    case providerRequest
    case toolDecision
    case toolExecution
    case checkpoint
    case runCompleted
    case runFailed
}

public struct AgentAuditRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var kind: AgentAuditKind
    public var runID: UUID
    public var sessionID: String
    public var agentID: String
    public var detail: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        kind: AgentAuditKind,
        runID: UUID,
        sessionID: String,
        agentID: String,
        detail: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.runID = runID
        self.sessionID = sessionID
        self.agentID = agentID
        self.detail = detail
    }
}

public protocol AgentAuditSink: Sendable {
    func record(_ record: AgentAuditRecord) async
}

public actor InMemoryAgentAuditSink: AgentAuditSink {
    public private(set) var records: [AgentAuditRecord] = []
    public init() {}
    public func record(_ record: AgentAuditRecord) { records.append(record) }
}
