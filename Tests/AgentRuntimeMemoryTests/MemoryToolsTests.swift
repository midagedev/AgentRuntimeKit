import Foundation
import XCTest
@testable import AgentRuntimeMemory

final class MemoryToolsTests: XCTestCase {
    func testSaveToolCannotBypassSensitivePolicy() async throws {
        let store = InMemoryMemoryStore()
        let bundle = MemoryToolFactory.make(store: store)
        let save = try XCTUnwrap(bundle.tools.first { $0.descriptor.name == "memory.save" })
        let context = executionContext(userID: "user-1")

        let healthOutput = try await save.execute(arguments: [
            "scope": "user",
            "kind": "observation",
            "content": "HealthKit resting heart rate summary",
            "sensitivity": "health",
        ], context: context)
        XCTAssertEqual(healthOutput.content["status"]?.stringValue, "requires_approval")
        let healthSearch = try await store.retrieve(MemoryQuery(
            scopes: [.user(appID: "app", userID: "user-1")],
            maximumSensitivity: .health
        ))
        XCTAssertTrue(healthSearch.hits.isEmpty)

        let secretOutput = try await save.execute(arguments: [
            "scope": "session",
            "kind": "fact",
            "content": "credential-like-value",
            "sensitivity": "secret",
            "ttl_seconds": 60,
        ], context: context)
        XCTAssertEqual(secretOutput.content["status"]?.stringValue, "rejected")
        XCTAssertTrue(secretOutput.isError)
    }

    func testSearchUsesOneExactContextBoundNamespace() async throws {
        let store = InMemoryMemoryStore()
        let bundle = MemoryToolFactory.make(store: store)
        let save = try XCTUnwrap(bundle.tools.first { $0.descriptor.name == "memory.save" })
        let search = try XCTUnwrap(bundle.tools.first { $0.descriptor.name == "memory.search" })
        let userOne = executionContext(userID: "user-1")
        let userTwo = executionContext(userID: "user-2")

        _ = try await save.execute(arguments: [
            "scope": "user",
            "kind": "preference",
            "content": "orchid belongs to user one",
            "sensitivity": "privateData",
        ], context: userOne)
        _ = try await save.execute(arguments: [
            "scope": "user",
            "kind": "preference",
            "content": "orchid belongs to user two",
            "sensitivity": "privateData",
        ], context: userTwo)

        let output = try await search.execute(arguments: [
            "scope": "user",
            "query": "orchid",
        ], context: userOne)
        let results = try XCTUnwrap(output.content["results"]?.arrayValue)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["content"]?.stringValue, "orchid belongs to user one")

        do {
            _ = try await search.execute(arguments: ["query": "orchid"], context: userOne)
            XCTFail("Search must require one explicit exact scope")
        } catch let error as MemoryToolError {
            guard case .invalidArgument = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSaveAssignsTrustedProvenanceAndArchiveUsesRevisionAndExactScope() async throws {
        let store = InMemoryMemoryStore()
        let bundle = MemoryToolFactory.make(store: store)
        let save = try XCTUnwrap(bundle.tools.first { $0.descriptor.name == "memory.save" })
        let archive = try XCTUnwrap(bundle.tools.first { $0.descriptor.name == "memory.archive" })
        let context = executionContext(userID: "user-1")
        let scope = MemoryScope.user(appID: "app", userID: "user-1")

        let saveOutput = try await save.execute(arguments: [
            "scope": "user",
            "kind": "fact",
            "content": "durable fact",
            "sensitivity": "privateData",
        ], context: context)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(
            saveOutput.content["id"]?.stringValue
        )))
        let fetchedRecord = try await store.fetch(id: id, scope: scope)
        let record = try XCTUnwrap(fetchedRecord)
        XCTAssertEqual(record.provenance.source, "agent-tool:memory.save")
        XCTAssertEqual(record.provenance.sourceID, context.runID.uuidString)
        XCTAssertEqual(record.provenance.actorID, context.agentID)

        let archiveOutput = try await archive.execute(arguments: [
            "scope": "user",
            "id": .string(id.uuidString),
            "expected_revision": 1,
        ], context: context)
        XCTAssertEqual(archiveOutput.content["status"]?.stringValue, "archived")
        let fetchedArchived = try await store.fetch(id: id, scope: scope)
        let archived = try XCTUnwrap(fetchedArchived)
        XCTAssertEqual(archived.status, .archived)
        XCTAssertEqual(archived.revision, 2)

        do {
            _ = try await archive.execute(arguments: [
                "scope": "user",
                "id": .string(id.uuidString),
                "expected_revision": 1,
            ], context: context)
            XCTFail("Archive must enforce optimistic revision")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .revisionConflict(id: id, expected: 1, actual: 2))
        }

        let otherUser = executionContext(userID: "user-2")
        do {
            _ = try await archive.execute(arguments: [
                "scope": "user",
                "id": .string(id.uuidString),
                "expected_revision": 2,
            ], context: otherUser)
            XCTFail("Archive must not cross exact namespace boundaries")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .notFound(id))
        }
    }

    private func executionContext(userID: String) -> AgentToolExecutionContext {
        AgentToolExecutionContext(
            runID: UUID(),
            sessionID: "session-\(userID)",
            appID: "app",
            userID: userID,
            agentID: "agent",
            metadata: ["workspaceID": .string("workspace-\(userID)")]
        )
    }
}
