import Foundation

/// Bridges governed memory into the runtime's context pipeline. The default
/// sensitivity ceiling excludes health, financial, and secret data. Hosts must
/// opt into health/financial context explicitly; secret memory is never emitted.
public struct MemoryContextProvider: AgentContextProvider, Sendable {
    public var identifier: String
    public var maximumSensitivity: AgentDataSensitivity
    public var minimumConfidence: Double
    public var minimumImportance: Double
    public var limit: Int
    public var workspaceMetadataKey: String

    private let store: any MemoryStore

    public init(
        identifier: String = "agent-runtime-memory",
        store: any MemoryStore,
        maximumSensitivity: AgentDataSensitivity = .privateData,
        minimumConfidence: Double = 0,
        minimumImportance: Double = 0,
        limit: Int = 20,
        workspaceMetadataKey: String = "workspaceID"
    ) {
        self.identifier = identifier
        self.store = store
        // Secret values belong in AgentSecretStore and are never model context.
        self.maximumSensitivity = maximumSensitivity == .secret ? .financial : maximumSensitivity
        self.minimumConfidence = min(1, max(0, minimumConfidence))
        self.minimumImportance = min(1, max(0, minimumImportance))
        self.limit = max(0, limit)
        self.workspaceMetadataKey = workspaceMetadataKey
    }

    public func context(for request: AgentContextRequest) async throws -> [AgentContextBlock] {
        guard request.characterBudget > 0, limit > 0 else { return [] }
        let workspaceID = request.metadata[workspaceMetadataKey]?.stringValue
        let scopes = Self.visibleScopes(
            appID: request.appID,
            userID: request.userID,
            agentID: request.agentID,
            workspaceID: workspaceID,
            sessionID: request.sessionID
        )
        let result = try await store.retrieve(MemoryQuery(
            scopes: scopes,
            text: request.query,
            maximumSensitivity: maximumSensitivity,
            minimumConfidence: minimumConfidence,
            minimumImportance: minimumImportance,
            limit: limit,
            characterBudget: request.characterBudget
        ))
        return result.hits.map { hit in
            AgentContextBlock(
                id: "memory:\(hit.record.id.uuidString)",
                title: "Memory: \(hit.record.kind.rawValue)",
                content: hit.contextText,
                priority: Int((hit.record.importance * 60) + (hit.relevance * 40)),
                sensitivity: hit.record.sensitivity,
                // The context injection is transient even when its governed source
                // record is durable. It must not be treated as a new memory write.
                isEphemeral: true,
                source: hit.record.provenance.source,
                metadata: [
                    "memoryID": .string(hit.record.id.uuidString),
                    "revision": .number(Double(hit.record.revision)),
                    "confidence": .number(hit.record.confidence),
                    "scope": .string(hit.record.scope.level.rawValue),
                    "truncated": .bool(hit.isTruncated),
                ]
            )
        }
    }

    /// Builds only deliberate shared scopes plus identities belonging to this
    /// request. It never enumerates other users, workspaces, or sessions.
    public static func visibleScopes(
        appID: String,
        userID: String?,
        agentID: String,
        workspaceID: String?,
        sessionID: String
    ) -> [MemoryScope] {
        var scopes: [MemoryScope] = [.application(appID: appID)]
        if let userID {
            scopes.append(.user(appID: appID, userID: userID))
        }

        // A host can intentionally keep an agent memory shared, or bind it to a user.
        scopes.append(.agent(appID: appID, agentID: agentID))
        if let userID {
            scopes.append(.agent(appID: appID, agentID: agentID, userID: userID))
        }

        if let workspaceID {
            scopes.append(.workspace(appID: appID, workspaceID: workspaceID))
            if userID != nil {
                scopes.append(.workspace(
                    appID: appID,
                    workspaceID: workspaceID,
                    userID: userID,
                    agentID: agentID
                ))
            }
        }

        // Session IDs are normally globally unique, but both unbound and fully
        // identity-bound forms are supported for explicit host semantics.
        scopes.append(.session(appID: appID, sessionID: sessionID))
        if userID != nil || workspaceID != nil {
            scopes.append(.session(
                appID: appID,
                sessionID: sessionID,
                userID: userID,
                agentID: agentID,
                workspaceID: workspaceID
            ))
        }
        return Array(Set(scopes)).sorted { lhs, rhs in
            if lhs.level.rawValue == rhs.level.rawValue {
                return String(describing: lhs) < String(describing: rhs)
            }
            return lhs.level.rawValue < rhs.level.rawValue
        }
    }
}
