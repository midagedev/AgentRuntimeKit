import AgentRuntimeApple
import XCTest

final class AgentRuntimeAppleTests: XCTestCase {
    func testKeychainStoreForwardsIsolationConfigurationAndRoundTripsUTF8() async throws {
        let client = MockKeychainClient()
        let store = KeychainAgentSecretStore(
            configuration: .init(
                accessGroup: "group.example.shared",
                accessibility: .whenUnlockedThisDeviceOnly,
                servicePrefix: "com.example.agent"
            ),
            client: client
        )

        try await store.saveSecret("sensitive-value", namespace: "provider", account: "primary")
        let loaded = try await store.loadSecret(namespace: "provider", account: "primary")
        try await store.deleteSecret(namespace: "provider", account: "primary")

        XCTAssertEqual(loaded, "sensitive-value")
        let operations = await client.operations
        XCTAssertEqual(operations.count, 3)
        XCTAssertEqual(operations[0].service, "com.example.agent.provider")
        XCTAssertEqual(operations[0].account, "primary")
        XCTAssertEqual(operations[0].accessGroup, "group.example.shared")
        XCTAssertEqual(operations[0].accessibility, .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(String(data: operations[0].data!, encoding: .utf8), "sensitive-value")
    }

    func testKeychainStoreRejectsEmptyIdentifiersBeforeCallingClient() async throws {
        let client = MockKeychainClient()
        let store = KeychainAgentSecretStore(client: client)

        do {
            try await store.saveSecret("never-forwarded", namespace: "", account: "account")
            XCTFail("Expected an invalid namespace error")
        } catch let error as KeychainAgentSecretStoreError {
            XCTAssertEqual(error, .invalidNamespace)
        }
        let operationCount = await client.operations.count
        XCTAssertEqual(operationCount, 0)
    }

    func testKeychainStoreRejectsNonUTF8DataWithoutIncludingItInError() async throws {
        let client = MockKeychainClient(initialData: Data([0xFF, 0xFE]))
        let store = KeychainAgentSecretStore(client: client)

        do {
            _ = try await store.loadSecret(namespace: "provider", account: "primary")
            XCTFail("Expected invalid UTF-8")
        } catch let error as KeychainAgentSecretStoreError {
            XCTAssertEqual(error, .invalidUTF8)
            XCTAssertFalse(error.localizedDescription.contains("FF"))
        }
    }

    func testProtectedCheckpointStoreSavesLoadsFindsLatestAndDeletes() async throws {
        let temporary = try TemporaryDirectory()
        let directory = temporary.url.appendingPathComponent("checkpoints", isDirectory: true)
        let store = ProtectedFileAgentCheckpointStore(
            configuration: .init(directory: directory, protection: .complete)
        )
        let older = makeCheckpoint(createdAt: Date(timeIntervalSince1970: 10))
        let newer = makeCheckpoint(createdAt: Date(timeIntervalSince1970: 20))
        let unrelated = makeCheckpoint(
            sessionID: "other-session",
            createdAt: Date(timeIntervalSince1970: 30)
        )

        try await store.save(older)
        try await store.save(newer)
        try await store.save(unrelated)

        let loaded = try await store.load(id: older.id)
        let latest = try await store.latest(
            appID: "app",
            userID: nil,
            sessionID: "session",
            agentID: "agent"
        )
        XCTAssertEqual(loaded, older)
        XCTAssertEqual(latest, newer)

        let checkpointURL = directory
            .appendingPathComponent(older.id.uuidString.lowercased())
            .appendingPathExtension("json")
        let attributes = try FileManager.default.attributesOfItem(atPath: checkpointURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try await store.delete(id: older.id)
        let deleted = try await store.load(id: older.id)
        XCTAssertNil(deleted)
        try await store.delete(id: older.id) // idempotent

        try await store.deleteAll(
            appID: "app",
            userID: nil,
            sessionID: "session",
            agentID: "agent"
        )
        let deletedNewest = try await store.load(id: newer.id)
        let preservedUnrelated = try await store.load(id: unrelated.id)
        XCTAssertNil(deletedNewest)
        XCTAssertEqual(preservedUnrelated, unrelated)
    }

    func testJSONLAuditSinkRedactsNestedCredentialsAndAppendsRecords() async throws {
        let temporary = try TemporaryDirectory()
        let file = temporary.url.appendingPathComponent("audit/events.jsonl")
        let sink = RedactedJSONLAgentAuditSink(
            configuration: .init(fileURL: file, protection: .complete, synchronizeAfterWrite: true)
        )
        let secret = "must-not-reach-disk"
        let first = AgentAuditRecord(
            kind: .providerRequest,
            runID: UUID(),
            sessionID: "session",
            agentID: "agent",
            detail: [
                "api_key": .string(secret),
                "nested": .object([
                    "Authorization": .string("Bearer abc123"),
                    "safe": .string("visible"),
                ]),
                "authorizationValue": .string("Basic Zm9vOmJhcg=="),
            ]
        )
        let second = AgentAuditRecord(
            kind: .runCompleted,
            runID: first.runID,
            sessionID: "session",
            agentID: "agent",
            detail: ["steps": .number(2)]
        )

        await sink.record(first)
        await sink.record(second)

        let data = try Data(contentsOf: file)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("abc123"))
        XCTAssertFalse(text.contains("Zm9vOmJhcg"))
        XCTAssertTrue(text.contains("visible"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        let droppedRecordCount = await sink.droppedRecordCount
        XCTAssertEqual(droppedRecordCount, 0)

        let firstLine = try XCTUnwrap(text.split(separator: "\n").first)
        let decoded = try JSONDecoder().decode(
            AgentAuditRecord.self,
            from: Data(firstLine.utf8)
        )
        XCTAssertEqual(decoded.detail["api_key"], .string("[REDACTED]"))
        XCTAssertEqual(decoded.detail["nested"]?["safe"], .string("visible"))

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testProtectedSQLiteFactorySecuresDatabaseWALAndSHMSidecars() async throws {
        let temporary = try TemporaryDirectory()
        let databaseURL = temporary.url
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("agent.sqlite")
        let store = try AppleProtectedMemoryStoreFactory.makeSQLiteStore(
            configuration: .init(databaseURL: databaseURL, protection: .complete)
        )
        let scope = MemoryScope.user(appID: "app", userID: "user")
        _ = try await store.upsert(MemoryProposal(
            scope: scope,
            kind: .fact,
            content: "Protected memory",
            provenance: MemoryProvenance(source: "apple-protection-test")
        ))
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.schemaVersion, 2)

        let artifacts = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        for artifact in artifacts {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: artifact.path),
                "Expected SQLite artifact at \(artifact.lastPathComponent)"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o077, 0)
        }
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: databaseURL.deletingLastPathComponent().path
        )
        let directoryPermissions = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.intValue & 0o077, 0)
    }

    func testProtectedSQLiteFactoryRejectsSymbolicLinkBeforeOpeningDatabase() throws {
        let temporary = try TemporaryDirectory()
        let directory = temporary.url.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = temporary.url.appendingPathComponent("outside.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data()))
        let databaseURL = directory.appendingPathComponent("agent.sqlite")
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: outside)

        XCTAssertThrowsError(try AppleProtectedMemoryStoreFactory.makeSQLiteStore(
            configuration: .init(databaseURL: databaseURL)
        )) { error in
            XCTAssertEqual(error as? ProtectedAgentFileStoreError, .symbolicLinkNotAllowed)
        }
    }

    private func makeCheckpoint(
        sessionID: String = "session",
        createdAt: Date
    ) -> AgentRunCheckpoint {
        AgentRunCheckpoint(
            runID: UUID(),
            sessionID: sessionID,
            appID: "app",
            agentID: "agent",
            providerID: "provider",
            model: "model",
            messages: [AgentMessage(role: .assistant, text: "saved")],
            stepCount: 1,
            toolCallCount: 0,
            usage: AgentTokenUsage(inputTokens: 2, outputTokens: 1),
            createdAt: createdAt
        )
    }
}

private actor MockKeychainClient: AgentKeychainClient {
    enum Kind: Sendable { case load, save, delete }

    struct Operation: Sendable {
        var kind: Kind
        var data: Data?
        var service: String
        var account: String
        var accessGroup: String?
        var accessibility: AgentKeychainAccessibility?
    }

    private var storedData: Data?
    private(set) var operations: [Operation] = []

    init(initialData: Data? = nil) {
        storedData = initialData
    }

    func load(service: String, account: String, accessGroup: String?) async throws -> Data? {
        operations.append(Operation(
            kind: .load,
            data: nil,
            service: service,
            account: account,
            accessGroup: accessGroup,
            accessibility: nil
        ))
        return storedData
    }

    func save(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        accessibility: AgentKeychainAccessibility
    ) async throws {
        storedData = data
        operations.append(Operation(
            kind: .save,
            data: data,
            service: service,
            account: account,
            accessGroup: accessGroup,
            accessibility: accessibility
        ))
    }

    func delete(service: String, account: String, accessGroup: String?) async throws {
        storedData = nil
        operations.append(Operation(
            kind: .delete,
            data: nil,
            service: service,
            account: account,
            accessGroup: accessGroup,
            accessibility: nil
        ))
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeAppleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
