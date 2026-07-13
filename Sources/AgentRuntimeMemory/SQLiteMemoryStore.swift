import Foundation
import CAgentSQLite

public struct SQLiteMemoryStoreDiagnostics: Sendable, Hashable {
    public var schemaVersion: Int
    public var journalMode: String
    public var busyTimeoutMilliseconds: Int
    public var fullTextSearchAvailable: Bool
    public var appendOnlyEventGuardsInstalled: Bool
    public var secureDeleteEnabled: Bool
}

/// One non-canonical scope found in a pre-0.2 SQLite database.
///
/// AgentRuntimeKit 0.2 rejects these identities for new writes. This summary is
/// exposed only for an explicit host migration or privacy-erasure flow; it does
/// not broaden ordinary retrieval. Counts contain no memory content.
public struct SQLiteLegacyScopeSummary: Sendable, Codable, Hashable {
    public let scope: MemoryScope
    public let recordCount: Int
    public let eventCount: Int

    public init(scope: MemoryScope, recordCount: Int, eventCount: Int) {
        self.scope = scope
        self.recordCount = recordCount
        self.eventCount = eventCount
    }
}

struct SQLiteMemoryArtifactCounts: Sendable, Equatable {
    var records: Int
    var events: Int
    var fullTextEntries: Int
}

