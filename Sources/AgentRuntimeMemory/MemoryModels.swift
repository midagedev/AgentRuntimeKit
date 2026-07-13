import Foundation
import CryptoKit

public enum MemoryScopeLevel: String, Sendable, Codable, Hashable, CaseIterable {
    case application
    case user
    case agent
    case workspace
    case session
}

/// An exact memory namespace. Callers explicitly compose the scopes a reader may see;
/// the store never broadens one user's or session's scope on its own.
public struct MemoryScope: Sendable, Codable, Hashable {
    public var level: MemoryScopeLevel
    public var appID: String
    public var userID: String?
    public var agentID: String?
    public var workspaceID: String?
    public var sessionID: String?

    public init(
        level: MemoryScopeLevel,
        appID: String,
        userID: String? = nil,
        agentID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil
    ) {
        self.level = level
        self.appID = appID
        self.userID = userID
        self.agentID = agentID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }

    public static func application(appID: String) -> Self {
        Self(level: .application, appID: appID)
    }

    public static func user(appID: String, userID: String) -> Self {
        Self(level: .user, appID: appID, userID: userID)
    }

    public static func agent(appID: String, agentID: String, userID: String? = nil) -> Self {
        Self(level: .agent, appID: appID, userID: userID, agentID: agentID)
    }

    public static func workspace(
        appID: String,
        workspaceID: String,
        userID: String? = nil,
        agentID: String? = nil
    ) -> Self {
        Self(
            level: .workspace,
            appID: appID,
            userID: userID,
            agentID: agentID,
            workspaceID: workspaceID
        )
    }

    public static func session(
        appID: String,
        sessionID: String,
        userID: String? = nil,
        agentID: String? = nil,
        workspaceID: String? = nil
    ) -> Self {
        Self(
            level: .session,
            appID: appID,
            userID: userID,
            agentID: agentID,
            workspaceID: workspaceID,
            sessionID: sessionID
        )
    }

    func validated() throws -> Self {
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryStoreError.invalidScope("appID must not be empty")
        }
        for (value, field) in [
            (Optional(appID), "appID"),
            (userID, "userID"),
            (agentID, "agentID"),
            (workspaceID, "workspaceID"),
            (sessionID, "sessionID"),
        ] {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MemoryStoreError.invalidScope("\(field) must not be empty")
            }
            guard value == trimmed else {
                throw MemoryStoreError.invalidScope(
                    "\(field) must not have leading or trailing whitespace"
                )
            }
            guard value.utf8.elementsEqual(
                value.precomposedStringWithCanonicalMapping.utf8
            ) else {
                throw MemoryStoreError.invalidScope("\(field) must use NFC Unicode normalization")
            }
            guard !value.unicodeScalars.contains(where: {
                $0.value == 0 || CharacterSet.controlCharacters.contains($0)
            }) else {
                throw MemoryStoreError.invalidScope(
                    "\(field) must not contain NUL or control characters"
                )
            }
        }
        let required: String?
        let field: String
        switch level {
        case .application:
            return self
        case .user:
            (required, field) = (userID, "userID")
        case .agent:
            (required, field) = (agentID, "agentID")
        case .workspace:
            (required, field) = (workspaceID, "workspaceID")
        case .session:
            (required, field) = (sessionID, "sessionID")
        }
        guard let required, !required.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryStoreError.invalidScope("\(field) is required for a \(level.rawValue) scope")
        }
        return self
    }

    /// Accepts the safely recoverable, exact-byte subset of scopes written by
    /// AgentRuntimeKit 0.1.x.
    ///
    /// SQLite read, update, and erasure operations use this compatibility
    /// boundary so a legacy row with whitespace, non-NUL control characters,
    /// or non-NFC identifiers never becomes unreachable after upgrade. NUL and
    /// present-empty optionals are rejected here because 0.1.x stored them as
    /// lossy aliases; explicit persisted-scope administration handles the
    /// remaining non-canonical storage keys.
    /// New proposals and source snapshots continue to use `validated()` and
    /// therefore cannot create another non-canonical scope.
    func validatedForLegacySQLiteAccess() throws -> Self {
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryStoreError.invalidScope("appID must not be empty")
        }
        for (value, field) in [
            (Optional(appID), "appID"),
            (userID, "userID"),
            (agentID, "agentID"),
            (workspaceID, "workspaceID"),
            (sessionID, "sessionID"),
        ] {
            guard let value else { continue }
            guard !value.isEmpty else {
                throw MemoryStoreError.invalidScope(
                    "\(field) must not be an explicitly present empty identifier"
                )
            }
            guard !value.utf8.contains(0) else {
                throw MemoryStoreError.invalidScope(
                    "\(field) must not contain NUL"
                )
            }
        }
        let required: String?
        let field: String
        switch level {
        case .application:
            return self
        case .user:
            (required, field) = (userID, "userID")
        case .agent:
            (required, field) = (agentID, "agentID")
        case .workspace:
            (required, field) = (workspaceID, "workspaceID")
        case .session:
            (required, field) = (sessionID, "sessionID")
        }
        guard let required,
              !required.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MemoryStoreError.invalidScope(
                "\(field) is required for a \(level.rawValue) scope"
            )
        }
        return self
    }
}

