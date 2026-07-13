import AgentRuntimeCore
import XCTest

final class AgentRuntimeTests: XCTestCase {
    func testToolLoopFeedsResultBackAndCompletes() async throws {
        let call = AgentToolCall(
            id: "call-1",
            name: "echo",
            arguments: .object(["value": .string("hello")])
        )
        let provider = ScriptedProvider(scripts: [
            [.toolCall(call), .usage(AgentTokenUsage(inputTokens: 10, outputTokens: 2)), .finish(.toolCalls)],
            [.textDelta("done"), .usage(AgentTokenUsage(inputTokens: 12, outputTokens: 3)), .finish(.stop)],
        ])
        let tool = RecordingTool()
        let registry = try AgentToolRegistry(tools: [tool])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: registry
        )

        let events = try await collectEvents(runtime.run(makeRequest()))

        let callCount = await tool.calls.count
        XCTAssertEqual(callCount, 1)
        let requests = await provider.state.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].messages.contains { message in
            message.content.contains { content in
                guard case .toolResult(let result) = content else { return false }
                return result.toolCallID == "call-1" && !result.isError
            }
        })
        guard case .completed(let result) = events.last else {
            return XCTFail("Expected a completed event")
        }
        XCTAssertEqual(result.finalMessage.text, "done")
        XCTAssertEqual(result.toolCallCount, 1)
        XCTAssertEqual(result.usage.totalTokens, 27)
    }

    func testInvalidArgumentsNeverReachNativeTool() async throws {
        let call = AgentToolCall(name: "echo", arguments: .object(["unexpected": .bool(true)]))
        let provider = ScriptedProvider(scripts: [
            [.toolCall(call), .finish(.toolCalls)],
            [.textDelta("recovered"), .finish(.stop)],
        ])
        let tool = RecordingTool()
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [tool])
        )

        let events = try await collectEvents(runtime.run(makeRequest()))

        let invalidArgumentCallCount = await tool.calls.count
        XCTAssertEqual(invalidArgumentCallCount, 0)
        XCTAssertTrue(events.contains { event in
            guard case .toolFinished(_, let result) = event else { return false }
            return result.isError && result.summary?.contains("Invalid arguments") == true
        })
    }

    func testSensitiveToolSessionApprovalIsRemembered() async throws {
        let firstCall = AgentToolCall(name: "private.read", arguments: .object(["value": .string("one")]))
        let secondCall = AgentToolCall(name: "private.read", arguments: .object(["value": .string("two")]))
        let provider = ScriptedProvider(scripts: [
            [.toolCall(firstCall), .finish(.toolCalls)], [.textDelta("first"), .finish(.stop)],
            [.toolCall(secondCall), .finish(.toolCalls)], [.textDelta("second"), .finish(.stop)],
        ])
        let tool = RecordingTool(name: "private.read", risk: .sensitive)
        let approvals = CountingApprovalHandler(decision: .allowForSession)
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [tool]),
            approvalHandler: approvals
        )

        _ = try await collectEvents(runtime.run(makeRequest(sessionID: "shared")))
        _ = try await collectEvents(runtime.run(makeRequest(sessionID: "shared")))

        let approvalCount = await approvals.count
        let sensitiveToolCallCount = await tool.calls.count
        XCTAssertEqual(approvalCount, 1)
        XCTAssertEqual(sensitiveToolCallCount, 2)
    }

    func testSessionApprovalIsInvalidatedWhenToolDescriptorChanges() async throws {
        let firstCall = AgentToolCall(
            id: "first",
            name: "private.read",
            arguments: ["value": "one"]
        )
        let secondCall = AgentToolCall(
            id: "second",
            name: "private.read",
            arguments: ["value": "two", "confirmed": true]
        )
        let provider = ScriptedProvider(scripts: [
            [.toolCall(firstCall), .finish(.toolCalls)], [.textDelta("first"), .finish(.stop)],
            [.toolCall(secondCall), .finish(.toolCalls)], [.textDelta("second"), .finish(.stop)],
        ])
        let firstTool = RecordingTool(name: "private.read", risk: .sensitive)
        let tools = try AgentToolRegistry(tools: [firstTool])
        let approvals = CountingApprovalHandler(decision: .allowForSession)
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: tools,
            approvalHandler: approvals
        )

        _ = try await collectEvents(runtime.run(makeRequest(sessionID: "shared")))
        let replacement = RecordingTool(
            name: "private.read",
            risk: .sensitive,
            sideEffect: .idempotent,
            inputSchema: [
                "type": "object",
                "properties": [
                    "value": ["type": "string"],
                    "confirmed": ["type": "boolean"],
                ],
                "required": ["value", "confirmed"],
                "additionalProperties": false,
            ]
        )
        try await tools.replace(replacement)
        _ = try await collectEvents(runtime.run(makeRequest(sessionID: "shared")))

        let approvalCount = await approvals.count
        let replacementCallCount = await replacement.calls.count
        XCTAssertEqual(approvalCount, 2)
        XCTAssertEqual(replacementCallCount, 1)
    }

    func testContextSensitivityAndPromptInjectionBoundary() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("ok"), .finish(.stop)]])
        let context = TestContextProvider(blocks: [
            AgentContextBlock(
                id: "public",
                title: "Public",
                content: "safe fact",
                sensitivity: .publicData
            ),
            AgentContextBlock(
                id: "health",
                title: "Health",
                content: "approved health fact",
                sensitivity: .health
            ),
            AgentContextBlock(
                id: "secret",
                title: "Secret",
                content: "never expose",
                sensitivity: .secret
            ),
        ])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(),
            contextProviders: [context]
        )
        let agent = AgentDefinition(
            id: "coach",
            providerID: "test",
            model: "model",
            instructions: "Coach.",
            maximumContextSensitivity: .health
        )

        _ = try await collectEvents(runtime.run(makeRequest(agent: agent)))

        let messages = await provider.state.requests[0].messages
        let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n")
        XCTAssertTrue(system.contains("safe fact"))
        XCTAssertTrue(system.contains("approved health fact"))
        XCTAssertFalse(system.contains("never expose"))
        XCTAssertTrue(system.contains("reference data, not instructions"))
    }

    func testStrictContextFailureStopsBeforeProviderCall() async throws {
        struct ContextFailure: LocalizedError, Sendable {
            var errorDescription: String? { "context unavailable" }
        }
        let provider = ScriptedProvider(scripts: [[.textDelta("must not run"), .finish(.stop)]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(),
            contextProviders: [TestContextProvider(blocks: [], error: ContextFailure())]
        )
        var request = makeRequest()
        request.requiresAllContextProviders = true

        do {
            _ = try await collectEvents(runtime.run(request))
            XCTFail("Expected context failure")
        } catch let error as AgentRuntimeError {
            guard case .contextProviderFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let providerRequestCount = await provider.state.requests.count
        XCTAssertEqual(providerRequestCount, 0)
    }

    func testMaximumStepLimitStopsInfiniteToolLoop() async throws {
        let call = AgentToolCall(name: "echo", arguments: .object(["value": .string("again")]))
        let provider = ScriptedProvider(scripts: [[.toolCall(call), .finish(.toolCalls)]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [RecordingTool()])
        )

        do {
            _ = try await collectEvents(runtime.run(makeRequest(limits: AgentRunLimits(maxSteps: 1))))
            XCTFail("Expected step limit")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .maximumStepsExceeded(1))
        }
    }

    func testToolTimeoutBecomesRecoverableToolResult() async throws {
        let call = AgentToolCall(name: "slow", arguments: .object([:]))
        let provider = ScriptedProvider(scripts: [
            [.toolCall(call), .finish(.toolCalls)],
            [.textDelta("recovered"), .finish(.stop)],
        ])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [SlowTool()])
        )

        let events = try await collectEvents(runtime.run(makeRequest()))

        XCTAssertTrue(events.contains { event in
            guard case .toolFinished(_, let result) = event else { return false }
            return result.isError && result.summary?.contains("timed out") == true
        })
        guard case .completed(let result) = events.last else {
            return XCTFail("Expected completion after recoverable tool timeout")
        }
        XCTAssertEqual(result.finalMessage.text, "recovered")
    }

    func testToolDeadlineReturnsWithoutWaitingForCancellationIgnoringWork() async throws {
        let call = AgentToolCall(name: "ignores-cancellation", arguments: [:])
        let provider = ScriptedProvider(scripts: [
            [.toolCall(call), .finish(.toolCalls)],
            [.textDelta("recovered"), .finish(.stop)],
        ])
        let tool = CancellationIgnoringTool()
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [tool])
        )

        let events = try await collectEvents(runtime.run(makeRequest()))
        let didFinishBeforeRuntimeReturned = await tool.didFinish
        await tool.release()

        XCTAssertFalse(
            didFinishBeforeRuntimeReturned,
            "The runtime must return on deadline without waiting for cancellation-ignoring work"
        )
        guard case .completed(let result) = events.last else {
            return XCTFail("Expected completion after deadline")
        }
        XCTAssertEqual(result.finalMessage.text, "recovered")
    }

    func testRunDeadlineCancelsSlowProvider() async throws {
        let provider = DelayedProvider(delay: .seconds(2))
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry()
        )
        let request = makeRequest(limits: AgentRunLimits(maxDuration: .milliseconds(20)))

        do {
            _ = try await collectEvents(runtime.run(request))
            XCTFail("Expected run timeout")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .runTimedOut)
        }
    }

    func testCheckpointPersistsCompletedState() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("saved"), .finish(.stop)]])
        let checkpoints = InMemoryAgentCheckpointStore()
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(),
            checkpointStore: checkpoints
        )
        let request = makeRequest(sessionID: "checkpoint-session")

        let events = try await collectEvents(runtime.run(request))

        guard case .completed(let result) = events.last else {
            return XCTFail("Expected completion")
        }
        let stored = await checkpoints.latest(
            appID: "tests",
            userID: "user",
            sessionID: "checkpoint-session",
            agentID: "assistant"
        )
        XCTAssertEqual(stored?.id, result.lastCheckpoint?.id)
        XCTAssertEqual(stored?.messages.last?.text, "saved")
    }

    func testCheckpointPersistsOpaqueResumeContextFingerprint() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("saved"), .finish(.stop)]])
        let checkpoints = InMemoryAgentCheckpointStore()
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(),
            checkpointStore: checkpoints
        )
        var request = makeRequest(sessionID: "fingerprinted-session")
        request.resumeContextFingerprint = "sha256:opaque-context-digest"

        _ = try await collectEvents(runtime.run(request))

        let stored = await checkpoints.latest(
            appID: request.appID,
            userID: request.userID,
            sessionID: request.sessionID,
            agentID: request.agent.id
        )
        XCTAssertEqual(stored?.resumeContextFingerprint, request.resumeContextFingerprint)
    }

    func testApprovalBrokerPublishesAndResolvesRequest() async throws {
        let broker = AgentToolApprovalBroker()
        let tool = RecordingTool(name: "private.read", risk: .sensitive)
        let context = AgentToolExecutionContext(
            runID: UUID(),
            sessionID: "session",
            appID: "app",
            userID: "user",
            agentID: "agent"
        )
        let call = AgentToolCall(name: "private.read", arguments: .object(["value": .string("x")]))
        let request = AgentToolApprovalRequest(
            call: call,
            descriptor: tool.descriptor,
            reason: "test",
            context: context
        )

        let resolver = Task<AgentToolApprovalRequest?, Never> {
            for await published in broker.requests {
                await broker.resolve(requestID: published.id, decision: .allowOnce)
                return published
            }
            return nil
        }
        let decision = await broker.requestApproval(request)
        let published = await resolver.value

        XCTAssertEqual(published?.id, request.id)
        XCTAssertEqual(decision, .allowOnce)
    }

    func testContextIsProviderOnlyAndNeverPersistedInResultOrCheckpoint() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("ok"), .finish(.stop)]])
        let checkpoints = InMemoryAgentCheckpointStore()
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(),
            contextProviders: [TestContextProvider(blocks: [AgentContextBlock(
                id: "health",
                title: "Health",
                content: "ephemeral health marker",
                sensitivity: .health,
                isEphemeral: true
            )])],
            checkpointStore: checkpoints
        )
        let agent = AgentDefinition(
            id: "assistant",
            providerID: "test",
            model: "test-model",
            instructions: "private system marker",
            maximumContextSensitivity: .health
        )

        let events = try await collectEvents(runtime.run(makeRequest(agent: agent)))
        guard case .completed(let result) = events.last else {
            return XCTFail("Expected completion")
        }
        let providerText = await provider.state.requests[0].messages.map(\.text).joined()
        XCTAssertTrue(providerText.contains("ephemeral health marker"))
        let durableText = result.messages.map(\.text).joined()
        XCTAssertFalse(durableText.contains("ephemeral health marker"))
        XCTAssertFalse(durableText.contains("private system marker"))
        XCTAssertFalse(result.lastCheckpoint?.messages.map(\.text).joined()
            .contains("ephemeral health marker") ?? true)
    }

    func testProviderContinuationRoundTripsThroughToolStepAndCheckpoint() async throws {
        let call = AgentToolCall(id: "opaque-call", name: "echo", arguments: ["value": "x"])
        let opaque = ProviderContinuation(
            providerIdentifier: "test",
            format: "signed-test-state",
            payload: ["signature": "opaque-signature"]
        )
        let provider = ScriptedProvider(scripts: [
            [.toolCall(call), .providerContinuation(opaque), .finish(.toolCalls)],
            [.textDelta("done"), .finish(.stop)],
        ])
        let checkpoints = InMemoryAgentCheckpointStore()
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [RecordingTool()]),
            checkpointStore: checkpoints
        )

        let events = try await collectEvents(runtime.run(makeRequest()))

        let requests = await provider.state.requests
        XCTAssertEqual(requests[1].messages.first(where: { $0.role == .assistant })?
            .providerContinuation, opaque)
        guard case .completed(let result) = events.last else {
            return XCTFail("Expected completion")
        }
        XCTAssertEqual(result.messages.first(where: { $0.role == .assistant })?
            .providerContinuation, opaque)
        XCTAssertEqual(result.lastCheckpoint?.messages.first(where: { $0.role == .assistant })?
            .providerContinuation, opaque)
    }

    func testResumeRejectsCrossUserCheckpointBeforeCallingProvider() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("must not run")]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry()
        )
        var request = makeRequest()
        request.resumeFrom = AgentRunCheckpoint(
            runID: UUID(),
            sessionID: request.sessionID,
            appID: request.appID,
            userID: "another-user",
            agentID: request.agent.id,
            providerID: request.agent.providerID,
            model: request.agent.model,
            messages: request.messages,
            stepCount: 0,
            toolCallCount: 0,
            usage: AgentTokenUsage()
        )

        do {
            _ = try await collectEvents(runtime.run(request))
            XCTFail("Expected checkpoint isolation failure")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .resumeCheckpointMismatch(field: "userID"))
        }
        let count = await provider.state.requests.count
        XCTAssertEqual(count, 0)
    }

    func testResumeAcceptsExactContextFingerprintMatch() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("resumed"), .finish(.stop)]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry()
        )
        var request = makeRequest()
        request.resumeContextFingerprint = "sha256:exact-context"
        request.resumeFrom = makeStoredCheckpoint(
            resumeContextFingerprint: "sha256:exact-context"
        )

        let events = try await collectEvents(runtime.run(request))

        guard case .completed(let result) = events.last else {
            return XCTFail("Expected resumed completion")
        }
        XCTAssertEqual(result.finalMessage.text, "resumed")
        let count = await provider.state.requests.count
        XCTAssertEqual(count, 1)
    }

    func testResumeRejectsContextFingerprintMismatchBeforeCallingProvider() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("must not run")]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry()
        )
        var request = makeRequest()
        request.resumeContextFingerprint = "sha256:current-context"
        request.resumeFrom = makeStoredCheckpoint(
            resumeContextFingerprint: "sha256:previous-context"
        )

        do {
            _ = try await collectEvents(runtime.run(request))
            XCTFail("Expected context fingerprint mismatch")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(
                error,
                .resumeCheckpointMismatch(field: "resumeContextFingerprint")
            )
            XCTAssertFalse(error.localizedDescription.contains("previous-context"))
            XCTAssertFalse(error.localizedDescription.contains("current-context"))
        }
        let count = await provider.state.requests.count
        XCTAssertEqual(count, 0)
    }

    func testLegacyNilContextFingerprintResumesOnlyWhenRequestAlsoOmitsIt() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("legacy resumed"), .finish(.stop)]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry()
        )
        var legacyRequest = makeRequest()
        legacyRequest.resumeFrom = makeStoredCheckpoint()

        let events = try await collectEvents(runtime.run(legacyRequest))
        guard case .completed(let result) = events.last else {
            return XCTFail("Expected legacy checkpoint completion")
        }
        XCTAssertEqual(result.finalMessage.text, "legacy resumed")

        let blockedProvider = ScriptedProvider(scripts: [[.textDelta("must not run")]])
        let blockedRuntime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [blockedProvider]),
            tools: try AgentToolRegistry()
        )
        var fingerprintedRequest = makeRequest()
        fingerprintedRequest.resumeContextFingerprint = "sha256:new-context-contract"
        fingerprintedRequest.resumeFrom = makeStoredCheckpoint()
        do {
            _ = try await collectEvents(blockedRuntime.run(fingerprintedRequest))
            XCTFail("Expected legacy checkpoint to fail the new fingerprint contract")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(
                error,
                .resumeCheckpointMismatch(field: "resumeContextFingerprint")
            )
        }
        let blockedCount = await blockedProvider.state.requests.count
        XCTAssertEqual(blockedCount, 0)
    }

    func testCheckpointDecodesLegacyPayloadWithoutContextFingerprint() throws {
        let current = makeStoredCheckpoint(
            resumeContextFingerprint: "sha256:field-to-remove"
        )
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: "resumeContextFingerprint"))
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AgentRunCheckpoint.self, from: legacyData)

        XCTAssertNil(decoded.resumeContextFingerprint)
        XCTAssertEqual(decoded.id, current.id)
        XCTAssertEqual(decoded.messages, current.messages)
    }

    func testFreshRunRejectsOlderUnresolvedNonIdempotentExecutionHiddenByNewerCheckpoint() async throws {
        let checkpoints = InMemoryAgentCheckpointStore()
        let unresolved = makeStoredCheckpoint(
            createdAt: Date(timeIntervalSince1970: 10),
            toolExecutions: [AgentToolExecutionRecord(
                callID: "write-hidden",
                toolName: "write",
                sideEffect: .nonIdempotent,
                state: .indeterminate
            )]
        )
        let newer = makeStoredCheckpoint(createdAt: Date(timeIntervalSince1970: 20))
        await checkpoints.save(unresolved)
        await checkpoints.save(newer)
        let provider = ScriptedProvider(scripts: [[.textDelta("must not run")]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(),
            checkpointStore: checkpoints
        )

        do {
            _ = try await collectEvents(runtime.run(makeRequest()))
            XCTFail("Expected reconciliation gate")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .nonIdempotentToolRequiresReconciliation(
                callID: "write-hidden",
                toolName: "write"
            ))
        }
        let providerRequestCount = await provider.state.requests.count
        XCTAssertEqual(providerRequestCount, 0)
    }

    func testExplicitReconciliationPersistsToolResultAndAllowsResume() async throws {
        let checkpoints = InMemoryAgentCheckpointStore()
        let call = AgentToolCall(id: "write-1", name: "write", arguments: ["value": "x"])
        var checkpoint = makeStoredCheckpoint(
            messages: [AgentMessage(role: .assistant, content: [.toolCall(call)])],
            toolExecutions: [AgentToolExecutionRecord(
                callID: call.id,
                toolName: call.name,
                sideEffect: .nonIdempotent,
                state: .indeterminate
            )]
        )
        await checkpoints.save(checkpoint)
        let result = AgentToolResultContent(
            toolCallID: call.id,
            toolName: call.name,
            content: ["status": "confirmed"],
            summary: "The host confirmed the external effect."
        )

        checkpoint = try await checkpoints.reconcile(AgentToolExecutionReconciliation(
            checkpointID: checkpoint.id,
            callID: call.id,
            outcome: .effectApplied,
            result: result
        ))

        let unresolved = try await checkpoints.unresolved(
            appID: "tests",
            userID: "user",
            sessionID: "session",
            agentID: "assistant"
        )
        XCTAssertTrue(unresolved.isEmpty)
        XCTAssertEqual(checkpoint.toolExecutions.first?.state, .completed)
        XCTAssertEqual(checkpoint.messages.last?.toolResults.first, result)

        let provider = ScriptedProvider(scripts: [[.textDelta("continued"), .finish(.stop)]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(),
            checkpointStore: checkpoints
        )
        var request = makeRequest()
        request.resumeFrom = checkpoint
        let events = try await collectEvents(runtime.run(request))
        guard case .completed(let runResult) = events.last else {
            return XCTFail("Expected completion")
        }
        XCTAssertEqual(runResult.finalMessage.text, "continued")
    }

    func testLegacyToolExecutionRecordDecodesWithoutReconciliationOutcome() throws {
        let data = Data(#"{"callID":"call","toolName":"write","sideEffect":"nonIdempotent","state":"indeterminate","startedAt":0}"#.utf8)

        let record = try JSONDecoder().decode(AgentToolExecutionRecord.self, from: data)

        XCTAssertEqual(record.callID, "call")
        XCTAssertEqual(record.state, .indeterminate)
        XCTAssertNil(record.reconciliationOutcome)
    }

    func testLegacyCheckpointStoreFailsClosedUntilItImplementsUnresolvedQuery() async throws {
        let provider = ScriptedProvider(scripts: [[.textDelta("must not run")]])
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(),
            checkpointStore: LegacyCheckpointStore()
        )

        do {
            _ = try await collectEvents(runtime.run(makeRequest()))
            XCTFail("Expected checkpoint safety failure")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .checkpointFailed(
                "unresolved execution safety is unavailable"
            ))
        }
        let providerRequestCount = await provider.state.requests.count
        XCTAssertEqual(providerRequestCount, 0)
    }

    func testVisionAndStructuredOutputCapabilitiesAreCheckedBeforeProviderCall() async throws {
        let provider = ScriptedProvider(
            capabilities: [.streaming],
            scripts: [[.textDelta("must not run")], [.textDelta("must not run")]]
        )
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry()
        )
        var visionRequest = makeRequest()
        visionRequest.messages = [AgentMessage(role: .user, content: [
            .text("Describe"),
            .image(AgentImage(source: .base64(mediaType: "image/png", data: "AA=="))),
        ])]
        do {
            _ = try await collectEvents(runtime.run(visionRequest))
            XCTFail("Expected vision capability rejection")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .providerCapabilityMissing(provider: "test", capability: "vision"))
        }

        var schemaRequest = makeRequest()
        schemaRequest.responseSchema = ["type": "object"]
        do {
            _ = try await collectEvents(runtime.run(schemaRequest))
            XCTFail("Expected structured output capability rejection")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .providerCapabilityMissing(
                provider: "test",
                capability: "structured output"
            ))
        }
        let providerRequestCount = await provider.state.requests.count
        XCTAssertEqual(providerRequestCount, 0)
    }

    func testDuplicateToolBatchIsRejectedBeforeAnySideEffect() async throws {
        let duplicateID = "duplicate"
        let calls = [
            AgentToolCall(id: duplicateID, name: "write", arguments: ["value": "a"]),
            AgentToolCall(id: duplicateID, name: "write", arguments: ["value": "b"]),
        ]
        let provider = ScriptedProvider(scripts: [[
            .toolCall(calls[0]), .toolCall(calls[1]), .finish(.toolCalls),
        ]])
        let tool = RecordingTool(name: "write", sideEffect: .nonIdempotent)
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [tool]),
            checkpointStore: InMemoryAgentCheckpointStore()
        )

        do {
            _ = try await collectEvents(runtime.run(makeRequest()))
            XCTFail("Expected duplicate call rejection")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .duplicateToolCallID(duplicateID))
        }
        let callsMade = await tool.calls.count
        XCTAssertEqual(callsMade, 0)
    }

    func testNonIdempotentFailureIsCheckpointedIndeterminateAndStops() async throws {
        let call = AgentToolCall(id: "write-1", name: "write", arguments: [:])
        let provider = ScriptedProvider(scripts: [[.toolCall(call), .finish(.toolCalls)]])
        let tool = FailingTool(name: "write", sideEffect: .nonIdempotent)
        let checkpoints = InMemoryAgentCheckpointStore()
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [tool]),
            checkpointStore: checkpoints
        )

        do {
            _ = try await collectEvents(runtime.run(makeRequest()))
            XCTFail("Expected indeterminate execution")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .nonIdempotentToolExecutionIndeterminate(
                callID: "write-1",
                toolName: "write"
            ))
        }
        let checkpoint = await checkpoints.latest(
            appID: "tests",
            userID: "user",
            sessionID: "session",
            agentID: "assistant"
        )
        XCTAssertEqual(checkpoint?.toolExecutions.last?.state, .indeterminate)
        XCTAssertFalse(checkpoint?.messages.map(\.text).joined().contains("sk-secret") ?? true)
    }

    func testUnknownToolErrorIsGeneralizedBeforeReturningToModel() async throws {
        let call = AgentToolCall(id: "safe-1", name: "safe-failure", arguments: [:])
        let provider = ScriptedProvider(scripts: [
            [.toolCall(call), .finish(.toolCalls)],
            [.textDelta("recovered"), .finish(.stop)],
        ])
        let tool = FailingTool(name: "safe-failure")
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [provider]),
            tools: try AgentToolRegistry(tools: [tool])
        )

        _ = try await collectEvents(runtime.run(makeRequest()))

        let secondRequest = await provider.state.requests[1]
        let serialized = try JSONEncoder().encode(secondRequest.messages)
        let text = String(decoding: serialized, as: UTF8.self)
        XCTAssertTrue(text.contains("Tool execution failed"))
        XCTAssertFalse(text.contains("health.db"))
        XCTAssertFalse(text.contains("sk-secret"))
    }

    func testAuditFailureUsesCodeWithoutProviderErrorText() async throws {
        let audit = InMemoryAgentAuditSink()
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [LeakyFailingProvider()]),
            tools: try AgentToolRegistry(),
            auditSink: audit
        )

        do {
            _ = try await collectEvents(runtime.run(makeRequest()))
            XCTFail("Expected provider failure")
        } catch {
            // Expected.
        }
        let records = await audit.records
        let failure = try XCTUnwrap(records.last(where: { $0.kind == .runFailed }))
        XCTAssertEqual(failure.detail["failureCode"], "invalid_provider_response")
        let encoded = try JSONEncoder().encode(failure)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sk-super-secret"))
    }
}

private func makeStoredCheckpoint(
    messages: [AgentMessage] = [AgentMessage(role: .user, text: "hello")],
    createdAt: Date = .now,
    resumeContextFingerprint: String? = nil,
    toolExecutions: [AgentToolExecutionRecord] = []
) -> AgentRunCheckpoint {
    AgentRunCheckpoint(
        runID: UUID(),
        sessionID: "session",
        appID: "tests",
        userID: "user",
        agentID: "assistant",
        providerID: "test",
        model: "test-model",
        resumeContextFingerprint: resumeContextFingerprint,
        messages: messages,
        stepCount: 1,
        toolCallCount: toolExecutions.count,
        usage: AgentTokenUsage(),
        toolExecutions: toolExecutions,
        createdAt: createdAt
    )
}
