import Foundation
import Security

/// Keychain accessibility choices supported by ``KeychainAgentSecretStore``.
public enum AgentKeychainAccessibility: String, Sendable, Codable, Hashable {
    case whenUnlocked
    case afterFirstUnlock
    case whenUnlockedThisDeviceOnly
    case afterFirstUnlockThisDeviceOnly
    case whenPasscodeSetThisDeviceOnly

    fileprivate var securityValue: CFString {
        switch self {
        case .whenUnlocked:
            kSecAttrAccessibleWhenUnlocked
        case .afterFirstUnlock:
            kSecAttrAccessibleAfterFirstUnlock
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenPasscodeSetThisDeviceOnly:
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        }
    }
}

public enum KeychainAgentSecretStoreError: LocalizedError, Sendable, Equatable {
    case invalidNamespace
    case invalidAccount
    case invalidUTF8
    case unexpectedItemType
    case keychain(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidNamespace:
            "The secret namespace must not be empty."
        case .invalidAccount:
            "The secret account must not be empty."
        case .invalidUTF8:
            "The stored secret is not valid UTF-8."
        case .unexpectedItemType:
            "The Keychain returned an unexpected item type."
        case .keychain(let operation, let status):
            "Keychain \(operation) failed with status \(status)."
        }
    }
}

/// A narrow, injectable boundary around the Security framework.
///
/// Applications normally use ``SystemAgentKeychainClient``. Tests can supply an
/// in-memory implementation without touching the user's Keychain.
public protocol AgentKeychainClient: Sendable {
    func load(service: String, account: String, accessGroup: String?) async throws -> Data?
    func save(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        accessibility: AgentKeychainAccessibility
    ) async throws
    func delete(service: String, account: String, accessGroup: String?) async throws
}

public struct SystemAgentKeychainClient: AgentKeychainClient, Sendable {
    private let usesDataProtectionKeychain: Bool

    /// On iOS-family platforms the Data Protection Keychain is native. On macOS,
    /// it requires Keychain Sharing entitlements and a provisioning profile, so
    /// the default remains the login Keychain for broadly distributable apps.
    public init(usesDataProtectionKeychain: Bool? = nil) {
#if os(macOS)
        self.usesDataProtectionKeychain = usesDataProtectionKeychain ?? false
#else
        self.usesDataProtectionKeychain = usesDataProtectionKeychain ?? true
#endif
    }

    public func load(service: String, account: String, accessGroup: String?) async throws -> Data? {
        var query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainAgentSecretStoreError.unexpectedItemType
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainAgentSecretStoreError.keychain(operation: "read", status: status)
        }
    }

    public func save(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        accessibility: AgentKeychainAccessibility
    ) async throws {
        let query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.securityValue,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item.merge(update) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // Another process may have inserted the item after our update.
                let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainAgentSecretStoreError.keychain(
                        operation: "write",
                        status: retryStatus
                    )
                }
            } else if addStatus != errSecSuccess {
                throw KeychainAgentSecretStoreError.keychain(operation: "write", status: addStatus)
            }
        default:
            throw KeychainAgentSecretStoreError.keychain(operation: "write", status: updateStatus)
        }
    }

    public func delete(service: String, account: String, accessGroup: String?) async throws {
        let status = SecItemDelete(
            baseQuery(service: service, account: account, accessGroup: accessGroup) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAgentSecretStoreError.keychain(operation: "delete", status: status)
        }
    }

    private func baseQuery(
        service: String,
        account: String,
        accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        if usesDataProtectionKeychain || accessGroup != nil {
            query[kSecUseDataProtectionKeychain as String] = true
        }
#endif
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

/// An actor-isolated ``AgentSecretStore`` backed by generic-password Keychain items.
///
/// Secret values are never included in errors or logs. `namespace` maps to the
/// Keychain service (optionally prefixed), and `account` maps to the Keychain account.
public actor KeychainAgentSecretStore: AgentSecretStore {
    public struct Configuration: Sendable, Hashable {
        public var accessGroup: String?
        public var accessibility: AgentKeychainAccessibility
        public var servicePrefix: String?

        public init(
            accessGroup: String? = nil,
            accessibility: AgentKeychainAccessibility = .afterFirstUnlockThisDeviceOnly,
            servicePrefix: String? = nil
        ) {
            self.accessGroup = accessGroup
            self.accessibility = accessibility
            self.servicePrefix = servicePrefix
        }
    }

    private let configuration: Configuration
    private let client: any AgentKeychainClient

    public init(
        configuration: Configuration = Configuration(),
        client: any AgentKeychainClient = SystemAgentKeychainClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    public func loadSecret(namespace: String, account: String) async throws -> String? {
        try validate(namespace: namespace, account: account)
        try Task.checkCancellation()
        guard let data = try await client.load(
            service: service(for: namespace),
            account: account,
            accessGroup: configuration.accessGroup
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainAgentSecretStoreError.invalidUTF8
        }
        return value
    }

    public func saveSecret(_ value: String, namespace: String, account: String) async throws {
        try validate(namespace: namespace, account: account)
        try Task.checkCancellation()
        try await client.save(
            Data(value.utf8),
            service: service(for: namespace),
            account: account,
            accessGroup: configuration.accessGroup,
            accessibility: configuration.accessibility
        )
    }

    public func deleteSecret(namespace: String, account: String) async throws {
        try validate(namespace: namespace, account: account)
        try Task.checkCancellation()
        try await client.delete(
            service: service(for: namespace),
            account: account,
            accessGroup: configuration.accessGroup
        )
    }

    private func service(for namespace: String) -> String {
        guard let prefix = configuration.servicePrefix, !prefix.isEmpty else { return namespace }
        return "\(prefix).\(namespace)"
    }

    private func validate(namespace: String, account: String) throws {
        guard !namespace.isEmpty else { throw KeychainAgentSecretStoreError.invalidNamespace }
        guard !account.isEmpty else { throw KeychainAgentSecretStoreError.invalidAccount }
    }
}

/// A discoverable Apple-prefixed spelling for hosts that group platform adapters by name.
public typealias AppleKeychainSecretStore = KeychainAgentSecretStore
