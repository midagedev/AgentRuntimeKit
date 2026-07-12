import Foundation
import AgentRuntimeMemory

public enum AgentFileProtection: String, Sendable, Codable, Hashable {
    case complete
    case completeUnlessOpen
    case completeUntilFirstUserAuthentication
    case none

    fileprivate var foundationValue: FileProtectionType {
        switch self {
        case .complete: .complete
        case .completeUnlessOpen: .completeUnlessOpen
        case .completeUntilFirstUserAuthentication: .completeUntilFirstUserAuthentication
        case .none: .none
        }
    }

    fileprivate var writingOption: Data.WritingOptions {
        switch self {
        case .complete: .completeFileProtection
        case .completeUnlessOpen: .completeFileProtectionUnlessOpen
        case .completeUntilFirstUserAuthentication:
            .completeFileProtectionUntilFirstUserAuthentication
        case .none: .noFileProtection
        }
    }
}

public enum ProtectedAgentFileStoreError: LocalizedError, Sendable, Equatable {
    case directoryIsNotDirectory
    case symbolicLinkNotAllowed

    public var errorDescription: String? {
        switch self {
        case .directoryIsNotDirectory:
            "The protected store location is not a directory."
        case .symbolicLinkNotAllowed:
            "Symbolic links are not allowed in the protected store."
        }
    }
}

private struct ProtectedAgentFileStorage {
    let directory: URL
    let protection: AgentFileProtection
    let fileManager: FileManager

    init(
        directory: URL,
        protection: AgentFileProtection,
        fileManager: FileManager = FileManager()
    ) {
        self.directory = directory
        self.protection = protection
        self.fileManager = fileManager
    }

    func prepareDirectory() throws {
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ProtectedAgentFileStoreError.directoryIsNotDirectory
            }
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw ProtectedAgentFileStoreError.symbolicLinkNotAllowed
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(directoryAttributes, ofItemAtPath: directory.path)
    }

    func ensureRegularDestination(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw ProtectedAgentFileStoreError.symbolicLinkNotAllowed
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        try ensureRegularDestination(url)
        try data.write(to: url, options: [.atomic, protection.writingOption])
        try protectFile(at: url)
    }

    func protectFile(at url: URL) throws {
        try fileManager.setAttributes(fileAttributes, ofItemAtPath: url.path)
    }

    var directoryAttributes: [FileAttributeKey: Any] {
        [
            .posixPermissions: NSNumber(value: Int16(0o700)),
            .protectionKey: protection.foundationValue,
        ]
    }

    var fileAttributes: [FileAttributeKey: Any] {
        [
            .posixPermissions: NSNumber(value: Int16(0o600)),
            .protectionKey: protection.foundationValue,
        ]
    }
}

private struct ProtectedCheckpointEnvelope: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var checkpoint: AgentRunCheckpoint

    init(checkpoint: AgentRunCheckpoint) {
        formatVersion = Self.currentFormatVersion
        self.checkpoint = checkpoint
    }
}

