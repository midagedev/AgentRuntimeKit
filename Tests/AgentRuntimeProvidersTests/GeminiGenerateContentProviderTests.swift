import AgentRuntimeCore
import AgentRuntimeProviders
import Foundation
import XCTest

final class GeminiGenerateContentProviderTests: XCTestCase {
    func testNormalizesFixtureAndBuildsGenerateContentRequest() async throws {
        let transport = FixtureHTTPClient([
            FixtureHTTPResponse(chunks: chunked(try loadFixture("gemini.sse"))),
            FixtureHTTPResponse(chunks: chunked(Data("""
            data: {"candidates":[{"index":0,"content":{"role":"model","parts":[{"text":"done"}]},"finishReason":"STOP"}]}

            """.utf8))),
        ])
        let provider = GeminiGenerateContentProvider(
            baseURL: URL(string: "https://proxy.example/google/v1beta")!,
            credentialResolver: StaticProviderCredentialResolver(credential: "gemini-key"),
            credentialHeaderName: "x-proxy-key",
            credentialPrefix: "Secret ",
            retryPolicy: .none,
            httpClient: transport
        )

        let events = try await collectEvents(provider.stream(fixtureRequest(model: "models/gemini-fixture")))

        XCTAssertEqual(textOutput(events), "Hello ")
        XCTAssertEqual(reasoningOutput(events), "planning")
        XCTAssertEqual(toolCalls(events), [
            AgentToolCall(id: "call_fixture", name: "weather", arguments: ["city": "Seoul"]),
        ])
        XCTAssertEqual(finalUsage(events), AgentTokenUsage(inputTokens: 8, outputTokens: 4, cachedInputTokens: 2))
        XCTAssertEqual(finalReason(events), .toolCalls)
        let continuation = try XCTUnwrap(finalContinuation(events))
        XCTAssertEqual(
            continuation.payload["parts"]?.arrayValue?.last?["thoughtSignature"],
            "signed-gemini-state"
        )

        _ = try await collectEvents(provider.stream(ModelRequest(
            model: "gemini-fixture",
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: [
                        .text("normalized fallback must not be duplicated"),
                        .toolCall(AgentToolCall(
                            id: "call_fixture",
                            name: "weather",
                            arguments: ["city": "Seoul"]
                        )),
                    ],
                    providerContinuation: continuation
                ),
                AgentMessage(role: .tool, content: [.toolResult(AgentToolResultContent(
                    toolCallID: "call_fixture",
                    toolName: "weather",
                    content: ["temperature": 22]
                ))]),
            ]
        )))

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://proxy.example/google/v1beta/models/gemini-fixture:streamGenerateContent?alt=sse"
        )
        XCTAssertEqual(header("x-proxy-key", in: request), "Secret gemini-key")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["systemInstruction"]?["parts"]?.arrayValue?.first?["text"], "Be concise.")
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["functionDeclarations"]?.arrayValue?.count, 1)
        XCTAssertEqual(body["generationConfig"]?["maxOutputTokens"], 128)
        XCTAssertEqual(body["generationConfig"]?["responseMimeType"], "application/json")
        XCTAssertEqual(body["contents"]?.arrayValue?.first?["role"], "user")
        let followup = try bodyJSON(requests[1])
        let replayed = followup["contents"]?.arrayValue?.first
        XCTAssertEqual(replayed, continuation.payload)
        XCTAssertFalse(try replayed?.encodedString().contains("normalized fallback") ?? true)
    }

    func testRejectsUnsafeModelPathBeforeTransport() async {
        let transport = FixtureHTTPClient([])
        let provider = GeminiGenerateContentProvider(retryPolicy: .none, httpClient: transport)

        do {
            _ = try await collectEvents(provider.stream(fixtureRequest(model: "models/../secret")))
            XCTFail("Expected invalid model identifier")
        } catch let error as AgentRuntimeError {
            guard case .invalidProviderResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
