import AgentRuntimeCore
import Foundation

public protocol ProviderCredentialResolving: Sendable {
    func credential(for providerIdentifier: String) async throws -> String
}
public enum ProviderCredentialError: LocalizedError, Sendable, Equatable {
    case missing(providerIdentifier: String, namespace: String, account: String)
    case empty(providerIdentifier: String, namespace: String, account: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let provider, let namespace, let account):
            "No credential for provider '\(provider)' was found in secret store namespace '\(namespace)' and account '\(account)'."
        case .empty(let provider, let namespace, let account):
            "The credential for provider '\(provider)' in secret store namespace '\(namespace)' and account '\(account)' is empty."
        }
    }
}

/// Resolves provider credentials from the host's `AgentSecretStore` implementation.
public struct ProviderCredentialResolver: ProviderCredentialResolving, Sendable {
    public let secretStore: any AgentSecretStore
    public let namespace: String
    public let accounts: [String: String]

    public init(
        secretStore: any AgentSecretStore,
        namespace: String = "AgentRuntimeKit.ModelProviders",
        accounts: [String: String] = [:]
    ) {
        self.secretStore = secretStore
        self.namespace = namespace
        self.accounts = accounts
    }

    public func credential(for providerIdentifier: String) async throws -> String {
        let account = accounts[providerIdentifier] ?? providerIdentifier
        guard let value = try await secretStore.loadSecret(namespace: namespace, account: account) else {
            throw ProviderCredentialError.missing(
                providerIdentifier: providerIdentifier,
                namespace: namespace,
                account: account
            )
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderCredentialError.empty(
                providerIdentifier: providerIdentifier,
                namespace: namespace,
                account: account
            )
        }
        return trimmed
    }
}

/// In-memory credential resolver intended for tests and short-lived host configuration.
public struct StaticProviderCredentialResolver: ProviderCredentialResolving, Sendable {
    private let credentials: [String: String]
    private let defaultCredential: String?

    public init(credentials: [String: String]) {
        self.credentials = credentials
        self.defaultCredential = nil
    }

    public init(credential: String) {
        self.credentials = [:]
        self.defaultCredential = credential
    }

    public func credential(for providerIdentifier: String) async throws -> String {
        let value = credentials[providerIdentifier] ?? defaultCredential
        guard let value else {
            throw ProviderCredentialError.missing(
                providerIdentifier: providerIdentifier,
                namespace: "in-memory",
                account: providerIdentifier
            )
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderCredentialError.empty(
                providerIdentifier: providerIdentifier,
                namespace: "in-memory",
                account: providerIdentifier
            )
        }
        return trimmed
    }
}
