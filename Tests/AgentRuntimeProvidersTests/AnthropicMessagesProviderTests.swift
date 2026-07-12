import AgentRuntimeCore
import AgentRuntimeProviders
import Foundation
import XCTest

final class AnthropicMessagesProviderTests: XCTestCase {
    func testNormalizesFixtureAndBuildsMessagesRequest() async throws {
        let transport = FixtureHTTPClient([
            FixtureHTTPResponse(
                headers: [
                    "request-id": "req_fixture",
                    "x-ratelimit-remaining-requests": "7",
                ],
                chunks: chunked(try loadFixture("anthropic-messages.sse"))
            ),
            FixtureHTTPResponse(chunks: chunked(Data("""
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_done","model":"claude-fixture","usage":{"input_tokens":1}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"done"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

            event: message_stop
            data: {"type":"message_stop"}

            """.utf8))),
        ])
        let provider = AnthropicMessagesProvider(
            endpoint: URL(string: "https://proxy.example/anthropic/messages")!,
            credentialResolver: StaticProviderCredentialResolver(credential: "anthropic-key"),
            credentialHeaderName: "x-proxy-secret",
            credentialPrefix: "Key ",
            retryPolicy: .none,
            httpClient: transport
        )

        let events = try await collectEvents(provider.stream(fixtureRequest(model: "claude-fixture")))

        XCTAssertEqual(textOutput(events), "Hello world")
        XCTAssertEqual(reasoningOutput(events), "carefully")
        XCTAssertEqual(toolCalls(events), [
            AgentToolCall(id: "tool_fixture", name: "weather", arguments: ["city": "Seoul"]),
        ])
        XCTAssertEqual(finalUsage(events), AgentTokenUsage(inputTokens: 12, outputTokens: 7, cachedInputTokens: 3))
        XCTAssertEqual(finalReason(events), .toolCalls)
        let continuation = try XCTUnwrap(finalContinuation(events))
        XCTAssertEqual(
            continuation.payload.arrayValue?.first?["signature"],
            "signed-anthropic-state"
        )

        _ = try await collectEvents(provider.stream(ModelRequest(
            model: "claude-fixture",
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: [.text("normalized fallback must not be duplicated")],
                    providerContinuation: continuation
                ),
                AgentMessage(role: .tool, content: [.toolResult(AgentToolResultContent(
                    toolCallID: "tool_fixture",
                    toolName: "weather",
                    content: ["temperature": 22]
                ))]),
            ]
        )))
        XCTAssertTrue(events.contains { event in
            guard case .metadata(let value) = event else { return false }
            return value["rateLimit"]?["remainingRequests"] == 7
        })

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://proxy.example/anthropic/messages")
        XCTAssertEqual(header("x-proxy-secret", in: request), "Key anthropic-key")
        XCTAssertEqual(header("anthropic-version", in: request), "2023-06-01")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["model"], "claude-fixture")
        XCTAssertEqual(body["system"], "Be concise.")
        XCTAssertEqual(body["max_tokens"], 128)
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["tools"]?.arrayValue?.count, 1)
        XCTAssertEqual(body["output_config"]?["format"]?["type"], "json_schema")
        let followup = try bodyJSON(requests[1])
        XCTAssertEqual(
            followup["messages"]?.arrayValue?.first?["content"],
            continuation.payload
        )
    }
}
