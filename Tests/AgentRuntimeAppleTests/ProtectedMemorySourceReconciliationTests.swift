import AgentRuntimeApple
import Foundation
import XCTest

final class ProtectedMemorySourceReconciliationTests: XCTestCase {
    func testProtectedStoreForwardsAtomicSourceReconciliationAndProtectsArtifacts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectedMemorySourceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("memory.sqlite")
        let store = try ProtectedSQLiteMemoryStore(configuration: .init(
            databaseURL: databaseURL
        ))
        let scope = MemoryScope.user(appID: "com.example.host", userID: "user")
        let snapshot = MemorySourceSnapshot(
            identifier: "documents-v1",
            scope: scope,
            records: [
                MemorySourceSnapshotRecord(
                    sourceRecordID: "notes.md#intro",
                    proposal: MemoryProposal(
                        scope: scope,
                        kind: .observation,
                        content: "Protected file memory",
                        provenance: MemoryProvenance(
                            source: "file-memory-test",
                            sourceID: "notes.md#intro"
                        ),
                        deduplicationKey: "file-memory-test:notes.md#intro"
                    )
                ),
            ]
        )

        let report = try await store.reconcileSourceSnapshot(
            snapshot,
            expectedGeneration: 0,
            missingPolicy: .archive
        )

        XCTAssertEqual(report.created, 1)
        let sourceState = try await store.sourceState(
            identifier: snapshot.identifier,
            scope: scope
        )
        XCTAssertEqual(sourceState?.generation, 1)
        let records = try await store.recordsOwned(appID: scope.appID, userID: "user")
        XCTAssertEqual(records.map(\.content), ["Protected file memory"])

        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o077, 0)
        }
    }
}
