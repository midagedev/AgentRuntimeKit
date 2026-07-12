import Foundation

public struct MemoryToolConfiguration: Sendable, Hashable {
    public var namePrefix: String
    public var allowedScopeLevels: Set<MemoryScopeLevel>
    public var maximumSearchSensitivity: AgentDataSensitivity
    public var workspaceMetadataKey: String
    public var maximumSearchLimit: Int
    public var maximumCharacterBudget: Int

    public init(
        namePrefix: String = "memory",
        allowedScopeLevels: Set<MemoryScopeLevel> = [.user, .agent, .workspace, .session],
        maximumSearchSensitivity: AgentDataSensitivity = .privateData,
        workspaceMetadataKey: String = "workspaceID",
        maximumSearchLimit: Int = 20,
        maximumCharacterBudget: Int = 12_000
    ) {
        self.namePrefix = namePrefix
        self.allowedScopeLevels = allowedScopeLevels
        self.maximumSearchSensitivity = maximumSearchSensitivity == .secret
            ? .financial
            : maximumSearchSensitivity
        self.workspaceMetadataKey = workspaceMetadataKey
        self.maximumSearchLimit = max(1, maximumSearchLimit)
        self.maximumCharacterBudget = max(1, maximumCharacterBudget)
    }
}

public struct MemoryToolBundle: Sendable {
    public var tools: [any AgentTool]
    /// Hosts use this reference to resolve pending approvals. Approval is
    /// intentionally not exposed as an agent-callable tool.
    public var writer: PolicyControlledMemoryWriter

    public init(tools: [any AgentTool], writer: PolicyControlledMemoryWriter) {
        self.tools = tools
        self.writer = writer
    }
}

public enum MemoryToolFactory {
    public static func make(
        store: any MemoryStore,
        policy: any MemoryPolicy = DefaultMemoryPolicy(),
        approvalHandler: (any MemoryApprovalHandler)? = nil,
        configuration: MemoryToolConfiguration = MemoryToolConfiguration()
    ) -> MemoryToolBundle {
        let writer = PolicyControlledMemoryWriter(
            store: store,
            policy: policy,
            approvalHandler: approvalHandler
        )
        return MemoryToolBundle(
            tools: [
                MemorySaveTool(writer: writer, configuration: configuration),
                MemorySearchTool(store: store, configuration: configuration),
                MemoryArchiveTool(store: store, configuration: configuration),
            ],
            writer: writer
        )
    }
}

public struct MemorySaveTool: AgentTool, Sendable {
    public let descriptor: AgentToolDescriptor
    private let writer: PolicyControlledMemoryWriter
    private let configuration: MemoryToolConfiguration

    public init(
        writer: PolicyControlledMemoryWriter,
        configuration: MemoryToolConfiguration = MemoryToolConfiguration()
    ) {
        self.writer = writer
        self.configuration = configuration
        self.descriptor = AgentToolDescriptor(
            name: "\(configuration.namePrefix).save",
            description: "Propose a scoped memory. Policy may reject it or require host approval before anything is stored.",
            inputSchema: Self.schema(configuration: configuration),
            risk: .sensitive,
            sideEffect: .idempotent,
            tags: ["memory", "write", "policy-controlled"]
        )
    }

