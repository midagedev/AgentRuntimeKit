import Foundation

public enum AgentDataSensitivity: String, Sendable, Codable, Hashable, Comparable {
    case publicData
    case privateData
    case health
    case financial
    case secret

    public static func < (lhs: AgentDataSensitivity, rhs: AgentDataSensitivity) -> Bool {
        let order: [AgentDataSensitivity] = [.publicData, .privateData, .health, .financial, .secret]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public struct AgentContextBlock: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var content: String
    public var priority: Int
    public var sensitivity: AgentDataSensitivity
    public var isEphemeral: Bool
    public var source: String?
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        title: String,
        content: String,
        priority: Int = 0,
        sensitivity: AgentDataSensitivity = .privateData,
        isEphemeral: Bool = true,
        source: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.priority = priority
        self.sensitivity = sensitivity
        self.isEphemeral = isEphemeral
        self.source = source
        self.metadata = metadata
    }
}

public struct AgentContextRequest: Sendable, Hashable {
    public var runID: UUID
    public var sessionID: String
    public var appID: String
    public var userID: String?
    public var agentID: String
    public var query: String
    public var characterBudget: Int
    public var metadata: [String: JSONValue]

    public init(
        runID: UUID,
        sessionID: String,
        appID: String,
        userID: String?,
        agentID: String,
        query: String,
        characterBudget: Int,
        metadata: [String: JSONValue] = [:]
    ) {
        self.runID = runID
        self.sessionID = sessionID
        self.appID = appID
        self.userID = userID
        self.agentID = agentID
        self.query = query
        self.characterBudget = characterBudget
        self.metadata = metadata
    }
}

public protocol AgentContextProvider: Sendable {
    var identifier: String { get }
    func context(for request: AgentContextRequest) async throws -> [AgentContextBlock]
}

public actor AgentContextProviderRegistry {
    private var providers: [String: any AgentContextProvider] = [:]

    public init(providers: [any AgentContextProvider] = []) {
        for provider in providers { self.providers[provider.identifier] = provider }
    }

    public func register(_ provider: any AgentContextProvider) {
        providers[provider.identifier] = provider
    }

    public func remove(identifier: String) {
        providers[identifier] = nil
    }

    public func provider(identifier: String) -> (any AgentContextProvider)? {
        providers[identifier]
    }

    public func all() -> [any AgentContextProvider] {
        providers.values.sorted { $0.identifier < $1.identifier }
    }
}

public struct StaticAgentContextProvider: AgentContextProvider, Sendable {
    public var identifier: String
    public var blocks: [AgentContextBlock]

    public init(identifier: String, blocks: [AgentContextBlock]) {
        self.identifier = identifier
        self.blocks = blocks
    }

    public func context(for request: AgentContextRequest) async throws -> [AgentContextBlock] { blocks }
}

public protocol AgentSecretStore: Sendable {
    func loadSecret(namespace: String, account: String) async throws -> String?
    func saveSecret(_ value: String, namespace: String, account: String) async throws
    func deleteSecret(namespace: String, account: String) async throws
}
