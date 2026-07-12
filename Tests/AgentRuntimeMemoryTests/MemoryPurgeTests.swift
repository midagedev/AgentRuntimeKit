import Foundation
import XCTest
import CAgentSQLite
@testable import AgentRuntimeMemory

final class MemoryPurgeTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testInMemoryRecordPurgeIsExactIdempotentAndReleasesDedupeIdentity() async throws {
        let store = InMemoryMemoryStore()
        let targetScope = MemoryScope.user(appID: "app", userID: "user-a")
        let otherScope = MemoryScope.user(appID: "app", userID: "user-b")
        let targetProposal = proposal(
            scope: targetScope,
            content: "target preference",
            deduplicationKey: "shared-preference"
        )
        let target = try await store.upsert(targetProposal)
        _ = try await store.upsert(targetProposal)
        let other = try await store.upsert(proposal(
            scope: otherScope,
            content: "other preference",
            deduplicationKey: "shared-preference"
        ))

        let wrongScope = try await store.purge(id: target.id, scope: otherScope)
        XCTAssertEqual(wrongScope, MemoryPurgeResult())
        let targetBeforePurge = try await store.fetch(id: target.id, scope: targetScope)
        XCTAssertNotNil(targetBeforePurge)

        let result = try await store.purge(id: target.id, scope: targetScope)
        XCTAssertEqual(result.recordsPurged, 1)
        XCTAssertEqual(result.eventsPurged, 2)
        XCTAssertEqual(result.fullTextEntriesPurged, 0)
        XCTAssertTrue(result.didPurgeAnything)

        let targetAfterPurge = try await store.fetch(id: target.id, scope: targetScope)
        XCTAssertNil(targetAfterPurge)
        let targetEvents = try await store.events(scope: targetScope, recordID: target.id)
        XCTAssertTrue(targetEvents.isEmpty)
        let preservedOther = try await store.fetch(id: other.id, scope: otherScope)
        XCTAssertEqual(preservedOther?.id, other.id)