    public func execute(
        arguments: JSONValue,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolOutput {
        let object = try MemoryToolArguments.object(arguments)
        let level = try MemoryToolArguments.scopeLevel(object, configuration: configuration)
        let scope = try MemoryToolScopeResolver.resolve(
            level: level,
            context: context,
            configuration: configuration
        )
        let kind = try MemoryToolArguments.enumeration(
            object,
            key: "kind",
            type: MemoryKind.self
        )
        let sensitivity = try MemoryToolArguments.enumeration(
            object,
            key: "sensitivity",
            type: AgentDataSensitivity.self
        )
        let content = try MemoryToolArguments.requiredString(object, key: "content")
        let confidence = try MemoryToolArguments.optionalDouble(object, key: "confidence") ?? 1
        let importance = try MemoryToolArguments.optionalDouble(object, key: "importance") ?? 0.5
        let ttl = try MemoryToolArguments.optionalDouble(object, key: "ttl_seconds")
        let deduplicationKey = try MemoryToolArguments.optionalString(
            object,
            key: "deduplication_key"
        )

        let proposal = MemoryProposal(
            scope: scope,
            kind: kind,
            content: content,
            sensitivity: sensitivity,
            provenance: MemoryProvenance(
                source: "agent-tool:\(descriptor.name)",
                sourceID: context.runID.uuidString,
                actorID: context.agentID,
                metadata: [
                    "sessionID": .string(context.sessionID),
                    "appID": .string(context.appID),
                ]
            ),
            confidence: confidence,
            importance: importance,
            timeToLive: ttl,
            deduplicationKey: deduplicationKey
        )

        switch try await writer.submit(proposal) {
        case .stored(let record):
            return AgentToolOutput(
                content: .object([
                    "status": .string("stored"),
                    "id": .string(record.id.uuidString),
                    "revision": .number(Double(record.revision)),
                    "scope": .string(record.scope.level.rawValue),
                ]),
                summary: "Memory stored in the exact \(record.scope.level.rawValue) scope."
            )
        case .requiresApproval(let request):
            return AgentToolOutput(
                content: .object([
                    "status": .string("requires_approval"),
                    "approval_request_id": .string(request.id.uuidString),
                    "reason": .string(request.reason),
                ]),
                summary: "Memory was not stored and is waiting for host approval."
            )
        case .rejected(let reason):
            return AgentToolOutput(
                content: .object([
                    "status": .string("rejected"),
                    "reason": .string(reason),
                ]),
                summary: "Memory policy rejected the proposal.",
                isError: true,
                metadata: [:]
            )
        }
    }

    private static func schema(configuration: MemoryToolConfiguration) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "scope": .object([
                    "type": "string",
                    "enum": .array(configuration.allowedScopeLevels
                        .sorted { $0.rawValue < $1.rawValue }
                        .map { .string($0.rawValue) }),
                ]),
                "kind": .object([
                    "type": "string",
                    "enum": .array(MemoryKind.allCases.map { .string($0.rawValue) }),
                ]),
                "content": .object(["type": "string", "minLength": 1]),
                "sensitivity": .object([
                    "type": "string",
                    "enum": .array(AgentDataSensitivity.memoryCases.map { .string($0.rawValue) }),
                ]),
                "confidence": .object(["type": "number", "minimum": 0, "maximum": 1]),
                "importance": .object(["type": "number", "minimum": 0, "maximum": 1]),
                "ttl_seconds": .object(["type": "number", "exclusiveMinimum": 0]),
                "deduplication_key": .object(["type": "string", "minLength": 1]),
            ]),
            "required": ["scope", "kind", "content", "sensitivity"],
            "additionalProperties": false,
        ])
    }
}

public struct MemorySearchTool: AgentTool, Sendable {
    public let descriptor: AgentToolDescriptor
    private let store: any MemoryStore
    private let configuration: MemoryToolConfiguration

