import Foundation

public struct ProviderCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let streaming = ProviderCapabilities(rawValue: 1 << 0)
    public static let tools = ProviderCapabilities(rawValue: 1 << 1)
    public static let parallelTools = ProviderCapabilities(rawValue: 1 << 2)
    public static let vision = ProviderCapabilities(rawValue: 1 << 3)
    public static let structuredOutput = ProviderCapabilities(rawValue: 1 << 4)
    public static let reasoning = ProviderCapabilities(rawValue: 1 << 5)
    public static let promptCaching = ProviderCapabilities(rawValue: 1 << 6)
}

public struct AgentTokenUsage: Sendable, Codable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    public static func + (lhs: AgentTokenUsage, rhs: AgentTokenUsage) -> AgentTokenUsage {
        AgentTokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens
        )
    }
}

public enum ModelFinishReason: String, Sendable, Codable, Hashable {
    case stop
    case toolCalls
    case length
    case contentFilter
    case cancelled
    case unknown
}

public enum ModelStreamEvent: Sendable, Hashable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCall(AgentToolCall)
    case providerContinuation(ProviderContinuation)
    case usage(AgentTokenUsage)
    case metadata([String: JSONValue])
    case finish(ModelFinishReason)
}

public struct ModelRequest: Sendable, Hashable {
    public var model: String
    public var messages: [AgentMessage]
    public var tools: [AgentToolDescriptor]
    public var temperature: Double?
    public var maxOutputTokens: Int?
    public var responseSchema: JSONValue?
    public var metadata: [String: JSONValue]
    public var providerMetadata: [String: JSONValue]

    public init(
        model: String,
        messages: [AgentMessage],
        tools: [AgentToolDescriptor] = [],
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        responseSchema: JSONValue? = nil,
        metadata: [String: JSONValue] = [:],
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.responseSchema = responseSchema
        self.metadata = metadata
        self.providerMetadata = providerMetadata
    }
}

public protocol ModelProvider: Sendable {
    var identifier: String { get }
    var capabilities: ProviderCapabilities { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

public actor ModelProviderRegistry {
    private var providers: [String: any ModelProvider] = [:]

    public init(providers: [any ModelProvider] = []) {
        for provider in providers { self.providers[provider.identifier] = provider }
    }

    public func register(_ provider: any ModelProvider) {
        providers[provider.identifier] = provider
    }

    public func remove(identifier: String) {
        providers[identifier] = nil
    }

    public func provider(identifier: String) -> (any ModelProvider)? {
        providers[identifier]
    }

    public func identifiers() -> [String] {
        providers.keys.sorted()
    }
}
