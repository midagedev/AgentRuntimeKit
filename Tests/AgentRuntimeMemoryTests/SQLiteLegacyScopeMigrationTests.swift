import CAgentSQLite
import Foundation
import XCTest
@testable import AgentRuntimeMemory

final class SQLiteLegacyScopeMigrationTests: XCTestCase {
    func testV011DatabaseKeepsLegacyScopesExactlyReadableMutableAndErasable() async throws {
        let temporary = try LegacySQLiteTemporaryDirectory()
        let validScope = MemoryScope.user(
            appID: "legacy.app",
            userID: "valid-user"
        )
        let whitespaceScope = MemoryScope.user(
            appID: " legacy.app ",
            userID: " legacy-user "
        )
        let decomposedScope = MemoryScope.user(
            appID: "legacy.app",
            userID: "e\u{0301}"
        )
        let controlScope = MemoryScope.workspace(
            appID: "legacy.app",
            workspaceID: "work\u{0001}space",
            userID: "control-owner"
        )
        let canonicalAgentScope = MemoryScope.agent(
            appID: "legacy.app",
            agentID: "canonical-agent"
        )
        let emptyOptionalAlias = MemoryScope.agent(
            appID: canonicalAgentScope.appID,
            agentID: try XCTUnwrap(canonicalAgentScope.agentID),
            userID: ""
        )
        // 0.1.x accepted this value, then sqlite3_bind_text(..., -1)
        // persisted only the prefix before each NUL.
        let nulScope = MemoryScope.workspace(
            appID: "nul-app\0ignored-app-suffix",
            workspaceID: "nul-workspace\0ignored-workspace-suffix",
            userID: "nul-user\0ignored-user-suffix"
        )
        let nulAtStartScope = MemoryScope.user(
            appID: "\0lost-app",
            userID: "\0lost-user"
        )
        let validFixture = LegacyV011Record(scope: validScope, content: "legacy valid record")
        let whitespaceFixture = LegacyV011Record(
            scope: whitespaceScope,
            content: "legacy whitespace record"
        )
        let decomposedFixture = LegacyV011Record(
            scope: decomposedScope,
            content: "legacy decomposed record"
        )
        let controlFixture = LegacyV011Record(
            scope: controlScope,
            content: "legacy control record"
        )
        let canonicalAgentFixture = LegacyV011Record(
            scope: canonicalAgentScope,
            content: "canonical agent record"
        )
        let nulFixture = LegacyV011Record(scope: nulScope, content: "legacy NUL record")
        let nulAtStartFixture = LegacyV011Record(
            scope: nulAtStartScope,
            content: "legacy empty-prefix record"
        )
        let fixtures = [
            validFixture,
            whitespaceFixture,
            decomposedFixture,
            controlFixture,
            canonicalAgentFixture,
            nulFixture,
            nulAtStartFixture,
        ]
        try createV011Database(at: temporary.databaseURL, records: fixtures)

        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.schemaVersion, 5)

        let ordinaryAccessFixtures = [
            validFixture,
            whitespaceFixture,
            decomposedFixture,
            controlFixture,
            canonicalAgentFixture,
        ]
        for fixture in ordinaryAccessFixtures {
            let fetched = try await store.fetch(
                id: fixture.id,
                scope: fixture.scope,
                includeExpired: true
            )
            XCTAssertEqual(fetched?.content, fixture.content)
            let events = try await store.events(
                scope: fixture.scope,
                recordID: fixture.id
            )
            XCTAssertEqual(events.count, 1)
        }

        let retrieval = try await store.retrieve(MemoryQuery(
            scopes: ordinaryAccessFixtures.map(\.scope),
            text: "legacy",
            maximumSensitivity: .privateData,
            limit: 10,
            characterBudget: 10_000,
            includeExpired: true
        ))
        XCTAssertEqual(
            Set(retrieval.records.map(\.id)),
            Set(ordinaryAccessFixtures.dropLast().map(\.id))
        )