public enum MemoryKind: String, Sendable, Codable, Hashable, CaseIterable {
    case fact
    case preference
    case instruction
    case summary
    case episode
    case relationship
    case task
    case observation
}

public enum MemoryStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case proposed
    case active
    case superseded
    case archived
    case rejected
    case deleted
}

public struct MemoryProvenance: Sendable, Codable, Hashable {
    public var source: String
    public var sourceID: String?
    public var actorID: String?
    public var capturedAt: Date
    public var metadata: [String: JSONValue]

    public init(
        source: String,
        sourceID: String? = nil,
        actorID: String? = nil,
        capturedAt: Date = .now,
        metadata: [String: JSONValue] = [:]
    ) {
        self.source = source
        self.sourceID = sourceID
        self.actorID = actorID
        self.capturedAt = capturedAt
        self.metadata = metadata
    }
}

public struct MemoryProposal: Sendable, Codable, Hashable {
    public var scope: MemoryScope
    public var kind: MemoryKind
    public var content: String
    public var sensitivity: AgentDataSensitivity
    public var provenance: MemoryProvenance
    public var confidence: Double
    public var importance: Double
    public var timeToLive: TimeInterval?
    public var deduplicationKey: String?
    public var metadata: [String: JSONValue]

    public init(
        scope: MemoryScope,
        kind: MemoryKind,
        content: String,
        sensitivity: AgentDataSensitivity = .privateData,
        provenance: MemoryProvenance,
        confidence: Double = 1,
        importance: Double = 0.5,
        timeToLive: TimeInterval? = nil,
        deduplicationKey: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.scope = scope
        self.kind = kind
        self.content = content
        self.sensitivity = sensitivity
        self.provenance = provenance
        self.confidence = confidence
        self.importance = importance
        self.timeToLive = timeToLive
        self.deduplicationKey = deduplicationKey
        self.metadata = metadata
    }

