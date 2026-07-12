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
    /// Present only when a host explicitly reconciled an execution whose
    /// external effect could not be determined by the runtime.
    public var reconciliationOutcome: AgentToolExecutionReconciliationOutcome?

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
        reconciliationOutcome = nil
    }

    public init(
        callID: String,
        toolName: String,
        sideEffect: AgentToolSideEffect,
        state: AgentToolExecutionState = .started,
        startedAt: Date = .now,
        completedAt: Date? = nil,
        reconciliationOutcome: AgentToolExecutionReconciliationOutcome?
    ) {
        self.callID = callID
        self.toolName = toolName
        self.sideEffect = sideEffect
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.reconciliationOutcome = reconciliationOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case callID, toolName, sideEffect, state, startedAt, completedAt, reconciliationOutcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callID = try container.decode(String.self, forKey: .callID)
        toolName = try container.decode(String.self, forKey: .toolName)
        sideEffect = try container.decode(AgentToolSideEffect.self, forKey: .sideEffect)
        state = try container.decode(AgentToolExecutionState.self, forKey: .state)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        reconciliationOutcome = try container.decodeIfPresent(
            AgentToolExecutionReconciliationOutcome.self,
            forKey: .reconciliationOutcome
        )
    }
}

public enum AgentToolExecutionReconciliationOutcome: String, Sendable, Codable, Hashable {
    /// The host verified that the external effect happened.
    case effectApplied
    /// The host verified that the external effect did not happen.
    case effectNotApplied
}

/// Host-supplied evidence that resolves one indeterminate non-idempotent call.
///
/// `result` is appended to the durable transcript so provider continuation can
/// resume with a complete tool-call/result pair. The store validates its call
/// ID and tool name against the write-ahead record before changing state.
public struct AgentToolExecutionReconciliation: Sendable, Codable, Hashable {
    public var checkpointID: UUID
    public var callID: String
    public var outcome: AgentToolExecutionReconciliationOutcome
    public var result: AgentToolResultContent
    public var reconciledAt: Date

    public init(
        checkpointID: UUID,
        callID: String,
        outcome: AgentToolExecutionReconciliationOutcome,
        result: AgentToolResultContent,
        reconciledAt: Date = .now
    ) {
        self.checkpointID = checkpointID
        self.callID = callID
        self.outcome = outcome
        self.result = result
        self.reconciledAt = reconciledAt
    }
}

public struct AgentUnresolvedToolExecution: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(checkpointID.uuidString):\(record.callID)" }
    public var checkpointID: UUID
    public var checkpointCreatedAt: Date
    public var record: AgentToolExecutionRecord

    public init(
        checkpointID: UUID,
        checkpointCreatedAt: Date,
        record: AgentToolExecutionRecord
    ) {
        self.checkpointID = checkpointID
        self.checkpointCreatedAt = checkpointCreatedAt
        self.record = record
    }
}

public enum AgentCheckpointStoreError: LocalizedError, Sendable, Equatable {
    case completeUnresolvedQueryUnsupported
    case reconciliationUnsupported
    case checkpointNotFound(UUID)
    case executionNotFound(callID: String)
    case executionAlreadyResolved(callID: String)
    case reconciliationResultMismatch
    case corruptCheckpoint(UUID?)

