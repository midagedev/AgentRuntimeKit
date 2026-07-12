import Foundation

public enum AgentToolExecutionState: String, Sendable, Codable, Hashable {
    case started
    case completed
    case indeterminate
}

/// Minimal write-ahead record used to make tool replay decisions without
/// persisting arguments or tool output outside the conversation transcript.
public struct AgentToolExecutionRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { callID }
    public var callID: String
    public var toolName: String
    public var sideEffect: AgentToolSideEffect
    public var state: AgentToolExecutionState
    public var startedAt: Date
    public var completedAt: Date?

    public init(
        callID: String,
        toolName: String,
        sideEffect: AgentToolSideEffect,
        state: AgentToolExecutionState = .started,
        startedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.callID = callID
        self.toolName = toolName
        self.sideEffect = sideEffect
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct AgentRunCheckpoint: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var runID: UUID
    public var sessionID: String
    public var appID: String
    public var userID: String?
    public var agentID: String
    public var providerID: String
    public var model: String
    public var messages: [AgentMessage]
    public var stepCount: Int
    public var toolCallCount: Int
    public var usage: AgentTokenUsage
    public var toolExecutions: [AgentToolExecutionRecord]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        sessionID: String,
        appID: String,
        userID: String? = nil,
        agentID: String,
        providerID: String,
        model: String,
        messages: [AgentMessage],
        stepCount: Int,
        toolCallCount: Int,
        usage: AgentTokenUsage,
        toolExecutions: [AgentToolExecutionRecord] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.runID = runID
        self.sessionID = sessionID
        self.appID = appID
        self.userID = userID
        self.agentID = agentID
        self.providerID = providerID
        self.model = model
        self.messages = messages
        self.stepCount = stepCount
        self.toolCallCount = toolCallCount
        self.usage = usage
        self.toolExecutions = toolExecutions
        self.createdAt = createdAt
    }
}

public protocol AgentCheckpointStore: Sendable {
    func save(_ checkpoint: AgentRunCheckpoint) async throws
    func load(id: UUID) async throws -> AgentRunCheckpoint?
    func latest(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) async throws -> AgentRunCheckpoint?
    func delete(id: UUID) async throws
    func deleteAll(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) async throws
}

public actor InMemoryAgentCheckpointStore: AgentCheckpointStore {
    private var checkpoints: [UUID: AgentRunCheckpoint] = [:]

    public init() {}

    public func save(_ checkpoint: AgentRunCheckpoint) { checkpoints[checkpoint.id] = checkpoint }
    public func load(id: UUID) -> AgentRunCheckpoint? { checkpoints[id] }
    public func latest(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) -> AgentRunCheckpoint? {
        checkpoints.values
            .filter {
                $0.appID == appID
                    && $0.userID == userID
                    && $0.sessionID == sessionID
                    && $0.agentID == agentID
            }
            .max { $0.createdAt < $1.createdAt }
    }
    public func delete(id: UUID) { checkpoints[id] = nil }
    public func deleteAll(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) {
        checkpoints = checkpoints.filter { _, checkpoint in
            checkpoint.appID != appID
                || checkpoint.userID != userID
                || checkpoint.sessionID != sessionID
                || checkpoint.agentID != agentID
        }
    }
}
