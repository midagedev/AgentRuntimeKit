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
}