    public var errorDescription: String? {
        switch self {
        case .completeUnresolvedQueryUnsupported:
            "This checkpoint store cannot prove that all unresolved executions were returned."
        case .reconciliationUnsupported:
            "This checkpoint store does not support durable execution reconciliation."
        case .checkpointNotFound(let id):
            "Checkpoint '\(id.uuidString)' was not found."
        case .executionNotFound(let callID):
            "Tool execution '\(callID)' was not found in the checkpoint."
        case .executionAlreadyResolved(let callID):
            "Tool execution '\(callID)' is already resolved."
        case .reconciliationResultMismatch:
            "The reconciliation result does not match the recorded tool execution."
        case .corruptCheckpoint(let id):
            if let id {
                "Checkpoint '\(id.uuidString)' is corrupt or uses an unsupported format."
            } else {
                "A checkpoint is corrupt or uses an unsupported format."
            }
        }
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

    public var unresolvedNonIdempotentToolExecutions: [AgentToolExecutionRecord] {
        toolExecutions.filter {
            $0.sideEffect == .nonIdempotent && $0.state != .completed
        }
    }

    package func reconciling(
        _ reconciliation: AgentToolExecutionReconciliation
    ) throws -> AgentRunCheckpoint {
        guard reconciliation.checkpointID == id else {
            throw AgentCheckpointStoreError.checkpointNotFound(reconciliation.checkpointID)
        }
        guard let index = toolExecutions.firstIndex(where: {
            $0.callID == reconciliation.callID
        }) else {
            throw AgentCheckpointStoreError.executionNotFound(callID: reconciliation.callID)
        }
        let execution = toolExecutions[index]
        guard execution.sideEffect == .nonIdempotent, execution.state != .completed else {
            throw AgentCheckpointStoreError.executionAlreadyResolved(callID: reconciliation.callID)
        }
        guard reconciliation.result.toolCallID == execution.callID,
              reconciliation.result.toolName == execution.toolName else {
            throw AgentCheckpointStoreError.reconciliationResultMismatch
        }
        guard reconciliation.outcome != .effectNotApplied || reconciliation.result.isError else {
            throw AgentCheckpointStoreError.reconciliationResultMismatch
        }
        guard messages.contains(where: {
            $0.toolCalls.contains {
                $0.id == execution.callID && $0.name == execution.toolName
            }
        }) else {
            throw AgentCheckpointStoreError.reconciliationResultMismatch
        }
        guard !messages.contains(where: {
            $0.toolResults.contains { $0.toolCallID == reconciliation.callID }
        }) else {
            throw AgentCheckpointStoreError.executionAlreadyResolved(callID: reconciliation.callID)
        }

        var updated = self
        updated.toolExecutions[index].state = .completed
        updated.toolExecutions[index].completedAt = reconciliation.reconciledAt
        updated.toolExecutions[index].reconciliationOutcome = reconciliation.outcome
        updated.messages.append(AgentMessage(
            role: .tool,
            content: [.toolResult(reconciliation.result)],
            createdAt: reconciliation.reconciledAt
        ))
        updated.createdAt = reconciliation.reconciledAt
        return updated
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
    /// Returns every unresolved non-idempotent execution for an identity, not
    /// merely the newest checkpoint. An incomplete implementation is unsafe.
    func unresolved(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) async throws -> [AgentUnresolvedToolExecution]
    /// Atomically records host reconciliation and its corresponding tool
    /// result, returning the checkpoint that is safe to resume.
    func reconcile(
        _ reconciliation: AgentToolExecutionReconciliation
    ) async throws -> AgentRunCheckpoint
}

public extension AgentCheckpointStore {
    /// Preserves source compatibility for existing conformers while failing
    /// closed at runtime: `latest` cannot prove that an older unresolved write
    /// is not hidden behind a newer checkpoint.
    func unresolved(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) async throws -> [AgentUnresolvedToolExecution] {
        throw AgentCheckpointStoreError.completeUnresolvedQueryUnsupported
    }

    func reconcile(
        _ reconciliation: AgentToolExecutionReconciliation
    ) async throws -> AgentRunCheckpoint {
        throw AgentCheckpointStoreError.reconciliationUnsupported
    }
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

    public func unresolved(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) async throws -> [AgentUnresolvedToolExecution] {
        checkpoints.values
            .filter {
                $0.appID == appID && $0.userID == userID
                    && $0.sessionID == sessionID && $0.agentID == agentID
            }
            .flatMap { checkpoint in
                checkpoint.unresolvedNonIdempotentToolExecutions.map {
                    AgentUnresolvedToolExecution(
                        checkpointID: checkpoint.id,
                        checkpointCreatedAt: checkpoint.createdAt,
                        record: $0
                    )
                }
            }
            .sorted {
                if $0.checkpointCreatedAt == $1.checkpointCreatedAt {
                    return $0.record.callID < $1.record.callID
                }
                return $0.checkpointCreatedAt < $1.checkpointCreatedAt
            }
    }

    public func reconcile(
        _ reconciliation: AgentToolExecutionReconciliation
    ) async throws -> AgentRunCheckpoint {
        guard let checkpoint = checkpoints[reconciliation.checkpointID] else {
            throw AgentCheckpointStoreError.checkpointNotFound(reconciliation.checkpointID)
        }
        let updated = try checkpoint.reconciling(reconciliation)
        checkpoints[updated.id] = updated
        return updated
    }
}
