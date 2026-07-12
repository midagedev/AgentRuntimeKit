import AgentRuntimeCore
import Foundation

actor ScriptedProviderState {
    private var scripts: [[ModelStreamEvent]]
    private(set) var requests: [ModelRequest] = []

    init(scripts: [[ModelStreamEvent]]) {
        self.scripts = scripts
    }

    func next(for request: ModelRequest) throws -> [ModelStreamEvent] {
        requests.append(request)
        guard !scripts.isEmpty else {
            throw AgentRuntimeError.invalidProviderResponse("No scripted response remains")
        }
        return scripts.removeFirst()
    }
}

struct ScriptedProvider: ModelProvider {
    let identifier: String
    let capabilities: ProviderCapabilities
    let state: ScriptedProviderState

    init(
        identifier: String = "test",
        capabilities: ProviderCapabilities = [.streaming, .tools],
        scripts: [[ModelStreamEvent]]
    ) {
        self.identifier = identifier
        self.capabilities = capabilities
        self.state = ScriptedProviderState(scripts: scripts)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let events = try await state.next(for: request)
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
}

struct DelayedProvider: ModelProvider {
    let identifier = "test"
    let capabilities: ProviderCapabilities = [.streaming]
    let delay: Duration

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: delay)
                    continuation.yield(.textDelta("late"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

actor RecordingTool: AgentTool {
    nonisolated let descriptor: AgentToolDescriptor
    private(set) var calls: [JSONValue] = []
    private let output: AgentToolOutput

    init(
        name: String = "echo",
        risk: AgentToolRisk = .safe,
        sideEffect: AgentToolSideEffect = .none,
        output: AgentToolOutput = AgentToolOutput(text: "ok")
    ) {
        descriptor = AgentToolDescriptor(
            name: name,
            description: "Echoes a value",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("value")]),
                "additionalProperties": .bool(false),
            ]),
            risk: risk,
            sideEffect: sideEffect
        )
        self.output = output
    }

    func execute(arguments: JSONValue, context: AgentToolExecutionContext) async throws -> AgentToolOutput {
        calls.append(arguments)
        return output
    }
}

struct SensitiveToolFailure: LocalizedError, Sendable {
    var errorDescription: String? { "database path /private/health.db and token sk-secret" }
}

actor FailingTool: AgentTool {
    nonisolated let descriptor: AgentToolDescriptor
    private(set) var callCount = 0

    init(name: String, sideEffect: AgentToolSideEffect = .none) {
        descriptor = AgentToolDescriptor(
            name: name,
            description: "Fails for testing",
            inputSchema: .object(["type": .string("object")]),
            sideEffect: sideEffect
        )
    }

    func execute(arguments: JSONValue, context: AgentToolExecutionContext) async throws -> AgentToolOutput {
        callCount += 1
        throw SensitiveToolFailure()
    }
}

struct LeakyFailingProvider: ModelProvider {
    let identifier = "test"
    let capabilities: ProviderCapabilities = [.streaming]

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AgentRuntimeError.invalidProviderResponse(
                "Incorrect API key: sk-super-secret"
            ))
        }
    }
}

actor SlowTool: AgentTool {
    nonisolated let descriptor = AgentToolDescriptor(
        name: "slow",
        description: "Sleeps past its deadline",
        inputSchema: .object(["type": .string("object")]),
        timeout: .milliseconds(20)
    )

    func execute(arguments: JSONValue, context: AgentToolExecutionContext) async throws -> AgentToolOutput {
        try await Task.sleep(for: .seconds(2))
        return AgentToolOutput(text: "too late")
    }
}

actor CancellationIgnoringTool: AgentTool {
    nonisolated let descriptor = AgentToolDescriptor(
        name: "ignores-cancellation",
        description: "Finishes well after its deadline and ignores cancellation",
        inputSchema: .object(["type": .string("object")]),
        timeout: .milliseconds(20)
    )

    func execute(arguments: JSONValue, context: AgentToolExecutionContext) async throws -> AgentToolOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                continuation.resume()
            }
        }
        return AgentToolOutput(text: "late")
    }
}

actor CountingApprovalHandler: AgentToolApprovalHandler {
    private(set) var count = 0
    let decision: AgentToolApprovalDecision

    init(decision: AgentToolApprovalDecision) { self.decision = decision }

    func requestApproval(_ request: AgentToolApprovalRequest) async -> AgentToolApprovalDecision {
        count += 1
        return decision
    }
}

struct TestContextProvider: AgentContextProvider {
    let identifier: String
    let blocks: [AgentContextBlock]
    var error: (any Error & Sendable)?

    init(identifier: String = "test-context", blocks: [AgentContextBlock], error: (any Error & Sendable)? = nil) {
        self.identifier = identifier
        self.blocks = blocks
        self.error = error
    }

    func context(for request: AgentContextRequest) async throws -> [AgentContextBlock] {
        if let error { throw error }
        return blocks
    }
}

func collectEvents(
    _ stream: AsyncThrowingStream<AgentEvent, Error>
) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

func makeRequest(
    sessionID: String = "session",
    agent: AgentDefinition? = nil,
    limits: AgentRunLimits = AgentRunLimits()
) -> AgentRunRequest {
    AgentRunRequest(
        sessionID: sessionID,
        appID: "tests",
        userID: "user",
        agent: agent ?? AgentDefinition(
            id: "assistant",
            providerID: "test",
            model: "test-model",
            instructions: "Be useful."
        ),
        messages: [AgentMessage(role: .user, text: "hello")],
        limits: limits
    )
}