        let retry = try await store.purge(id: target.id, scope: targetScope)
        XCTAssertEqual(retry, MemoryPurgeResult())
        let recreated = try await store.upsert(targetProposal)
        XCTAssertNotEqual(recreated.id, target.id)
        XCTAssertEqual(recreated.revision, 1)
    }

    func testInMemoryMultiScopePurgeDoesNotBroadenScopes() async throws {
        let store = InMemoryMemoryStore()
        let userA = MemoryScope.user(appID: "app", userID: "user-a")
        let sessionA = MemoryScope.session(
            appID: "app",
            sessionID: "session-a",
            userID: "user-a"
        )
        let userB = MemoryScope.user(appID: "app", userID: "user-b")
        let otherApp = MemoryScope.user(appID: "other-app", userID: "user-a")

        let targets = [
            try await store.upsert(proposal(scope: userA, content: "user a one", deduplicationKey: "one")),
            try await store.upsert(proposal(scope: userA, content: "user a two", deduplicationKey: "two")),
            try await store.upsert(proposal(scope: sessionA, content: "session a", deduplicationKey: "one")),
        ]
        let preserved = [
            try await store.upsert(proposal(scope: userB, content: "user b", deduplicationKey: "one")),
            try await store.upsert(proposal(scope: otherApp, content: "other app", deduplicationKey: "one")),
        ]

        let result = try await store.purge(scopes: [userA, sessionA, userA])
        XCTAssertEqual(result.recordsPurged, 3)
        XCTAssertEqual(result.eventsPurged, 3)

        for record in targets {
            let fetched = try await store.fetch(id: record.id, scope: record.scope)
            XCTAssertNil(fetched)
        }
        for record in preserved {
            let fetched = try await store.fetch(id: record.id, scope: record.scope)
            XCTAssertEqual(fetched?.id, record.id)
        }
    }

    func testSQLiteRecordPurgeRemovesRowsFTSAndBytesAcrossReopen() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("memory.sqlite")
        let targetScope = MemoryScope.user(appID: "app", userID: "user-a")
        let otherScope = MemoryScope.user(appID: "app", userID: "user-b")
        let sensitiveMarker = "purgeonlymarker7f933e4d"
        let sensitiveContent = "\(sensitiveMarker) private preference"
        let targetProposal = proposal(
            scope: targetScope,
            content: sensitiveContent,
            deduplicationKey: "profile-preference"
        )

        let store = try SQLiteMemoryStore(url: databaseURL)
        let diagnostics = try await store.diagnostics()
        XCTAssertTrue(diagnostics.secureDeleteEnabled)
        let target = try await store.upsert(targetProposal)
        _ = try await store.upsert(targetProposal)
        _ = try await store.update(
            id: target.id,
            scope: targetScope,
            patch: MemoryPatch(importance: 0.9),
            expectedRevision: 1
        )
        let other = try await store.upsert(proposal(
            scope: otherScope,
            content: "preserved neighboring preference",
            deduplicationKey: "profile-preference"
        ))

        let before = try await store.persistedArtifactCounts(recordID: target.id)
        XCTAssertEqual(before, SQLiteMemoryArtifactCounts(records: 1, events: 3, fullTextEntries: 1))
        let wrongScope = try await store.purge(id: target.id, scope: otherScope)
        XCTAssertEqual(wrongScope, MemoryPurgeResult())

        let result = try await store.purge(id: target.id, scope: targetScope)
        XCTAssertEqual(result.recordsPurged, 1)
        XCTAssertEqual(result.eventsPurged, 3)
        XCTAssertEqual(result.fullTextEntriesPurged, 1)
        let after = try await store.persistedArtifactCounts(recordID: target.id)
        XCTAssertEqual(after, SQLiteMemoryArtifactCounts(records: 0, events: 0, fullTextEntries: 0))
        let preservedArtifacts = try await store.persistedArtifactCounts(recordID: other.id)
        XCTAssertEqual(
            preservedArtifacts,
            SQLiteMemoryArtifactCounts(records: 1, events: 1, fullTextEntries: 1)
        )
        try assertArtifactsDoNotContain(sensitiveContent, databaseURL: databaseURL)
        try assertArtifactsDoNotContain(sensitiveMarker, databaseURL: databaseURL)
        try await store.close()

        let reopened = try SQLiteMemoryStore(url: databaseURL)
        let reopenedCounts = try await reopened.persistedArtifactCounts(recordID: target.id)
        XCTAssertEqual(
            reopenedCounts,
            SQLiteMemoryArtifactCounts(records: 0, events: 0, fullTextEntries: 0)
        )
        let purgedRecord = try await reopened.fetch(
            id: target.id,
            scope: targetScope,
            includeExpired: true
        )
        XCTAssertNil(purgedRecord)
        let purgedEvents = try await reopened.events(scope: targetScope, recordID: target.id)
        XCTAssertTrue(purgedEvents.isEmpty)
        let preservedRecord = try await reopened.fetch(id: other.id, scope: otherScope)
        XCTAssertEqual(preservedRecord?.content, "preserved neighboring preference")

        let recreated = try await reopened.upsert(targetProposal)
        XCTAssertNotEqual(recreated.id, target.id)
        XCTAssertEqual(recreated.revision, 1)
    }

    func testSQLiteMultiScopePurgeIsAtomicExactAndDurable() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("memory.sqlite")
        let userA = MemoryScope.user(appID: "app", userID: "user-a")
        let sessionA = MemoryScope.session(
            appID: "app",
            sessionID: "session-a",
            userID: "user-a"
        )
        let userB = MemoryScope.user(appID: "app", userID: "user-b")
        let sessionB = MemoryScope.session(
            appID: "app",
            sessionID: "session-a",
            userID: "user-b"
        )
        let store = try SQLiteMemoryStore(url: databaseURL)
        let targets = [
            try await store.upsert(proposal(scope: userA, content: "a one", deduplicationKey: "one")),
            try await store.upsert(proposal(scope: userA, content: "a two", deduplicationKey: "two")),
            try await store.upsert(proposal(scope: sessionA, content: "a session", deduplicationKey: "one")),
        ]
        let preserved = [
            try await store.upsert(proposal(scope: userB, content: "b user", deduplicationKey: "one")),
            try await store.upsert(proposal(scope: sessionB, content: "b session", deduplicationKey: "one")),
        ]

        let result = try await store.purge(scopes: [userA, sessionA, userA])
        XCTAssertEqual(result.recordsPurged, 3)
        XCTAssertEqual(result.eventsPurged, 3)
        XCTAssertEqual(result.fullTextEntriesPurged, 3)
        try await store.close()

        let reopened = try SQLiteMemoryStore(url: databaseURL)
        for record in targets {
            let counts = try await reopened.persistedArtifactCounts(recordID: record.id)
            XCTAssertEqual(
                counts,
                SQLiteMemoryArtifactCounts(records: 0, events: 0, fullTextEntries: 0)
            )
        }
        for record in preserved {
            let fetched = try await reopened.fetch(id: record.id, scope: record.scope)
            XCTAssertEqual(fetched?.id, record.id)
            let counts = try await reopened.persistedArtifactCounts(recordID: record.id)
            XCTAssertEqual(
                counts,
                SQLiteMemoryArtifactCounts(records: 1, events: 1, fullTextEntries: 1)
            )
        }
    }

    func testSQLiteScopePurgeValidatesEveryScopeBeforeMutating() async throws {
        let store = try SQLiteMemoryStore(
            url: try makeTemporaryDirectory().appendingPathComponent("memory.sqlite")
        )
        let valid = MemoryScope.user(appID: "app", userID: "user")
        let record = try await store.upsert(proposal(scope: valid, content: "must remain"))
        let invalid = MemoryScope(level: .user, appID: "app", userID: "   ")

        do {
            _ = try await store.purge(scopes: [valid, invalid])
            XCTFail("All scopes must validate before the transaction starts")
        } catch let error as MemoryStoreError {
            guard case .invalidScope = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let fetched = try await store.fetch(id: record.id, scope: valid)
        XCTAssertEqual(fetched?.id, record.id)
    }

    func testInMemoryOwnerAPIFindsPastSessionsButExcludesUnboundAndApplicationData() async throws {
        let store = InMemoryMemoryStore()
        let seeded = try await seedOwnerBoundary(in: store)

        let listed = try await store.recordsOwned(appID: "app", userID: "owner")
        XCTAssertEqual(Set(listed.map(\.id)), Set(seeded.owned.map(\.id)))
        XCTAssertTrue(listed.contains { $0.scope.sessionID == "old-session" })
        XCTAssertTrue(listed.contains { $0.status == .deleted })
        XCTAssertTrue(listed.contains { $0.isExpired(at: Date(timeIntervalSince1970: 1_000)) })

        let result = try await store.purgeOwned(appID: "app", userID: "owner")
        XCTAssertEqual(result.recordsPurged, seeded.owned.count)
        XCTAssertEqual(result.eventsPurged, seeded.owned.count)
        let after = try await store.recordsOwned(appID: "app", userID: "owner")
        XCTAssertTrue(after.isEmpty)
        for record in seeded.excluded {
            let fetched = try await store.fetch(
                id: record.id,
                scope: record.scope,
                includeExpired: true
            )
            XCTAssertEqual(fetched?.id, record.id)
        }
    }

    func testSQLiteOwnerPurgeIsBoundToExactAppAndUserAcrossReopen() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("memory.sqlite")
        let store = try SQLiteMemoryStore(url: databaseURL)
        let seeded = try await seedOwnerBoundary(in: store)

        let listed = try await store.recordsOwned(appID: "app", userID: "owner")
        XCTAssertEqual(Set(listed.map(\.id)), Set(seeded.owned.map(\.id)))
        let result = try await store.purgeOwned(appID: "app", userID: "owner")
        XCTAssertEqual(result.recordsPurged, seeded.owned.count)
        XCTAssertEqual(result.eventsPurged, seeded.owned.count)
        XCTAssertEqual(result.fullTextEntriesPurged, 3)
        try await store.close()

        let reopened = try SQLiteMemoryStore(url: databaseURL)
        let after = try await reopened.recordsOwned(appID: "app", userID: "owner")
        XCTAssertTrue(after.isEmpty)
        for record in seeded.owned {
            let counts = try await reopened.persistedArtifactCounts(recordID: record.id)
            XCTAssertEqual(
                counts,
                SQLiteMemoryArtifactCounts(records: 0, events: 0, fullTextEntries: 0)
            )
        }
        for record in seeded.excluded {
            let fetched = try await reopened.fetch(
                id: record.id,
                scope: record.scope,
                includeExpired: true
            )
            XCTAssertEqual(fetched?.id, record.id)
        }
    }

    func testSQLiteOwnerPurgeFailsClosedForUnknownScopeLevels() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("memory.sqlite")
        let ownerScope = MemoryScope.user(appID: "app", userID: "owner")
        let store = try SQLiteMemoryStore(url: databaseURL)
        let record = try await store.upsert(proposal(
            scope: ownerScope,
            content: "future scope must remain"
        ))
        try await store.close()

        try withSQLiteDatabase(at: databaseURL) { database in
            try executeSQLite(
                database,
                sql: "UPDATE memory_records SET scope_level = 'future-owner-scope' "
                    + "WHERE id = '\(record.id.uuidString)'"
            )
        }

        let reopened = try SQLiteMemoryStore(url: databaseURL)
        let listed = try await reopened.recordsOwned(appID: "app", userID: "owner")
        XCTAssertTrue(listed.isEmpty)
        let result = try await reopened.purgeOwned(appID: "app", userID: "owner")
        XCTAssertEqual(result, MemoryPurgeResult())
        let counts = try await reopened.persistedArtifactCounts(recordID: record.id)
        XCTAssertEqual(
            counts,
            SQLiteMemoryArtifactCounts(records: 1, events: 1, fullTextEntries: 1)
        )
    }

    func testSQLiteBusyCleanupIsTypedRetryableAndRestoresAppendOnlyGuard() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("memory.sqlite")
        let scope = MemoryScope.user(appID: "app", userID: "owner")
        let store = try SQLiteMemoryStore(
            url: databaseURL,
            busyTimeoutMilliseconds: 25
        )
        let target = try await store.upsert(proposal(
            scope: scope,
            content: "busy cleanup marker 5d4b"
        ))
        let neighborScope = MemoryScope.user(appID: "app", userID: "neighbor")
        let neighbor = try await store.upsert(proposal(
            scope: neighborScope,
            content: "neighbor remains"
        ))

        var reader: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                databaseURL.path,
                &reader,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let readerDatabase = try XCTUnwrap(reader)
        defer {
            _ = sqlite3_exec(readerDatabase, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(readerDatabase)
        }
        try executeSQLite(
            readerDatabase,
            sql: "BEGIN; SELECT COUNT(*) FROM memory_records;"
        )

        do {
            _ = try await store.purge(id: target.id, scope: scope)
            XCTFail("An active reader should prevent complete physical cleanup")
        } catch let error as MemoryPurgeCleanupError {
            XCTAssertEqual(error.committedResult.recordsPurged, 1)
            XCTAssertEqual(error.committedResult.eventsPurged, 1)
            XCTAssertTrue(
                error.stage == .databaseCompaction
                    || error.stage == .writeAheadLogTruncation
            )
        }

        let diagnosticsAfterCommit = try await store.diagnostics()
        XCTAssertTrue(diagnosticsAfterCommit.appendOnlyEventGuardsInstalled)
        XCTAssertTrue(diagnosticsAfterCommit.secureDeleteEnabled)
        try executeSQLite(readerDatabase, sql: "COMMIT")

        let retry = try await store.purge(id: target.id, scope: scope)
        XCTAssertEqual(retry, MemoryPurgeResult())
        let targetCounts = try await store.persistedArtifactCounts(recordID: target.id)
        XCTAssertEqual(
            targetCounts,
            SQLiteMemoryArtifactCounts(records: 0, events: 0, fullTextEntries: 0)
        )
        let preserved = try await store.fetch(id: neighbor.id, scope: neighborScope)
        XCTAssertEqual(preserved?.id, neighbor.id)
    }

    func testLegacyMemoryStoreConformerFailsClosedWithoutSourceChanges() async throws {
        let store: any MemoryStore = LegacyMemoryStore()
        let scope = MemoryScope.user(appID: "app", userID: "owner")

        do {
            _ = try await store.purge(id: UUID(), scope: scope)
            XCTFail("A legacy conformer must not silently claim to purge")
        } catch let error as MemoryStoreCapabilityError {
            XCTAssertEqual(error, .privacyPurgeUnavailable)
        }

        do {
            _ = try await store.recordsOwned(appID: "app", userID: "owner")
            XCTFail("A legacy conformer must not return an incomplete inventory")
        } catch let error as MemoryStoreCapabilityError {
            XCTAssertEqual(error, .privacyPurgeUnavailable)
        }
    }

    private func proposal(
        scope: MemoryScope,
        content: String,
        deduplicationKey: String = UUID().uuidString,
        timeToLive: TimeInterval? = nil
    ) -> MemoryProposal {
        MemoryProposal(
            scope: scope,
            kind: .preference,
            content: content,
            provenance: MemoryProvenance(
                source: "purge-test",
                sourceID: "stable-source",
                capturedAt: Date(timeIntervalSince1970: 10_000)
            ),
            confidence: 0.9,
            importance: 0.7,
            timeToLive: timeToLive,
            deduplicationKey: deduplicationKey
        )
    }

    private func seedOwnerBoundary(
        in store: some MemoryStore
    ) async throws -> (owned: [MemoryRecord], excluded: [MemoryRecord]) {
        let oldDate = Date(timeIntervalSince1970: 100)
        let owned = [
            try await store.upsert(proposal(
                scope: .user(appID: "app", userID: "owner"),
                content: "owned user"
            )),
            try await store.upsert(proposal(
                scope: .agent(appID: "app", agentID: "coach", userID: "owner"),
                content: "owned deleted agent"
            ), status: .deleted),
            try await store.upsert(proposal(
                scope: .workspace(
                    appID: "app",
                    workspaceID: "workspace",
                    userID: "owner",
                    agentID: "coach"
                ),
                content: "owned workspace"
            )),
            try await store.upsert(proposal(
                scope: .session(
                    appID: "app",
                    sessionID: "old-session",
                    userID: "owner",
                    agentID: "coach"
                ),
                content: "owned expired session",
                timeToLive: 1
            ), at: oldDate),
        ]
        let excluded = [
            try await store.upsert(proposal(
                scope: .application(appID: "app"),
                content: "application wide"
            )),
            try await store.upsert(proposal(
                scope: MemoryScope(
                    level: .application,
                    appID: "app",
                    userID: "owner"
                ),
                content: "application level remains excluded"
            )),
            try await store.upsert(proposal(
                scope: .session(appID: "app", sessionID: "unbound-session"),
                content: "unbound session"
            )),
            try await store.upsert(proposal(
                scope: .user(appID: "app", userID: "neighbor"),
                content: "neighbor user"
            )),
            try await store.upsert(proposal(
                scope: .user(appID: "other-app", userID: "owner"),
                content: "same user other app"
            )),
        ]
        return (owned, excluded)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeMemoryPurgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func withSQLiteDatabase<T>(
        at url: URL,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw SQLiteTestError.openFailed(result)
        }
        defer { sqlite3_close_v2(database) }
        return try operation(database)
    }

    private func executeSQLite(_ database: OpaquePointer, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let description = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw SQLiteTestError.executionFailed(result, description)
        }
    }

    private func assertArtifactsDoNotContain(
        _ text: String,
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let marker = Data(text.utf8)
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            XCTAssertNil(
                data.range(of: marker),
                "Purged content remained in \(url.lastPathComponent)"
            )
        }
    }
}

