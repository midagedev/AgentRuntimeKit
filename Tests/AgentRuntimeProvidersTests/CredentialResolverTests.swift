import AgentRuntimeProviders
import XCTest

final class CredentialResolverTests: XCTestCase {
    func testResolvesMappedAccountAndTrimsWhitespace() async throws {
        let store = TestSecretStore()
        await store.saveSecret("  byok-secret\n", namespace: "test", account: "shared-openai")
        let resolver = ProviderCredentialResolver(
            secretStore: store,
            namespace: "test",
            accounts: ["openrouter": "shared-openai"]
        )

        let credential = try await resolver.credential(for: "openrouter")

        XCTAssertEqual(credential, "byok-secret")
    }

    func testMissingCredentialHasTypedNonSecretError() async {
        let resolver = ProviderCredentialResolver(secretStore: TestSecretStore(), namespace: "test")

        do {
            _ = try await resolver.credential(for: "anthropic")
            XCTFail("Expected a missing-credential error")
        } catch let error as ProviderCredentialError {
            XCTAssertEqual(
                error,
                .missing(providerIdentifier: "anthropic", namespace: "test", account: "anthropic")
            )
            XCTAssertFalse(error.localizedDescription.contains("api_key"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyCredentialIsRejected() async throws {
        let store = TestSecretStore()
        await store.saveSecret(" \n ", namespace: "test", account: "gemini")
        let resolver = ProviderCredentialResolver(secretStore: store, namespace: "test")

        do {
            _ = try await resolver.credential(for: "gemini")
            XCTFail("Expected an empty-credential error")
        } catch let error as ProviderCredentialError {
            XCTAssertEqual(
                error,
                .empty(providerIdentifier: "gemini", namespace: "test", account: "gemini")
            )
        }
    }
}
