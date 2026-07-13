import Foundation

/// Optional capability for stores that can atomically replace all memories
/// owned by one external source.
///
/// A source is identified by the exact pair of `identifier` and `scope`.
/// Implementations never broaden that scope. Callers use `generation` as a
/// compare-and-swap token so two scanners cannot silently overwrite each
/// other's view of the same source.
public protocol MemorySourceReconciliationStore: MemoryStore {
    func sourceState(
        identifier: String,
        scope: MemoryScope
    ) async throws -> MemorySourceState?

    func reconcileSourceSnapshot(
        _ snapshot: MemorySourceSnapshot,
        expectedGeneration: Int,
        missingPolicy: MemorySourceMissingPolicy,
        at date: Date
    ) async throws -> MemorySourceReconciliationReport
}

public extension MemorySourceReconciliationStore {
    func reconcileSourceSnapshot(
        _ snapshot: MemorySourceSnapshot,
        expectedGeneration: Int,
        missingPolicy: MemorySourceMissingPolicy,
        at date: Date = .now
    ) async throws -> MemorySourceReconciliationReport {
        try await reconcileSourceSnapshot(
            snapshot,
            expectedGeneration: expectedGeneration,
            missingPolicy: missingPolicy,
            at: date
        )
    }
}

/// Durable compare-and-swap state for one source in one exact memory scope.
public struct MemorySourceState: Sendable, Codable, Hashable {
    public var identifier: String
    public var scope: MemoryScope
    public var generation: Int

    public init(identifier: String, scope: MemoryScope, generation: Int) {
        self.identifier = identifier
        self.scope = scope
        self.generation = generation
    }
}

/// A complete source inventory. Omitting a previously mapped source record
/// applies the selected `MemorySourceMissingPolicy` atomically with all upserts.
public struct MemorySourceSnapshot: Sendable, Codable, Hashable {
    /// Source identifiers are intentionally bounded before any store mutation.
    public static let maximumIdentifierUTF8ByteCount = 1_024

    public var identifier: String
    public var scope: MemoryScope
    public var records: [MemorySourceSnapshotRecord]

    public init(
        identifier: String,
        scope: MemoryScope,
        records: [MemorySourceSnapshotRecord]
    ) {
        self.identifier = identifier
        self.scope = scope
        self.records = records
    }
}

/// One stable item inside a source snapshot.
///
/// `sourceRecordID` is the source's durable identity, such as a root-relative
/// path plus fragment identifier. It remains mapped to the same memory UUID
/// when content or the explicit proposal deduplication key changes.
public struct MemorySourceSnapshotRecord: Sendable, Codable, Hashable {
    public static let maximumSourceRecordIDUTF8ByteCount = 4_096

    public var sourceRecordID: String
    public var proposal: MemoryProposal

    public init(sourceRecordID: String, proposal: MemoryProposal) {
        self.sourceRecordID = sourceRecordID
        self.proposal = proposal
    }
}

public enum MemorySourceMissingPolicy: String, Sendable, Codable, Hashable {
    /// Preserve the mapping and stable memory UUID, but mark the memory archived.
    case archive
    /// Physically erase the memory, its audit events, its search entry, and mapping.
    case purge
}

/// Counts the result of one committed source generation.
///
/// `unchanged` counts mapped source entries that required no mutation, including
/// already-archived entries that remain absent in a later archive snapshot.
public struct MemorySourceReconciliationReport: Sendable, Codable, Hashable {
    public var identifier: String
    public var scope: MemoryScope
    public var previousGeneration: Int
    public var generation: Int
    public var created: Int
    public var updated: Int
    public var unchanged: Int
    public var archived: Int
    public var purged: Int

    public init(
        identifier: String,
        scope: MemoryScope,
        previousGeneration: Int,
        generation: Int,
        created: Int = 0,
        updated: Int = 0,
        unchanged: Int = 0,
        archived: Int = 0,
        purged: Int = 0
    ) {
        self.identifier = identifier
        self.scope = scope
        self.previousGeneration = previousGeneration
        self.generation = generation
        self.created = created
        self.updated = updated
        self.unchanged = unchanged
        self.archived = archived
        self.purged = purged
    }
}

public enum MemorySourceReconciliationError: Error, Sendable, Equatable, LocalizedError {
    case invalidSnapshot(String)
    case generationConflict(expected: Int, actual: Int)
    case recordOwnershipConflict(UUID)
    case corruptMapping(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot(let reason):
            "Invalid memory source snapshot: \(reason)"
        case .generationConflict(let expected, let actual):
            "The memory source is at generation \(actual), not expected generation \(expected)."
        case .recordOwnershipConflict(let id):
            "Memory record \(id) is already owned by another source identity."
        case .corruptMapping(let reason):
            "The memory source mapping is inconsistent: \(reason)"
        }
    }
}

