import Foundation

public enum AgentRole: String, Sendable, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

public struct AgentImage: Sendable, Codable, Hashable {
    public enum Source: Sendable, Codable, Hashable {
        case url(URL)
        case base64(mediaType: String, data: String)
    }

    public var source: Source
    public var detail: String?

    public init(source: Source, detail: String? = nil) {
        self.source = source
        self.detail = detail
    }
}

public struct AgentToolCall: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String = UUID().uuidString, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AgentToolResultContent: Sendable, Codable, Hashable {
    public var toolCallID: String
    public var toolName: String
    public var content: JSONValue
    public var summary: String?
    public var isError: Bool

    public init(
        toolCallID: String,
        toolName: String,
        content: JSONValue,
        summary: String? = nil,
        isError: Bool = false
    ) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.content = content
        self.summary = summary
        self.isError = isError
    }
}

public enum AgentContent: Sendable, Codable, Hashable {
    case text(String)
    case image(AgentImage)
    case toolCall(AgentToolCall)
    case toolResult(AgentToolResultContent)
}

/// Provider-owned, opaque turn state needed to continue signed or encrypted
/// reasoning/tool-call sequences. Hosts persist it but must not inspect, render,
/// audit, or forward it to a different provider adapter.
public struct ProviderContinuation: Sendable, Codable, Hashable {
    public var providerIdentifier: String
    public var format: String
    public var formatVersion: Int
    public var payload: JSONValue

    public init(
        providerIdentifier: String,
        format: String,
        formatVersion: Int = 1,
        payload: JSONValue
    ) {
        self.providerIdentifier = providerIdentifier
        self.format = format
        self.formatVersion = formatVersion
        self.payload = payload
    }
}

public struct AgentMessage: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var role: AgentRole
    public var content: [AgentContent]
    public var createdAt: Date
    public var metadata: [String: JSONValue]
    public var providerContinuation: ProviderContinuation?

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        content: [AgentContent],
        createdAt: Date = .now,
        metadata: [String: JSONValue] = [:],
        providerContinuation: ProviderContinuation? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.metadata = metadata
        self.providerContinuation = providerContinuation
    }

    public init(role: AgentRole, text: String, metadata: [String: JSONValue] = [:]) {
        self.init(role: role, content: [.text(text)], metadata: metadata)
    }

    public var text: String {
        content.compactMap { item in
            if case .text(let value) = item { return value }
            return nil
        }.joined()
    }

    public var toolCalls: [AgentToolCall] {
        content.compactMap { item in
            if case .toolCall(let value) = item { return value }
            return nil
        }
    }
}
