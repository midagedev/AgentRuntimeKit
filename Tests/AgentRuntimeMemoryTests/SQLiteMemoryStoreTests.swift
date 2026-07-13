import Foundation
import XCTest
@testable import AgentRuntimeMemory

final class SQLiteMemoryStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testMigrationsConfigureWALAndBusyTimeout() async throws {
        let store = try makeStore(busyTimeout: 1_234)
        let diagnostics = try await store.diagnostics()

        XCTAssertEqual(diagnostics.schemaVersion, 5)
        XCTAssertEqual(diagnostics.journalMode.lowercased(), "wal")
        XCTAssertEqual(diagnostics.busyTimeoutMilliseconds, 1_234)
        XCTAssertTrue(diagnostics.fullTextSearchAvailable)
        XCTAssertTrue(diagnostics.appendOnlyEventGuardsInstalled)
        let databaseURL = await store.databaseURL
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o077, 0)
    }

    func testStoreRejectsMissingProvenanceBeforePersistence() async throws {
        let store = try makeStore()
        var invalid = proposal(
            scope: .user(appID: "app", userID: "user"),
            content: "unattributed fact"
        )
        invalid.provenance.source = ""

        do {
            _ = try await store.upsert(invalid)
            XCTFail("Missing provenance must be rejected by the store boundary")
        } catch let error as MemoryStoreError {
            guard case .invalidProposal(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("provenance"))
        }
        let result = try await store.retrieve(MemoryQuery(scopes: [invalid.scope]))
        XCTAssertTrue(result.hits.isEmpty)
    }

    func testExactScopesIsolateEveryNamespaceAndDedupeKey() async throws {
        let store = try makeStore()
        let scopes: [MemoryScope] = [
            .application(appID: "app-a"),
            .user(appID: "app-a", userID: "user-a"),
            .agent(appID: "app-a", agentID: "agent-a", userID: "user-a"),
            .workspace(
                appID: "app-a",
                workspaceID: "workspace-a",
                userID: "user-a",
                agentID: "agent-a"
            ),
            .session(
                appID: "app-a",
                sessionID: "session-a",
                userID: "user-a",
                agentID: "agent-a",
                workspaceID: "workspace-a"
            ),
        ]
        var records: [MemoryRecord] = []
        for (index, scope) in scopes.enumerated() {
            records.append(try await store.upsert(proposal(
                scope: scope,
                content: "scope marker \(index)",
                deduplicationKey: "same-logical-key"
            )))
        }

        XCTAssertEqual(Set(records.map(\.id)).count, scopes.count)
        for (index, scope) in scopes.enumerated() {
            let result = try await store.retrieve(MemoryQuery(
                scopes: [scope],
                characterBudget: 1_000
            ))
            XCTAssertEqual(result.records.map(\.id), [records[index].id])
        }

        let otherUser = MemoryScope.user(appID: "app-a", userID: "user-b")
        let crossScopeFetch = try await store.fetch(id: records[1].id, scope: otherUser)
        XCTAssertNil(crossScopeFetch)
        let crossScopeSearch = try await store.retrieve(MemoryQuery(scopes: [otherUser]))
        XCTAssertTrue(crossScopeSearch.hits.isEmpty)
    }

    func testTTLAndProvenanceRoundTripAtExpiryBoundary() async throws {
        let store = try makeStore()
        let scope = MemoryScope.user(appID: "app", userID: "user")
        let now = Date(timeIntervalSince1970: 2_000_000)
        let provenance = MemoryProvenance(
            source: "healthkit-ephemeral-summary",
            sourceID: "sample-42",
            actorID: "host",
            capturedAt: now.addingTimeInterval(-5),
            metadata: ["device": "watch"]
        )
        let record = try await store.upsert(MemoryProposal(
            scope: scope,
            kind: .observation,
            content: "Short-lived observation",
            sensitivity: .health,
            provenance: provenance,
            confidence: 0.9,
            importance: 0.7,
            timeToLive: 60
        ), at: now)

        XCTAssertEqual(record.provenance, provenance)
        XCTAssertEqual(record.expiresAt, now.addingTimeInterval(60))
        let beforeExpiry = try await store.fetch(
            id: record.id,
            scope: scope,
            at: now.addingTimeInterval(59.999)
        )
        XCTAssertEqual(beforeExpiry?.provenance, provenance)
        let atExpiry = try await store.fetch(
            id: record.id,
            scope: scope,
            at: now.addingTimeInterval(60)
        )
        XCTAssertNil(atExpiry)
        let explicitlyIncluded = try await store.fetch(
            id: record.id,
            scope: scope,
            includeExpired: true,
            at: now.addingTimeInterval(600)
        )
        XCTAssertEqual(explicitlyIncluded?.id, record.id)

        let hidden = try await store.retrieve(MemoryQuery(
            scopes: [scope],
            maximumSensitivity: .health,
            asOf: now.addingTimeInterval(60)
        ))
        XCTAssertTrue(hidden.hits.isEmpty)
        let included = try await store.retrieve(MemoryQuery(
            scopes: [scope],
            maximumSensitivity: .health,
            asOf: now.addingTimeInterval(60),
            includeExpired: true
        ))
        XCTAssertEqual(included.records.map(\.id), [record.id])
    }

    func testDedupeUpsertOptimisticRevisionAndContentFreeAudit() async throws {
        let store = try makeStore()
        let scope = MemoryScope.session(appID: "app", sessionID: "session")
        let secretPhrase = "private phrase that must not enter audit detail"
        let firstProposal = proposal(
            scope: scope,
            content: secretPhrase,
            deduplicationKey: "profile-name"
        )
        let first = try await store.upsert(firstProposal)
        for _ in 0..<25 {
            let duplicate = try await store.upsert(firstProposal, expectedRevision: 1)
            XCTAssertEqual(duplicate.id, first.id)
            XCTAssertEqual(duplicate.revision, 1)
        }

        var replacement = firstProposal
        replacement.content = "replacement value"
        let second = try await store.upsert(replacement, expectedRevision: 1)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.revision, 2)

        do {
            _ = try await store.update(
                id: first.id,
                scope: scope,
                patch: MemoryPatch(importance: 1),
                expectedRevision: 1
            )
            XCTFail("Expected a stale revision conflict")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .revisionConflict(id: first.id, expected: 1, actual: 2))
        }

        let third = try await store.update(
            id: first.id,
            scope: scope,
            patch: MemoryPatch(importance: 1),
            expectedRevision: 2
        )
        XCTAssertEqual(third.revision, 3)
        let events = try await store.events(scope: scope, recordID: first.id)
        XCTAssertEqual(events.first?.kind, .created)
        XCTAssertEqual(events.filter { $0.kind == .deduplicated }.count, 25)
        XCTAssertEqual(events.suffix(2).map(\.kind), [.updated, .updated])
        XCTAssertEqual(events.suffix(2).map(\.revision), [2, 3])

        let auditJSON = try JSONEncoder().encode(events)
        let auditText = String(decoding: auditJSON, as: UTF8.self)
        XCTAssertFalse(auditText.contains(secretPhrase))
        XCTAssertFalse(auditText.contains("replacement value"))
    }

    func testRetrievalRanksLexicallyAndFitsContextBudget() async throws {
        let store = try makeStore()
        let scope = MemoryScope.user(appID: "app", userID: "user")
        _ = try await store.upsert(proposal(
            scope: scope,
            content: "The orchid launch checklist is ready",
            importance: 0.9
        ))
        _ = try await store.upsert(proposal(
            scope: scope,
            content: "The launch schedule mentions an orchid review",
            importance: 0.6
        ))
        _ = try await store.upsert(proposal(
            scope: scope,
            content: "Unrelated grocery reminder",
            importance: 1
        ))

        let result = try await store.retrieve(MemoryQuery(
            scopes: [scope],
            text: "orchid launch",
            limit: 10,
            characterBudget: 2_000
        ))
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.records.allSatisfy {
            $0.content.localizedCaseInsensitiveContains("orchid")
        })
        XCTAssertTrue(result.mode == .fullText || result.mode == .lexical)

        let fitted = try await store.retrieve(MemoryQuery(
            scopes: [scope],
            text: "orchid launch",
            limit: 10,
            characterBudget: 8
        ))
        XCTAssertEqual(fitted.usedCharacterCount, 8)
        XCTAssertEqual(fitted.hits.count, 1)
        XCTAssertEqual(fitted.hits[0].contextText.count, 8)
        XCTAssertTrue(fitted.hits[0].isTruncated)
        XCTAssertTrue(fitted.exhaustedBudget)
    }

    func testMaximumIntegerRetrievalLimitDoesNotOverflowCandidateOverscan() async throws {
        let store = try makeStore()
        let scope = MemoryScope.user(appID: "app", userID: "user")
        let record = try await store.upsert(proposal(
            scope: scope,
            content: "bounded retrieval"
        ))

        let result = try await store.retrieve(MemoryQuery(
            scopes: [scope],
            limit: .max,
            characterBudget: 1_000
        ))

        XCTAssertEqual(result.records.map(\.id), [record.id])
    }

    func testRecordsAndEventsPersistAcrossReopen() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("memory.sqlite")
        let scope = MemoryScope.workspace(
            appID: "app",
            workspaceID: "workspace",
            userID: "user",
            agentID: "agent"
        )
        let firstStore = try SQLiteMemoryStore(url: databaseURL)
        let original = try await firstStore.upsert(proposal(
            scope: scope,
            content: "durable workspace fact"
        ))
        try await firstStore.close()

        let reopened = try SQLiteMemoryStore(url: databaseURL)
        let fetched = try await reopened.fetch(id: original.id, scope: scope)
        let loaded = try XCTUnwrap(fetched)
        XCTAssertEqual(loaded.id, original.id)
        XCTAssertEqual(loaded.scope, original.scope)
        XCTAssertEqual(loaded.content, original.content)
        XCTAssertEqual(loaded.provenance.source, original.provenance.source)
        XCTAssertEqual(loaded.provenance.sourceID, original.provenance.sourceID)
        XCTAssertEqual(loaded.provenance.metadata, original.provenance.metadata)
        XCTAssertEqual(
            loaded.provenance.capturedAt.timeIntervalSince1970,
            original.provenance.capturedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(loaded.revision, original.revision)
        XCTAssertEqual(loaded.status, original.status)
        let events = try await reopened.events(scope: scope, recordID: original.id)
        XCTAssertEqual(events.map(\.kind), [.created])
    }

    private func proposal(
        scope: MemoryScope,
        content: String,
        sensitivity: AgentDataSensitivity = .privateData,
        confidence: Double = 0.95,
        importance: Double = 0.5,
        deduplicationKey: String? = nil
    ) -> MemoryProposal {
        MemoryProposal(
            scope: scope,
            kind: .fact,
            content: content,
            sensitivity: sensitivity,
            provenance: MemoryProvenance(source: "unit-test", sourceID: UUID().uuidString),
            confidence: confidence,
            importance: importance,
            deduplicationKey: deduplicationKey
        )
    }

    private func makeStore(busyTimeout: Int = 5_000) throws -> SQLiteMemoryStore {
        let directory = try makeTemporaryDirectory()
        return try SQLiteMemoryStore(
            url: directory.appendingPathComponent("memory.sqlite"),
            busyTimeoutMilliseconds: busyTimeout
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }
}
