import AgentRuntimeCore
import AgentRuntimeProviders
import Foundation
import XCTest

final class ProviderReliabilityTests: XCTestCase {
    func testRetriesRateLimitUsingNormalizedHeaders() async throws {
        let rateLimitBody = Data("{\"error\":{\"message\":\"Please retry later\"}}".utf8)
        let transport = FixtureHTTPClient([
            FixtureHTTPResponse(
                statusCode: 429,
                headers: [
                    "Retry-After": "0",
                    "X-RateLimit-Limit-Requests": "100",
                    "X-RateLimit-Remaining-Requests": "0",
                    "X-Request-ID": "rate_fixture",
                ],
                chunks: [rateLimitBody]
            ),
            FixtureHTTPResponse(chunks: chunked(try loadFixture("openai-chat.sse"))),
        ])
        let provider = OpenAIChatCompletionsProvider(
            credentialResolver: StaticProviderCredentialResolver(credential: "never-log-this-key"),
            retryPolicy: ProviderRetryPolicy(
                maximumAttempts: 2,
                baseDelaySeconds: 0,
                maximumDelaySeconds: 0,
                jitterRatio: 0
            ),
            httpClient: transport
        )

        let events = try await collectEvents(provider.stream(fixtureRequest()))

        XCTAssertEqual(textOutput(events), "Hi there")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
    }

    func testTerminalHTTPErrorIsTypedAndDoesNotExposeRawBodyOrKey() async throws {
        let secret = "never-log-this-key"
        let rawMarker = "raw-body-private-marker"
        let body = Data("{\"error\":{\"message\":\"Denied\",\"debug\":\"\(rawMarker)\"}}".utf8)
        let transport = FixtureHTTPClient([
            FixtureHTTPResponse(
                statusCode: 429,
                headers: ["Retry-After": "2", "X-Request-ID": "req_fixture"],
                chunks: [body]
            ),
        ])
        let provider = OpenAIChatCompletionsProvider(
            credentialResolver: StaticProviderCredentialResolver(credential: secret),
            retryPolicy: .none,
            httpClient: transport
        )

        do {
            _ = try await collectEvents(provider.stream(fixtureRequest()))
            XCTFail("Expected HTTP error")
        } catch let error as ProviderHTTPError {
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(error.category, .rateLimited)
            XCTAssertEqual(error.message, "Denied")
            XCTAssertEqual(error.requestID, "req_fixture")
            XCTAssertEqual(error.rateLimit.retryAfterSeconds, 2)
            XCTAssertTrue(error.isRetryable)
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertFalse(error.localizedDescription.contains(rawMarker))
            XCTAssertFalse(String(reflecting: error).contains(rawMarker))
        }
    }

    func testProviderErrorMessageRedactsEchoedCredentialAndLocalPath() async throws {
        let body = Data(#"{"error":{"message":"Invalid API key: sk-live-supersecret at /Users/alice/private.json"}}"#.utf8)
        let transport = FixtureHTTPClient([
            FixtureHTTPResponse(
                statusCode: 401,
                headers: ["X-Request-ID": "Bearer sk-request-secret"],
                chunks: [body]
            ),
        ])
        let provider = OpenAIChatCompletionsProvider(
            credentialResolver: StaticProviderCredentialResolver(credential: "unrelated-key"),
            retryPolicy: .none,
            httpClient: transport
        )

        do {
            _ = try await collectEvents(provider.stream(fixtureRequest()))
            XCTFail("Expected HTTP error")
        } catch let error as ProviderHTTPError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertTrue(error.message.contains("[REDACTED]"))
            XCTAssertFalse(error.message.contains("sk-live-supersecret"))
            XCTAssertFalse(error.localizedDescription.contains("/Users/alice"))
            XCTAssertNil(error.requestID)
        }
    }

    func testFallbackMovesOnBeforeContent() async throws {
        let failing = StubModelProvider(identifier: "first", failure: .fixtureFailure)
        let succeeding = StubModelProvider(
            identifier: "second",
            capabilities: [.streaming, .tools, .vision],
            events: [.metadata(["id": "ok"]), .textDelta("fallback"), .finish(.stop)]
        )
        let provider = FallbackModelProvider(providers: [failing, succeeding])

        let events = try await collectEvents(provider.stream(fixtureRequest()))

        XCTAssertEqual(textOutput(events), "fallback")
        XCTAssertEqual(finalReason(events), .stop)
        XCTAssertTrue(provider.capabilities.contains(.streaming))
        XCTAssertTrue(provider.capabilities.contains(.tools))
        XCTAssertFalse(provider.capabilities.contains(.vision), "Capabilities are the safe intersection")
        XCTAssertTrue(events.contains { event in
            guard case .metadata(let metadata) = event else { return false }
            return metadata["fallbackProvider"] == "second"
        })
    }

    func testFallbackDoesNotReplayAfterPartialContent() async {
        let partial = StubModelProvider(
            identifier: "partial",
            events: [.textDelta("already emitted")],
            failure: .fixtureFailure
        )
        let unused = StubModelProvider(
            identifier: "unused",
            events: [.textDelta("should not appear"), .finish(.stop)]
        )
        let provider = FallbackModelProvider(providers: [partial, unused])

        var events: [ModelStreamEvent] = []
        do {
            for try await event in provider.stream(fixtureRequest()) { events.append(event) }
            XCTFail("Expected partial provider failure")
        } catch {
            XCTAssertEqual(error as? ProviderTestError, .fixtureFailure)
        }
        XCTAssertEqual(textOutput(events), "already emitted")
    }

