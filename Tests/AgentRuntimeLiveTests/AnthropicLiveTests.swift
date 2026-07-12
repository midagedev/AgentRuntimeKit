import AgentRuntimeCore
import AgentRuntimeProviders
import AgentRuntimeTestKit
import Foundation
import XCTest

/// Opt-in contract tests against Anthropic's production Messages API.
///
/// These tests are skipped unless `AGENT_RUNTIME_LIVE_ANTHROPIC=1` and
/// `ANTHROPIC_API_KEY` are present. The credential is held only by the in-memory
/// resolver and is never included in an assertion, log, or failure message.
final class AnthropicLiveTests: XCTestCase {
    private var model: String {
        ProcessInfo.processInfo.environment["AGENT_RUNTIME_ANTHROPIC_MODEL"]
            ?? "claude-sonnet-5"
    }

    func testTextStreamingUsageAndMultiTurnContinuation() async throws {
        let key = try liveCredential()
        let runtime = try makeRuntime(key: key)
        let first = try await run(
            runtime,
            sessionID: "live-text-\(UUID().uuidString)",
            messages: [AgentMessage(
                role: .user,
                text: "Reply with exactly ARK_STREAM_OK and no other text."
            )]
        )

        XCTAssertFalse(first.deltas.isEmpty)
        XCTAssertEqual(first.result.finalMessage.text.trimmingCharacters(in: .whitespacesAndNewlines), "ARK_STREAM_OK")
        XCTAssertGreaterThan(first.result.usage.totalTokens, 0)

        let second = try await run(
            runtime,
            sessionID: first.result.sessionID,
            messages: first.result.messages + [AgentMessage(
                role: .user,
                text: "Now reply with exactly ARK_CONTINUATION_OK and no other text."
            )]
        )

        XCTAssertEqual(second.result.finalMessage.text.trimmingCharacters(in: .whitespacesAndNewlines), "ARK_CONTINUATION_OK")
        XCTAssertTrue(first.result.messages.contains {
            $0.providerContinuation?.providerIdentifier == "anthropic"
        })
    }

    func testToolRoundTripStreamsAndUsesOpaqueProviderContinuation() async throws {
        let key = try liveCredential()
        let runtime = try makeRuntime(key: key, includeProbeTool: true)
        let output = try await run(
            runtime,
            sessionID: "live-tool-\(UUID().uuidString)",
            messages: [AgentMessage(
                role: .user,
                text: "Call echo_probe exactly once with value ARK_TOOL_INPUT. After reading its result, reply with exactly ARK_TOOL_OK."
            )]
        )

        XCTAssertEqual(output.startedTools, ["echo_probe"])
        XCTAssertEqual(output.finishedTools, ["echo_probe"])
        XCTAssertEqual(output.result.toolCallCount, 1)
        XCTAssertEqual(output.result.finalMessage.text.trimmingCharacters(in: .whitespacesAndNewlines), "ARK_TOOL_OK")
        XCTAssertTrue(output.result.messages.contains {
            $0.providerContinuation?.providerIdentifier == "anthropic"
        })
    }

    func testCancellationStopsInFlightProviderRequest() async throws {
        let key = try liveCredential()
        let provider = AnthropicMessagesProvider(
            credentialResolver: StaticProviderCredentialResolver(credential: key),
            retryPolicy: .none
        )
        let stream = provider.stream(ModelRequest(
            model: model,
            messages: [AgentMessage(
                role: .user,
                text: "Write a long numbered list from 1 to 200, one item per line."
            )],
            maxOutputTokens: 1_024
        ))

        let task = Task {
            for try await _ in stream {}
            return Task.isCancelled
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            let observedCancellation = try await task.value
            XCTAssertTrue(observedCancellation, "The provider stream completed before observing cancellation")
        } catch is CancellationError {
            // Also valid: some AsyncSequence consumers surface cancellation as
            // an error while others finish iteration with the Task still marked
            // cancelled. The transport unit test verifies URLSessionTask.cancel().
        }
    }

    func testInvalidCredentialErrorDoesNotEchoCredential() async throws {
        try requireLiveOptIn()
        let invalidCredential = "invalid-live-contract-credential-\(UUID().uuidString)"
        let provider = AnthropicMessagesProvider(
            credentialResolver: StaticProviderCredentialResolver(credential: invalidCredential),
            retryPolicy: .none
        )

        do {
            for try await _ in provider.stream(ModelRequest(
                model: model,
                messages: [AgentMessage(role: .user, text: "Reply with OK.")],
                maxOutputTokens: 16
            )) {}
            XCTFail("An invalid credential must be rejected")
        } catch {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(invalidCredential))
            XCTAssertLessThanOrEqual(description.count, 512)
        }
    }

    private func makeRuntime(key: String, includeProbeTool: Bool = false) throws -> AgentRuntime {
        let provider = AnthropicMessagesProvider(
            credentialResolver: StaticProviderCredentialResolver(credential: key),
            retryPolicy: .none
        )
        let tools: [any AgentTool]
        if includeProbeTool {
            tools = [ClosureAgentTool(
                descriptor: AgentToolDescriptor(
                    name: "echo_probe",
                    description: "Returns the supplied value for a live contract test.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("value")]),
                        "additionalProperties": .bool(false),
                    ])
                ),
                execute: { arguments, _ in
                    AgentToolOutput(text: arguments["value"]?.stringValue ?? "missing")
                }
            )]
        } else {
            tools = []
        }
        return AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: tools),
            checkpointStore: InMemoryAgentCheckpointStore()
        )
    }

    private func run(
        _ runtime: AgentRuntime,
        sessionID: String,
        messages: [AgentMessage]
    ) async throws -> LiveRunOutput {
        var deltas: [String] = []
        var startedTools: [String] = []
        var finishedTools: [String] = []
        var completed: AgentRunResult?
        let request = AgentRunRequest(
            sessionID: sessionID,
            appID: "dev.agentruntimekit.live-tests",
            userID: "live-test-user",
            agent: AgentDefinition(
                id: "live-anthropic",
                providerID: "anthropic",
                model: model,
                instructions: "Follow the user's contract-test instruction exactly.",
                allowedTools: ["echo_probe"],
                maxOutputTokens: 256
            ),
            messages: messages,
            limits: AgentRunLimits(
                maxSteps: 4,
                maxToolCalls: 2,
                maxTotalTokens: 8_000,
                maxDuration: .seconds(60)
            )
        )

        for try await event in runtime.run(request) {
            switch event {
            case .assistantTextDelta(let text):
                deltas.append(text)
            case .toolStarted(let call, _):
                startedTools.append(call.name)
            case .toolFinished(let call, _):
                finishedTools.append(call.name)
            case .completed(let result):
                completed = result
            default:
                break
            }
        }
        return LiveRunOutput(
            result: try XCTUnwrap(completed),
            deltas: deltas,
            startedTools: startedTools,
            finishedTools: finishedTools
        )
    }

    private func liveCredential() throws -> String {
        try requireLiveOptIn()
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw XCTSkip("ANTHROPIC_API_KEY is required for live provider tests.")
        }
        return key
    }

    private func requireLiveOptIn() throws {
        guard ProcessInfo.processInfo.environment["AGENT_RUNTIME_LIVE_ANTHROPIC"] == "1" else {
            throw XCTSkip("Set AGENT_RUNTIME_LIVE_ANTHROPIC=1 to run live provider tests.")
        }
    }
}

private struct LiveRunOutput {
    var result: AgentRunResult
    var deltas: [String]
    var startedTools: [String]
    var finishedTools: [String]
}
