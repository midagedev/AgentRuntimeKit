import Foundation
import XCTest
import AgentRuntimeApple
import AgentRuntimeMemory

final class ProtectedMemoryPurgeTests: XCTestCase {
    func testOwnerPurgeKeepsArtifactsProtectedAndPreservesNeighbor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectedMemoryPurgeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("memory.sqlite")
        let store = try ProtectedSQLiteMemoryStore(configuration: .init(
            databaseURL: databaseURL,
            protection: .complete
        ))
        let ownedScope = MemoryScope.session(
            appID: "app",
            sessionID: "old-session",
            userID: "owner"
        )
        let neighborScope = MemoryScope.user(appID: "app", userID: "neighbor")
        _ = try await store.upsert(proposal(scope: ownedScope, content: "owned"))
        let neighbor = try await store.upsert(proposal(
            scope: neighborScope,
            content: "neighbor"
        ))

        let result = try await store.purgeOwned(appID: "app", userID: "owner")
        XCTAssertEqual(result.recordsPurged, 1)
        let listed = try await store.recordsOwned(appID: "app", userID: "owner")
        XCTAssertTrue(listed.isEmpty)
        let preserved = try await store.fetch(id: neighbor.id, scope: neighborScope)
        XCTAssertEqual(preserved?.id, neighbor.id)

        for artifact in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: artifact.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o077, 0)
            XCTAssertNotEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        }
    }

    private func proposal(scope: MemoryScope, content: String) -> MemoryProposal {
        MemoryProposal(
            scope: scope,
            kind: .fact,
            content: content,
            provenance: MemoryProvenance(source: "protected-purge-test"),
            deduplicationKey: content
        )
    }
}
