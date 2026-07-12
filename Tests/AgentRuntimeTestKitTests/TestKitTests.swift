import AgentRuntimeCore
import AgentRuntimeTestKit
import XCTest

final class TestKitTests: XCTestCase {
    func testScriptedProviderRecordsRequests() async throws {
        let provider = ScriptedModelProvider(scripts: [[.textDelta("ok"), .finish(.stop)]])
        let request = ModelRequest(
            model: "model",
            messages: [AgentMessage(role: .user, text: "hello")]
        )
        var events: [ModelStreamEvent] = []
        for try await event in provider.stream(request) { events.append(event) }

        let recorded = await provider.requests
        XCTAssertEqual(recorded, [request])
        XCTAssertEqual(events, [.textDelta("ok"), .finish(.stop)])
    }

    func testInMemorySecretStoreUsesNamespaceAndAccount() async throws {
        let store = InMemorySecretStore()
        await store.saveSecret("one", namespace: "app-a", account: "openai")
        await store.saveSecret("two", namespace: "app-b", account: "openai")
        let first = await store.loadSecret(namespace: "app-a", account: "openai")
        let second = await store.loadSecret(namespace: "app-b", account: "openai")
        XCTAssertEqual(first, "one")
        XCTAssertEqual(second, "two")
    }
}