struct MemorySourceIdentity: Sendable, Hashable {
    var identifier: String
    var scope: MemoryScope
}

struct ValidatedMemorySourceSnapshotRecord: Sendable {
    var sourceRecordID: String
    var proposal: MemoryProposal
    var deduplicationKey: String
}

struct ValidatedMemorySourceSnapshot: Sendable {
    var identity: MemorySourceIdentity
    var records: [ValidatedMemorySourceSnapshotRecord]
    var expectedGeneration: Int
    var date: Date
}

enum MemorySourceReconciliationValidation {
    static func identity(identifier: String, scope: MemoryScope) throws -> MemorySourceIdentity {
        _ = try scope.validated()
        try validateIdentifier(
            identifier,
            field: "identifier",
            maximumUTF8ByteCount: MemorySourceSnapshot.maximumIdentifierUTF8ByteCount
        )
        return MemorySourceIdentity(identifier: identifier, scope: scope)
    }

    static func snapshot(
        _ snapshot: MemorySourceSnapshot,
        expectedGeneration: Int,
        at date: Date
    ) throws -> ValidatedMemorySourceSnapshot {
        guard expectedGeneration >= 0 else {
            throw MemorySourceReconciliationError.invalidSnapshot(
                "expectedGeneration must not be negative"
            )
        }
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw MemorySourceReconciliationError.invalidSnapshot("date must be finite")
        }
        let identity = try identity(identifier: snapshot.identifier, scope: snapshot.scope)
        var sourceRecordIDs: Set<String> = []
        var deduplicationKeys: Set<String> = []
        var validatedRecords: [ValidatedMemorySourceSnapshotRecord] = []
        validatedRecords.reserveCapacity(snapshot.records.count)

        for record in snapshot.records {
            try validateIdentifier(
                record.sourceRecordID,
                field: "sourceRecordID",
                maximumUTF8ByteCount:
                    MemorySourceSnapshotRecord.maximumSourceRecordIDUTF8ByteCount
            )
            guard sourceRecordIDs.insert(record.sourceRecordID).inserted else {
                throw MemorySourceReconciliationError.invalidSnapshot(
                    "sourceRecordID values must be unique"
                )
            }
            guard record.proposal.scope == snapshot.scope else {
                throw MemorySourceReconciliationError.invalidSnapshot(
                    "every proposal must use the source's exact scope"
                )
            }
            guard record.proposal.deduplicationKey != nil else {
                throw MemorySourceReconciliationError.invalidSnapshot(
                    "every proposal must provide an explicit deduplicationKey"
                )
            }
            let proposal: MemoryProposal
            do {
                proposal = try record.proposal.validated()
            } catch let error as MemoryStoreError {
                throw MemorySourceReconciliationError.invalidSnapshot(
                    error.localizedDescription
                )
            }
            let deduplicationKey = proposal.resolvedDeduplicationKey()
            guard deduplicationKeys.insert(deduplicationKey).inserted else {
                throw MemorySourceReconciliationError.invalidSnapshot(
                    "proposal deduplication keys must be unique within a snapshot"
                )
            }
            validatedRecords.append(ValidatedMemorySourceSnapshotRecord(
                sourceRecordID: record.sourceRecordID,
                proposal: proposal,
                deduplicationKey: deduplicationKey
            ))
        }
        return ValidatedMemorySourceSnapshot(
            identity: identity,
            records: validatedRecords,
            expectedGeneration: expectedGeneration,
            date: date
        )
    }

    static func nextGeneration(after generation: Int) throws -> Int {
        let (next, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else {
            throw MemorySourceReconciliationError.invalidSnapshot(
                "source generation cannot be advanced"
            )
        }
        return next
    }

    private static func validateIdentifier(
        _ identifier: String,
        field: String,
        maximumUTF8ByteCount: Int
    ) throws {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemorySourceReconciliationError.invalidSnapshot(
                "\(field) must not be empty"
            )
        }
        guard trimmed == identifier else {
            throw MemorySourceReconciliationError.invalidSnapshot(
                "\(field) must not have leading or trailing whitespace"
            )
        }
        guard identifier.utf8.count <= maximumUTF8ByteCount else {
            throw MemorySourceReconciliationError.invalidSnapshot(
                "\(field) exceeds \(maximumUTF8ByteCount) UTF-8 bytes"
            )
        }
        guard !identifier.unicodeScalars.contains(where: {
            $0.value == 0 || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw MemorySourceReconciliationError.invalidSnapshot(
                "\(field) must not contain NUL or control characters"
            )
        }
        guard identifier.utf8.elementsEqual(
            identifier.precomposedStringWithCanonicalMapping.utf8
        ) else {
            throw MemorySourceReconciliationError.invalidSnapshot(
                "\(field) must use NFC Unicode normalization"
            )
        }
    }
}
