import AgentRuntimeMemory
import Foundation
import XCTest

/// This file deliberately uses a normal import instead of `@testable import`.
/// It is a compile-time fixture for types downstream `MemoryStore` conformers
/// must be able to construct without relying on package internals.
final class MemoryStorePublicAPITests: XCTestCase {
    func testDownstreamStoreCanConstructEveryCompositeReturnValue() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let record = MemoryRecord(
            id: UUID(),
            scope: .user(appID: "community-store", userID: "user"),
            kind: .fact,
            content: "public initializer",
            sensitivity: .privateData,
            provenance: MemoryProvenance(
                source: "community-store",
                capturedAt: timestamp
            ),
            confidence: 1,
            importance: 0.5,
            expiresAt: nil,
            revision: 1,
            status: .active,
            deduplicationKey: "store-owned-key",
            deduplicationKeyOrigin: .explicit,
            metadata: [:],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let hit = MemorySearchHit(
            record: record,
            relevance: 0.75,
            contextText: record.content,
            isTruncated: false
        )
        let retrieval = MemoryRetrievalResult(
            hits: [hit],
            mode: .lexical,
            usedCharacterCount: record.content.count,
            exhaustedBudget: false
        )
        let sourceState = MemorySourceState(
            identifier: "community-source",
            scope: record.scope,
            generation: 1
        )
        let sourceRecord = MemorySourceSnapshotRecord(
            sourceRecordID: "note.md#0",
            proposal: MemoryProposal(
                scope: record.scope,
                kind: record.kind,
                content: record.content,
                provenance: record.provenance,
                deduplicationKey: "note.md#0"
            )
        )
        let snapshot = MemorySourceSnapshot(
            identifier: sourceState.identifier,
            scope: sourceState.scope,
            records: [sourceRecord]
        )
        let report = MemorySourceReconciliationReport(
            identifier: snapshot.identifier,
            scope: snapshot.scope,
            previousGeneration: 0,
            generation: 1,
            created: 1
        )
        let legacySummary = SQLiteLegacyScopeSummary(
            scope: record.scope,
            recordCount: 1,
            eventCount: 1
        )

        XCTAssertEqual(retrieval.records, [record])
        XCTAssertEqual(sourceState.generation, report.generation)
        XCTAssertEqual(snapshot.records.count, report.created)
        XCTAssertEqual(legacySummary.scope, record.scope)

        let store: any MemorySourceReconciliationStore = PublicSurfaceMemoryStore(
            record: record,
            retrieval: retrieval
        )
        let fetched = try await store.fetch(id: record.id, scope: record.scope)
        let retrieved = try await store.retrieve(MemoryQuery(scopes: [record.scope]))
        let fetchedSourceState = try await store.sourceState(
            identifier: snapshot.identifier,
            scope: snapshot.scope
        )
        XCTAssertEqual(fetched, record)
        XCTAssertEqual(retrieved, retrieval)
        XCTAssertEqual(fetchedSourceState, MemorySourceState(
            identifier: snapshot.identifier,
            scope: snapshot.scope,
            generation: 0
        ))
    }
}

private actor PublicSurfaceMemoryStore: MemorySourceReconciliationStore {
    private let record: MemoryRecord
    private let retrieval: MemoryRetrievalResult

    init(record: MemoryRecord, retrieval: MemoryRetrievalResult) {
        self.record = record
        self.retrieval = retrieval
    }

    func upsert(
        _ proposal: MemoryProposal,
        status: MemoryStatus,
        expectedRevision: Int?,
        at date: Date
    ) -> MemoryRecord {
        record
    }

    func fetch(
        id: UUID,
        scope: MemoryScope,
        includeExpired: Bool,
        at date: Date
    ) -> MemoryRecord? {
        id == record.id && scope == record.scope ? record : nil
    }

    func update(
        id: UUID,
        scope: MemoryScope,
        patch: MemoryPatch,
        expectedRevision: Int,
        at date: Date
    ) -> MemoryRecord {
        record
    }

    func delete(
        id: UUID,
        scope: MemoryScope,
        expectedRevision: Int,
        at date: Date
    ) {}

    func retrieve(_ query: MemoryQuery) -> MemoryRetrievalResult {
        retrieval
    }

    func events(
        scope: MemoryScope,
        recordID: UUID?,
        limit: Int
    ) -> [MemoryEvent] {
        []
    }

    func sourceState(
        identifier: String,
        scope: MemoryScope
    ) -> MemorySourceState? {
        MemorySourceState(identifier: identifier, scope: scope, generation: 0)
    }

    func reconcileSourceSnapshot(
        _ snapshot: MemorySourceSnapshot,
        expectedGeneration: Int,
        missingPolicy: MemorySourceMissingPolicy,
        at date: Date
    ) -> MemorySourceReconciliationReport {
        MemorySourceReconciliationReport(
            identifier: snapshot.identifier,
            scope: snapshot.scope,
            previousGeneration: expectedGeneration,
            generation: expectedGeneration + 1,
            unchanged: snapshot.records.count
        )
    }
}
