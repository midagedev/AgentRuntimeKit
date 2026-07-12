import AgentRuntimeCore
import AgentRuntimeProviders
import Foundation
import XCTest

final class OpenAIChatCompletionsProviderTests: XCTestCase {
    func testNormalizesFixtureAndBuildsCompatibleRequest() async throws {
        let transport = FixtureHTTPClient([
            FixtureHTTPResponse(chunks: chunked(try loadFixture("openai-chat.sse"))),
        ])
        let provider = OpenAIChatCompletionsProvider(
            identifier: "custom-proxy",
            endpoint: URL(string: "https://proxy.example/v1/chat/completions")!,
            credentialResolver: StaticProviderCredentialResolver(credential: "proxy-key"),
            authorizationHeader: "x-provider-key",
            authorizationPrefix: "Token ",
            maxOutputTokensParameter: "max_tokens",
            additionalHeaders: ["x-tenant": "fixture"],
            retryPolicy: .none,
            httpClient: transport
        )

        let events = try await collectEvents(provider.stream(fixtureRequest(model: "gpt-fixture")))

        XCTAssertEqual(textOutput(events), "Hi there")
        XCTAssertEqual(reasoningOutput(events), "thinking ")
        XCTAssertEqual(toolCalls(events), [
            AgentToolCall(id: "call_fixture", name: "weather", arguments: ["city": "Seoul"]),
        ])
        XCTAssertEqual(finalUsage(events), AgentTokenUsage(inputTokens: 9, outputTokens: 4, cachedInputTokens: 2))
        XCTAssertEqual(finalReason(events), .toolCalls)

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(header("x-provider-key", in: request), "Token proxy-key")
        XCTAssertEqual(header("x-tenant", in: request), "fixture")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["model"], "gpt-fixture")
        XCTAssertEqual(body["max_tokens"], 128)
        XCTAssertEqual(body["parallel_tool_calls"], true)
        XCTAssertEqual(body["stream_options"]?["include_usage"], true)
        XCTAssertEqual(body["response_format"]?["json_schema"]?["name"], "fixture_response")
        XCTAssertEqual(body["messages"]?.arrayValue?.count, 2)
    }

    func testOpenRouterXAIAndOllamaPresets() async throws {
        let done = Data("data: [DONE]\n\n".utf8)
        let openRouterTransport = FixtureHTTPClient([FixtureHTTPResponse(chunks: [done])])
        let openRouter = OpenAIChatCompletionsProvider.openRouter(
            credentialResolver: StaticProviderCredentialResolver(credential: "router-key"),
            referer: URL(string: "https://example.app")!,
            applicationName: "Fixture App",
            retryPolicy: .none,
            httpClient: openRouterTransport
        )
        _ = try await collectEvents(openRouter.stream(fixtureRequest()))
        let routerRequests = await openRouterTransport.requests()
        let routerRequest = try XCTUnwrap(routerRequests.first)
        XCTAssertEqual(routerRequest.url.host, "openrouter.ai")
        XCTAssertEqual(header("authorization", in: routerRequest), "Bearer router-key")
        XCTAssertEqual(header("HTTP-Referer", in: routerRequest), "https://example.app")
        XCTAssertEqual(header("X-Title", in: routerRequest), "Fixture App")

        let xaiTransport = FixtureHTTPClient([FixtureHTTPResponse(chunks: [done])])
        let xai = OpenAIChatCompletionsProvider.xAI(
            credentialResolver: StaticProviderCredentialResolver(credential: "xai-key"),
            retryPolicy: .none,
            httpClient: xaiTransport
        )
        _ = try await collectEvents(xai.stream(fixtureRequest()))
        let xaiRequests = await xaiTransport.requests()
        XCTAssertEqual(try XCTUnwrap(xaiRequests.first).url.host, "api.x.ai")

        let ollamaTransport = FixtureHTTPClient([FixtureHTTPResponse(chunks: [done])])
        let ollama = OpenAIChatCompletionsProvider.ollama(
            retryPolicy: .none,
            httpClient: ollamaTransport
        )
        _ = try await collectEvents(ollama.stream(fixtureRequest()))
        let ollamaRequests = await ollamaTransport.requests()
        let ollamaRequest = try XCTUnwrap(ollamaRequests.first)
        XCTAssertEqual(ollamaRequest.url.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertNil(header("authorization", in: ollamaRequest))
        XCTAssertNil(try bodyJSON(ollamaRequest)["stream_options"])
    }
}