    func validated() throws -> Self {
        _ = try scope.validated()
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryStoreError.invalidProposal("content must not be empty")
        }
        guard !provenance.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryStoreError.invalidProposal("provenance.source must not be empty")
        }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw MemoryStoreError.invalidProposal("confidence must be between 0 and 1")
        }
        guard importance.isFinite, (0...1).contains(importance) else {
            throw MemoryStoreError.invalidProposal("importance must be between 0 and 1")
        }
        if let timeToLive, (!timeToLive.isFinite || timeToLive <= 0) {
            throw MemoryStoreError.invalidProposal("timeToLive must be greater than zero")
        }
        if let deduplicationKey,
           deduplicationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemoryStoreError.invalidProposal("deduplicationKey must not be empty")
        }
        return self
    }

    func resolvedDeduplicationKey() -> String {
        if let deduplicationKey { return Self.digest("explicit:\(deduplicationKey)") }
        let normalized = content
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return Self.digest("\(kind.rawValue):\(normalized)")
    }

    func resolvedDeduplicationKeyOrigin() -> MemoryDeduplicationKeyOrigin {
        deduplicationKey == nil ? .derived : .explicit
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Records whether a memory's stable identity was explicitly supplied by its
/// caller or derived from mutable content. Legacy SQLite/JSON records can lack
/// this field; stores treat that unknown origin conservatively.
public enum MemoryDeduplicationKeyOrigin: String, Sendable, Codable, Hashable {
    case derived
    case explicit
    case legacyUnknown
}

public struct MemoryRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var scope: MemoryScope
    public var kind: MemoryKind
    public var content: String
    public var sensitivity: AgentDataSensitivity
    public var provenance: MemoryProvenance
    public var confidence: Double
    public var importance: Double
    public var expiresAt: Date?
    public var revision: Int
    public var status: MemoryStatus
    public var deduplicationKey: String
    public var deduplicationKeyOrigin: MemoryDeduplicationKeyOrigin? = nil
    public var metadata: [String: JSONValue]
    public var createdAt: Date
    public var updatedAt: Date

    /// Creates a fully materialized memory record.
    ///
    /// Custom `MemoryStore` implementations use this initializer when loading
    /// their own durable representation. Stores are responsible for preserving
    /// the record invariants documented by `MemoryStore` (including a positive
    /// revision and an exact, validated scope).
    public init(
        id: UUID,
        scope: MemoryScope,
        kind: MemoryKind,
        content: String,
        sensitivity: AgentDataSensitivity,
        provenance: MemoryProvenance,
        confidence: Double,
        importance: Double,
        expiresAt: Date?,
        revision: Int,
        status: MemoryStatus,
        deduplicationKey: String,
        deduplicationKeyOrigin: MemoryDeduplicationKeyOrigin? = nil,
        metadata: [String: JSONValue],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.scope = scope
        self.kind = kind
        self.content = content
        self.sensitivity = sensitivity
        self.provenance = provenance
        self.confidence = confidence
        self.importance = importance
        self.expiresAt = expiresAt
        self.revision = revision
        self.status = status
        self.deduplicationKey = deduplicationKey
        self.deduplicationKeyOrigin = deduplicationKeyOrigin
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isExpired: Bool { isExpired(at: .now) }

    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

public struct MemoryPatch: Sendable, Codable, Hashable {
    public var content: String?
    public var sensitivity: AgentDataSensitivity?
    public var provenance: MemoryProvenance?
    public var confidence: Double?
    public var importance: Double?
    /// `nil` preserves the current expiry; `.some(nil)` removes it.
    public var expiresAt: Date??
    public var status: MemoryStatus?
    public var metadata: [String: JSONValue]?

    public init(
        content: String? = nil,
        sensitivity: AgentDataSensitivity? = nil,
        provenance: MemoryProvenance? = nil,
        confidence: Double? = nil,
        importance: Double? = nil,
        expiresAt: Date?? = nil,
        status: MemoryStatus? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.content = content
        self.sensitivity = sensitivity
        self.provenance = provenance
        self.confidence = confidence
        self.importance = importance
        self.expiresAt = expiresAt
        self.status = status
        self.metadata = metadata
    }
}

public enum MemorySearchMode: String, Sendable, Codable, Hashable {
    case fullText
    case lexical
    case recent
}

public struct MemoryQuery: Sendable, Hashable {
    public var scopes: [MemoryScope]
    public var text: String
    public var kinds: Set<MemoryKind>?
    public var statuses: Set<MemoryStatus>
    public var maximumSensitivity: AgentDataSensitivity
    public var minimumConfidence: Double
    public var minimumImportance: Double
    public var limit: Int
    public var characterBudget: Int
    public var asOf: Date
    public var includeExpired: Bool

    public init(
        scopes: [MemoryScope],
        text: String = "",
        kinds: Set<MemoryKind>? = nil,
        statuses: Set<MemoryStatus> = [.active],
        maximumSensitivity: AgentDataSensitivity = .privateData,
        minimumConfidence: Double = 0,
        minimumImportance: Double = 0,
        limit: Int = 20,
        characterBudget: Int = 12_000,
        asOf: Date = .now,
        includeExpired: Bool = false
    ) {
        self.scopes = scopes
        self.text = text
        self.kinds = kinds
        self.statuses = statuses
        self.maximumSensitivity = maximumSensitivity
        self.minimumConfidence = minimumConfidence
        self.minimumImportance = minimumImportance
        self.limit = max(0, limit)
        self.characterBudget = max(0, characterBudget)
        self.asOf = asOf
        self.includeExpired = includeExpired
    }
}

public struct MemorySearchHit: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID { record.id }
    public var record: MemoryRecord
    public var relevance: Double
    /// Budget-fitted text intended for direct use as model context.
    public var contextText: String
    public var isTruncated: Bool

    public init(
        record: MemoryRecord,
        relevance: Double,
        contextText: String,
        isTruncated: Bool
    ) {
        self.record = record
        self.relevance = relevance
        self.contextText = contextText
        self.isTruncated = isTruncated
    }
}

public struct MemoryRetrievalResult: Sendable, Codable, Hashable {
    public var hits: [MemorySearchHit]
    public var mode: MemorySearchMode
    public var usedCharacterCount: Int
    public var exhaustedBudget: Bool

    public init(
        hits: [MemorySearchHit],
        mode: MemorySearchMode,
        usedCharacterCount: Int,
        exhaustedBudget: Bool
    ) {
        self.hits = hits
        self.mode = mode
        self.usedCharacterCount = usedCharacterCount
        self.exhaustedBudget = exhaustedBudget
    }

    public var records: [MemoryRecord] { hits.map(\.record) }
}

/// Counts the durable artifacts removed by a privacy purge.
///
/// A zero-valued result is a successful no-op. This makes purge safe to retry
/// after an optimistic UI has raced with another deletion or after a process
/// was interrupted while cleaning SQLite's write-ahead log.
public struct MemoryPurgeResult: Sendable, Codable, Hashable {
    public var recordsPurged: Int
    public var eventsPurged: Int
    public var fullTextEntriesPurged: Int

    public init(
        recordsPurged: Int = 0,
        eventsPurged: Int = 0,
        fullTextEntriesPurged: Int = 0
    ) {
        self.recordsPurged = recordsPurged
        self.eventsPurged = eventsPurged
        self.fullTextEntriesPurged = fullTextEntriesPurged
    }

    public var didPurgeAnything: Bool {
        recordsPurged > 0 || eventsPurged > 0 || fullTextEntriesPurged > 0
    }
}

/// Reports that the logical purge transaction committed, but a physical
/// cleanup step did not finish. The same purge call is safe to retry; the
/// committed counts let a host avoid presenting the retry as a second delete.
public struct MemoryPurgeCleanupError: Error, Sendable, Equatable, LocalizedError {
    public enum Stage: String, Sendable, Codable, Hashable {
        case databaseCompaction
        case writeAheadLogTruncation
    }

    public var committedResult: MemoryPurgeResult
    public var stage: Stage
    public var underlyingDescription: String

    public init(
        committedResult: MemoryPurgeResult,
        stage: Stage,
        underlyingDescription: String
    ) {
        self.committedResult = committedResult
        self.stage = stage
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? {
        let step = switch stage {
        case .databaseCompaction: "database compaction"
        case .writeAheadLogTruncation: "write-ahead log truncation"
        }
        return "The memory purge committed, but \(step) did not finish. "
            + "Retry the same idempotent purge. \(underlyingDescription)"
    }
}

/// A fail-closed capability error used by source-compatible default methods on
/// custom `MemoryStore` conformers that have not implemented privacy purge.
public enum MemoryStoreCapabilityError: Error, Sendable, Equatable, LocalizedError {
    case privacyPurgeUnavailable

    public var errorDescription: String? {
        "This memory store does not implement privacy purge."
    }
}

public enum MemoryEventKind: String, Sendable, Codable, Hashable {
    case created
    case updated
    case deduplicated
    case statusChanged
    case deleted
}

/// Append-only mutation evidence. Content is deliberately excluded so audit logs do
/// not become an ungoverned second copy of sensitive memory.
public struct MemoryEvent: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var recordID: UUID
    public var scope: MemoryScope
    public var kind: MemoryEventKind
    public var timestamp: Date
    public var previousRevision: Int?
    public var revision: Int
    public var detail: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        recordID: UUID,
        scope: MemoryScope,
        kind: MemoryEventKind,
        timestamp: Date = .now,
        previousRevision: Int?,
        revision: Int,
        detail: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.recordID = recordID
        self.scope = scope
        self.kind = kind
        self.timestamp = timestamp
        self.previousRevision = previousRevision
        self.revision = revision
        self.detail = detail
    }
}

public enum MemoryStoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidScope(String)
    case invalidProposal(String)
    case notFound(UUID)
    case revisionConflict(id: UUID, expected: Int, actual: Int)
    case contentPatchRequiresExplicitDeduplicationKey(UUID)
    case database(String)
    case serialization(String)

    public var errorDescription: String? {
        switch self {
        case .invalidScope(let reason): "Invalid memory scope: \(reason)"
        case .invalidProposal(let reason): "Invalid memory proposal: \(reason)"
        case .notFound(let id): "Memory record \(id) was not found in the requested scope."
        case .revisionConflict(let id, let expected, let actual):
            "Memory record \(id) has revision \(actual), not expected revision \(expected)."
        case .contentPatchRequiresExplicitDeduplicationKey(let id):
            "Memory record \(id) uses a content-derived or legacy deduplication key; replace it with an explicitly keyed upsert instead of patching content."
        case .database(let reason): "Memory database error: \(reason)"
        case .serialization(let reason): "Memory serialization error: \(reason)"
        }
    }
}

extension AgentDataSensitivity {
    var memoryRank: Int {
        switch self {
        case .publicData: 0
        case .privateData: 1
        case .health: 2
        case .financial: 3
        case .secret: 4
        }
    }
}
