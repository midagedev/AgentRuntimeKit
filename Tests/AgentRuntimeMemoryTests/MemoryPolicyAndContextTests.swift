import Foundation
import XCTest
@testable import AgentRuntimeMemory

final class MemoryPolicyAndContextTests: XCTestCase {
    func testDefaultPolicyRejectsSecretsAndRequiresApprovalForDurableSensitiveData() async {
        let policy = DefaultMemoryPolicy()
        let userScope = MemoryScope.user(appID: "app", userID: "user")

        let secret = proposal(scope: userScope, sensitivity: .secret)
        guard case .deny(let secretReason) = await policy.evaluate(secret) else {
            return XCTFail("Secret memory must be denied")
        }
        XCTAssertTrue(secretReason.localizedCaseInsensitiveContains("secret store"))

        for sensitivity in [AgentDataSensitivity.health, .financial] {
            let durable = proposal(scope: userScope, sensitivity: sensitivity)
            guard case .requireApproval = await policy.evaluate(durable) else {
                return XCTFail("Durable \(sensitivity) memory must require approval")
            }

            var shortSession = durable
            shortSession.scope = .session(
                appID: "app",
                sessionID: "session",
                userID: "user",
                agentID: "agent"
            )
            shortSession.timeToLive = 60 * 60
            let shortSessionDecision = await policy.evaluate(shortSession)
            XCTAssertEqual(shortSessionDecision, .allow)

            shortSession.timeToLive = 48 * 60 * 60
            guard case .requireApproval = await policy.evaluate(shortSession) else {
                return XCTFail("Long-lived sensitive session memory must require approval")
            }
        }
    }

    func testPolicyRejectsMissingProvenanceAndProtectsPersistentInstructions() async {
        let policy = DefaultMemoryPolicy(requiresApprovalForApplicationScope: false)
        var missingProvenance = proposal(
            scope: .user(appID: "app", userID: "user"),
            sensitivity: .privateData
        )
        missingProvenance.provenance.source = "   "
        guard case .deny(let reason) = await policy.evaluate(missingProvenance) else {
            return XCTFail("Missing provenance must be rejected")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("provenance"))

        var instruction = proposal(
            scope: .agent(appID: "app", agentID: "agent", userID: "user"),
            sensitivity: .privateData
        )
        instruction.kind = .instruction
        guard case .requireApproval(let instructionReason) = await policy.evaluate(instruction) else {
            return XCTFail("Persistent instructions must require approval")
        }
        XCTAssertTrue(instructionReason.localizedCaseInsensitiveContains("behavior"))
    }

    func testPendingApprovalDoesNotPersistUntilExplicitResolution() async throws {
        let store = InMemoryMemoryStore()
        let writer = PolicyControlledMemoryWriter(store: store)
        let proposal = proposal(
            scope: .user(appID: "app", userID: "user"),
            sensitivity: .health,
            ttl: 600
        )

        let initial = try await writer.submit(proposal)
        guard case .requiresApproval(let request) = initial else {
            return XCTFail("Expected an approval request")
        }
        let beforeApproval = try await store.retrieve(MemoryQuery(
            scopes: [proposal.scope],
            maximumSensitivity: .health
        ))
        XCTAssertTrue(beforeApproval.hits.isEmpty)

        let resolved = try await writer.resolve(requestID: request.id, decision: .approve)
        guard case .stored(let record) = resolved else {
            return XCTFail("Approved memory was not stored")
        }
        XCTAssertEqual(record.provenance, proposal.provenance)
        XCTAssertNotNil(record.expiresAt)
        let afterApproval = try await store.retrieve(MemoryQuery(
            scopes: [proposal.scope],
            maximumSensitivity: .health
        ))
        XCTAssertEqual(afterApproval.records.map(\.id), [record.id])
    }

    func testContextProviderDefaultsToPrivateAndMaintainsUserWorkspaceIsolation() async throws {
        let store = InMemoryMemoryStore()
        let userOneWorkspace = MemoryScope.workspace(
            appID: "app",
            workspaceID: "workspace",
            userID: "user-1",
            agentID: "agent"
        )
        let userTwoWorkspace = MemoryScope.workspace(
            appID: "app",
            workspaceID: "workspace",
            userID: "user-2",
            agentID: "agent"
        )
        let allowed = try await store.upsert(proposal(
            scope: userOneWorkspace,
            sensitivity: .privateData,
            content: "orchid preference"
        ))
        _ = try await store.upsert(proposal(
            scope: userTwoWorkspace,
            sensitivity: .privateData,
            content: "orchid belonging to another user"
        ))
        _ = try await store.upsert(proposal(
            scope: userOneWorkspace,
            sensitivity: .health,
            content: "orchid health observation",
            ttl: 600
        ))

        let provider = MemoryContextProvider(store: store)
        let request = AgentContextRequest(
            runID: UUID(),
            sessionID: "session",
            appID: "app",
            userID: "user-1",
            agentID: "agent",
            query: "orchid",
            characterBudget: 1_000,
            metadata: ["workspaceID": "workspace"]
        )
        let blocks = try await provider.context(for: request)

        XCTAssertEqual(blocks.map(\.id), ["memory:\(allowed.id.uuidString)"])
        XCTAssertEqual(blocks.map(\.content), ["orchid preference"])
        XCTAssertTrue(blocks.allSatisfy(\.isEphemeral))
        XCTAssertTrue(blocks.allSatisfy { $0.sensitivity <= .privateData })
    }

    func testContextProviderNeverEmitsSecretEvenWhenConfiguredWithSecretCeiling() async throws {
        let store = InMemoryMemoryStore()
        let scope = MemoryScope.session(
            appID: "app",
            sessionID: "session",
            userID: "user",
            agentID: "agent"
        )
        _ = try await store.upsert(proposal(
            scope: scope,
            sensitivity: .secret,
            content: "token-shaped secret"
        ))
        let provider = MemoryContextProvider(
            store: store,
            maximumSensitivity: .secret
        )
        let blocks = try await provider.context(for: AgentContextRequest(
            runID: UUID(),
            sessionID: "session",
            appID: "app",
            userID: "user",
            agentID: "agent",
            query: "secret",
            characterBudget: 1_000
        ))
        XCTAssertTrue(blocks.isEmpty)
    }

    private func proposal(
        scope: MemoryScope,
        sensitivity: AgentDataSensitivity,
        content: String = "remembered value",
        ttl: TimeInterval? = nil
    ) -> MemoryProposal {
        MemoryProposal(
            scope: scope,
            kind: .fact,
            content: content,
            sensitivity: sensitivity,
            provenance: MemoryProvenance(
                source: "unit-test",
                sourceID: "source-id",
                capturedAt: Date(timeIntervalSince1970: 1_000)
            ),
            confidence: 0.9,
            importance: 0.7,
            timeToLive: ttl
        )
    }
}
