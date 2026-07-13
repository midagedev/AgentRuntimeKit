import AgentRuntimeMemory
import CAgentSQLite
import Foundation
import XCTest

final class MemorySourceReconciliationTests: XCTestCase {
    func testInMemoryReconciliationLifecycleKeepsStableMappings() async throws {
        try await assertReconciliationLifecycle(store: InMemoryMemoryStore())
    }

    func testInMemoryPurgesThreeThousandSourceRecordsInOneBatch() async throws {
        let store = InMemoryMemoryStore()
        let ordinary = try await store.upsert(sourceProposal(
            scope: sourceScope,
            sourceRecordID: "ordinary",
            content: "ordinary memory must survive source cleanup",
            deduplicationKey: "ordinary-key"
        ))
        let recordCount = 3_000
        let snapshot = sourceSnapshot(records: (0..<recordCount).map {
            ("fragment-\($0)", "content \($0)", "dedupe-\($0)")
        })
        let created = try await store.reconcileSourceSnapshot(
            snapshot,
            expectedGeneration: 0,
            missingPolicy: .archive,
            at: sourceDate
        )
        XCTAssertEqual(created.created, recordCount)

        let clock = ContinuousClock()
        let start = clock.now
        let purged = try await store.reconcileSourceSnapshot(
            sourceSnapshot(records: []),
            expectedGeneration: 1,
            missingPolicy: .purge,
            at: sourceDate.addingTimeInterval(1)
        )
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(purged.purged, recordCount)
        XCTAssertEqual(purged.generation, 2)
        XCTAssertLessThan(
            elapsed,
            .seconds(5),
            "Batch purge took \(elapsed); this path must remain linear in source size"
        )
        let remainingRecords = try await ownedRecords(store: store)
        XCTAssertEqual(remainingRecords.map(\.id), [ordinary.id])
        let remainingEvents = try await store.events(scope: sourceScope)
        XCTAssertEqual(remainingEvents.map(\.recordID), [ordinary.id])

        let recreated = try await store.reconcileSourceSnapshot(
            sourceSnapshot(records: [
                ("fragment-0", "content 0", "dedupe-0"),
                ("fragment-2999", "content 2999", "dedupe-2999"),
            ]),
            expectedGeneration: 2,
            missingPolicy: .purge,
            at: sourceDate.addingTimeInterval(2)
        )
        XCTAssertEqual(recreated.created, 2)
        let recordsAfterRecreation = try await ownedRecords(store: store)
        XCTAssertEqual(recordsAfterRecreation.count, 3)
    }