    func testFallbackPinsOpaqueContinuationToSelectedProviderAcrossToolLoop() async throws {
        let childContinuation = ProviderContinuation(
            providerIdentifier: "second",
            format: "signed-state",
            payload: ["signature": "opaque"]
        )
        let first = StubModelProvider(identifier: "first", failure: .fixtureFailure)
        let second = RecordingStubModelProvider(identifier: "second", scripts: [
            [
                .toolCall(AgentToolCall(id: "call-1", name: "weather", arguments: ["city": "Seoul"])),
                .providerContinuation(childContinuation),
                .finish(.toolCalls),
            ],
            [.textDelta("done"), .finish(.stop)],
        ])
        let fallback = FallbackModelProvider(providers: [first, second])
        let initial = ModelRequest(
            model: "fixture-model",
            messages: [AgentMessage(role: .user, text: "Weather?")],
            tools: [fixtureTool]
        )

        let firstEvents = try await collectEvents(fallback.stream(initial))
        let routed = try XCTUnwrap(finalContinuation(firstEvents))
        XCTAssertEqual(routed.providerIdentifier, "fallback")
        XCTAssertNotEqual(routed.payload, childContinuation.payload)

        let assistant = AgentMessage(
            role: .assistant,
            content: [.toolCall(AgentToolCall(
                id: "call-1",
                name: "weather",
                arguments: ["city": "Seoul"]
            ))],
            providerContinuation: routed
        )
        let followUp = ModelRequest(
            model: "fixture-model",
            messages: [
                initial.messages[0],
                assistant,
                AgentMessage(role: .tool, content: [.toolResult(AgentToolResultContent(
                    toolCallID: "call-1",
                    toolName: "weather",
                    content: ["temperature": 27]
                ))]),
            ],
            tools: [fixtureTool]
        )

        let secondEvents = try await collectEvents(fallback.stream(followUp))

        XCTAssertEqual(textOutput(secondEvents), "done")
        let requests = await second.state.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[1].messages.first(where: { $0.role == .assistant })?.providerContinuation,
            childContinuation
        )
    }

    func testFallbackRoutedContinuationPassesRuntimeAdapterValidation() async throws {
        let continuation = ProviderContinuation(
            providerIdentifier: "second",
            format: "signed-state",
            payload: ["signature": "opaque"]
        )
        let child = RecordingStubModelProvider(identifier: "second", scripts: [
            [
                .toolCall(AgentToolCall(
                    id: "call-1",
                    name: "weather",
                    arguments: ["city": "Seoul"]
                )),
                .providerContinuation(continuation),
                .finish(.toolCalls),
            ],
            [.textDelta("done"), .finish(.stop)],
        ])
        let fallback = FallbackModelProvider(
            providers: [StubModelProvider(identifier: "first", failure: .fixtureFailure), child]
        )
        let runtime = AgentRuntime(
            providers: ModelProviderRegistry(providers: [fallback]),
            tools: try AgentToolRegistry(tools: [ProviderFixtureTool()])
        )
        let request = AgentRunRequest(
            sessionID: "session",
            appID: "tests",
            agent: AgentDefinition(
                id: "assistant",
                providerID: fallback.identifier,
                model: "model",
                instructions: "Be concise."
            ),
            messages: [AgentMessage(role: .user, text: "Weather in Seoul?")]
        )

        var events: [AgentEvent] = []
        for try await event in runtime.run(request) { events.append(event) }

        guard case .completed(let result) = events.last else {
            return XCTFail("Expected completed runtime event")
        }
        XCTAssertEqual(result.finalMessage.text, "done")
        XCTAssertEqual(
            result.messages.first(where: { !$0.toolCalls.isEmpty })?.providerContinuation?
                .providerIdentifier,
            fallback.identifier
        )
        let requests = await child.state.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[1].messages.first(where: { !$0.toolCalls.isEmpty })?.providerContinuation,
            continuation
        )
    }

    func testFallbackRejectsCorruptRoutingEnvelopeWithoutTryingAnotherProvider() async throws {
        let first = RecordingStubModelProvider(identifier: "first", scripts: [[.textDelta("unsafe")]])
        let fallback = FallbackModelProvider(providers: [first])
        let corrupt = ProviderContinuation(
            providerIdentifier: "fallback",
            format: "agent-runtime.fallback-route",
            payload: ["providerIdentifier": "missing"]
        )
        let request = ModelRequest(
            model: "model",
            messages: [AgentMessage(
                role: .assistant,
                content: [.text("partial")],
                providerContinuation: corrupt
            )]
        )

        do {
            _ = try await collectEvents(fallback.stream(request))
            XCTFail("Expected corrupt continuation rejection")
        } catch let error as AgentRuntimeError {
            guard case .invalidProviderResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let requestCount = await first.state.requests.count
        XCTAssertEqual(requestCount, 0)
    }
}
