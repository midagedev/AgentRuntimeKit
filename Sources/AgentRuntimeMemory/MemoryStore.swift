import Foundation

public protocol MemoryStore: Sendable {
    func upsert(
        _ proposal: MemoryProposal,
        status: MemoryStatus,
        expectedRevision: Int?,
        at date: Date
    ) async throws -> MemoryRecord

    func fetch(
        id: UUID,
        scope: MemoryScope,
        includeExpired: Bool,
        at date: Date
    ) async throws -> MemoryRecord?

    func update(
        id: UUID,
        scope: MemoryScope,
        patch: MemoryPatch,
        expectedRevision: Int,
        at date: Date
    ) async throws -> MemoryRecord

    func delete(
        id: UUID,
        scope: MemoryScope,
        expectedRevision: Int,
        at date: Date
    ) async throws

    /// Physically removes one record and its related store-owned artifacts.
    /// The ID is acted on only when it belongs to the exact supplied scope.
    func purge(id: UUID, scope: MemoryScope) async throws -> MemoryPurgeResult

    /// Physically removes every record in the supplied exact scopes. Scopes are
    /// never widened to child, parent, application, or neighboring user scopes.
    func purge(scopes: [MemoryScope]) async throws -> MemoryPurgeResult

    /// Lists every record explicitly owned by one app user, including expired,
    /// rejected, deleted, and records from past session IDs. Application-wide
    /// and scopes without this exact user ID are excluded.
    func recordsOwned(appID: String, userID: String) async throws -> [MemoryRecord]

    /// Physically removes all records returned by `recordsOwned`. It never
    /// removes application-wide or user-unbound records.
    func purgeOwned(appID: String, userID: String) async throws -> MemoryPurgeResult

    func retrieve(_ query: MemoryQuery) async throws -> MemoryRetrievalResult

    func events(
        scope: MemoryScope,
        recordID: UUID?,
        limit: Int
    ) async throws -> [MemoryEvent]
}

public extension MemoryStore {
    func upsert(
        _ proposal: MemoryProposal,
        status: MemoryStatus = .active,
        expectedRevision: Int? = nil,
        at date: Date = .now
    ) async throws -> MemoryRecord {
        try await upsert(
            proposal,
            status: status,
            expectedRevision: expectedRevision,
            at: date
        )
    }

    func fetch(
        id: UUID,
        scope: MemoryScope,
        includeExpired: Bool = false,
        at date: Date = .now
    ) async throws -> MemoryRecord? {
        try await fetch(id: id, scope: scope, includeExpired: includeExpired, at: date)
    }

    func update(
        id: UUID,
        scope: MemoryScope,
        patch: MemoryPatch,
        expectedRevision: Int,
        at date: Date = .now
    ) async throws -> MemoryRecord {
        try await update(
            id: id,
            scope: scope,
            patch: patch,
            expectedRevision: expectedRevision,
            at: date
        )
    }

    func delete(
        id: UUID,
        scope: MemoryScope,
        expectedRevision: Int,
        at date: Date = .now
    ) async throws {
        try await delete(id: id, scope: scope, expectedRevision: expectedRevision, at: date)
    }

    /// Preserves source compatibility for existing custom stores while failing
    /// closed: a store must opt in with a real physical-purge implementation.
    func purge(id: UUID, scope: MemoryScope) async throws -> MemoryPurgeResult {
        throw MemoryStoreCapabilityError.privacyPurgeUnavailable
    }

    /// Preserves source compatibility for existing custom stores while failing
    /// closed: a store must opt in with a real physical-purge implementation.
    func purge(scopes: [MemoryScope]) async throws -> MemoryPurgeResult {
        throw MemoryStoreCapabilityError.privacyPurgeUnavailable
    }

    /// Preserves source compatibility for existing custom stores while failing
    /// closed instead of silently returning an incomplete owner inventory.
    func recordsOwned(appID: String, userID: String) async throws -> [MemoryRecord] {
        throw MemoryStoreCapabilityError.privacyPurgeUnavailable
    }