    func testSQLiteReconciliationLifecycleKeepsStableMappings() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        try await assertReconciliationLifecycle(store: store)
    }

    func testSQLitePurgesThreeThousandSourceRecordsInOneBatch() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        let ordinary = try await store.upsert(sourceProposal(
            scope: sourceScope,
            sourceRecordID: "ordinary-sqlite",
            content: "ordinary SQLite memory must survive source cleanup",
            deduplicationKey: "ordinary-sqlite-key"
        ))
        let recordCount = 3_000
        let snapshot = sourceSnapshot(records: (0..<recordCount).map {
            ("sqlite-fragment-\($0)", "SQLite content \($0)", "sqlite-dedupe-\($0)")
        })
        let created = try await store.reconcileSourceSnapshot(
            snapshot,
            expectedGeneration: 0,
            missingPolicy: .archive,
            at: sourceDate
        )
        XCTAssertEqual(created.created, recordCount)

        let clock = ContinuousClock()
        let start = clock.now
        let purged = try await store.reconcileSourceSnapshot(
            sourceSnapshot(records: []),
            expectedGeneration: 1,
            missingPolicy: .purge,
            at: sourceDate.addingTimeInterval(1)
        )
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(purged.purged, recordCount)
        XCTAssertEqual(purged.generation, 2)
        XCTAssertLessThan(
            elapsed,
            .seconds(10),
            "SQLite batch purge took \(elapsed); this path must not regress to per-record scans"
        )
        let remainingRecords = try await ownedRecords(store: store)
        XCTAssertEqual(remainingRecords.map(\.id), [ordinary.id])
        let remainingEvents = try await store.events(scope: sourceScope)
        XCTAssertEqual(remainingEvents.map(\.recordID), [ordinary.id])
        let committedState = try await store.sourceState(
            identifier: snapshot.identifier,
            scope: snapshot.scope
        )
        XCTAssertEqual(committedState?.generation, 2)

        try await store.close()
        let reopened = try SQLiteMemoryStore(url: temporary.databaseURL)
        let reopenedState = try await reopened.sourceState(
            identifier: snapshot.identifier,
            scope: snapshot.scope
        )
        XCTAssertEqual(reopenedState?.generation, 2)
        let reopenedRecords = try await ownedRecords(store: reopened)
        XCTAssertEqual(reopenedRecords.map(\.id), [ordinary.id])

        let recreated = try await reopened.reconcileSourceSnapshot(
            sourceSnapshot(records: [
                ("sqlite-fragment-0", "SQLite content 0", "sqlite-dedupe-0"),
                ("sqlite-fragment-2999", "SQLite content 2999", "sqlite-dedupe-2999"),
            ]),
            expectedGeneration: 2,
            missingPolicy: .purge,
            at: sourceDate.addingTimeInterval(2)
        )
        XCTAssertEqual(recreated.created, 2)
        let recreatedRecords = try await ownedRecords(store: reopened)
        XCTAssertEqual(recreatedRecords.count, 3)
    }

    func testInvalidSnapshotsAreRejectedBeforeInMemoryMutation() async throws {
        try await assertInvalidSnapshotsDoNotMutate(store: InMemoryMemoryStore())
    }

    func testInvalidSnapshotsAreRejectedBeforeSQLiteMutation() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        try await assertInvalidSnapshotsDoNotMutate(store: store)
    }

    func testInMemoryUpdatesDeduplicationKeyOnlyAndAtomicallySwapsKeys() async throws {
        try await assertDeduplicationKeyEvolution(store: InMemoryMemoryStore())
    }

    func testSQLiteUpdatesDeduplicationKeyOnlyAndAtomicallySwapsKeys() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        try await assertDeduplicationKeyEvolution(store: store)
    }

    func testInMemoryRejectsDeduplicationKeyOnlyCollisionWithoutMutation() async throws {
        try await assertDeduplicationKeyCollisionRollsBack(store: InMemoryMemoryStore())
    }

    func testSQLiteRejectsDeduplicationKeyOnlyCollisionWithoutMutation() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        try await assertDeduplicationKeyCollisionRollsBack(store: store)
    }

    func testInMemoryCASAllowsExactlyOneConcurrentScanner() async throws {
        let store = InMemoryMemoryStore()
        let snapshot = sourceSnapshot(records: [("fragment", "value", "key")])
        let outcomes = await concurrentCASOutcomes(
            stores: [store, store],
            snapshot: snapshot
        )
        XCTAssertEqual(outcomes.filter { $0 == .committed }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .conflict }.count, 1)
        let state = try await store.sourceState(
            identifier: snapshot.identifier,
            scope: snapshot.scope
        )
        XCTAssertEqual(state?.generation, 1)
    }

    func testSQLiteCASAcrossConnectionsAllowsExactlyOneConcurrentScanner() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let first = try SQLiteMemoryStore(url: temporary.databaseURL)
        let second = try SQLiteMemoryStore(url: temporary.databaseURL)
        let snapshot = sourceSnapshot(records: [("fragment", "value", "key")])
        let outcomes = await concurrentCASOutcomes(
            stores: [first, second],
            snapshot: snapshot
        )
        XCTAssertEqual(outcomes.filter { $0 == .committed }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .conflict }.count, 1)
        let state = try await first.sourceState(
            identifier: snapshot.identifier,
            scope: snapshot.scope
        )
        XCTAssertEqual(state?.generation, 1)
    }

    func testSQLiteMappingAndGenerationSurviveReopen() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let scope = sourceScope
        let initial = sourceSnapshot(records: [("fragment", "old", "old-key")])
        let first = try SQLiteMemoryStore(url: temporary.databaseURL)
        _ = try await first.reconcileSourceSnapshot(
            initial,
            expectedGeneration: 0,
            missingPolicy: .archive
        )
        let originalRecords = try await first.recordsOwned(
            appID: scope.appID,
            userID: try XCTUnwrap(scope.userID)
        )
        let original = try XCTUnwrap(originalRecords.first)
        try await first.close()

        let reopened = try SQLiteMemoryStore(url: temporary.databaseURL)
        let reopenedState = try await reopened.sourceState(
            identifier: initial.identifier,
            scope: scope
        )
        XCTAssertEqual(reopenedState?.generation, 1)
        let changed = sourceSnapshot(records: [("fragment", "new", "new-key")])
        let report = try await reopened.reconcileSourceSnapshot(
            changed,
            expectedGeneration: 1,
            missingPolicy: .archive
        )
        XCTAssertEqual(report.updated, 1)
        let records = try await reopened.recordsOwned(
            appID: scope.appID,
            userID: try XCTUnwrap(scope.userID)
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, original.id)
        XCTAssertEqual(records[0].content, "new")
        XCTAssertEqual(records[0].revision, 2)
    }

    func testSQLiteRejectsNULTerminatedSourceIdentitiesBeforeBinding() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)

        for identifier in ["source\0A", "source\0B"] {
            do {
                _ = try await store.sourceState(identifier: identifier, scope: sourceScope)
                XCTFail("Expected embedded NUL to be rejected before SQLite binding")
            } catch let error as MemorySourceReconciliationError {
                guard case .invalidSnapshot = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            let snapshot = MemorySourceSnapshot(
                identifier: identifier,
                scope: sourceScope,
                records: [sourceRecord("record", "content", "key-\(identifier.count)")]
            )
            do {
                _ = try await store.reconcileSourceSnapshot(
                    snapshot,
                    expectedGeneration: 0,
                    missingPolicy: .archive
                )
                XCTFail("Expected embedded NUL to be rejected before SQLite binding")
            } catch let error as MemorySourceReconciliationError {
                guard case .invalidSnapshot = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        let records = try await store.recordsOwned(
            appID: sourceScope.appID,
            userID: try XCTUnwrap(sourceScope.userID)
        )
        XCTAssertTrue(records.isEmpty)
    }

    func testSQLiteReconcilesMoreThanTwoThousandRecordsWithoutVariableLimits() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        let count = 2_101
        let records = (0..<count).map {
            ("fragment-\($0)", "content \($0)", "dedupe-\($0)")
        }
        let snapshot = sourceSnapshot(records: records)

        let created = try await store.reconcileSourceSnapshot(
            snapshot,
            expectedGeneration: 0,
            missingPolicy: .archive
        )
        XCTAssertEqual(created.created, count)
        XCTAssertEqual(created.generation, 1)

        let unchanged = try await store.reconcileSourceSnapshot(
            snapshot,
            expectedGeneration: 1,
            missingPolicy: .archive
        )
        XCTAssertEqual(unchanged.unchanged, count)
        XCTAssertEqual(unchanged.generation, 2)
        let persisted = try await store.recordsOwned(
            appID: sourceScope.appID,
            userID: try XCTUnwrap(sourceScope.userID)
        )
        XCTAssertEqual(persisted.count, count)
    }

    func testSQLiteRollsBackSourceRecordEventAndGenerationAfterMidBatchFailure() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        try installAbortTrigger(databaseURL: temporary.databaseURL)
        let snapshot = sourceSnapshot(records: [
            ("first", "will roll back", "first-key"),
            ("second", "abort-this-source-write", "second-key"),
        ])

        do {
            _ = try await store.reconcileSourceSnapshot(
                snapshot,
                expectedGeneration: 0,
                missingPolicy: .archive
            )
            XCTFail("The injected SQLite failure must abort the whole generation")
        } catch let error as MemoryStoreError {
            guard case .database(let reason) = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
            XCTAssertTrue(reason.contains("injected source reconciliation failure"))
        }

        let state = try await store.sourceState(
            identifier: snapshot.identifier,
            scope: snapshot.scope
        )
        XCTAssertNil(state)
        let records = try await store.recordsOwned(
            appID: sourceScope.appID,
            userID: try XCTUnwrap(sourceScope.userID)
        )
        XCTAssertTrue(records.isEmpty)
        let events = try await store.events(scope: sourceScope)
        XCTAssertTrue(events.isEmpty)
    }

    func testSQLitePurgeSnapshotCanRetryPhysicalCleanupAfterGenerationCommitted() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(
            url: temporary.databaseURL,
            busyTimeoutMilliseconds: 25
        )
        let initial = sourceSnapshot(records: [("fragment", "private value", "key")])
        _ = try await store.reconcileSourceSnapshot(
            initial,
            expectedGeneration: 0,
            missingPolicy: .archive
        )

        var reader: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                temporary.databaseURL.path,
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
            _ = try await store.reconcileSourceSnapshot(
                sourceSnapshot(records: []),
                expectedGeneration: 1,
                missingPolicy: .purge
            )
            XCTFail("The reader should block physical cleanup after the generation commits")
        } catch let error as MemoryPurgeCleanupError {
            XCTAssertEqual(error.committedResult.recordsPurged, 1)
        }
        let committed = try await store.sourceState(
            identifier: initial.identifier,
            scope: initial.scope
        )
        XCTAssertEqual(committed?.generation, 2)
        try await store.close()
        try executeSQLite(readerDatabase, sql: "COMMIT")

        // Reopening proves the pending cleanup is durable rather than an actor-
        // local optimization flag.
        let reopened = try SQLiteMemoryStore(
            url: temporary.databaseURL,
            busyTimeoutMilliseconds: 25
        )
        let retry = try await reopened.reconcileSourceSnapshot(
            sourceSnapshot(records: []),
            expectedGeneration: 2,
            missingPolicy: .purge
        )
        XCTAssertEqual(retry.purged, 0)
        XCTAssertEqual(retry.generation, 3)

        // Once the durable pending epoch is completed, a later no-op purge
        // must not attempt VACUUM. The same reader would make VACUUM fail.
        try executeSQLite(
            readerDatabase,
            sql: "BEGIN; SELECT COUNT(*) FROM memory_records;"
        )
        let cleanNoOp = try await reopened.reconcileSourceSnapshot(
            sourceSnapshot(records: []),
            expectedGeneration: 3,
            missingPolicy: .purge
        )
        XCTAssertEqual(cleanNoOp.purged, 0)
        XCTAssertEqual(cleanNoOp.generation, 4)
        try executeSQLite(readerDatabase, sql: "COMMIT")
    }

    func testSQLiteScopePurgeAlsoErasesSourceState() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        let snapshot = sourceSnapshot(records: [("fragment", "value", "key")])
        _ = try await store.reconcileSourceSnapshot(
            snapshot,
            expectedGeneration: 0,
            missingPolicy: .archive
        )

        _ = try await store.purge(scopes: [snapshot.scope])
        let state = try await store.sourceState(
            identifier: snapshot.identifier,
            scope: snapshot.scope
        )
        XCTAssertNil(state)
    }

    func testSQLiteSourceIdentityIncludesEveryExactScopeField() async throws {
        let temporary = try SourceReconciliationTemporaryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.databaseURL)
        let firstScope = MemoryScope.workspace(
            appID: "source-app",
            workspaceID: "workspace",
            userID: "first-user",
            agentID: "agent"
        )
        let secondScope = MemoryScope.workspace(
            appID: "source-app",
            workspaceID: "workspace",
            userID: "second-user",
            agentID: "agent"
        )
        let first = MemorySourceSnapshot(
            identifier: "same-source",
            scope: firstScope,
            records: [MemorySourceSnapshotRecord(
                sourceRecordID: "same-record",
                proposal: sourceProposal(
                    scope: firstScope,
                    sourceRecordID: "same-record",
                    content: "first",
                    deduplicationKey: "same-key"
                )
            )]
        )
        let second = MemorySourceSnapshot(
            identifier: "same-source",
            scope: secondScope,
            records: [MemorySourceSnapshotRecord(
                sourceRecordID: "same-record",
                proposal: sourceProposal(
                    scope: secondScope,
                    sourceRecordID: "same-record",
                    content: "second",
                    deduplicationKey: "same-key"
                )
            )]
        )

        _ = try await store.reconcileSourceSnapshot(
            first,
            expectedGeneration: 0,
            missingPolicy: .archive
        )
        _ = try await store.reconcileSourceSnapshot(
            second,
            expectedGeneration: 0,
            missingPolicy: .archive
        )
        let firstState = try await store.sourceState(identifier: "same-source", scope: firstScope)
        let secondState = try await store.sourceState(identifier: "same-source", scope: secondScope)
        XCTAssertEqual(firstState?.generation, 1)
        XCTAssertEqual(secondState?.generation, 1)
        let firstRecords = try await store.recordsOwned(
            appID: "source-app",
            userID: "first-user"
        )
        let secondRecords = try await store.recordsOwned(
            appID: "source-app",
            userID: "second-user"
        )
        XCTAssertEqual(firstRecords.count, 1)
        XCTAssertEqual(secondRecords.count, 1)
    }

    private func assertReconciliationLifecycle(
        store: any MemorySourceReconciliationStore
    ) async throws {
        let scope = sourceScope
        let firstSnapshot = sourceSnapshot(records: [
            ("a", "alpha", "alpha-key"),
            ("b", "beta", "beta-key"),
        ])
        let first = try await store.reconcileSourceSnapshot(
            firstSnapshot,
            expectedGeneration: 0,
            missingPolicy: .archive,
            at: sourceDate
        )
        XCTAssertEqual(first.created, 2)
        XCTAssertEqual(first.generation, 1)
        var records = try await ownedRecords(store: store)
        XCTAssertEqual(records.count, 2)
        let alphaID = try XCTUnwrap(records.first { $0.content == "alpha" }?.id)
        let betaID = try XCTUnwrap(records.first { $0.content == "beta" }?.id)

        let changed = sourceSnapshot(records: [("a", "alpha changed", "alpha-key-v2")])
        let second = try await store.reconcileSourceSnapshot(
            changed,
            expectedGeneration: 1,
            missingPolicy: .archive,
            at: sourceDate.addingTimeInterval(1)
        )
        XCTAssertEqual(second.updated, 1)
        XCTAssertEqual(second.archived, 1)
        XCTAssertEqual(second.generation, 2)
        records = try await ownedRecords(store: store)
        XCTAssertEqual(records.first { $0.id == alphaID }?.content, "alpha changed")
        XCTAssertEqual(records.first { $0.id == alphaID }?.status, .active)
        XCTAssertEqual(records.first { $0.id == betaID }?.status, .archived)

        let noChange = try await store.reconcileSourceSnapshot(
            changed,
            expectedGeneration: 2,
            missingPolicy: .archive,
            at: sourceDate.addingTimeInterval(2)
        )
        XCTAssertEqual(noChange.unchanged, 2)
        XCTAssertEqual(noChange.generation, 3)

        let restored = sourceSnapshot(records: [
            ("a", "alpha changed", "alpha-key-v2"),
            ("b", "beta", "beta-key"),
        ])
        let fourth = try await store.reconcileSourceSnapshot(
            restored,
            expectedGeneration: 3,
            missingPolicy: .archive,
            at: sourceDate.addingTimeInterval(3)
        )
        XCTAssertEqual(fourth.unchanged, 1)
        XCTAssertEqual(fourth.updated, 1)
        records = try await ownedRecords(store: store)
        XCTAssertEqual(records.first { $0.content == "beta" }?.id, betaID)
        XCTAssertEqual(records.first { $0.id == betaID }?.status, .active)

        let purged = try await store.reconcileSourceSnapshot(
            sourceSnapshot(records: []),
            expectedGeneration: 4,
            missingPolicy: .purge,
            at: sourceDate.addingTimeInterval(4)
        )
        XCTAssertEqual(purged.purged, 2)
        XCTAssertEqual(purged.generation, 5)
        let remaining = try await ownedRecords(store: store)
        XCTAssertTrue(remaining.isEmpty)
        let remainingEvents = try await store.events(scope: scope)
        XCTAssertTrue(remainingEvents.isEmpty)
    }

    private func assertDeduplicationKeyEvolution(
        store: any MemorySourceReconciliationStore
    ) async throws {
        let initial = sourceSnapshot(records: [
            ("a", "alpha", "alpha-key"),
            ("b", "beta", "beta-key"),
        ])
        _ = try await store.reconcileSourceSnapshot(
            initial,
            expectedGeneration: 0,
            missingPolicy: .archive,
            at: sourceDate
        )
        let original = try await ownedRecords(store: store)
        let alpha = try XCTUnwrap(original.first { $0.content == "alpha" })
        let beta = try XCTUnwrap(original.first { $0.content == "beta" })

        let keyOnly = sourceSnapshot(records: [
            ("a", "alpha", "alpha-key-v2"),
            ("b", "beta", "beta-key"),
        ])
        let keyOnlyReport = try await store.reconcileSourceSnapshot(
            keyOnly,
            expectedGeneration: 1,
            missingPolicy: .archive,
            at: sourceDate.addingTimeInterval(1)
        )
        XCTAssertEqual(keyOnlyReport.updated, 1)
        XCTAssertEqual(keyOnlyReport.unchanged, 1)
        var afterKeyOnly = try await ownedRecords(store: store)
        let updatedAlpha = try XCTUnwrap(afterKeyOnly.first { $0.id == alpha.id })
        XCTAssertEqual(updatedAlpha.content, alpha.content)
        XCTAssertEqual(updatedAlpha.revision, alpha.revision + 1)
        XCTAssertNotEqual(updatedAlpha.deduplicationKey, alpha.deduplicationKey)
        XCTAssertEqual(afterKeyOnly.first { $0.id == beta.id }?.revision, beta.revision)

        // Both desired keys are occupied at the start of this generation. The
        // source record IDs, not the keys, remain the durable mapping identity.
        let swapped = sourceSnapshot(records: [
            ("a", "alpha", "beta-key"),
            ("b", "beta", "alpha-key-v2"),
        ])
        let swapReport = try await store.reconcileSourceSnapshot(
            swapped,
            expectedGeneration: 2,
            missingPolicy: .archive,
            at: sourceDate.addingTimeInterval(2)
        )
        XCTAssertEqual(swapReport.updated, 2)
        afterKeyOnly = try await ownedRecords(store: store)
        let swappedAlpha = try XCTUnwrap(afterKeyOnly.first { $0.id == alpha.id })
        let swappedBeta = try XCTUnwrap(afterKeyOnly.first { $0.id == beta.id })
        XCTAssertEqual(swappedAlpha.content, "alpha")
        XCTAssertEqual(swappedBeta.content, "beta")
        XCTAssertEqual(swappedAlpha.deduplicationKey, beta.deduplicationKey)
        XCTAssertEqual(swappedBeta.deduplicationKey, updatedAlpha.deduplicationKey)
        XCTAssertEqual(swappedAlpha.revision, alpha.revision + 2)
        XCTAssertEqual(swappedBeta.revision, beta.revision + 1)
    }

    private func assertDeduplicationKeyCollisionRollsBack(
        store: any MemorySourceReconciliationStore
    ) async throws {
        let baseline = sourceSnapshot(records: [("stable", "same content", "source-key")])
        _ = try await store.reconcileSourceSnapshot(
            baseline,
            expectedGeneration: 0,
            missingPolicy: .archive,
            at: sourceDate
        )
        let baselineRecords = try await ownedRecords(store: store)
        let original = try XCTUnwrap(baselineRecords.first {
            $0.content == "same content"
        })
        let occupied = try await store.upsert(sourceProposal(
            scope: sourceScope,
            sourceRecordID: "ordinary",
            content: "ordinary record",
            deduplicationKey: "occupied-key"
        ))
        let collision = sourceSnapshot(records: [
            ("stable", "same content", "occupied-key"),
        ])

        do {
            _ = try await store.reconcileSourceSnapshot(
                collision,
                expectedGeneration: 1,
                missingPolicy: .archive,
                at: sourceDate.addingTimeInterval(1)
            )
            XCTFail("A key-only update must not claim an ordinary record's identity")
        } catch let error as MemorySourceReconciliationError {
            XCTAssertEqual(error, .recordOwnershipConflict(occupied.id))
        }
        let state = try await store.sourceState(
            identifier: baseline.identifier,
            scope: baseline.scope
        )
        XCTAssertEqual(state?.generation, 1)
        let preserved = try await store.fetch(
            id: original.id,
            scope: original.scope,
            includeExpired: true
        )
        XCTAssertEqual(preserved, original)
    }

    private func assertInvalidSnapshotsDoNotMutate(
        store: any MemorySourceReconciliationStore
    ) async throws {
        let baseline = sourceSnapshot(records: [("stable", "original", "stable-key")])
        _ = try await store.reconcileSourceSnapshot(
            baseline,
            expectedGeneration: 0,
            missingPolicy: .archive,
            at: sourceDate
        )
        let baselineRecords = try await ownedRecords(store: store)
        let original = try XCTUnwrap(baselineRecords.first)
        let otherScope = MemoryScope.user(appID: "source-app", userID: "other-user")
        let invalidSnapshots = [
            MemorySourceSnapshot(
                identifier: baseline.identifier,
                scope: baseline.scope,
                records: [
                    sourceRecord("stable", "changed", "changed-key"),
                    MemorySourceSnapshotRecord(
                        sourceRecordID: "missing-key",
                        proposal: MemoryProposal(
                            scope: baseline.scope,
                            kind: .fact,
                            content: "invalid",
                            provenance: sourceProvenance(id: "missing-key")
                        )
                    ),
                ]
            ),
            MemorySourceSnapshot(
                identifier: baseline.identifier,
                scope: baseline.scope,
                records: [
                    sourceRecord("duplicate", "one", "one-key"),
                    sourceRecord("duplicate", "two", "two-key"),
                ]
            ),
            MemorySourceSnapshot(
                identifier: baseline.identifier,
                scope: baseline.scope,
                records: [MemorySourceSnapshotRecord(
                    sourceRecordID: "wrong-scope",
                    proposal: sourceProposal(
                        scope: otherScope,
                        sourceRecordID: "wrong-scope",
                        content: "wrong",
                        deduplicationKey: "wrong-key"
                    )
                )]
            ),
            MemorySourceSnapshot(
                identifier: baseline.identifier,
                scope: baseline.scope,
                records: [
                    sourceRecord("one", "one", "same-key"),
                    sourceRecord("two", "two", "same-key"),
                ]
            ),
            MemorySourceSnapshot(
                identifier: baseline.identifier,
                scope: baseline.scope,
                records: [sourceRecord(
                    String(repeating: "x", count: 4_097),
                    "large",
                    "large-key"
                )]
            ),
            MemorySourceSnapshot(
                identifier: "source\0identity",
                scope: baseline.scope,
                records: [sourceRecord("record", "content", "control-source-key")]
            ),
            MemorySourceSnapshot(
                identifier: baseline.identifier,
                scope: baseline.scope,
                records: [sourceRecord("record\0identity", "content", "control-record-key")]
            ),
            MemorySourceSnapshot(
                identifier: "source-e\u{301}",
                scope: baseline.scope,
                records: [sourceRecord("record", "content", "normalized-source-key")]
            ),
            MemorySourceSnapshot(
                identifier: baseline.identifier,
                scope: baseline.scope,
                records: [sourceRecord("record-e\u{301}", "content", "normalized-record-key")]
            ),
        ]

        for invalid in invalidSnapshots {
            do {
                _ = try await store.reconcileSourceSnapshot(
                    invalid,
                    expectedGeneration: 1,
                    missingPolicy: .purge,
                    at: sourceDate.addingTimeInterval(1)
                )
                XCTFail("Invalid source snapshot must fail before mutation")
            } catch is MemorySourceReconciliationError {
                // Expected.
            }
            let state = try await store.sourceState(
                identifier: baseline.identifier,
                scope: baseline.scope
            )
            XCTAssertEqual(state?.generation, 1)
            let records = try await ownedRecords(store: store)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].id, original.id)
            XCTAssertEqual(records[0].content, original.content)
            XCTAssertEqual(records[0].revision, original.revision)
        }

        let occupied = try await store.upsert(sourceProposal(
            scope: baseline.scope,
            sourceRecordID: "ordinary-record",
            content: "ordinary memory",
            deduplicationKey: "occupied-key"
        ))
        let ownershipCollision = MemorySourceSnapshot(
            identifier: baseline.identifier,
            scope: baseline.scope,
            records: [
                sourceRecord("stable", "must roll back", "changed-key"),
                sourceRecord("claim", "must not claim", "occupied-key"),
            ]
        )
        do {
            _ = try await store.reconcileSourceSnapshot(
                ownershipCollision,
                expectedGeneration: 1,
                missingPolicy: .archive,
                at: sourceDate.addingTimeInterval(1)
            )
            XCTFail("A source must not claim an ordinary memory's deduplication identity")
        } catch let error as MemorySourceReconciliationError {
            XCTAssertEqual(error, .recordOwnershipConflict(occupied.id))
        }
        let afterCollisionState = try await store.sourceState(
            identifier: baseline.identifier,
            scope: baseline.scope
        )
        XCTAssertEqual(afterCollisionState?.generation, 1)
        let afterCollision = try await ownedRecords(store: store)
        XCTAssertEqual(afterCollision.first { $0.id == original.id }?.content, original.content)
        XCTAssertEqual(afterCollision.first { $0.id == original.id }?.revision, original.revision)

        do {
            _ = try await store.reconcileSourceSnapshot(
                baseline,
                expectedGeneration: 0,
                missingPolicy: .archive
            )
            XCTFail("A stale generation must not commit")
        } catch let error as MemorySourceReconciliationError {
            XCTAssertEqual(error, .generationConflict(expected: 0, actual: 1))
        }
    }

    private func ownedRecords(
        store: any MemoryStore
    ) async throws -> [MemoryRecord] {
        try await store.recordsOwned(
            appID: sourceScope.appID,
            userID: try XCTUnwrap(sourceScope.userID)
        )
    }
}