    public init(
        store: any MemoryStore,
        configuration: MemoryToolConfiguration = MemoryToolConfiguration()
    ) {
        self.store = store
        self.configuration = configuration
        self.descriptor = AgentToolDescriptor(
            name: "\(configuration.namePrefix).search",
            description: "Search one exact, context-bound memory namespace. The tool never widens the scope automatically.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "scope": .object([
                        "type": "string",
                        "enum": .array(configuration.allowedScopeLevels
                            .sorted { $0.rawValue < $1.rawValue }
                            .map { .string($0.rawValue) }),
                    ]),
                    "query": .object(["type": "string"]),
                    "limit": .object(["type": "integer", "minimum": 1]),
                    "character_budget": .object(["type": "integer", "minimum": 1]),
                ]),
                "required": ["scope", "query"],
                "additionalProperties": false,
            ]),
            risk: .sensitive,
            sideEffect: .none,
            tags: ["memory", "read", "exact-scope"]
        )
    }

    public func execute(
        arguments: JSONValue,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolOutput {
        let object = try MemoryToolArguments.object(arguments)
        let level = try MemoryToolArguments.scopeLevel(object, configuration: configuration)
        let scope = try MemoryToolScopeResolver.resolve(
            level: level,
            context: context,
            configuration: configuration
        )
        let text = try MemoryToolArguments.requiredString(object, key: "query", allowEmpty: true)
        let requestedLimit = Int(try MemoryToolArguments.optionalDouble(object, key: "limit")
            ?? Double(configuration.maximumSearchLimit))
        let requestedBudget = Int(try MemoryToolArguments.optionalDouble(
            object,
            key: "character_budget"
        ) ?? Double(configuration.maximumCharacterBudget))
        let result = try await store.retrieve(MemoryQuery(
            scopes: [scope],
            text: text,
            maximumSensitivity: configuration.maximumSearchSensitivity,
            limit: min(configuration.maximumSearchLimit, max(1, requestedLimit)),
            characterBudget: min(configuration.maximumCharacterBudget, max(1, requestedBudget))
        ))
        return AgentToolOutput(
            content: .object([
                "scope": .string(scope.level.rawValue),
                "search_mode": .string(result.mode.rawValue),
                "used_characters": .number(Double(result.usedCharacterCount)),
                "exhausted_budget": .bool(result.exhaustedBudget),
                "results": .array(result.hits.map { hit in
                    .object([
                        "id": .string(hit.record.id.uuidString),
                        "kind": .string(hit.record.kind.rawValue),
                        "content": .string(hit.contextText),
                        "sensitivity": .string(hit.record.sensitivity.rawValue),
                        "revision": .number(Double(hit.record.revision)),
                        "relevance": .number(hit.relevance),
                        "truncated": .bool(hit.isTruncated),
                    ])
                }),
            ]),
            summary: "Found \(result.hits.count) memories in one exact \(scope.level.rawValue) scope."
        )
    }
}

public struct MemoryArchiveTool: AgentTool, Sendable {
    public let descriptor: AgentToolDescriptor
    private let store: any MemoryStore
    private let configuration: MemoryToolConfiguration

    public init(
        store: any MemoryStore,
        configuration: MemoryToolConfiguration = MemoryToolConfiguration()
    ) {
        self.store = store
        self.configuration = configuration
        self.descriptor = AgentToolDescriptor(
            name: "\(configuration.namePrefix).archive",
            description: "Archive one memory by ID and expected revision in one exact, context-bound namespace.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "scope": .object([
                        "type": "string",
                        "enum": .array(configuration.allowedScopeLevels
                            .sorted { $0.rawValue < $1.rawValue }
                            .map { .string($0.rawValue) }),
                    ]),
                    "id": .object(["type": "string", "minLength": 1]),
                    "expected_revision": .object(["type": "integer", "minimum": 1]),
                ]),
                "required": ["scope", "id", "expected_revision"],
                "additionalProperties": false,
            ]),
            risk: .sensitive,
            sideEffect: .nonIdempotent,
            tags: ["memory", "write", "archive", "exact-scope"]
        )
    }

    public func execute(
        arguments: JSONValue,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolOutput {
        let object = try MemoryToolArguments.object(arguments)
        let level = try MemoryToolArguments.scopeLevel(object, configuration: configuration)
        let scope = try MemoryToolScopeResolver.resolve(
            level: level,
            context: context,
            configuration: configuration
        )
        let idString = try MemoryToolArguments.requiredString(object, key: "id")
        guard let id = UUID(uuidString: idString) else {
            throw MemoryToolError.invalidArgument("id must be a UUID")
        }
        let expectedRevision = Int(try MemoryToolArguments.requiredDouble(
            object,
            key: "expected_revision"
        ))
        let record = try await store.update(
            id: id,
            scope: scope,
            patch: MemoryPatch(status: .archived),
            expectedRevision: expectedRevision
        )
        return AgentToolOutput(
            content: .object([
                "status": .string("archived"),
                "id": .string(record.id.uuidString),
                "revision": .number(Double(record.revision)),
                "scope": .string(record.scope.level.rawValue),
            ]),
            summary: "Memory archived."
        )
    }
}

