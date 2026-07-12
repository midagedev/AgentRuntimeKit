import Foundation

public enum MemoryPolicyDecision: Sendable, Hashable {
    case allow
    case requireApproval(reason: String)
    case deny(reason: String)
}

public protocol MemoryPolicy: Sendable {
    func evaluate(_ proposal: MemoryProposal) async -> MemoryPolicyDecision
}

/// Conservative defaults for durable agent memory:
/// - secrets are never accepted;
/// - health and financial data are automatic only as short-lived session memory;
/// - durable health/financial memory and persistent instructions require approval;
/// - application-wide writes require approval because they affect every user.
public struct DefaultMemoryPolicy: MemoryPolicy, Sendable {
    public var minimumConfidence: Double
    public var maximumSensitiveSessionTTL: TimeInterval
    public var requiresApprovalForInstructions: Bool
    public var requiresApprovalForApplicationScope: Bool

    public init(
        minimumConfidence: Double = 0.5,
        maximumSensitiveSessionTTL: TimeInterval = 24 * 60 * 60,
        requiresApprovalForInstructions: Bool = true,
        requiresApprovalForApplicationScope: Bool = true
    ) {
        self.minimumConfidence = min(1, max(0, minimumConfidence))
        self.maximumSensitiveSessionTTL = max(0, maximumSensitiveSessionTTL)
        self.requiresApprovalForInstructions = requiresApprovalForInstructions
        self.requiresApprovalForApplicationScope = requiresApprovalForApplicationScope
    }

    public func evaluate(_ proposal: MemoryProposal) async -> MemoryPolicyDecision {
        do {
            _ = try proposal.validated()
        } catch {
            return .deny(reason: error.localizedDescription)
        }
        guard !proposal.provenance.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .deny(reason: "Memory requires a non-empty provenance source.")
        }
        guard proposal.confidence >= minimumConfidence else {
            return .deny(reason: "Memory confidence is below the policy threshold.")
        }
        if proposal.sensitivity == .secret {
            return .deny(reason: "Secret data must use a secret store and cannot become agent memory.")
        }
        if requiresApprovalForInstructions, proposal.kind == .instruction {
            return .requireApproval(
                reason: "Persistent instructions can change future agent behavior."
            )
        }
        if proposal.sensitivity == .health || proposal.sensitivity == .financial {
            if proposal.scope.level == .session,
               let ttl = proposal.timeToLive,
               ttl <= maximumSensitiveSessionTTL {
                return .allow
            }
            return .requireApproval(
                reason: "Health and financial memory must be explicitly approved unless it is short-lived session data."
            )
        }
        if requiresApprovalForApplicationScope, proposal.scope.level == .application {
            return .requireApproval(
                reason: "Application-wide memory is shared across users and requires approval."
            )
        }
        return .allow
    }
}

public struct MemoryApprovalRequest: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var proposal: MemoryProposal
    public var reason: String
    public var requestedAt: Date

    public init(
        id: UUID = UUID(),
        proposal: MemoryProposal,
        reason: String,
        requestedAt: Date = .now
    ) {
        self.id = id
        self.proposal = proposal
        self.reason = reason
        self.requestedAt = requestedAt
    }
}

public enum MemoryApprovalDecision: Sendable, Hashable {
    case approve
    case deny(reason: String)
}

public protocol MemoryApprovalHandler: Sendable {
    func requestApproval(_ request: MemoryApprovalRequest) async -> MemoryApprovalDecision
}

public struct DenyAllMemoryApprovalHandler: MemoryApprovalHandler, Sendable {
    public init() {}

    public func requestApproval(_ request: MemoryApprovalRequest) async -> MemoryApprovalDecision {
        .deny(reason: "No memory approval handler is installed.")
    }
}

public enum MemorySubmissionOutcome: Sendable, Hashable {
    case stored(MemoryRecord)
    case requiresApproval(MemoryApprovalRequest)
    case rejected(reason: String)
}

public enum MemoryPolicyError: Error, Sendable, Equatable, LocalizedError {
    case pendingRequestNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .pendingRequestNotFound(let id):
            "Pending memory approval request \(id) was not found."
        }
    }
}

/// Applies policy before content reaches durable storage. Pending sensitive
/// proposals remain only in this actor until the host explicitly resolves them.
public actor PolicyControlledMemoryWriter {
    private let store: any MemoryStore
    private let policy: any MemoryPolicy
    private let approvalHandler: (any MemoryApprovalHandler)?
    private var pending: [UUID: MemoryApprovalRequest] = [:]

    public init(
        store: any MemoryStore,
        policy: any MemoryPolicy = DefaultMemoryPolicy(),
        approvalHandler: (any MemoryApprovalHandler)? = nil
    ) {
        self.store = store
        self.policy = policy
        self.approvalHandler = approvalHandler
    }

    public func submit(
        _ proposal: MemoryProposal,
        expectedRevision: Int? = nil,
        at date: Date = .now
    ) async throws -> MemorySubmissionOutcome {
        switch await policy.evaluate(proposal) {
        case .allow:
            return .stored(try await store.upsert(
                proposal,
                status: .active,
                expectedRevision: expectedRevision,
                at: date
            ))
        case .deny(let reason):
            return .rejected(reason: reason)
        case .requireApproval(let reason):
            let request = MemoryApprovalRequest(
                proposal: proposal,
                reason: reason,
                requestedAt: date
            )
            guard let approvalHandler else {
                pending[request.id] = request
                return .requiresApproval(request)
            }
            switch await approvalHandler.requestApproval(request) {
            case .approve:
                return .stored(try await store.upsert(
                    proposal,
                    status: .active,
                    expectedRevision: expectedRevision,
                    at: date
                ))
            case .deny(let reason):
                return .rejected(reason: reason)
            }
        }
    }

    public func resolve(
        requestID: UUID,
        decision: MemoryApprovalDecision,
        expectedRevision: Int? = nil,
        at date: Date = .now
    ) async throws -> MemorySubmissionOutcome {
        guard let request = pending.removeValue(forKey: requestID) else {
            throw MemoryPolicyError.pendingRequestNotFound(requestID)
        }
        switch decision {
        case .approve:
            return .stored(try await store.upsert(
                request.proposal,
                status: .active,
                expectedRevision: expectedRevision,
                at: date
            ))
        case .deny(let reason):
            return .rejected(reason: reason)
        }
    }

    public func pendingRequests() -> [MemoryApprovalRequest] {
        pending.values.sorted { $0.requestedAt < $1.requestedAt }
    }
}
