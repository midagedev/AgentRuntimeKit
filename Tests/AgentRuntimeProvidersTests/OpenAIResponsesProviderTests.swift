import AgentRuntimeCore
import AgentRuntimeProviders
import Foundation
import XCTest

final class OpenAIResponsesProviderTests: XCTestCase {
    func testNormalizesFixtureWithoutDuplicatingCompletedTool() async throws {
        let transport = FixtureHTTPClient([
            FixtureHTTPResponse(chunks: chunked(try loadFixture("openai-responses.sse"))),
            FixtureHTTPResponse(chunks: chunked(Data("""
            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_done","status":"completed","output":[{"id":"msg_done","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"done","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1}}}

            """.utf8))),
        ])
        let provider = OpenAIResponsesProvider(
            credentialResolver: StaticProviderCredentialResolver(credential: "responses-key"),
            retryPolicy: .none,
            httpClient: transport
        )

        let events = try await collectEvents(provider.stream(fixtureRequest(model: "gpt-fixture")))

        XCTAssertEqual(textOutput(events), "Checking ")
        XCTAssertEqual(reasoningOutput(events), "brief thought")
        XCTAssertEqual(toolCalls(events), [
            AgentToolCall(id: "call_fixture", name: "weather", arguments: ["city": "Seoul"]),
        ])
        XCTAssertEqual(finalUsage(events), AgentTokenUsage(inputTokens: 11, outputTokens: 5, cachedInputTokens: 4))
        XCTAssertEqual(finalReason(events), .toolCalls)
        let continuation = try XCTUnwrap(finalContinuation(events))
        XCTAssertEqual(
            continuation.payload.arrayValue?.first?["encrypted_content"],
            "encrypted-reasoning-state"
        )

        _ = try await collectEvents(provider.stream(ModelRequest(
            model: "gpt-fixture",
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: [.text("normalized fallback must not be duplicated")],
                    providerContinuation: continuation
                ),
                AgentMessage(role: .tool, content: [.toolResult(AgentToolResultContent(
                    toolCallID: "call_fixture",
                    toolName: "weather",
                    content: ["temperature": 22]
                ))]),
            ],
            metadata: ["private_health_id": "must-not-leave-device"],
            providerMetadata: ["metadata": ["tenant": "fixture"]]
        )))

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.path, "/v1/responses")
        XCTAssertEqual(header("authorization", in: request), "Bearer responses-key")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["instructions"], "Be concise.")
        XCTAssertEqual(body["max_output_tokens"], 128)
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["type"], "function")
        XCTAssertEqual(body["text"]?["format"]?["type"], "json_schema")
        XCTAssertEqual(body["input"]?.arrayValue?.first?["role"], "user")
        XCTAssertEqual(body["store"], false)
        XCTAssertEqual(body["include"]?.arrayValue, ["reasoning.encrypted_content"])
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["strict"], false)
        XCTAssertEqual(body["metadata"]?["test_run"], "fixture")
        XCTAssertNil(body["metadata"]?["local_health_context_id"])

        let followup = try bodyJSON(requests[1])
        let input = try XCTUnwrap(followup["input"]?.arrayValue)
        let expectedItems = try XCTUnwrap(continuation.payload.arrayValue)
        XCTAssertEqual(Array(input.prefix(expectedItems.count)), expectedItems)
        XCTAssertEqual(followup["metadata"]?["tenant"], "fixture")
        XCTAssertNil(followup["metadata"]?["private_health_id"])
    }
}