private enum CASOutcome: Sendable, Equatable {
    case committed
    case conflict
    case unexpected
}

private func concurrentCASOutcomes(
    stores: [any MemorySourceReconciliationStore],
    snapshot: MemorySourceSnapshot
) async -> [CASOutcome] {
    await withTaskGroup(of: CASOutcome.self) { group in
        for store in stores {
            group.addTask {
                do {
                    _ = try await store.reconcileSourceSnapshot(
                        snapshot,
                        expectedGeneration: 0,
                        missingPolicy: .archive,
                        at: sourceDate
                    )
                    return .committed
                } catch MemorySourceReconciliationError.generationConflict {
                    return .conflict
                } catch {
                    return .unexpected
                }
            }
        }
        var results: [CASOutcome] = []
        for await result in group { results.append(result) }
        return results
    }
}

private let sourceScope = MemoryScope.user(appID: "source-app", userID: "source-user")
private let sourceDate = Date(timeIntervalSince1970: 10_000_000)

private func sourceSnapshot(
    records: [(String, String, String)]
) -> MemorySourceSnapshot {
    MemorySourceSnapshot(
        identifier: "workspace-files",
        scope: sourceScope,
        records: records.map { sourceRecord($0.0, $0.1, $0.2) }
    )
}

private func sourceRecord(
    _ sourceRecordID: String,
    _ content: String,
    _ deduplicationKey: String
) -> MemorySourceSnapshotRecord {
    MemorySourceSnapshotRecord(
        sourceRecordID: sourceRecordID,
        proposal: sourceProposal(
            scope: sourceScope,
            sourceRecordID: sourceRecordID,
            content: content,
            deduplicationKey: deduplicationKey
        )
    )
}