    /// Preserves source compatibility for existing custom stores while failing
    /// closed: a store must opt in with a real physical-purge implementation.
    func purgeOwned(appID: String, userID: String) async throws -> MemoryPurgeResult {
        throw MemoryStoreCapabilityError.privacyPurgeUnavailable
    }

    func events(
        scope: MemoryScope,
        recordID: UUID? = nil,
        limit: Int = 200
    ) async throws -> [MemoryEvent] {
        try await events(scope: scope, recordID: recordID, limit: limit)
    }
}

public actor InMemoryMemoryStore: MemoryStore {
    private struct DedupeIdentity: Hashable {
        var scope: MemoryScope
        var key: String
    }

    private var records: [UUID: MemoryRecord] = [:]
    private var dedupeIndex: [DedupeIdentity: UUID] = [:]
    private var eventLog: [MemoryEvent] = []

    public init() {}

    public func upsert(
        _ proposal: MemoryProposal,
        status: MemoryStatus,
        expectedRevision: Int?,
        at date: Date
    ) throws -> MemoryRecord {
        let proposal = try proposal.validated()
        let key = proposal.resolvedDeduplicationKey()
        let identity = DedupeIdentity(scope: proposal.scope, key: key)

        if let id = dedupeIndex[identity], var record = records[id] {
            if let expectedRevision, expectedRevision != record.revision {
                throw MemoryStoreError.revisionConflict(
                    id: id,
                    expected: expectedRevision,
                    actual: record.revision
                )
            }
            if Self.matches(record, proposal: proposal, status: status, at: date) {
                appendEvent(
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
            records[id] = record
            appendEvent(
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
        records[record.id] = record
        dedupeIndex[identity] = record.id
        appendEvent(record: record, kind: .created, previousRevision: nil, at: date)
        return record
    }

    public func fetch(
        id: UUID,
        scope: MemoryScope,
        includeExpired: Bool,
        at date: Date
    ) throws -> MemoryRecord? {
        _ = try scope.validated()
        guard let record = records[id], record.scope == scope else { return nil }
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
        _ = try scope.validated()
        guard var record = records[id], record.scope == scope else {
            throw MemoryStoreError.notFound(id)
        }
        guard record.revision == expectedRevision else {
            throw MemoryStoreError.revisionConflict(
                id: id,
                expected: expectedRevision,
                actual: record.revision
            )
        }
        try Self.apply(patch, to: &record)
        let oldRevision = record.revision
        record.revision += 1
        record.updatedAt = date
        records[id] = record
        appendEvent(
            record: record,
            kind: patch.status == .deleted
                ? .deleted
                : (patch.status == nil ? .updated : .statusChanged),
            previousRevision: oldRevision,
            at: date
        )
        return record
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
        _ = try scope.validated()
        guard let record = records[id], record.scope == scope else {
            return MemoryPurgeResult()
        }

        records.removeValue(forKey: id)
        dedupeIndex = dedupeIndex.filter { $0.value != id }
        let eventCount = eventLog.count { $0.recordID == id }
        eventLog.removeAll { $0.recordID == id }
        return MemoryPurgeResult(recordsPurged: 1, eventsPurged: eventCount)
    }

    public func purge(scopes: [MemoryScope]) async throws -> MemoryPurgeResult {
        let exactScopes = Set(try scopes.map { try $0.validated() })
        guard !exactScopes.isEmpty else { return MemoryPurgeResult() }

        let recordIDs = Set(records.values.lazy
            .filter { exactScopes.contains($0.scope) }
            .map(\.id))
        let eventCount = eventLog.count {
            recordIDs.contains($0.recordID) || exactScopes.contains($0.scope)
        }
        records = records.filter { !recordIDs.contains($0.key) }
        dedupeIndex = dedupeIndex.filter { !recordIDs.contains($0.value) }
        eventLog.removeAll {
            recordIDs.contains($0.recordID) || exactScopes.contains($0.scope)
        }
        return MemoryPurgeResult(
            recordsPurged: recordIDs.count,
            eventsPurged: eventCount
        )
    }

    public func recordsOwned(appID: String, userID: String) async throws -> [MemoryRecord] {
        _ = try MemoryScope.user(appID: appID, userID: userID).validated()
        return records.values
            .filter { Self.isOwned($0.scope, appID: appID, userID: userID) }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public func purgeOwned(appID: String, userID: String) async throws -> MemoryPurgeResult {
        _ = try MemoryScope.user(appID: appID, userID: userID).validated()
        let recordIDs = Set(records.values.lazy
            .filter { Self.isOwned($0.scope, appID: appID, userID: userID) }
            .map(\.id))
        let eventCount = eventLog.count {
            recordIDs.contains($0.recordID)
                || Self.isOwned($0.scope, appID: appID, userID: userID)
        }
        records = records.filter { !recordIDs.contains($0.key) }
        dedupeIndex = dedupeIndex.filter { !recordIDs.contains($0.value) }
        eventLog.removeAll {
            recordIDs.contains($0.recordID)
                || Self.isOwned($0.scope, appID: appID, userID: userID)
        }
        return MemoryPurgeResult(
            recordsPurged: recordIDs.count,
            eventsPurged: eventCount
        )
    }

    public func retrieve(_ query: MemoryQuery) throws -> MemoryRetrievalResult {
        try MemoryRetrievalEngine.validate(query)
        let visibleScopes = Set(query.scopes)
        let candidates = records.values.filter { record in
            visibleScopes.contains(record.scope)
                && query.statuses.contains(record.status)
                && (query.kinds?.contains(record.kind) ?? true)
                && record.sensitivity.memoryRank <= query.maximumSensitivity.memoryRank
                && record.confidence >= query.minimumConfidence
                && record.importance >= query.minimumImportance
                && (query.includeExpired || !record.isExpired(at: query.asOf))
        }
        let mode: MemorySearchMode = MemoryRetrievalEngine.terms(query.text).isEmpty
            ? .recent
            : .lexical
        return MemoryRetrievalEngine.result(
            candidates: Array(candidates),
            query: query,
            mode: mode
        )
    }

    public func events(
        scope: MemoryScope,
        recordID: UUID?,
        limit: Int
    ) throws -> [MemoryEvent] {
        _ = try scope.validated()
        return eventLog
            .reversed()
            .filter { $0.scope == scope && (recordID == nil || $0.recordID == recordID) }
            .prefix(max(0, limit))
            .reversed()
    }

    private func appendEvent(
        record: MemoryRecord,
        kind: MemoryEventKind,
        previousRevision: Int?,
        at date: Date
    ) {
        eventLog.append(MemoryEvent(
            recordID: record.id,
            scope: record.scope,
            kind: kind,
            timestamp: date,
            previousRevision: previousRevision,
            revision: record.revision,
            detail: [
                "status": .string(record.status.rawValue),
                "kind": .string(record.kind.rawValue),
                "sensitivity": .string(record.sensitivity.rawValue),
            ]
        ))
    }

    private static func isOwned(
        _ scope: MemoryScope,
        appID: String,
        userID: String
    ) -> Bool {
        switch scope.level {
        case .application:
            false
        case .user, .agent, .workspace, .session:
            scope.appID == appID && scope.userID == userID
        }
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
            && record.deduplicationKeyOrigin == proposal.resolvedDeduplicationKeyOrigin()
            && record.metadata == proposal.metadata
    }

    private static func optionalDatesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)):
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
            && abs(lhs.capturedAt.timeIntervalSince(rhs.capturedAt)) <= 0.001
    }

    static func apply(_ patch: MemoryPatch, to record: inout MemoryRecord) throws {
        if let content = patch.content {
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryStoreError.invalidProposal("content must not be empty")
            }
            guard content == record.content || record.deduplicationKeyOrigin == .explicit else {
                throw MemoryStoreError.contentPatchRequiresExplicitDeduplicationKey(record.id)
            }
            record.content = content
        }
        if let sensitivity = patch.sensitivity { record.sensitivity = sensitivity }
        if let provenance = patch.provenance { record.provenance = provenance }
        if let confidence = patch.confidence {
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw MemoryStoreError.invalidProposal("confidence must be between 0 and 1")
            }
            record.confidence = confidence
        }
        if let importance = patch.importance {
            guard importance.isFinite, (0...1).contains(importance) else {
                throw MemoryStoreError.invalidProposal("importance must be between 0 and 1")
            }
            record.importance = importance
        }
        if let expiresAt = patch.expiresAt { record.expiresAt = expiresAt }
        if let status = patch.status { record.status = status }
        if let metadata = patch.metadata { record.metadata = metadata }
    }
}