        await assertInvalidScope {
            _ = try await store.upsert(MemoryProposal(
                scope: nulScope,
                kind: .fact,
                content: "new writes must remain strict",
                provenance: MemoryProvenance(source: "migration-test")
            ))
        }

        let updatedControlRecord = try await store.update(
            id: controlFixture.id,
            scope: controlScope,
            patch: MemoryPatch(importance: 0.9),
            expectedRevision: 1
        )
        XCTAssertEqual(updatedControlRecord.revision, 2)
        XCTAssertEqual(updatedControlRecord.importance, 0.9)
        let controlEvents = try await store.events(
            scope: controlScope,
            recordID: controlFixture.id
        )
        XCTAssertEqual(controlEvents.count, 2)

        let ownedWhitespace = try await store.recordsOwned(
            appID: whitespaceScope.appID,
            userID: try XCTUnwrap(whitespaceScope.userID)
        )
        XCTAssertEqual(ownedWhitespace.map(\.id), [whitespaceFixture.id])

        // Standard APIs never reproduce v0.1's lossy C-string binding. A NUL
        // suffix or a present-empty optional cannot alias a legitimate prefix
        // namespace for reads, events, retrieval, or privacy deletion.
        await assertInvalidScope {
            _ = try await store.fetch(
                id: nulFixture.id,
                scope: nulScope,
                includeExpired: true
            )
        }
        await assertInvalidScope {
            _ = try await store.purge(id: nulFixture.id, scope: nulScope)
        }
        await assertInvalidScope {
            _ = try await store.update(
                id: nulFixture.id,
                scope: nulScope,
                patch: MemoryPatch(importance: 0.8),
                expectedRevision: 1
            )
        }
        await assertInvalidScope {
            _ = try await store.events(scope: nulScope, recordID: nulFixture.id)
        }
        await assertInvalidScope {
            _ = try await store.purge(scopes: [nulScope])
        }
        await assertInvalidScope {
            _ = try await store.retrieve(MemoryQuery(scopes: [nulScope]))
        }
        await assertInvalidScope {
            _ = try await store.recordsOwned(
                appID: nulScope.appID,
                userID: try XCTUnwrap(nulScope.userID)
            )
        }
        await assertInvalidScope {
            _ = try await store.purgeOwned(
                appID: nulScope.appID,
                userID: try XCTUnwrap(nulScope.userID)
            )
        }
        await assertInvalidScope {
            _ = try await store.fetch(
                id: canonicalAgentFixture.id,
                scope: emptyOptionalAlias,
                includeExpired: true
            )
        }
        await assertInvalidScope {
            _ = try await store.purge(
                id: canonicalAgentFixture.id,
                scope: emptyOptionalAlias
            )
        }
        await assertInvalidScope {
            _ = try await store.events(
                scope: emptyOptionalAlias,
                recordID: canonicalAgentFixture.id
            )
        }
        await assertInvalidScope {
            _ = try await store.retrieve(MemoryQuery(scopes: [emptyOptionalAlias]))
        }
        await assertInvalidScope {
            _ = try await store.purge(scopes: [emptyOptionalAlias])
        }

        let nulPersistedScope = legacyV011BoundScope(nulScope)
        let nulVictimAfterAliasAttempts = try await store.fetch(
            id: nulFixture.id,
            scope: nulPersistedScope,
            includeExpired: true
        )
        XCTAssertEqual(nulVictimAfterAliasAttempts?.content, nulFixture.content)
        let agentVictimAfterAliasAttempts = try await store.fetch(
            id: canonicalAgentFixture.id,
            scope: canonicalAgentScope,
            includeExpired: true
        )
        XCTAssertEqual(agentVictimAfterAliasAttempts?.content, canonicalAgentFixture.content)