private func sourceProposal(
    scope: MemoryScope,
    sourceRecordID: String,
    content: String,
    deduplicationKey: String
) -> MemoryProposal {
    MemoryProposal(
        scope: scope,
        kind: .fact,
        content: content,
        provenance: sourceProvenance(id: sourceRecordID),
        deduplicationKey: deduplicationKey,
        metadata: ["source_record_id": .string(sourceRecordID)]
    )
}

private func sourceProvenance(id: String) -> MemoryProvenance {
    MemoryProvenance(
        source: "source-reconciliation-test",
        sourceID: id,
        capturedAt: sourceDate
    )
}

private final class SourceReconciliationTemporaryDirectory {
    let url: URL
    var databaseURL: URL { url.appendingPathComponent("memory.sqlite") }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemorySourceReconciliationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func installAbortTrigger(databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw MemoryStoreError.database("could not open fault-injection connection")
    }
    defer { sqlite3_close_v2(database) }
    let sql = """
        CREATE TRIGGER abort_source_reconciliation_test
        BEFORE INSERT ON memory_records
        WHEN NEW.content = 'abort-this-source-write'
        BEGIN
            SELECT RAISE(ABORT, 'injected source reconciliation failure');
        END;
        """
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
        let description = message.map { String(cString: $0) } ?? "could not install trigger"
        sqlite3_free(message)
        throw MemoryStoreError.database(description)
    }
}

private func executeSQLite(_ database: OpaquePointer, sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
        let description = message.map { String(cString: $0) }
            ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(message)
        throw MemoryStoreError.database(description)
    }
}