enum MemoryRetrievalEngine {
    static func validate(_ query: MemoryQuery) throws {
        guard !query.scopes.isEmpty else {
            throw MemoryStoreError.invalidScope("at least one readable scope is required")
        }
        for scope in query.scopes { _ = try scope.validated() }
        guard query.minimumConfidence.isFinite,
              (0...1).contains(query.minimumConfidence),
              query.minimumImportance.isFinite,
              (0...1).contains(query.minimumImportance) else {
            throw MemoryStoreError.invalidProposal(
                "retrieval thresholds must be between 0 and 1"
            )
        }
    }

    static func terms(_ text: String) -> [String] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        var result: [String] = []
        var seen: Set<String> = []
        for term in folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            where !term.isEmpty && seen.insert(term).inserted {
            result.append(term)
        }
        return result
    }

    static func result(
        candidates: [MemoryRecord],
        query: MemoryQuery,
        mode: MemorySearchMode
    ) -> MemoryRetrievalResult {
        let queryTerms = terms(query.text)
        let normalizedQuery = query.text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let scored: [(MemoryRecord, Double)] = candidates.compactMap { record in
            let normalizedContent = record.content.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let termScore: Double
            if queryTerms.isEmpty {
                termScore = 0.5
            } else {
                let matched = queryTerms.filter { normalizedContent.contains($0) }.count
                guard matched > 0 else { return nil }
                termScore = Double(matched) / Double(queryTerms.count)
            }
            let phraseBoost = !normalizedQuery.isEmpty && normalizedContent.contains(normalizedQuery)
                ? 0.1
                : 0
            let age = max(0, query.asOf.timeIntervalSince(record.updatedAt))
            let recency = exp(-age / (60 * 60 * 24 * 30))
            let score = termScore * 0.6
                + record.importance * 0.2
                + record.confidence * 0.1
                + recency * 0.1
                + phraseBoost
            return (record, score)
        }.sorted {
            if $0.1 == $1.1 {
                if $0.0.updatedAt == $1.0.updatedAt {
                    return $0.0.id.uuidString < $1.0.id.uuidString
                }
                return $0.0.updatedAt > $1.0.updatedAt
            }
            return $0.1 > $1.1
        }

        var remaining = query.characterBudget
        var hits: [MemorySearchHit] = []
        var truncated = false
        for (record, relevance) in scored.prefix(query.limit) {
            guard remaining > 0 else {
                truncated = true
                break
            }
            let text: String
            let isTruncated: Bool
            if record.content.count > remaining {
                text = String(record.content.prefix(remaining))
                isTruncated = true
                truncated = true
            } else {
                text = record.content
                isTruncated = false
            }
            hits.append(MemorySearchHit(
                record: record,
                relevance: relevance,
                contextText: text,
                isTruncated: isTruncated
            ))
            remaining -= text.count
            if isTruncated { break }
        }
        if scored.count > hits.count { truncated = true }
        return MemoryRetrievalResult(
            hits: hits,
            mode: mode,
            usedCharacterCount: query.characterBudget - remaining,
            exhaustedBudget: truncated
        )
    }
}