private enum SQLiteTestError: Error {
    case openFailed(Int32)
    case executionFailed(Int32, String)
}

/// Models a downstream conformer compiled before privacy-purge requirements
/// were added. The protocol extension must keep this declaration valid.
private actor LegacyMemoryStore: MemoryStore {
    func upsert(
        _ proposal: MemoryProposal,
        status: MemoryStatus,
        expectedRevision: Int?,
        at date: Date
    ) throws -> MemoryRecord {
        throw MemoryStoreError.database("unused")
    }

    func fetch(
        id: UUID,
        scope: MemoryScope,
        includeExpired: Bool,
        at date: Date
    ) throws -> MemoryRecord? {
        throw MemoryStoreError.database("unused")
    }

    func update(
        id: UUID,
        scope: MemoryScope,
        patch: MemoryPatch,
        expectedRevision: Int,
        at date: Date
    ) throws -> MemoryRecord {
        throw MemoryStoreError.database("unused")
    }

    func delete(
        id: UUID,
        scope: MemoryScope,
        expectedRevision: Int,
        at date: Date
    ) throws {
        throw MemoryStoreError.database("unused")
    }

    func retrieve(_ query: MemoryQuery) throws -> MemoryRetrievalResult {
        throw MemoryStoreError.database("unused")
    }

    func events(
        scope: MemoryScope,
        recordID: UUID?,
        limit: Int
    ) throws -> [MemoryEvent] {
        throw MemoryStoreError.database("unused")
    }
}