/// Stores each checkpoint as an atomically replaced, protected JSON document.
public actor ProtectedFileAgentCheckpointStore: AgentCheckpointStore {
    public struct Configuration: Sendable, Hashable {
        public var directory: URL
        public var protection: AgentFileProtection
        public var maximumCheckpointsPerIdentity: Int

        public init(
            directory: URL,
            protection: AgentFileProtection = .completeUntilFirstUserAuthentication,
            maximumCheckpointsPerIdentity: Int = 20
        ) {
            self.directory = directory
            self.protection = protection
            self.maximumCheckpointsPerIdentity = max(1, maximumCheckpointsPerIdentity)
        }
    }

    private let storage: ProtectedAgentFileStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumCheckpointsPerIdentity: Int

    public init(configuration: Configuration) {
        storage = ProtectedAgentFileStorage(
            directory: configuration.directory,
            protection: configuration.protection
        )
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        maximumCheckpointsPerIdentity = configuration.maximumCheckpointsPerIdentity
    }

    public func save(_ checkpoint: AgentRunCheckpoint) throws {
        try Task.checkCancellation()
        let data = try encoder.encode(ProtectedCheckpointEnvelope(checkpoint: checkpoint))
        try storage.writeAtomically(data, to: url(for: checkpoint.id))
        // Retention is best effort after the requested checkpoint is safely on disk.
        // A cleanup failure must not turn a successful write-ahead save into an
        // ambiguous non-idempotent execution state.
        try? pruneCheckpoints(olderThan: checkpoint)
    }

    public func load(id: UUID) throws -> AgentRunCheckpoint? {
        try Task.checkCancellation()
        let url = url(for: id)
        guard storage.fileManager.fileExists(atPath: url.path) else { return nil }
        try storage.ensureRegularDestination(url)
        return try decodeCheckpoint(at: url)
    }

    public func latest(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) throws -> AgentRunCheckpoint? {
        try Task.checkCancellation()
        guard storage.fileManager.fileExists(atPath: storage.directory.path) else { return nil }
        try storage.prepareDirectory()

        let urls = try storage.fileManager.contentsOfDirectory(
            at: storage.directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var newest: AgentRunCheckpoint?
        for url in urls where url.pathExtension == "json" {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard let checkpoint = try? decodeCheckpoint(at: url) else { continue }
            guard checkpoint.appID == appID,
                  checkpoint.userID == userID,
                  checkpoint.sessionID == sessionID,
                  checkpoint.agentID == agentID
            else { continue }
            if newest == nil || checkpoint.createdAt > newest!.createdAt {
                newest = checkpoint
            }
        }
        return newest
    }

    public func delete(id: UUID) throws {
        try Task.checkCancellation()
        let url = url(for: id)
        guard storage.fileManager.fileExists(atPath: url.path) else { return }
        try storage.ensureRegularDestination(url)
        try storage.fileManager.removeItem(at: url)
    }

    public func deleteAll(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) throws {
        try Task.checkCancellation()
        guard storage.fileManager.fileExists(atPath: storage.directory.path) else { return }
        try storage.prepareDirectory()
        let urls = try storage.fileManager.contentsOfDirectory(
            at: storage.directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "json" {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let checkpoint: AgentRunCheckpoint
            do {
                checkpoint = try decodeCheckpoint(at: url)
            } catch {
                throw AgentCheckpointStoreError.corruptCheckpoint(
                    UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                )
            }
            guard checkpoint.appID == appID,
                  checkpoint.userID == userID,
                  checkpoint.sessionID == sessionID,
                  checkpoint.agentID == agentID
            else { continue }
            try storage.ensureRegularDestination(url)
            try storage.fileManager.removeItem(at: url)
        }
    }

    public func unresolved(
        appID: String,
        userID: String?,
        sessionID: String,
        agentID: String
    ) async throws -> [AgentUnresolvedToolExecution] {
        try Task.checkCancellation()
        guard storage.fileManager.fileExists(atPath: storage.directory.path) else { return [] }
        try storage.prepareDirectory()
        let urls = try storage.fileManager.contentsOfDirectory(
            at: storage.directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var result: [AgentUnresolvedToolExecution] = []
        for url in urls where url.pathExtension == "json" {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let checkpoint: AgentRunCheckpoint
            do {
                checkpoint = try decodeCheckpoint(at: url)
            } catch {
                throw AgentCheckpointStoreError.corruptCheckpoint(
                    UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                )
            }
            guard checkpoint.appID == appID,
                  checkpoint.userID == userID,
                  checkpoint.sessionID == sessionID,
                  checkpoint.agentID == agentID
            else { continue }
            result.append(contentsOf: checkpoint.unresolvedNonIdempotentToolExecutions.map {
                AgentUnresolvedToolExecution(
                    checkpointID: checkpoint.id,
                    checkpointCreatedAt: checkpoint.createdAt,
                    record: $0
                )
            })
        }
        return result.sorted {
            if $0.checkpointCreatedAt == $1.checkpointCreatedAt {
                return $0.record.callID < $1.record.callID
            }
            return $0.checkpointCreatedAt < $1.checkpointCreatedAt
        }
    }

    public func reconcile(
        _ reconciliation: AgentToolExecutionReconciliation
    ) async throws -> AgentRunCheckpoint {
        try Task.checkCancellation()
        guard let checkpoint = try load(id: reconciliation.checkpointID) else {
            throw AgentCheckpointStoreError.checkpointNotFound(reconciliation.checkpointID)
        }
        let updated = try checkpoint.reconciling(reconciliation)
        try save(updated)
        return updated
    }

    private func url(for id: UUID) -> URL {
        storage.directory
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("json")
    }

    private func decodeCheckpoint(at url: URL) throws -> AgentRunCheckpoint {
        let data = try Data(contentsOf: url)
        if let envelope = try? decoder.decode(ProtectedCheckpointEnvelope.self, from: data) {
            guard envelope.formatVersion == ProtectedCheckpointEnvelope.currentFormatVersion else {
                throw AgentCheckpointStoreError.corruptCheckpoint(
                    UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                )
            }
            return envelope.checkpoint
        }
        // Version 0 stored AgentRunCheckpoint directly. Reading it is the
        // migration; the next save atomically rewrites it in the envelope.
        return try decoder.decode(AgentRunCheckpoint.self, from: data)
    }

    private func pruneCheckpoints(olderThan saved: AgentRunCheckpoint) throws {
        let urls = try storage.fileManager.contentsOfDirectory(
            at: storage.directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var matching: [(url: URL, checkpoint: AgentRunCheckpoint)] = []
        for url in urls where url.pathExtension == "json" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let checkpoint = try? decodeCheckpoint(at: url),
                  checkpoint.appID == saved.appID,
                  checkpoint.userID == saved.userID,
                  checkpoint.sessionID == saved.sessionID,
                  checkpoint.agentID == saved.agentID
            else { continue }
            matching.append((url, checkpoint))
        }
        // Automatic retention must never erase evidence of a write whose
        // external effect still requires host reconciliation.
        let obsolete = matching
            .filter { $0.checkpoint.unresolvedNonIdempotentToolExecutions.isEmpty }
            .sorted { $0.checkpoint.createdAt > $1.checkpoint.createdAt }
            .dropFirst(maximumCheckpointsPerIdentity)
        for entry in obsolete {
            try storage.ensureRegularDestination(entry.url)
            try storage.fileManager.removeItem(at: entry.url)
        }
    }
}

public typealias AppleProtectedCheckpointStore = ProtectedFileAgentCheckpointStore

/// An Apple-platform SQLite memory store that reapplies strict permissions and
/// data-protection attributes to the database and its WAL/SHM sidecars after
/// every operation that can create them.
///
/// The wrapped SQLite store is deliberately not exposed: routing access through
/// this actor keeps future sidecar creation inside the protection boundary.
public actor ProtectedSQLiteMemoryStore: MemoryStore {
    public struct Configuration: Sendable, Hashable {
        /// Keep this URL in the app, app-group, or CloudKit container. The
        /// package privacy manifest declares Apple's C617.1 container reason
        /// for the file metadata checks used to reject symbolic links.
        public var databaseURL: URL
        public var protection: AgentFileProtection
        public var busyTimeoutMilliseconds: Int

        public init(
            databaseURL: URL,
            protection: AgentFileProtection = .completeUntilFirstUserAuthentication,
            busyTimeoutMilliseconds: Int = 5_000
        ) {
            self.databaseURL = databaseURL
            self.protection = protection
            self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        }
    }

    public nonisolated let databaseURL: URL

    private let store: SQLiteMemoryStore
    private let storage: ProtectedAgentFileStorage

    public init(configuration: Configuration) throws {
        databaseURL = configuration.databaseURL.standardizedFileURL
        storage = ProtectedAgentFileStorage(
            directory: databaseURL.deletingLastPathComponent(),
            protection: configuration.protection
        )
        try storage.prepareDirectory()
        for url in Self.artifactURLs(for: databaseURL) {
            try storage.ensureRegularDestination(url)
        }
        store = try SQLiteMemoryStore(
            url: databaseURL,
            busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds
        )
        try Self.protectArtifacts(storage: storage, databaseURL: databaseURL)
    }

    public func upsert(
        _ proposal: MemoryProposal,
        status: MemoryStatus,
        expectedRevision: Int?,
        at date: Date
    ) async throws -> MemoryRecord {
        let record = try await store.upsert(
            proposal,
            status: status,
            expectedRevision: expectedRevision,
            at: date
        )
        try protectArtifacts()
        return record
    }

    public func fetch(
        id: UUID,
        scope: MemoryScope,
        includeExpired: Bool,
        at date: Date
    ) async throws -> MemoryRecord? {
        let record = try await store.fetch(
            id: id,
            scope: scope,
            includeExpired: includeExpired,
            at: date
        )
        try protectArtifacts()
        return record
    }

    public func update(
        id: UUID,
        scope: MemoryScope,
        patch: MemoryPatch,
        expectedRevision: Int,
        at date: Date
    ) async throws -> MemoryRecord {
        let record = try await store.update(
            id: id,
            scope: scope,
            patch: patch,
            expectedRevision: expectedRevision,
            at: date
        )
        try protectArtifacts()
        return record
    }

    public func delete(
        id: UUID,
        scope: MemoryScope,
        expectedRevision: Int,
        at date: Date
    ) async throws {
        try await store.delete(
            id: id,
            scope: scope,
            expectedRevision: expectedRevision,
            at: date
        )
        try protectArtifacts()
    }

    public func purge(id: UUID, scope: MemoryScope) async throws -> MemoryPurgeResult {
        do {
            let result = try await store.purge(id: id, scope: scope)
            try protectArtifacts()
            return result
        } catch {
            // SQLite can commit the row purge before physical compaction or a
            // WAL checkpoint reports a failure. Reapply the file boundary on
            // both success and failure, and never hide a protection failure.
            let operationError = error
            try protectArtifacts()
            throw operationError
        }
    }

    public func purge(scopes: [MemoryScope]) async throws -> MemoryPurgeResult {
        do {
            let result = try await store.purge(scopes: scopes)
            try protectArtifacts()
            return result
        } catch {
            let operationError = error
            try protectArtifacts()
            throw operationError
        }
    }

    public func recordsOwned(appID: String, userID: String) async throws -> [MemoryRecord] {
        let records = try await store.recordsOwned(appID: appID, userID: userID)
        try protectArtifacts()
        return records
    }

    public func purgeOwned(appID: String, userID: String) async throws -> MemoryPurgeResult {
        do {
            let result = try await store.purgeOwned(appID: appID, userID: userID)
            try protectArtifacts()
            return result
        } catch {
            let operationError = error
            try protectArtifacts()
            throw operationError
        }
    }

    public func retrieve(_ query: MemoryQuery) async throws -> MemoryRetrievalResult {
        let result = try await store.retrieve(query)
        try protectArtifacts()
        return result
    }

    public func events(
        scope: MemoryScope,
        recordID: UUID?,
        limit: Int
    ) async throws -> [MemoryEvent] {
        let result = try await store.events(scope: scope, recordID: recordID, limit: limit)
        try protectArtifacts()
        return result
    }

    public func diagnostics() async throws -> SQLiteMemoryStoreDiagnostics {
        let result = try await store.diagnostics()
        try protectArtifacts()
        return result
    }

    public func close() async throws {
        try await store.close()
        try protectArtifacts()
    }

    /// Explicitly verifies and reapplies protection, useful after a host has
    /// restored files from backup before it resumes normal memory operations.
    public func refreshProtection() throws {
        try protectArtifacts()
    }

    private func protectArtifacts() throws {
        try Self.protectArtifacts(storage: storage, databaseURL: databaseURL)
    }

    private static func protectArtifacts(
        storage: ProtectedAgentFileStorage,
        databaseURL: URL
    ) throws {
        try storage.prepareDirectory()
        for url in Self.artifactURLs(for: databaseURL)
            where storage.fileManager.fileExists(atPath: url.path) {
            try storage.ensureRegularDestination(url)
            try storage.protectFile(at: url)
        }
    }

    private static func artifactURLs(for databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }
}

public enum AppleProtectedMemoryStoreFactory {
    public static func makeSQLiteStore(
        configuration: ProtectedSQLiteMemoryStore.Configuration
    ) throws -> ProtectedSQLiteMemoryStore {
        try ProtectedSQLiteMemoryStore(configuration: configuration)
    }
}

/// Recursively redacts likely credential fields before an audit record reaches disk.
public struct AgentAuditRedactionPolicy: Sendable, Hashable {
    public var sensitiveKeyFragments: Set<String>
    public var replacement: String

    public init(
        sensitiveKeyFragments: Set<String> = [
            "authorization", "apikey", "accesstoken", "refreshtoken", "idtoken",
            "password", "passphrase", "secret", "clientsecret", "credential",
            "credentials", "cookie", "setcookie", "privatekey", "error", "message",
        ],
        replacement: String = "[REDACTED]"
    ) {
        self.sensitiveKeyFragments = Set(sensitiveKeyFragments.map(Self.normalize))
        self.replacement = replacement
    }

    public func redact(_ detail: [String: JSONValue]) -> [String: JSONValue] {
        detail.reduce(into: [:]) { result, pair in
            let (key, value) = pair
            result[key] = isSensitive(key: key) ? .string(replacement) : redact(value)
        }
    }

    private func redact(_ value: JSONValue, keyIsSensitive: Bool = false) -> JSONValue {
        if keyIsSensitive { return .string(replacement) }
        switch value {
        case .object(let object):
            return .object(object.reduce(into: [:]) { result, pair in
                let (key, nestedValue) = pair
                result[key] = isSensitive(key: key)
                    ? .string(replacement)
                    : redact(nestedValue)
            })
        case .array(let array):
            return .array(array.map { redact($0) })
        case .string(let string) where isSensitive(value: string):
            return .string(replacement)
        default:
            return value
        }
    }

    private func isSensitive(key: String) -> Bool {
        let normalized = Self.normalize(key)
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private func isSensitive(value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("bearer ") || normalized.hasPrefix("basic ") {
            return true
        }
        if normalized.contains("-----begin ") && normalized.contains("private key-----") {
            return true
        }
        return sensitiveKeyFragments.contains { fragment in
            normalized.contains("\(fragment)=") || normalized.contains("\(fragment)%3d")
        }
    }

    private static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}

/// A best-effort JSON Lines audit sink with actor-serialized appends and redaction.
///
/// `AgentAuditSink.record` cannot throw. Failures are counted and exposed through
/// ``droppedRecordCount`` without logging record contents or underlying error text.
public actor RedactedJSONLAgentAuditSink: AgentAuditSink {
    public struct Configuration: Sendable, Hashable {
        public var fileURL: URL
        public var protection: AgentFileProtection
        public var redactionPolicy: AgentAuditRedactionPolicy
        public var synchronizeAfterWrite: Bool

        public init(
            fileURL: URL,
            protection: AgentFileProtection = .completeUntilFirstUserAuthentication,
            redactionPolicy: AgentAuditRedactionPolicy = AgentAuditRedactionPolicy(),
            synchronizeAfterWrite: Bool = false
        ) {
            self.fileURL = fileURL
            self.protection = protection
            self.redactionPolicy = redactionPolicy
            self.synchronizeAfterWrite = synchronizeAfterWrite
        }
    }

    public private(set) var droppedRecordCount = 0
    public private(set) var lastWriteFailedAt: Date?

    private let configuration: Configuration
    private let storage: ProtectedAgentFileStorage
    private let encoder: JSONEncoder

    public init(configuration: Configuration) {
        self.configuration = configuration
        storage = ProtectedAgentFileStorage(
            directory: configuration.fileURL.deletingLastPathComponent(),
            protection: configuration.protection
        )
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    public func record(_ record: AgentAuditRecord) {
        do {
            var redacted = record
            redacted.detail = configuration.redactionPolicy.redact(record.detail)
            var data = try encoder.encode(redacted)
            data.append(0x0A)
            try append(data)
        } catch {
            // The protocol is intentionally best-effort. Never log the record or
            // the underlying error because either could contain sensitive values.
            droppedRecordCount += 1
            lastWriteFailedAt = .now
        }
    }

    private func append(_ data: Data) throws {
        try storage.prepareDirectory()
        let url = configuration.fileURL
        try storage.ensureRegularDestination(url)
        if !storage.fileManager.fileExists(atPath: url.path) {
            try Data().write(to: url, options: configuration.protection.writingOption)
            try storage.protectFile(at: url)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        if configuration.synchronizeAfterWrite {
            try handle.synchronize()
        }
        try storage.protectFile(at: url)
    }
}

public typealias AppleJSONLAuditSink = RedactedJSONLAgentAuditSink