        let inventory = try await store.legacyScopeInventory()
        let emptyPrefixSummary = try XCTUnwrap(inventory.first {
            $0.scope.level == .user
                && $0.scope.appID.isEmpty
                && $0.scope.userID == nil
        })
        XCTAssertEqual(emptyPrefixSummary.recordCount, 1)
        XCTAssertEqual(emptyPrefixSummary.eventCount, 1)
        await assertInvalidScope {
            _ = try await store.purgeLegacyPersistedScope(validScope)
        }
        let emptyPrefixPurge = try await store.purgeLegacyPersistedScope(
            emptyPrefixSummary.scope
        )
        XCTAssertEqual(emptyPrefixPurge.recordsPurged, 1)
        XCTAssertEqual(emptyPrefixPurge.eventsPurged, 1)

        let whitespacePurge = try await store.purgeOwned(
            appID: whitespaceScope.appID,
            userID: try XCTUnwrap(whitespaceScope.userID)
        )
        XCTAssertEqual(whitespacePurge.recordsPurged, 1)
        XCTAssertEqual(whitespacePurge.eventsPurged, 1)

        let decomposedPurge = try await store.purge(scopes: [decomposedScope])
        XCTAssertEqual(decomposedPurge.recordsPurged, 1)
        XCTAssertEqual(decomposedPurge.eventsPurged, 1)

        let controlPurge = try await store.purge(id: controlFixture.id, scope: controlScope)
        XCTAssertEqual(controlPurge.recordsPurged, 1)
        XCTAssertEqual(controlPurge.eventsPurged, 2)

        let purgedFixtures = [
            whitespaceFixture,
            decomposedFixture,
            controlFixture,
            nulAtStartFixture,
        ]
        for fixture in purgedFixtures {
            let artifacts = try await store.persistedArtifactCounts(recordID: fixture.id)
            XCTAssertEqual(
                artifacts,
                SQLiteMemoryArtifactCounts(records: 0, events: 0, fullTextEntries: 0)
            )
        }
        let surviving = try await store.fetch(
            id: validFixture.id,
            scope: validScope,
            includeExpired: true
        )
        XCTAssertEqual(surviving?.content, validFixture.content)