/// Durable, process-safe memory storage. One actor serializes access through a
/// full-mutex SQLite connection while WAL and a busy timeout coordinate other
/// processes opening the same database.
public actor SQLiteMemoryStore: MemoryStore, MemorySourceReconciliationStore {
    private final class Connection: @unchecked Sendable {
        var pointer: OpaquePointer?

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }

        deinit {
            if let pointer { sqlite3_close_v2(pointer) }
        }
    }

    private enum Binding {
        case text(String)
        case integer(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    private static let currentSchemaVersion = 5
    private static let exactScopePredicate = """
        scope_level = ? AND app_id = ? AND user_id = ?
        AND agent_id = ? AND workspace_id = ? AND session_id = ?
        """
    private static let ownedPredicate = """
        scope_level IN (?, ?, ?, ?) AND app_id = ? AND user_id = ?
        """
    private static let sourceIdentityPredicate = """
        source_identifier = ? AND source_scope_level = ? AND source_app_id = ?
        AND source_user_id = ? AND source_agent_id = ?
        AND source_workspace_id = ? AND source_session_id = ?
        """
    private static let createEventDeleteGuardSQL = """
        CREATE TRIGGER memory_events_are_append_only_on_delete
        BEFORE DELETE ON memory_events
        BEGIN
            SELECT RAISE(ABORT, 'memory events are append-only');
        END
        """
    private static let createFullTextSearchSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_records_fts
        USING fts5(
            record_id UNINDEXED,
            content,
            tokenize = 'unicode61 remove_diacritics 2'
        )
        """

    public let databaseURL: URL
    private let connection: Connection
    private var fullTextSearchAvailable: Bool

    public init(
        url: URL,
        busyTimeoutMilliseconds: Int = 5_000
    ) throws {
        guard busyTimeoutMilliseconds >= 0 else {
            throw MemoryStoreError.database("busy timeout must not be negative")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "could not allocate a SQLite connection"
            if let handle { sqlite3_close_v2(handle) }
            throw MemoryStoreError.database(message)
        }

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )

        do {
            guard sqlite3_busy_timeout(handle, Int32(busyTimeoutMilliseconds)) == SQLITE_OK else {
                throw Self.error(from: handle)
            }
            try Self.execute(handle, sql: "PRAGMA foreign_keys = ON")
            // Hard-purge is a privacy boundary, so deleted cells must be
            // overwritten rather than merely added to SQLite's freelist.
            try Self.execute(handle, sql: "PRAGMA secure_delete = ON")
            try Self.execute(handle, sql: "PRAGMA journal_mode = WAL")
            try Self.execute(handle, sql: "PRAGMA synchronous = NORMAL")
            try Self.migrate(handle)
            let fts = Self.configureFullTextSearch(handle)
            self.databaseURL = url
            self.connection = Connection(handle)
            self.fullTextSearchAvailable = fts
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    public func close() throws {
        guard let database = connection.pointer else { return }
        let result = sqlite3_close_v2(database)
        guard result == SQLITE_OK else { throw Self.error(from: database) }
        connection.pointer = nil
    }

    public func diagnostics() throws -> SQLiteMemoryStoreDiagnostics {
        let database = try openDatabase()
        return SQLiteMemoryStoreDiagnostics(
            schemaVersion: Int(try Self.scalarInt(database, sql: "PRAGMA user_version")),
            journalMode: try Self.scalarText(database, sql: "PRAGMA journal_mode"),
            busyTimeoutMilliseconds: Int(try Self.scalarInt(database, sql: "PRAGMA busy_timeout")),
            fullTextSearchAvailable: fullTextSearchAvailable,
            appendOnlyEventGuardsInstalled: try Self.scalarInt(
                database,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'trigger' AND name IN (
                        'memory_events_are_append_only_on_update',
                        'memory_events_are_append_only_on_delete'
                    )
                    """
            ) == 2,
            secureDeleteEnabled: try Self.scalarInt(database, sql: "PRAGMA secure_delete") == 1
        )
    }

    func persistedArtifactCounts(recordID: UUID) throws -> SQLiteMemoryArtifactCounts {
        let database = try openDatabase()
        let id = Binding.text(recordID.uuidString)
        return try SQLiteMemoryArtifactCounts(
            records: scalarInt(database, sql: "SELECT COUNT(*) FROM memory_records WHERE id = ?", bindings: [id]),
            events: scalarInt(database, sql: "SELECT COUNT(*) FROM memory_events WHERE record_id = ?", bindings: [id]),
            fullTextEntries: try fullTextSearchTableExists(database)
                ? scalarInt(
                    database,
                    sql: "SELECT COUNT(*) FROM memory_records_fts WHERE record_id = ?",
                    bindings: [id]
                )
                : 0
        )
    }

    public func upsert(
        _ proposal: MemoryProposal,
        status: MemoryStatus,
        expectedRevision: Int?,
        at date: Date
    ) throws -> MemoryRecord {
        let proposal = try proposal.validated()
        let key = proposal.resolvedDeduplicationKey()

        return try transaction {
            let database = try openDatabase()
            if var record = try findByDedupeKey(
                database,
                scope: proposal.scope,
                key: key
            ) {
                if let expectedRevision, expectedRevision != record.revision {
                    throw MemoryStoreError.revisionConflict(
                        id: record.id,
                        expected: expectedRevision,
                        actual: record.revision
                    )
                }

                if Self.matches(record, proposal: proposal, status: status, at: date) {
                    try insertEvent(
                        database,
                        record: record,
                        kind: .deduplicated,
                        previousRevision: record.revision,
                        at: date
                    )
                    return record
                }

                let oldRevision = record.revision
                record.kind = proposal.kind
                record.content = proposal.content
                record.sensitivity = proposal.sensitivity
                record.provenance = proposal.provenance
                record.confidence = proposal.confidence
                record.importance = proposal.importance
                record.expiresAt = proposal.timeToLive.map { date.addingTimeInterval($0) }
                record.status = status
                record.deduplicationKeyOrigin = proposal.resolvedDeduplicationKeyOrigin()
                record.metadata = proposal.metadata
                record.revision += 1
                record.updatedAt = date
                try writeRecord(database, record: record, inserting: false)
                try synchronizeFullTextIndex(database, record: record)
                try insertEvent(
                    database,
                    record: record,
                    kind: .updated,
                    previousRevision: oldRevision,
                    at: date
                )
                return record
            }

            if let expectedRevision, expectedRevision != 0 {
                throw MemoryStoreError.invalidProposal(
                    "expectedRevision for a new record must be nil or zero"
                )
            }
            let record = MemoryRecord(
                id: UUID(),
                scope: proposal.scope,
                kind: proposal.kind,
                content: proposal.content,
                sensitivity: proposal.sensitivity,
                provenance: proposal.provenance,
                confidence: proposal.confidence,
                importance: proposal.importance,
                expiresAt: proposal.timeToLive.map { date.addingTimeInterval($0) },
                revision: 1,
                status: status,
                deduplicationKey: key,
                deduplicationKeyOrigin: proposal.resolvedDeduplicationKeyOrigin(),
                metadata: proposal.metadata,
                createdAt: date,
                updatedAt: date
            )
            try writeRecord(database, record: record, inserting: true)
            try synchronizeFullTextIndex(database, record: record)
            try insertEvent(
                database,
                record: record,
                kind: .created,
                previousRevision: nil,
                at: date
            )
            return record
        }
    }

    public func fetch(
        id: UUID,
        scope: MemoryScope,
        includeExpired: Bool,
        at date: Date
    ) throws -> MemoryRecord? {
        let scope = try scope.validatedForLegacySQLiteAccess()
        let database = try openDatabase()
        guard let record = try find(database, id: id, scope: scope) else { return nil }
        guard includeExpired || !record.isExpired(at: date) else { return nil }
        return record
    }

    public func update(
        id: UUID,
        scope: MemoryScope,
        patch: MemoryPatch,
        expectedRevision: Int,
        at date: Date
    ) throws -> MemoryRecord {
        let scope = try scope.validatedForLegacySQLiteAccess()
        return try transaction {
            let database = try openDatabase()
            guard var record = try find(database, id: id, scope: scope) else {
                throw MemoryStoreError.notFound(id)
            }
            guard record.revision == expectedRevision else {
                throw MemoryStoreError.revisionConflict(
                    id: id,
                    expected: expectedRevision,
                    actual: record.revision
                )
            }
            let oldRevision = record.revision
            try InMemoryMemoryStore.apply(patch, to: &record)
            record.revision += 1
            record.updatedAt = date
            try writeRecord(database, record: record, inserting: false)
            try synchronizeFullTextIndex(database, record: record)
            try insertEvent(
                database,
                record: record,
                kind: patch.status == .deleted
                    ? .deleted
                    : (patch.status == nil ? .updated : .statusChanged),
                previousRevision: oldRevision,
                at: date
            )
            return record
        }
    }

    public func delete(
        id: UUID,
        scope: MemoryScope,
        expectedRevision: Int,
        at date: Date
    ) throws {
        _ = try update(
            id: id,
            scope: scope,
            patch: MemoryPatch(status: .deleted),
            expectedRevision: expectedRevision,
            at: date
        )
    }

    public func purge(id: UUID, scope: MemoryScope) async throws -> MemoryPurgeResult {
        let scope = try scope.validatedForLegacySQLiteAccess()
        let result = try transaction {
            let database = try openDatabase()
            guard try find(database, id: id, scope: scope) != nil else {
                return MemoryPurgeResult()
            }
            try removeEventDeletionGuard(database)
            let result = try purgeRecords(
                database,
                where: "id = ? AND \(Self.exactScopePredicate)",
                bindings: [.text(id.uuidString)] + scopeBindings(scope)
            )
            if result.recordsPurged > 0, try fullTextSearchTableExists(database) {
                try rebuildFullTextIndex(database)
            }
            try restoreEventDeletionGuard(database)
            if result.didPurgeAnything {
                try schedulePhysicalPurgeCleanup(database)
            }
            return result
        }
        // A durable cleanup epoch makes an idempotent retry useful after an
        // interrupted cleanup without imposing VACUUM on ordinary no-ops.
        return try finishPhysicalPurgeIfNeeded(result)
    }

    public func purge(scopes: [MemoryScope]) async throws -> MemoryPurgeResult {
        // Do not place legacy scopes in a Swift `Set`: `String` equality uses
        // canonical Unicode equivalence while SQLite scope identity preserves
        // exact UTF-8 bytes. Processing an exact duplicate twice is harmless
        // and keeps canonically equivalent legacy namespaces distinct.
        let exactScopes = try scopes.map {
            try $0.validatedForLegacySQLiteAccess()
        }
        guard !exactScopes.isEmpty else { return MemoryPurgeResult() }

        let result = try transaction {
            let database = try openDatabase()
            try removeEventDeletionGuard(database)
            var aggregate = MemoryPurgeResult()
            var deletedSourceStates = 0
            for scope in exactScopes {
                let partial = try purgeRecords(
                    database,
                    where: Self.exactScopePredicate,
                    bindings: scopeBindings(scope)
                )
                aggregate.recordsPurged += partial.recordsPurged
                aggregate.eventsPurged += partial.eventsPurged
                aggregate.fullTextEntriesPurged += partial.fullTextEntriesPurged
                deletedSourceStates += try executePreparedChanges(
                    database,
                    sql: "DELETE FROM memory_sources WHERE \(Self.exactScopePredicate)",
                    bindings: scopeBindings(scope)
                )
            }
            if aggregate.recordsPurged > 0, try fullTextSearchTableExists(database) {
                try rebuildFullTextIndex(database)
            }
            try restoreEventDeletionGuard(database)
            if aggregate.didPurgeAnything || deletedSourceStates > 0 {
                try schedulePhysicalPurgeCleanup(database)
            }
            return aggregate
        }
        return try finishPhysicalPurgeIfNeeded(result)
    }

    public func recordsOwned(appID: String, userID: String) async throws -> [MemoryRecord] {
        let bindings = try ownerBindings(appID: appID, userID: userID)
        let database = try openDatabase()
        return try records(
            database,
            sql: """
                SELECT \(Self.recordColumns)
                FROM memory_records
                WHERE \(Self.ownedPredicate)
                ORDER BY updated_at DESC, id ASC
                """,
            bindings: bindings
        )
    }

    public func purgeOwned(appID: String, userID: String) async throws -> MemoryPurgeResult {
        let bindings = try ownerBindings(appID: appID, userID: userID)
        let result = try transaction {
            let database = try openDatabase()
            try removeEventDeletionGuard(database)
            let result = try purgeRecords(
                database,
                where: Self.ownedPredicate,
                bindings: bindings
            )
            let deletedSourceStates = try executePreparedChanges(
                database,
                sql: "DELETE FROM memory_sources WHERE \(Self.ownedPredicate)",
                bindings: bindings
            )
            if result.recordsPurged > 0, try fullTextSearchTableExists(database) {
                try rebuildFullTextIndex(database)
            }
            try restoreEventDeletionGuard(database)
            if result.didPurgeAnything || deletedSourceStates > 0 {
                try schedulePhysicalPurgeCleanup(database)
            }
            return result
        }
        return try finishPhysicalPurgeIfNeeded(result)
    }

    /// Lists persisted scopes that fail current canonical validation.
    ///
    /// This is an administrative migration surface for databases written by
    /// AgentRuntimeKit 0.1.x. Callers should present or log only aggregate
    /// counts, never raw identifiers, unless their own privacy UI requires it.
    /// Ordinary read and purge methods remain exact-scope and reject lossy NUL
    /// or empty-optional aliases.
    public func legacyScopeInventory() throws -> [SQLiteLegacyScopeSummary] {
        let database = try openDatabase()
        let statement = try prepare(
            database,
            sql: """
                SELECT
                    r.scope_level, r.app_id, r.user_id, r.agent_id,
                    r.workspace_id, r.session_id, COUNT(*),
                    (
                        SELECT COUNT(*) FROM memory_events e
                        WHERE e.scope_level = r.scope_level
                          AND e.app_id = r.app_id AND e.user_id = r.user_id
                          AND e.agent_id = r.agent_id
                          AND e.workspace_id = r.workspace_id
                          AND e.session_id = r.session_id
                    )
                FROM memory_records r
                GROUP BY
                    r.scope_level, r.app_id, r.user_id, r.agent_id,
                    r.workspace_id, r.session_id
                ORDER BY
                    r.scope_level, r.app_id, r.user_id, r.agent_id,
                    r.workspace_id, r.session_id
                """,
            bindings: []
        )
        defer { sqlite3_finalize(statement) }
        var result: [SQLiteLegacyScopeSummary] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let level = MemoryScopeLevel(rawValue: try Self.text(statement, 0)) else {
                    throw MemoryStoreError.serialization(
                        "a legacy scope row contains an unknown scope level"
                    )
                }
                let scope = MemoryScope(
                    level: level,
                    appID: try Self.text(statement, 1),
                    userID: try Self.optionalIdentifier(statement, 2),
                    agentID: try Self.optionalIdentifier(statement, 3),
                    workspaceID: try Self.optionalIdentifier(statement, 4),
                    sessionID: try Self.optionalIdentifier(statement, 5)
                )
                guard (try? scope.validated()) == nil else { continue }
                result.append(SQLiteLegacyScopeSummary(
                    scope: scope,
                    recordCount: Int(sqlite3_column_int64(statement, 6)),
                    eventCount: Int(sqlite3_column_int64(statement, 7))
                ))
            case SQLITE_DONE:
                return result
            default:
                throw Self.error(from: database)
            }
        }
    }

    /// Purges one exact non-canonical persisted scope returned by
    /// ``legacyScopeInventory()``.
    ///
    /// This deliberately does not reinterpret NUL-terminated 0.1.x input. That
    /// historical binding discarded the suffix and cannot distinguish it from
    /// a legitimate prefix namespace. Hosts must select the exact persisted
    /// scope from the inventory. A canonical scope must use the ordinary purge
    /// APIs instead.
    public func purgeLegacyPersistedScope(
        _ persistedScope: MemoryScope
    ) async throws -> MemoryPurgeResult {
        guard [
            persistedScope.userID,
            persistedScope.agentID,
            persistedScope.workspaceID,
            persistedScope.sessionID,
        ].allSatisfy({ $0 != "" }) else {
            throw MemoryStoreError.invalidScope(
                "legacy purge selectors must use nil, not a present empty optional identifier"
            )
        }
        guard (try? persistedScope.validated()) == nil else {
            throw MemoryStoreError.invalidScope(
                "canonical scopes must use the ordinary purge API"
            )
        }

        let result = try transaction {
            let database = try openDatabase()
            try removeEventDeletionGuard(database)
            let result = try purgeRecords(
                database,
                where: Self.exactScopePredicate,
                bindings: scopeBindings(persistedScope)
            )
            let deletedSourceStates = try executePreparedChanges(
                database,
                sql: "DELETE FROM memory_sources WHERE \(Self.exactScopePredicate)",
                bindings: scopeBindings(persistedScope)
            )
            if result.recordsPurged > 0, try fullTextSearchTableExists(database) {
                try rebuildFullTextIndex(database)
            }
            try restoreEventDeletionGuard(database)
            if result.didPurgeAnything || deletedSourceStates > 0 {
                try schedulePhysicalPurgeCleanup(database)
            }
            return result
        }
        return try finishPhysicalPurgeIfNeeded(result)
    }

    public func sourceState(
        identifier: String,
        scope: MemoryScope
    ) throws -> MemorySourceState? {
        let identity = try MemorySourceReconciliationValidation.identity(
            identifier: identifier,
            scope: scope
        )
        let database = try openDatabase()
        let statement = try prepare(
            database,
            sql: """
                SELECT generation FROM memory_sources
                WHERE identifier = ? AND \(Self.exactScopePredicate)
                """,
            bindings: sourceBindings(identity)
        )
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return MemorySourceState(
                identifier: identity.identifier,
                scope: identity.scope,
                generation: Int(sqlite3_column_int64(statement, 0))
            )
        case SQLITE_DONE:
            return nil
        default:
            throw Self.error(from: database)
        }
    }

    public func reconcileSourceSnapshot(
        _ snapshot: MemorySourceSnapshot,
        expectedGeneration: Int,
        missingPolicy: MemorySourceMissingPolicy,
        at date: Date
    ) throws -> MemorySourceReconciliationReport {
        // Perform all caller-controlled validation before BEGIN IMMEDIATE so a
        // malformed item near the end of a large snapshot cannot mutate state.
        let snapshot = try MemorySourceReconciliationValidation.snapshot(
            snapshot,
            expectedGeneration: expectedGeneration,
            at: date
        )
        let result: (MemorySourceReconciliationReport, MemoryPurgeResult) = try transaction {
            let database = try openDatabase()
            let currentGeneration = try sourceGeneration(database, identity: snapshot.identity)
                ?? 0
            guard currentGeneration == snapshot.expectedGeneration else {
                throw MemorySourceReconciliationError.generationConflict(
                    expected: snapshot.expectedGeneration,
                    actual: currentGeneration
                )
            }
            let nextGeneration = try MemorySourceReconciliationValidation.nextGeneration(
                after: currentGeneration
            )
            let sourceExisted = try sourceGeneration(
                database,
                identity: snapshot.identity
            ) != nil
            if !sourceExisted {
                try insertSource(
                    database,
                    identity: snapshot.identity,
                    generation: currentGeneration
                )
            }

            let mappings = try sourceMappings(database, identity: snapshot.identity)
            let desiredDedupeKeyByMappedID = Dictionary(
                uniqueKeysWithValues: snapshot.records.compactMap { item in
                    mappings[item.sourceRecordID].map { ($0, item.deduplicationKey) }
                }
            )
            var report = MemorySourceReconciliationReport(
                identifier: snapshot.identity.identifier,
                scope: snapshot.identity.scope,
                previousGeneration: currentGeneration,
                generation: nextGeneration
            )

            // Preflight every collision and mapped record before writing. The
            // transaction itself remains the final cross-process authority.
            for item in snapshot.records {
                let mappedID = mappings[item.sourceRecordID]
                if let mappedID {
                    guard try find(
                        database,
                        id: mappedID,
                        scope: snapshot.identity.scope
                    ) != nil else {
                        throw MemorySourceReconciliationError.corruptMapping(
                            "a source entry points to a missing record or a different scope"
                        )
                    }
                    if let owner = try sourceOwner(database, recordID: mappedID),
                       owner != snapshot.identity {
                        throw MemorySourceReconciliationError.recordOwnershipConflict(mappedID)
                    }
                }
                if let existing = try findByDedupeKey(
                    database,
                    scope: snapshot.identity.scope,
                    key: item.deduplicationKey
                ), existing.id != mappedID {
                    guard let desiredKey = desiredDedupeKeyByMappedID[existing.id],
                          desiredKey != item.deduplicationKey else {
                        throw MemorySourceReconciliationError.recordOwnershipConflict(existing.id)
                    }
                }
            }

            // SQLite enforces the exact-scope deduplication identity with a
            // UNIQUE constraint. Move changing, source-owned keys to private
            // transaction-local sentinels first so swaps and longer cycles do
            // not depend on input order. Rollback restores every original key.
            for (id, desiredKey) in desiredDedupeKeyByMappedID {
                guard let record = try find(
                    database,
                    id: id,
                    scope: snapshot.identity.scope
                ) else {
                    throw MemorySourceReconciliationError.corruptMapping(
                        "a mapped record disappeared before key staging"
                    )
                }
                guard record.deduplicationKey != desiredKey else { continue }
                try stageTemporaryDeduplicationKey(
                    database,
                    recordID: id,
                    scope: snapshot.identity.scope
                )
            }

            let incomingIDs = Set(snapshot.records.map(\.sourceRecordID))
            for item in snapshot.records {
                if let id = mappings[item.sourceRecordID] {
                    guard var record = try find(
                        database,
                        id: id,
                        scope: snapshot.identity.scope
                    ) else {
                        throw MemorySourceReconciliationError.corruptMapping(
                            "a mapped record disappeared during reconciliation"
                        )
                    }
                    if Self.matches(record, proposal: item.proposal, status: .active, at: date) {
                        report.unchanged += 1
                        continue
                    }
                    let oldRevision = record.revision
                    InMemoryMemoryStore.replace(
                        &record,
                        with: item.proposal,
                        deduplicationKey: item.deduplicationKey,
                        status: .active,
                        at: date
                    )
                    try writeRecord(database, record: record, inserting: false)
                    try synchronizeFullTextIndex(database, record: record)
                    try insertEvent(
                        database,
                        record: record,
                        kind: .updated,
                        previousRevision: oldRevision,
                        at: date
                    )
                    report.updated += 1
                } else {
                    let record = InMemoryMemoryStore.makeRecord(
                        proposal: item.proposal,
                        deduplicationKey: item.deduplicationKey,
                        at: date
                    )
                    try writeRecord(database, record: record, inserting: true)
                    try synchronizeFullTextIndex(database, record: record)
                    try insertEvent(
                        database,
                        record: record,
                        kind: .created,
                        previousRevision: nil,
                        at: date
                    )
                    try insertSourceMapping(
                        database,
                        identity: snapshot.identity,
                        sourceRecordID: item.sourceRecordID,
                        recordID: record.id
                    )
                    report.created += 1
                }
            }

            let missing = mappings.filter { !incomingIDs.contains($0.key) }
            var purgeResult = MemoryPurgeResult()
            switch missingPolicy {
            case .archive:
                for (_, id) in missing {
                    guard var record = try find(
                        database,
                        id: id,
                        scope: snapshot.identity.scope
                    ) else {
                        throw MemorySourceReconciliationError.corruptMapping(
                            "a missing source entry points to an absent memory record"
                        )
                    }
                    if record.status == .archived {
                        report.unchanged += 1
                        continue
                    }
                    let oldRevision = record.revision
                    record.status = .archived
                    record.revision += 1
                    record.updatedAt = date
                    try writeRecord(database, record: record, inserting: false)
                    try synchronizeFullTextIndex(database, record: record)
                    try insertEvent(
                        database,
                        record: record,
                        kind: .statusChanged,
                        previousRevision: oldRevision,
                        at: date
                    )
                    report.archived += 1
                }
            case .purge:
                if !missing.isEmpty {
                    try removeEventDeletionGuard(database)
                    let partial = try purgeSourceRecordsBatch(
                        database,
                        recordIDs: missing.map(\.value),
                        scope: snapshot.identity.scope
                    )
                    purgeResult = partial
                    report.purged += partial.recordsPurged
                    if partial.recordsPurged > 0,
                       try fullTextSearchTableExists(database) {
                        try rebuildFullTextIndex(database)
                    }
                    try restoreEventDeletionGuard(database)
                    if partial.didPurgeAnything {
                        try schedulePhysicalPurgeCleanup(database)
                    }
                }
            }

            try executePrepared(
                database,
                sql: """
                    UPDATE memory_sources SET generation = ?
                    WHERE identifier = ? AND \(Self.exactScopePredicate)
                    """,
                bindings: [.integer(Int64(nextGeneration))] + sourceBindings(snapshot.identity)
            )
            return (report, purgeResult)
        }
        // A no-op `.purge` reconciliation consults durable maintenance state.
        // It retries cleanup after a committed failure, but otherwise avoids
        // an unnecessary VACUUM and WAL checkpoint.
        if missingPolicy == .purge {
            _ = try finishPhysicalPurgeIfNeeded(result.1)
        }
        return result.0
    }

    public func retrieve(_ query: MemoryQuery) throws -> MemoryRetrievalResult {
        try MemoryRetrievalEngine.validateForLegacySQLiteAccess(query)
        guard query.limit > 0, query.characterBudget > 0 else {
            return MemoryRetrievalResult(
                hits: [],
                mode: MemoryRetrievalEngine.terms(query.text).isEmpty ? .recent : .lexical,
                usedCharacterCount: 0,
                exhaustedBudget: query.characterBudget == 0
            )
        }
        let database = try openDatabase()
        let terms = MemoryRetrievalEngine.terms(query.text)
        var mode: MemorySearchMode = terms.isEmpty ? .recent : .lexical
        let candidates: [MemoryRecord]

        if !terms.isEmpty, fullTextSearchAvailable {
            do {
                var indexed = try fullTextCandidates(database, query: query, terms: terms)
                // Secret values are deliberately not copied into FTS. They remain
                // retrievable only when the caller opts into secret sensitivity.
                if query.maximumSensitivity == .secret {
                    let secrets = try baseCandidates(
                        database,
                        query: query,
                        sensitivityExactly: .secret
                    )
                    let indexedIDs = Set(indexed.map(\.id))
                    indexed.append(contentsOf: secrets.filter { !indexedIDs.contains($0.id) })
                }
                if indexed.isEmpty {
                    candidates = try baseCandidates(database, query: query)
                } else {
                    candidates = indexed
                    mode = .fullText
                }
            } catch {
                fullTextSearchAvailable = false
                candidates = try baseCandidates(database, query: query)
            }
        } else {
            candidates = try baseCandidates(database, query: query)
        }
        return MemoryRetrievalEngine.result(candidates: candidates, query: query, mode: mode)
    }

    public func events(
        scope: MemoryScope,
        recordID: UUID?,
        limit: Int
    ) throws -> [MemoryEvent] {
        let scope = try scope.validatedForLegacySQLiteAccess()
        let database = try openDatabase()
        var sql = """
            SELECT id, record_id, scope_level, app_id, user_id, agent_id,
                   workspace_id, session_id, event_kind, event_at,
                   previous_revision, revision, detail_json
            FROM memory_events
            WHERE scope_level = ? AND app_id = ? AND user_id = ?
              AND agent_id = ? AND workspace_id = ? AND session_id = ?
            """
        var bindings = scopeBindings(scope)
        if let recordID {
            sql += " AND record_id = ?"
            bindings.append(.text(recordID.uuidString))
        }
        sql += " ORDER BY event_sequence DESC LIMIT ?"
        bindings.append(.integer(Int64(max(0, limit))))
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [MemoryEvent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decodeEvent(statement))
            case SQLITE_DONE:
                return result.reversed()
            default:
                throw Self.error(from: database)
            }
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        guard let database = connection.pointer else {
            throw MemoryStoreError.database("the SQLite memory store is closed")
        }
        return database
    }

    private static func migrate(_ database: OpaquePointer) throws {
        let version = Int(try scalarInt(database, sql: "PRAGMA user_version"))
        guard version <= currentSchemaVersion else {
            throw MemoryStoreError.database(
                "schema version \(version) is newer than supported version \(currentSchemaVersion)"
            )
        }
        if version < 1 {
            try execute(database, sql: "BEGIN IMMEDIATE")
            do {
                try execute(database, sql: """
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

                    PRAGMA user_version = 1;
                    """)
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
        }
        if version < 2 {
            try execute(database, sql: "BEGIN IMMEDIATE")
            do {
                try execute(database, sql: """
                    ALTER TABLE memory_records
                    ADD COLUMN deduplication_key_origin TEXT NOT NULL DEFAULT 'legacyUnknown';
                    PRAGMA user_version = 2;
                    """)
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
        }
        if version < 3 {
            try execute(database, sql: "BEGIN IMMEDIATE")
            do {
                try execute(database, sql: """
                    CREATE TABLE memory_sources (
                        identifier TEXT NOT NULL,
                        scope_level TEXT NOT NULL,
                        app_id TEXT NOT NULL,
                        user_id TEXT NOT NULL DEFAULT '',
                        agent_id TEXT NOT NULL DEFAULT '',
                        workspace_id TEXT NOT NULL DEFAULT '',
                        session_id TEXT NOT NULL DEFAULT '',
                        generation INTEGER NOT NULL CHECK(generation >= 0),
                        PRIMARY KEY(
                            identifier, scope_level, app_id, user_id, agent_id,
                            workspace_id, session_id
                        )
                    );

                    CREATE INDEX memory_sources_scope_lookup
                    ON memory_sources(
                        scope_level, app_id, user_id, agent_id,
                        workspace_id, session_id
                    );

                    CREATE TABLE memory_source_records (
                        source_identifier TEXT NOT NULL,
                        source_scope_level TEXT NOT NULL,
                        source_app_id TEXT NOT NULL,
                        source_user_id TEXT NOT NULL DEFAULT '',
                        source_agent_id TEXT NOT NULL DEFAULT '',
                        source_workspace_id TEXT NOT NULL DEFAULT '',
                        source_session_id TEXT NOT NULL DEFAULT '',
                        source_record_id TEXT NOT NULL,
                        record_id TEXT NOT NULL UNIQUE
                            REFERENCES memory_records(id) ON DELETE CASCADE,
                        PRIMARY KEY(
                            source_identifier, source_scope_level, source_app_id,
                            source_user_id, source_agent_id, source_workspace_id,
                            source_session_id, source_record_id
                        ),
                        FOREIGN KEY(
                            source_identifier, source_scope_level, source_app_id,
                            source_user_id, source_agent_id, source_workspace_id,
                            source_session_id
                        ) REFERENCES memory_sources(
                            identifier, scope_level, app_id, user_id, agent_id,
                            workspace_id, session_id
                        ) ON DELETE CASCADE
                    );

                    PRAGMA user_version = 3;
                    """)
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
        }
        if version < 4 {
            // Databases created by a previous library version may have had a
            // logical purge commit immediately before physical cleanup failed.
            // Conservatively leave one cleanup pending for upgraded stores;
            // brand-new databases have no historical cleanup to recover.
            let initialCleanupEpoch = version == 0 ? 0 : 1
            try execute(database, sql: "BEGIN IMMEDIATE")
            do {
                try execute(database, sql: """
                    CREATE TABLE memory_store_maintenance (
                        singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1),
                        purge_cleanup_epoch INTEGER NOT NULL
                            CHECK(purge_cleanup_epoch >= 0),
                        completed_purge_cleanup_epoch INTEGER NOT NULL
                            CHECK(
                                completed_purge_cleanup_epoch >= 0
                                AND completed_purge_cleanup_epoch <= purge_cleanup_epoch
                            )
                    );

                    INSERT INTO memory_store_maintenance (
                        singleton, purge_cleanup_epoch, completed_purge_cleanup_epoch
                    ) VALUES (1, \(initialCleanupEpoch), 0);

                    PRAGMA user_version = 4;
                    """)
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
        }
        if version < 5 {
            try execute(database, sql: "BEGIN IMMEDIATE")
            do {
                try execute(database, sql: """
                    CREATE INDEX memory_events_record_lookup
                    ON memory_events(record_id);

                    PRAGMA user_version = 5;
                    """)
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
        }
    }

    private static func configureFullTextSearch(_ database: OpaquePointer) -> Bool {
        do {
            try execute(database, sql: createFullTextSearchSQL)
            return true
        } catch {
            return false
        }
    }

    private func removeEventDeletionGuard(_ database: OpaquePointer) throws {
        // The guard remains authoritative for every ordinary store operation.
        // SQLite DDL is transactional, so any failure rolls the trigger and the
        // purge back together, including across other process connections.
        try Self.execute(
            database,
            sql: "DROP TRIGGER IF EXISTS memory_events_are_append_only_on_delete"
        )
    }

    private func restoreEventDeletionGuard(_ database: OpaquePointer) throws {
        try Self.execute(database, sql: Self.createEventDeleteGuardSQL)
    }

    private func purgeRecords(
        _ database: OpaquePointer,
        where predicate: String,
        bindings: [Binding]
    ) throws -> MemoryPurgeResult {
        let subquery = "SELECT id FROM memory_records WHERE \(predicate)"
        let fullTextEntries = try fullTextSearchTableExists(database)
            ? try executePreparedChanges(
                database,
                sql: "DELETE FROM memory_records_fts WHERE record_id IN (\(subquery))",
                bindings: bindings
            )
            : 0
        let events = try executePreparedChanges(
            database,
            sql: "DELETE FROM memory_events WHERE record_id IN (\(subquery))",
            bindings: bindings
        )
        let records = try executePreparedChanges(
            database,
            sql: "DELETE FROM memory_records WHERE \(predicate)",
            bindings: bindings
        )
        return MemoryPurgeResult(
            recordsPurged: records,
            eventsPurged: events,
            fullTextEntriesPurged: fullTextEntries
        )
    }

    private func purgeSourceRecordsBatch(
        _ database: OpaquePointer,
        recordIDs: [UUID],
        scope: MemoryScope
    ) throws -> MemoryPurgeResult {
        let uniqueIDs = Set(recordIDs)
        guard uniqueIDs.count == recordIDs.count else {
            throw MemorySourceReconciliationError.corruptMapping(
                "multiple source entries point to the same memory record"
            )
        }

        try Self.execute(database, sql: """
            CREATE TEMP TABLE IF NOT EXISTS agentruntime_source_purge_ids (
                id TEXT PRIMARY KEY NOT NULL
            ) WITHOUT ROWID
            """)
        try Self.execute(
            database,
            sql: "DELETE FROM agentruntime_source_purge_ids"
        )

        let sortedIDs = uniqueIDs.map(\.uuidString).sorted()
        let batchSize = 256
        var start = 0
        while start < sortedIDs.count {
            let end = min(start + batchSize, sortedIDs.count)
            let batch = sortedIDs[start..<end]
            let placeholders = Array(repeating: "(?)", count: batch.count)
                .joined(separator: ",")
            try executePrepared(
                database,
                sql: "INSERT INTO agentruntime_source_purge_ids(id) VALUES \(placeholders)",
                bindings: batch.map(Binding.text)
            )
            start = end
        }

        let matchedRecordCount = try scalarInt(
            database,
            sql: """
                SELECT COUNT(*) FROM memory_records
                WHERE id IN (SELECT id FROM agentruntime_source_purge_ids)
                  AND \(Self.exactScopePredicate)
                """,
            bindings: scopeBindings(scope)
        )
        guard matchedRecordCount == sortedIDs.count else {
            throw MemorySourceReconciliationError.corruptMapping(
                "a missing source entry points to an absent record or a different scope"
            )
        }

        let fullTextEntries = try fullTextSearchTableExists(database)
            ? try executePreparedChanges(
                database,
                sql: """
                    DELETE FROM memory_records_fts
                    WHERE record_id IN (SELECT id FROM agentruntime_source_purge_ids)
                    """,
                bindings: []
            )
            : 0
        let events = try executePreparedChanges(
            database,
            sql: """
                DELETE FROM memory_events
                WHERE record_id IN (SELECT id FROM agentruntime_source_purge_ids)
                """,
            bindings: []
        )
        let records = try executePreparedChanges(
            database,
            sql: """
                DELETE FROM memory_records
                WHERE id IN (SELECT id FROM agentruntime_source_purge_ids)
                  AND \(Self.exactScopePredicate)
                """,
            bindings: scopeBindings(scope)
        )
        guard records == sortedIDs.count else {
            throw MemorySourceReconciliationError.corruptMapping(
                "the batch source purge did not remove every mapped record"
            )
        }
        try Self.execute(
            database,
            sql: "DELETE FROM agentruntime_source_purge_ids"
        )
        return MemoryPurgeResult(
            recordsPurged: records,
            eventsPurged: events,
            fullTextEntriesPurged: fullTextEntries
        )
    }

    private func rebuildFullTextIndex(_ database: OpaquePointer) throws {
        // FTS5 normally retains old term segments until they are merged. A
        // privacy purge therefore rebuilds the virtual table from the remaining
        // non-secret active records instead of relying on delete markers.
        try Self.execute(database, sql: "DROP TABLE memory_records_fts")
        try Self.execute(database, sql: Self.createFullTextSearchSQL)
        try Self.execute(database, sql: """
            INSERT INTO memory_records_fts(record_id, content)
            SELECT id, content FROM memory_records
            WHERE status = 'active' AND sensitivity != 'secret'
            """)
        fullTextSearchAvailable = true
    }

    private func fullTextSearchTableExists(_ database: OpaquePointer) throws -> Bool {
        try scalarInt(
            database,
            sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'memory_records_fts'
                """,
            bindings: []
        ) == 1
    }

    private func schedulePhysicalPurgeCleanup(_ database: OpaquePointer) throws {
        let changed = try executePreparedChanges(
            database,
            sql: """
                UPDATE memory_store_maintenance
                SET purge_cleanup_epoch = purge_cleanup_epoch + 1
                WHERE singleton = 1 AND purge_cleanup_epoch < ?
                """,
            bindings: [.integer(Int64.max)]
        )
        guard changed == 1 else {
            throw MemoryStoreError.database(
                "physical purge cleanup state is missing or exhausted"
            )
        }
    }

    private func physicalPurgeCleanupState(
        _ database: OpaquePointer
    ) throws -> (scheduled: Int64, completed: Int64) {
        let statement = try prepare(
            database,
            sql: """
                SELECT purge_cleanup_epoch, completed_purge_cleanup_epoch
                FROM memory_store_maintenance WHERE singleton = 1
                """,
            bindings: []
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MemoryStoreError.database("physical purge cleanup state is missing")
        }
        return (
            scheduled: sqlite3_column_int64(statement, 0),
            completed: sqlite3_column_int64(statement, 1)
        )
    }

    private func markPhysicalPurgeCleanupCompleted(through epoch: Int64) throws {
        try transaction {
            let database = try openDatabase()
            let changed = try executePreparedChanges(
                database,
                sql: """
                    UPDATE memory_store_maintenance
                    SET completed_purge_cleanup_epoch = MAX(
                        completed_purge_cleanup_epoch, ?
                    )
                    WHERE singleton = 1 AND purge_cleanup_epoch >= ?
                    """,
                bindings: [.integer(epoch), .integer(epoch)]
            )
            guard changed == 1 else {
                throw MemoryStoreError.database(
                    "physical purge cleanup completion could not be persisted"
                )
            }
        }
    }

    private func finishPhysicalPurgeIfNeeded(
        _ committedResult: MemoryPurgeResult
    ) throws -> MemoryPurgeResult {
        let database = try openDatabase()
        let cleanup = try physicalPurgeCleanupState(database)
        guard cleanup.scheduled > cleanup.completed else {
            return committedResult
        }

        // SQLite explicitly does not guarantee that core secure_delete scrubs
        // FTS5 shadow tables. Rebuilding removes logical terms in the atomic
        // transaction; VACUUM then rewrites the database file from the live
        // pages so old virtual-table pages are not retained in the file.
        do {
            try Self.execute(database, sql: "VACUUM")
        } catch {
            throw MemoryPurgeCleanupError(
                committedResult: committedResult,
                stage: .databaseCompaction,
                underlyingDescription: Self.errorDescription(error)
            )
        }

        do {
            try truncateWriteAheadLog()
        } catch {
            throw MemoryPurgeCleanupError(
                committedResult: committedResult,
                stage: .writeAheadLogTruncation,
                underlyingDescription: Self.errorDescription(error)
            )
        }

        do {
            try markPhysicalPurgeCleanupCompleted(through: cleanup.scheduled)
        } catch {
            throw MemoryPurgeCleanupError(
                committedResult: committedResult,
                // Keep the existing public two-stage error surface. Durable
                // maintenance state is the final WAL-cleanup checkpoint, and
                // its detailed cause remains available to callers here.
                stage: .writeAheadLogTruncation,
                underlyingDescription: "Maintenance-state persistence failed: "
                    + Self.errorDescription(error)
            )
        }
        return committedResult
    }

    private func truncateWriteAheadLog() throws {
        let database = try openDatabase()
        let statement = try prepare(
            database,
            sql: "PRAGMA wal_checkpoint(TRUNCATE)",
            bindings: []
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw Self.error(from: database)
        }
        let busyConnections = sqlite3_column_int64(statement, 0)
        guard busyConnections == 0 else {
            throw MemoryStoreError.database("WAL truncation remained busy")
        }
    }

    private func transaction<T>(operation: () throws -> T) throws -> T {
        let database = try openDatabase()
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try Self.execute(database, sql: "COMMIT")
            return value
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private func findByDedupeKey(
        _ database: OpaquePointer,
        scope: MemoryScope,
        key: String
    ) throws -> MemoryRecord? {
        let sql = """
            SELECT \(Self.recordColumns)
            FROM memory_records
            WHERE scope_level = ? AND app_id = ? AND user_id = ?
              AND agent_id = ? AND workspace_id = ? AND session_id = ?
              AND deduplication_key = ?
            """
        return try firstRecord(
            database,
            sql: sql,
            bindings: scopeBindings(scope) + [.text(key)]
        )
    }

    private func stageTemporaryDeduplicationKey(
        _ database: OpaquePointer,
        recordID: UUID,
        scope: MemoryScope
    ) throws {
        let temporaryKey: String
        while true {
            // Valid proposals resolve to lowercase SHA-256 values. The prefix
            // also protects imported legacy rows, and the lookup makes the
            // uniqueness argument authoritative rather than probabilistic.
            let candidate = "agent-runtime-temporary:\(UUID().uuidString)"
            if try findByDedupeKey(database, scope: scope, key: candidate) == nil {
                temporaryKey = candidate
                break
            }
        }
        let changed = try executePreparedChanges(
            database,
            sql: "UPDATE memory_records SET deduplication_key = ? WHERE id = ?",
            bindings: [.text(temporaryKey), .text(recordID.uuidString)]
        )
        guard changed == 1 else {
            throw MemorySourceReconciliationError.corruptMapping(
                "a mapped record could not be staged for a deduplication-key update"
            )
        }
    }

    private func find(
        _ database: OpaquePointer,
        id: UUID,
        scope: MemoryScope
    ) throws -> MemoryRecord? {
        let sql = """
            SELECT \(Self.recordColumns)
            FROM memory_records
            WHERE id = ? AND scope_level = ? AND app_id = ? AND user_id = ?
              AND agent_id = ? AND workspace_id = ? AND session_id = ?
            """
        return try firstRecord(
            database,
            sql: sql,
            bindings: [.text(id.uuidString)] + scopeBindings(scope)
        )
    }

    private func sourceGeneration(
        _ database: OpaquePointer,
        identity: MemorySourceIdentity
    ) throws -> Int? {
        let statement = try prepare(
            database,
            sql: """
                SELECT generation FROM memory_sources
                WHERE identifier = ? AND \(Self.exactScopePredicate)
                """,
            bindings: sourceBindings(identity)
        )
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return Int(sqlite3_column_int64(statement, 0))
        case SQLITE_DONE:
            return nil
        default:
            throw Self.error(from: database)
        }
    }

    private func insertSource(
        _ database: OpaquePointer,
        identity: MemorySourceIdentity,
        generation: Int
    ) throws {
        try executePrepared(
            database,
            sql: """
                INSERT INTO memory_sources (
                    identifier, scope_level, app_id, user_id, agent_id,
                    workspace_id, session_id, generation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            bindings: sourceBindings(identity) + [.integer(Int64(generation))]
        )
    }

    private func sourceMappings(
        _ database: OpaquePointer,
        identity: MemorySourceIdentity
    ) throws -> [String: UUID] {
        let statement = try prepare(
            database,
            sql: """
                SELECT source_record_id, record_id FROM memory_source_records
                WHERE \(Self.sourceIdentityPredicate)
                ORDER BY source_record_id
                """,
            bindings: sourceMappingBindings(identity)
        )
        defer { sqlite3_finalize(statement) }
        var result: [String: UUID] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let sourceRecordID = try Self.text(statement, 0)
                guard let recordID = UUID(uuidString: try Self.text(statement, 1)) else {
                    throw MemorySourceReconciliationError.corruptMapping(
                        "a mapped record ID is not a UUID"
                    )
                }
                guard result.updateValue(recordID, forKey: sourceRecordID) == nil else {
                    throw MemorySourceReconciliationError.corruptMapping(
                        "one source record ID has duplicate mappings"
                    )
                }
            case SQLITE_DONE:
                return result
            default:
                throw Self.error(from: database)
            }
        }
    }

    private func sourceOwner(
        _ database: OpaquePointer,
        recordID: UUID
    ) throws -> MemorySourceIdentity? {
        let statement = try prepare(
            database,
            sql: """
                SELECT source_identifier, source_scope_level, source_app_id,
                       source_user_id, source_agent_id, source_workspace_id,
                       source_session_id
                FROM memory_source_records WHERE record_id = ?
                """,
            bindings: [.text(recordID.uuidString)]
        )
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let level = MemoryScopeLevel(rawValue: try Self.text(statement, 1)) else {
                throw MemorySourceReconciliationError.corruptMapping(
                    "a mapped source scope has an unknown level"
                )
            }
            return MemorySourceIdentity(
                identifier: try Self.text(statement, 0),
                scope: MemoryScope(
                    level: level,
                    appID: try Self.text(statement, 2),
                    userID: try Self.optionalIdentifier(statement, 3),
                    agentID: try Self.optionalIdentifier(statement, 4),
                    workspaceID: try Self.optionalIdentifier(statement, 5),
                    sessionID: try Self.optionalIdentifier(statement, 6)
                )
            )
        case SQLITE_DONE:
            return nil
        default:
            throw Self.error(from: database)
        }
    }

    private func insertSourceMapping(
        _ database: OpaquePointer,
        identity: MemorySourceIdentity,
        sourceRecordID: String,
        recordID: UUID
    ) throws {
        try executePrepared(
            database,
            sql: """
                INSERT INTO memory_source_records (
                    source_identifier, source_scope_level, source_app_id,
                    source_user_id, source_agent_id, source_workspace_id,
                    source_session_id, source_record_id, record_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            bindings: sourceMappingBindings(identity) + [
                .text(sourceRecordID),
                .text(recordID.uuidString),
            ]
        )
    }

    private func firstRecord(
        _ database: OpaquePointer,
        sql: String,
        bindings: [Binding]
    ) throws -> MemoryRecord? {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decodeRecord(statement)
        case SQLITE_DONE: return nil
        default: throw Self.error(from: database)
        }
    }

    private func writeRecord(
        _ database: OpaquePointer,
        record: MemoryRecord,
        inserting: Bool
    ) throws {
        let provenance = try Self.encode(record.provenance)
        let metadata = try Self.encode(record.metadata)
        let bindings: [Binding] = [
            .text(record.id.uuidString),
            .text(record.scope.level.rawValue),
            .text(record.scope.appID),
            .text(record.scope.userID ?? ""),
            .text(record.scope.agentID ?? ""),
            .text(record.scope.workspaceID ?? ""),
            .text(record.scope.sessionID ?? ""),
            .text(record.kind.rawValue),
            .text(record.content),
            .text(record.sensitivity.rawValue),
            .integer(Int64(record.sensitivity.memoryRank)),
            .blob(provenance),
            .double(record.confidence),
            .double(record.importance),
            record.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .integer(Int64(record.revision)),
            .text(record.status.rawValue),
            .text(record.deduplicationKey),
            .text((record.deduplicationKeyOrigin ?? .legacyUnknown).rawValue),
            .blob(metadata),
            .double(record.createdAt.timeIntervalSince1970),
            .double(record.updatedAt.timeIntervalSince1970),
        ]
        let sql: String
        if inserting {
            sql = """
                INSERT INTO memory_records (
                    id, scope_level, app_id, user_id, agent_id, workspace_id,
                    session_id, kind, content, sensitivity, sensitivity_rank,
                    provenance_json, confidence, importance, expires_at, revision,
                    status, deduplication_key, deduplication_key_origin,
                    metadata_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
        } else {
            sql = """
                UPDATE memory_records SET
                    scope_level = ?, app_id = ?, user_id = ?, agent_id = ?,
                    workspace_id = ?, session_id = ?, kind = ?, content = ?,
                    sensitivity = ?, sensitivity_rank = ?, provenance_json = ?,
                    confidence = ?, importance = ?, expires_at = ?, revision = ?,
                    status = ?, deduplication_key = ?, deduplication_key_origin = ?,
                    metadata_json = ?,
                    created_at = ?, updated_at = ?
                WHERE id = ?
                """
        }
        if inserting {
            try executePrepared(database, sql: sql, bindings: bindings)
        } else {
            try executePrepared(database, sql: sql, bindings: Array(bindings.dropFirst()) + [bindings[0]])
        }
    }

    private func synchronizeFullTextIndex(
        _ database: OpaquePointer,
        record: MemoryRecord
    ) throws {
        guard fullTextSearchAvailable else { return }
        try executePrepared(
            database,
            sql: "DELETE FROM memory_records_fts WHERE record_id = ?",
            bindings: [.text(record.id.uuidString)]
        )
        guard record.status == .active, record.sensitivity != .secret else { return }
        try executePrepared(
            database,
            sql: "INSERT INTO memory_records_fts(record_id, content) VALUES (?, ?)",
            bindings: [.text(record.id.uuidString), .text(record.content)]
        )
    }

    private func insertEvent(
        _ database: OpaquePointer,
        record: MemoryRecord,
        kind: MemoryEventKind,
        previousRevision: Int?,
        at date: Date
    ) throws {
        let detail: [String: JSONValue] = [
            "status": .string(record.status.rawValue),
            "kind": .string(record.kind.rawValue),
            "sensitivity": .string(record.sensitivity.rawValue),
        ]
        try executePrepared(
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
                .text(record.id.uuidString),
            ] + scopeBindings(record.scope) + [
                .text(kind.rawValue),
                .double(date.timeIntervalSince1970),
                previousRevision.map { .integer(Int64($0)) } ?? .null,
                .integer(Int64(record.revision)),
                .blob(try Self.encode(detail)),
            ]
        )
    }

    private func fullTextCandidates(
        _ database: OpaquePointer,
        query: MemoryQuery,
        terms: [String]
    ) throws -> [MemoryRecord] {
        let filter = queryFilter(query, alias: "m")
        let ftsQuery = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " OR ")
        let sql = """
            SELECT \(Self.recordColumnsWithAlias("m"))
            FROM memory_records_fts
            JOIN memory_records m ON m.id = memory_records_fts.record_id
            WHERE memory_records_fts MATCH ? AND \(filter.sql)
            ORDER BY bm25(memory_records_fts), m.importance DESC, m.updated_at DESC
            LIMIT ?
            """
        let boundLimit = min(2_000, max(200, query.limit * 20))
        return try records(
            database,
            sql: sql,
            bindings: [.text(ftsQuery)] + filter.bindings + [.integer(Int64(boundLimit))]
        )
    }

    private func baseCandidates(
        _ database: OpaquePointer,
        query: MemoryQuery,
        sensitivityExactly: AgentDataSensitivity? = nil
    ) throws -> [MemoryRecord] {
        var filter = queryFilter(query, alias: "m")
        if let sensitivityExactly {
            filter.sql += " AND m.sensitivity_rank = ?"
            filter.bindings.append(.integer(Int64(sensitivityExactly.memoryRank)))
        }
        let sql = """
            SELECT \(Self.recordColumnsWithAlias("m"))
            FROM memory_records m
            WHERE \(filter.sql)
            ORDER BY m.importance DESC, m.updated_at DESC
            LIMIT ?
            """
        let boundLimit = min(2_000, max(200, query.limit * 20))
        return try records(
            database,
            sql: sql,
            bindings: filter.bindings + [.integer(Int64(boundLimit))]
        )
    }

    private func queryFilter(
        _ query: MemoryQuery,
        alias: String
    ) -> (sql: String, bindings: [Binding]) {
        var scopeClauses: [String] = []
        var bindings: [Binding] = []
        for scope in query.scopes {
            scopeClauses.append("""
                (\(alias).scope_level = ? AND \(alias).app_id = ?
                 AND \(alias).user_id = ? AND \(alias).agent_id = ?
                 AND \(alias).workspace_id = ? AND \(alias).session_id = ?)
                """)
            bindings.append(contentsOf: scopeBindings(scope))
        }

        let statuses = query.statuses.sorted { $0.rawValue < $1.rawValue }
        let statusPlaceholders = Array(repeating: "?", count: statuses.count).joined(separator: ",")
        var clauses = [
            "(\(scopeClauses.joined(separator: " OR ")))",
            "\(alias).status IN (\(statusPlaceholders))",
            "\(alias).sensitivity_rank <= ?",
            "\(alias).confidence >= ?",
            "\(alias).importance >= ?",
        ]
        bindings.append(contentsOf: statuses.map { .text($0.rawValue) })
        bindings.append(.integer(Int64(query.maximumSensitivity.memoryRank)))
        bindings.append(.double(query.minimumConfidence))
        bindings.append(.double(query.minimumImportance))

        if let kinds = query.kinds {
            let sorted = kinds.sorted { $0.rawValue < $1.rawValue }
            let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ",")
            clauses.append("\(alias).kind IN (\(placeholders))")
            bindings.append(contentsOf: sorted.map { .text($0.rawValue) })
        }
        if !query.includeExpired {
            clauses.append("(\(alias).expires_at IS NULL OR \(alias).expires_at > ?)")
            bindings.append(.double(query.asOf.timeIntervalSince1970))
        }
        return (clauses.joined(separator: " AND "), bindings)
    }

    private func records(
        _ database: OpaquePointer,
        sql: String,
        bindings: [Binding]
    ) throws -> [MemoryRecord] {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [MemoryRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(try decodeRecord(statement))
            case SQLITE_DONE: return result
            default: throw Self.error(from: database)
            }
        }
    }

    private func decodeRecord(_ statement: OpaquePointer) throws -> MemoryRecord {
        guard
            let id = UUID(uuidString: try Self.text(statement, 0)),
            let level = MemoryScopeLevel(rawValue: try Self.text(statement, 1)),
            let kind = MemoryKind(rawValue: try Self.text(statement, 7)),
            let sensitivity = AgentDataSensitivity(rawValue: try Self.text(statement, 9)),
            let status = MemoryStatus(rawValue: try Self.text(statement, 15))
        else {
            throw MemoryStoreError.serialization("a memory row contains an unknown enum or UUID")
        }
        let scope = MemoryScope(
            level: level,
            appID: try Self.text(statement, 2),
            userID: try Self.optionalIdentifier(statement, 3),
            agentID: try Self.optionalIdentifier(statement, 4),
            workspaceID: try Self.optionalIdentifier(statement, 5),
            sessionID: try Self.optionalIdentifier(statement, 6)
        )
        return MemoryRecord(
            id: id,
            scope: scope,
            kind: kind,
            content: try Self.text(statement, 8),
            sensitivity: sensitivity,
            provenance: try Self.decode(
                MemoryProvenance.self,
                from: Self.data(statement, 10)
            ),
            confidence: sqlite3_column_double(statement, 11),
            importance: sqlite3_column_double(statement, 12),
            expiresAt: sqlite3_column_type(statement, 13) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
            revision: Int(sqlite3_column_int64(statement, 14)),
            status: status,
            deduplicationKey: try Self.text(statement, 16),
            deduplicationKeyOrigin: MemoryDeduplicationKeyOrigin(
                rawValue: try Self.text(statement, 17)
            ) ?? .legacyUnknown,
            metadata: try Self.decode(
                [String: JSONValue].self,
                from: Self.data(statement, 18)
            ),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 19)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 20))
        )
    }

    private func decodeEvent(_ statement: OpaquePointer) throws -> MemoryEvent {
        guard
            let id = UUID(uuidString: try Self.text(statement, 0)),
            let recordID = UUID(uuidString: try Self.text(statement, 1)),
            let level = MemoryScopeLevel(rawValue: try Self.text(statement, 2)),
            let kind = MemoryEventKind(rawValue: try Self.text(statement, 8))
        else {
            throw MemoryStoreError.serialization("a memory event contains an unknown enum or UUID")
        }
        return MemoryEvent(
            id: id,
            recordID: recordID,
            scope: MemoryScope(
                level: level,
                appID: try Self.text(statement, 3),
                userID: try Self.optionalIdentifier(statement, 4),
                agentID: try Self.optionalIdentifier(statement, 5),
                workspaceID: try Self.optionalIdentifier(statement, 6),
                sessionID: try Self.optionalIdentifier(statement, 7)
            ),
            kind: kind,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            previousRevision: sqlite3_column_type(statement, 10) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(statement, 10)),
            revision: Int(sqlite3_column_int64(statement, 11)),
            detail: try Self.decode(
                [String: JSONValue].self,
                from: Self.data(statement, 12)
            )
        )
    }

    private func scopeBindings(_ scope: MemoryScope) -> [Binding] {
        [
            .text(scope.level.rawValue),
            .text(scope.appID),
            .text(scope.userID ?? ""),
            .text(scope.agentID ?? ""),
            .text(scope.workspaceID ?? ""),
            .text(scope.sessionID ?? ""),
        ]
    }

    private func sourceBindings(_ identity: MemorySourceIdentity) -> [Binding] {
        [.text(identity.identifier)] + scopeBindings(identity.scope)
    }

    private func sourceMappingBindings(_ identity: MemorySourceIdentity) -> [Binding] {
        [.text(identity.identifier)] + scopeBindings(identity.scope)
    }

    private func ownerBindings(appID: String, userID: String) throws -> [Binding] {
        let scope = try MemoryScope.user(appID: appID, userID: userID)
            .validatedForLegacySQLiteAccess()
        return [
            .text(MemoryScopeLevel.user.rawValue),
            .text(MemoryScopeLevel.agent.rawValue),
            .text(MemoryScopeLevel.workspace.rawValue),
            .text(MemoryScopeLevel.session.rawValue),
            .text(scope.appID),
            .text(scope.userID ?? ""),
        ]
    }

    private static let recordColumns = """
        id, scope_level, app_id, user_id, agent_id, workspace_id, session_id,
        kind, content, sensitivity, provenance_json, confidence, importance,
        expires_at, revision, status, deduplication_key, deduplication_key_origin, metadata_json,
        created_at, updated_at
        """

    private static func recordColumnsWithAlias(_ alias: String) -> String {
        recordColumns
            .split(separator: ",")
            .map { "\(alias).\($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: ", ")
    }

    private static func matches(
        _ record: MemoryRecord,
        proposal: MemoryProposal,
        status: MemoryStatus,
        at date: Date
    ) -> Bool {
        let proposedExpiry = proposal.timeToLive.map { date.addingTimeInterval($0) }
        return record.kind == proposal.kind
            && record.content == proposal.content
            && record.sensitivity == proposal.sensitivity
            && provenanceMatches(record.provenance, proposal.provenance)
            && record.confidence == proposal.confidence
            && record.importance == proposal.importance
            && optionalDatesMatch(record.expiresAt, proposedExpiry)
            && record.status == status
            && record.deduplicationKey == proposal.resolvedDeduplicationKey()
            && record.deduplicationKeyOrigin == proposal.resolvedDeduplicationKeyOrigin()
            && record.metadata == proposal.metadata
    }

    private static func optionalDatesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)):
            // SQLite REAL round trips may differ below a millisecond.
            abs(lhs.timeIntervalSince(rhs)) <= 0.001
        default: false
        }
    }

    private static func provenanceMatches(
        _ lhs: MemoryProvenance,
        _ rhs: MemoryProvenance
    ) -> Bool {
        lhs.source == rhs.source
            && lhs.sourceID == rhs.sourceID
            && lhs.actorID == rhs.actorID
            && lhs.metadata == rhs.metadata
            // JSON/SQLite REAL round trips may differ below a millisecond.
            && abs(lhs.capturedAt.timeIntervalSince(rhs.capturedAt)) <= 0.001
    }

    private func prepare(
        _ database: OpaquePointer,
        sql: String,
        bindings: [Binding]
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw Self.error(from: database)
        }
        do {
            for (offset, binding) in bindings.enumerated() {
                try Self.bind(binding, to: statement, at: Int32(offset + 1), database: database)
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func executePrepared(
        _ database: OpaquePointer,
        sql: String,
        bindings: [Binding]
    ) throws {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(from: database) }
    }

    private func executePreparedChanges(
        _ database: OpaquePointer,
        sql: String,
        bindings: [Binding]
    ) throws -> Int {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(from: database) }
        return Int(sqlite3_changes(database))
    }

    private func scalarInt(
        _ database: OpaquePointer,
        sql: String,
        bindings: [Binding]
    ) throws -> Int {
        let statement = try prepare(database, sql: sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.error(from: database) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func bind(
        _ value: Binding,
        to statement: OpaquePointer,
        at index: Int32,
        database: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result: Int32
        switch value {
        case .text(let value):
            let byteCount = value.utf8.count
            guard byteCount <= Int(Int32.max) else {
                throw MemoryStoreError.database("A text binding exceeds SQLite's byte limit.")
            }
            result = value.withCString { pointer in
                sqlite3_bind_text(
                    statement,
                    index,
                    pointer,
                    Int32(byteCount),
                    transient
                )
            }
        case .integer(let value):
            result = sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            result = sqlite3_bind_double(statement, index, value)
        case .blob(let data):
            guard data.count <= Int(Int32.max) else {
                throw MemoryStoreError.database("A blob binding exceeds SQLite's byte limit.")
            }
            result = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
            }
        case .null:
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw error(from: database) }
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw MemoryStoreError.database(message)
        }
    }

    private static func errorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }

    private static func scalarInt(_ database: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw error(from: database)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error(from: database) }
        return sqlite3_column_int64(statement, 0)
    }

    private static func scalarText(_ database: OpaquePointer, sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw error(from: database)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error(from: database) }
        return try text(statement, 0)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount > 0,
              let value = sqlite3_column_text(statement, column) else { return "" }
        guard let decoded = String(
            bytes: UnsafeBufferPointer(start: value, count: byteCount),
            encoding: .utf8
        ) else {
            throw MemoryStoreError.serialization("a SQLite text column contains invalid UTF-8")
        }
        return decoded
    }

    private static func optionalIdentifier(
        _ statement: OpaquePointer,
        _ column: Int32
    ) throws -> String? {
        let value = try text(statement, column)
        return value.isEmpty ? nil : value
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: pointer, count: count)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        } catch {
            throw MemoryStoreError.serialization(String(describing: error))
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(type, from: data)
        } catch {
            throw MemoryStoreError.serialization(String(describing: error))
        }
    }

    private static func error(from database: OpaquePointer) -> MemoryStoreError {
        MemoryStoreError.database(String(cString: sqlite3_errmsg(database)))
    }
}