public enum MemoryToolError: Error, Sendable, Equatable, LocalizedError {
    case invalidArgument(String)
    case unavailableScope(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let reason): "Invalid memory tool arguments: \(reason)"
        case .unavailableScope(let reason): "Memory scope is unavailable: \(reason)"
        }
    }
}

private enum MemoryToolScopeResolver {
    static func resolve(
        level: MemoryScopeLevel,
        context: AgentToolExecutionContext,
        configuration: MemoryToolConfiguration
    ) throws -> MemoryScope {
        guard configuration.allowedScopeLevels.contains(level) else {
            throw MemoryToolError.unavailableScope("\(level.rawValue) is not host-allowed")
        }
        switch level {
        case .application:
            return .application(appID: context.appID)
        case .user:
            guard let userID = context.userID else {
                throw MemoryToolError.unavailableScope("this run has no user identity")
            }
            return .user(appID: context.appID, userID: userID)
        case .agent:
            return .agent(
                appID: context.appID,
                agentID: context.agentID,
                userID: context.userID
            )
        case .workspace:
            guard let workspaceID = context.metadata[configuration.workspaceMetadataKey]?.stringValue,
                  !workspaceID.isEmpty else {
                throw MemoryToolError.unavailableScope("this run has no workspace identity")
            }
            return .workspace(
                appID: context.appID,
                workspaceID: workspaceID,
                userID: context.userID,
                agentID: context.agentID
            )
        case .session:
            return .session(
                appID: context.appID,
                sessionID: context.sessionID,
                userID: context.userID,
                agentID: context.agentID,
                workspaceID: context.metadata[configuration.workspaceMetadataKey]?.stringValue
            )
        }
    }
}

private enum MemoryToolArguments {
    static func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let object = value.objectValue else {
            throw MemoryToolError.invalidArgument("arguments must be an object")
        }
        return object
    }

    static func requiredString(
        _ object: [String: JSONValue],
        key: String,
        allowEmpty: Bool = false
    ) throws -> String {
        guard let value = object[key]?.stringValue,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryToolError.invalidArgument("\(key) must be a string")
        }
        return value
    }

    static func optionalString(
        _ object: [String: JSONValue],
        key: String
    ) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let string = value.stringValue else {
            throw MemoryToolError.invalidArgument("\(key) must be a string")
        }
        return string
    }

    static func requiredDouble(
        _ object: [String: JSONValue],
        key: String
    ) throws -> Double {
        guard let value = try optionalDouble(object, key: key) else {
            throw MemoryToolError.invalidArgument("\(key) must be a number")
        }
        return value
    }

    static func optionalDouble(
        _ object: [String: JSONValue],
        key: String
    ) throws -> Double? {
        guard let value = object[key] else { return nil }
        let number: Double
        switch value {
        case .number(let value): number = value
        case .integer(let value): number = Double(value)
        case .unsignedInteger(let value): number = Double(value)
        case .decimal(let value): number = NSDecimalNumber(decimal: value).doubleValue
        default:
            throw MemoryToolError.invalidArgument("\(key) must be a finite number")
        }
        guard number.isFinite else {
            throw MemoryToolError.invalidArgument("\(key) must be a finite number")
        }
        return number
    }

    static func enumeration<T: RawRepresentable>(
        _ object: [String: JSONValue],
        key: String,
        type: T.Type
    ) throws -> T where T.RawValue == String {
        let rawValue = try requiredString(object, key: key)
        guard let value = T(rawValue: rawValue) else {
            throw MemoryToolError.invalidArgument("\(key) has an unsupported value")
        }
        return value
    }

    static func scopeLevel(
        _ object: [String: JSONValue],
        configuration: MemoryToolConfiguration
    ) throws -> MemoryScopeLevel {
        let level = try enumeration(object, key: "scope", type: MemoryScopeLevel.self)
        guard configuration.allowedScopeLevels.contains(level) else {
            throw MemoryToolError.unavailableScope("\(level.rawValue) is not host-allowed")
        }
        return level
    }
}

extension AgentDataSensitivity {
    fileprivate static let memoryCases: [AgentDataSensitivity] = [
        .publicData, .privateData, .health, .financial, .secret,
    ]
}