        try await store.close()
        let reopened = try SQLiteMemoryStore(url: temporary.databaseURL)
        let reopenedSurvivor = try await reopened.fetch(
            id: validFixture.id,
            scope: validScope,
            includeExpired: true
        )
        XCTAssertEqual(reopenedSurvivor?.content, validFixture.content)
        let reopenedNULVictim = try await reopened.fetch(
            id: nulFixture.id,
            scope: nulPersistedScope,
            includeExpired: true
        )
        XCTAssertEqual(reopenedNULVictim?.content, nulFixture.content)
        let reopenedAgentVictim = try await reopened.fetch(
            id: canonicalAgentFixture.id,
            scope: canonicalAgentScope,
            includeExpired: true
        )
        XCTAssertEqual(reopenedAgentVictim?.content, canonicalAgentFixture.content)
        for fixture in purgedFixtures {
            let artifacts = try await reopened.persistedArtifactCounts(recordID: fixture.id)
            XCTAssertEqual(
                artifacts,
                SQLiteMemoryArtifactCounts(records: 0, events: 0, fullTextEntries: 0)
            )
        }
    }

    private func assertInvalidScope(
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected an invalid-scope failure", file: file, line: line)
        } catch let error as MemoryStoreError {
            guard case .invalidScope = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private struct LegacyV011Record {
    let id = UUID()
    let scope: MemoryScope
    let content: String
    let deduplicationKey = UUID().uuidString
}

private enum LegacySQLiteFixtureError: Error {
    case open(Int32)
    case execute(Int32, String)
    case prepare(Int32)
    case bind(Int32)
    case step(Int32)
}

private enum LegacySQLiteBinding {
    case text(String)
    case integer(Int64)
    case double(Double)
    case blob(Data)
    case null
}

private final class LegacySQLiteTemporaryDirectory {
    let url: URL
    var databaseURL: URL { url.appendingPathComponent("memory-v0.1.1.sqlite") }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentRuntimeLegacySQLiteTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Creates the schema emitted by AgentRuntimeKit v0.1.1 after migration 2.
private func createV011Database(
    at url: URL,
    records: [LegacyV011Record]
) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw LegacySQLiteFixtureError.open(openResult)
    }
    defer { sqlite3_close_v2(database) }

    try executeLegacySQL(database, sql: """
        PRAGMA foreign_keys = ON;
        CREATE TABLE memory_records (
            id TEXT PRIMARY KEY NOT NULL,
            scope_level TEXT NOT NULL,
            app_id TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT '',
            agent_id TEXT NOT NULL DEFAULT '',
            workspace_id TEXT NOT NULL DEFAULT '',
            session_id TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL,
            content TEXT NOT NULL,
            sensitivity TEXT NOT NULL,
            sensitivity_rank INTEGER NOT NULL,
            provenance_json BLOB NOT NULL,
            confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
            importance REAL NOT NULL CHECK(importance >= 0 AND importance <= 1),
            expires_at REAL,
            revision INTEGER NOT NULL CHECK(revision > 0),
            status TEXT NOT NULL,
            deduplication_key TEXT NOT NULL,
            metadata_json BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            deduplication_key_origin TEXT NOT NULL DEFAULT 'legacyUnknown',
            UNIQUE(
                scope_level, app_id, user_id, agent_id,
                workspace_id, session_id, deduplication_key
            )
        );
        CREATE INDEX memory_records_scope_lookup
        ON memory_records(
            scope_level, app_id, user_id, agent_id,
            workspace_id, session_id, status, updated_at DESC
        );
        CREATE INDEX memory_records_expiry
        ON memory_records(expires_at) WHERE expires_at IS NOT NULL;
        CREATE TABLE memory_events (
            event_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT UNIQUE NOT NULL,
            record_id TEXT NOT NULL REFERENCES memory_records(id),
            scope_level TEXT NOT NULL,
            app_id TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT '',
            agent_id TEXT NOT NULL DEFAULT '',
            workspace_id TEXT NOT NULL DEFAULT '',
            session_id TEXT NOT NULL DEFAULT '',
            event_kind TEXT NOT NULL,
            event_at REAL NOT NULL,
            previous_revision INTEGER,
            revision INTEGER NOT NULL,
            detail_json BLOB NOT NULL
        );
        CREATE INDEX memory_events_scope_lookup
        ON memory_events(
            scope_level, app_id, user_id, agent_id,
            workspace_id, session_id, event_sequence
        );
        CREATE TRIGGER memory_events_are_append_only_on_update
        BEFORE UPDATE ON memory_events
        BEGIN
            SELECT RAISE(ABORT, 'memory events are append-only');
        END;
        CREATE TRIGGER memory_events_are_append_only_on_delete
        BEFORE DELETE ON memory_events
        BEGIN
            SELECT RAISE(ABORT, 'memory events are append-only');
        END;
        CREATE VIRTUAL TABLE memory_records_fts
        USING fts5(
            record_id UNINDEXED,
            content,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        PRAGMA user_version = 2;
        """)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    for fixture in records {
        let storedScope = legacyV011BoundScope(fixture.scope)
        let provenance = try encoder.encode(MemoryProvenance(
            source: "legacy-v0.1.1-fixture",
            sourceID: fixture.id.uuidString,
            capturedAt: timestamp
        ))
        let metadata = try encoder.encode([String: JSONValue]())
        let detail = try encoder.encode([
            "kind": JSONValue.string(MemoryKind.fact.rawValue),
            "sensitivity": JSONValue.string(AgentDataSensitivity.privateData.rawValue),
            "status": JSONValue.string(MemoryStatus.active.rawValue),
        ])

        try executeLegacyPrepared(
            database,
            sql: """
                INSERT INTO memory_records (
                    id, scope_level, app_id, user_id, agent_id, workspace_id,
                    session_id, kind, content, sensitivity, sensitivity_rank,
                    provenance_json, confidence, importance, expires_at, revision,
                    status, deduplication_key, metadata_json, created_at, updated_at,
                    deduplication_key_origin
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            bindings: [
                .text(fixture.id.uuidString),
                .text(storedScope.level.rawValue),
                .text(storedScope.appID),
                .text(storedScope.userID ?? ""),
                .text(storedScope.agentID ?? ""),
                .text(storedScope.workspaceID ?? ""),
                .text(storedScope.sessionID ?? ""),
                .text(MemoryKind.fact.rawValue),
                .text(fixture.content),
                .text(AgentDataSensitivity.privateData.rawValue),
                .integer(1),
                .blob(provenance),
                .double(1),
                .double(0.5),
                .null,
                .integer(1),
                .text(MemoryStatus.active.rawValue),
                .text(fixture.deduplicationKey),
                .blob(metadata),
                .double(timestamp.timeIntervalSince1970),
                .double(timestamp.timeIntervalSince1970),
                .text(MemoryDeduplicationKeyOrigin.explicit.rawValue),
            ]
        )
        try executeLegacyPrepared(
            database,
            sql: """
                INSERT INTO memory_events (
                    id, record_id, scope_level, app_id, user_id, agent_id,
                    workspace_id, session_id, event_kind, event_at,
                    previous_revision, revision, detail_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            bindings: [
                .text(UUID().uuidString),
                .text(fixture.id.uuidString),
                .text(storedScope.level.rawValue),
                .text(storedScope.appID),
                .text(storedScope.userID ?? ""),
                .text(storedScope.agentID ?? ""),
                .text(storedScope.workspaceID ?? ""),
                .text(storedScope.sessionID ?? ""),
                .text(MemoryEventKind.created.rawValue),
                .double(timestamp.timeIntervalSince1970),
                .null,
                .integer(1),
                .blob(detail),
            ]
        )
        try executeLegacyPrepared(
            database,
            sql: "INSERT INTO memory_records_fts(record_id, content) VALUES (?, ?)",
            bindings: [.text(fixture.id.uuidString), .text(fixture.content)]
        )
    }
}

private func legacyV011BoundScope(_ scope: MemoryScope) -> MemoryScope {
    func prefixBeforeNUL(_ value: String?) -> String? {
        guard let value,
              let nulIndex = value.utf8.firstIndex(of: 0)
        else { return value }
        return String(decoding: value.utf8[..<nulIndex], as: UTF8.self)
    }
    return MemoryScope(
        level: scope.level,
        appID: prefixBeforeNUL(scope.appID) ?? "",
        userID: prefixBeforeNUL(scope.userID),
        agentID: prefixBeforeNUL(scope.agentID),
        workspaceID: prefixBeforeNUL(scope.workspaceID),
        sessionID: prefixBeforeNUL(scope.sessionID)
    )
}

private func executeLegacySQL(_ database: OpaquePointer, sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    let description = message.map { String(cString: $0) } ?? "unknown SQLite error"
    sqlite3_free(message)
    guard result == SQLITE_OK else {
        throw LegacySQLiteFixtureError.execute(result, description)
    }
}

private func executeLegacyPrepared(
    _ database: OpaquePointer,
    sql: String,
    bindings: [LegacySQLiteBinding]
) throws {
    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
        throw LegacySQLiteFixtureError.prepare(prepareResult)
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, binding) in bindings.enumerated() {
        let index = Int32(offset + 1)
        let result: Int32
        switch binding {
        case .text(let value):
            result = value.withCString {
                sqlite3_bind_text(statement, index, $0, -1, transient)
            }
        case .integer(let value):
            result = sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            result = sqlite3_bind_double(statement, index, value)
        case .blob(let value):
            result = value.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
            }
        case .null:
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw LegacySQLiteFixtureError.bind(result)
        }
    }
    let stepResult = sqlite3_step(statement)
    guard stepResult == SQLITE_DONE else {
        throw LegacySQLiteFixtureError.step(stepResult)
    }
}
