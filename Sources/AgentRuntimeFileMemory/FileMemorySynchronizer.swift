import AgentRuntimeCore
import AgentRuntimeMemory
import Foundation

/// Rebuilds one exact source+scope index from a complete directory scan.
///
/// The file provider is read-only. A scan is fully materialized before the
/// store receives one atomic snapshot. Generation conflicts trigger another
/// full scan, so an older snapshot can never overwrite a newer concurrent scan.
public actor FileMemorySynchronizer {
    private let configuration: FileMemoryConfiguration
    private let fileAccess: any FileMemoryFileAccess
    private let store: any MemorySourceReconciliationStore

    public init(
        configuration: FileMemoryConfiguration,
        fileAccess: any FileMemoryFileAccess,
        store: any MemorySourceReconciliationStore
    ) {
        self.configuration = configuration
        self.fileAccess = fileAccess
        self.store = store
    }

    /// Performs a complete scan and one atomic source reconcile.
    ///
    /// File-system notifications should call this method only as a hint. Each
    /// invocation independently discovers the complete current source state.
    public func synchronize(at date: Date = .now) async throws -> FileMemorySyncReport {
        try validateRuntimeConfiguration()
        var conflictCount = 0

        for attempt in 0...configuration.maximumGenerationRetries {
            try Task.checkCancellation()
            let state = try await store.sourceState(
                identifier: configuration.sourceID,
                scope: configuration.scope
            )
            let expectedGeneration = state?.generation ?? 0
            // Capture the compare-and-swap token before reading any files. If
            // another scanner commits while this full scan is in progress,
            // reconciliation must conflict and retry from a fresh inventory.
            let scan = try await scanSource()
            let snapshot = MemorySourceSnapshot(
                identifier: configuration.sourceID,
                scope: configuration.scope,
                records: scan.records.sorted { $0.sourceRecordID < $1.sourceRecordID }
            )

            do {
                let reconciliation = try await store.reconcileSourceSnapshot(
                    snapshot,
                    expectedGeneration: expectedGeneration,
                    missingPolicy: configuration.missingPolicy,
                    at: date
                )
                return FileMemorySyncReport(
                    sourceID: configuration.sourceID,
                    previousGeneration: reconciliation.previousGeneration,
                    generation: reconciliation.generation,
                    directoriesScanned: scan.directoriesScanned,
                    filesScanned: scan.filesScanned,
                    bytesRead: scan.bytesRead,
                    chunkCount: scan.records.count,
                    generatedCharacterCount: scan.generatedCharacterCount,
                    created: reconciliation.created,
                    updated: reconciliation.updated,
                    unchanged: reconciliation.unchanged,
                    archived: reconciliation.archived,
                    purged: reconciliation.purged,
                    generationConflictCount: conflictCount,
                    skipped: scan.skipped,
                    rejected: scan.rejected
                )
            } catch MemorySourceReconciliationError.generationConflict {
                conflictCount += 1
                guard attempt < configuration.maximumGenerationRetries else {
                    throw FileMemoryError.generationConflictExhausted(attempts: conflictCount)
                }
                // Intentionally loop through a fresh full scan. Retrying a
                // previously materialized snapshot could restore stale files.
            }
        }

        throw FileMemoryError.generationConflictExhausted(attempts: conflictCount)
    }

    private struct ScanResult {
        var records: [MemorySourceSnapshotRecord]
        var directoriesScanned: Int
        var filesScanned: Int
        var bytesRead: Int
        var generatedCharacterCount: Int
        var skipped: [FileMemoryIssue]
        var rejected: [FileMemoryIssue]
    }

    private func scanSource() async throws -> ScanResult {
        var directories: [FileMemoryPath] = [.root]
        var directoryIndex = 0
        var files: [FileMemoryDirectoryEntry] = []
        var seenPaths: Set<FileMemoryPath> = []
        var skipped: [FileMemoryIssue] = []
        var rejected: [FileMemoryIssue] = []
        var directoriesScanned = 0
        var regularFileCount = 0
        var entryCount = 0

        while directoryIndex < directories.count {
            try Task.checkCancellation()
            let directory = directories[directoryIndex]
            directoryIndex += 1
            directoriesScanned += 1
            guard directoriesScanned <= configuration.maximumDirectoryCount else {
                throw FileMemoryError.limitExceeded(
                    .directoryCount,
                    limit: configuration.maximumDirectoryCount
                )
            }

            let remainingEntryCount = configuration.maximumEntryCount - entryCount
            guard remainingEntryCount > 0 else {
                throw FileMemoryError.limitExceeded(
                    .entryCount,
                    limit: configuration.maximumEntryCount
                )
            }
            let listed = try await fileAccess.listDirectory(
                at: directory,
                maximumEntryCount: remainingEntryCount
            )
                .sorted { $0.path < $1.path }
            for entry in listed {
                try Task.checkCancellation()
                entryCount += 1
                guard entryCount <= configuration.maximumEntryCount else {
                    throw FileMemoryError.limitExceeded(
                        .entryCount,
                        limit: configuration.maximumEntryCount
                    )
                }
                guard entry.path.parent == directory,
                      entry.path.depth == directory.depth + 1,
                      seenPaths.insert(entry.path).inserted else {
                    rejected.append(FileMemoryIssue(path: entry.path, reason: .invalidProviderEntry))
                    continue
                }

                if entry.isHidden || entry.path.name?.hasPrefix(".") == true {
                    rejected.append(FileMemoryIssue(path: entry.path, reason: .hidden))
                    continue
                }

                switch entry.kind {
                case .symbolicLink:
                    rejected.append(FileMemoryIssue(path: entry.path, reason: .symbolicLink))
                case .other:
                    rejected.append(FileMemoryIssue(path: entry.path, reason: .nonRegularFile))
                case .directory:
                    guard configuration.recursive else {
                        skipped.append(FileMemoryIssue(path: entry.path, reason: .depthLimit))
                        continue
                    }
                    guard entry.path.depth <= configuration.maximumDepth else {
                        skipped.append(FileMemoryIssue(path: entry.path, reason: .depthLimit))
                        continue
                    }
                    directories.append(entry.path)
                case .regularFile:
                    regularFileCount += 1
                    guard regularFileCount <= configuration.maximumFileCount else {
                        throw FileMemoryError.limitExceeded(
                            .fileCount,
                            limit: configuration.maximumFileCount
                        )
                    }
                    guard configuration.includedExtensions.contains(fileExtension(of: entry.path)) else {
                        skipped.append(FileMemoryIssue(
                            path: entry.path,
                            reason: .unsupportedExtension
                        ))
                        continue
                    }
                    files.append(entry)
                }
            }
        }

        files.sort { $0.path < $1.path }
        var records: [MemorySourceSnapshotRecord] = []
        var filesScanned = 0
        var bytesRead = 0
        var generatedCharacterCount = 0

        for entry in files {
            try Task.checkCancellation()
            filesScanned += 1
            if let byteCount = entry.byteCount,
               byteCount > configuration.maximumFileByteCount {
                rejected.append(FileMemoryIssue(path: entry.path, reason: .tooLarge))
                continue
            }

            let read: FileMemoryReadResult
            do {
                read = try await fileAccess.readFile(
                    at: entry.path,
                    maximumByteCount: configuration.maximumFileByteCount
                )
            } catch FileMemoryError.fileTooLarge {
                rejected.append(FileMemoryIssue(path: entry.path, reason: .tooLarge))
                continue
            } catch FileMemoryError.symbolicLink {
                rejected.append(FileMemoryIssue(path: entry.path, reason: .symbolicLink))
                continue
            } catch FileMemoryError.notRegularFile {
                rejected.append(FileMemoryIssue(path: entry.path, reason: .nonRegularFile))
                continue
            }

            guard entry.byteCount == nil || entry.byteCount == read.data.count,
                  entry.modifiedAt == nil || read.modifiedAt == nil || entry.modifiedAt == read.modifiedAt else {
                // Abort instead of reconciling a partial source. The next hint
                // or explicit invocation starts over from a clean inventory.
                throw FileMemoryError.changedDuringScan(entry.path)
            }
            guard read.data.count <= configuration.maximumFileByteCount else {
                rejected.append(FileMemoryIssue(path: entry.path, reason: .tooLarge))
                continue
            }

            let (newTotal, overflow) = bytesRead.addingReportingOverflow(read.data.count)
            guard !overflow, newTotal <= configuration.maximumTotalByteCount else {
                throw FileMemoryError.limitExceeded(
                    .totalBytes,
                    limit: configuration.maximumTotalByteCount
                )
            }
            bytesRead = newTotal

            guard !isBinary(read.data) else {
                rejected.append(FileMemoryIssue(path: entry.path, reason: .binaryContent))
                continue
            }
            guard let text = String(data: read.data, encoding: .utf8) else {
                rejected.append(FileMemoryIssue(path: entry.path, reason: .invalidUTF8))
                continue
            }

            let chunks = try FileMemoryChunker.chunks(
                in: text,
                path: entry.path,
                maximumCharacterCount: configuration.maximumChunkCharacterCount,
                maximumChunkCount: configuration.maximumChunkCount,
                maximumGeneratedCharacterCount: configuration.maximumGeneratedCharacterCount
            )
            guard !chunks.isEmpty else {
                skipped.append(FileMemoryIssue(path: entry.path, reason: .emptyContent))
                continue
            }

            let fileHash = FileMemoryChunker.sha256(read.data)
            let capturedAt = read.modifiedAt ?? entry.modifiedAt ?? Date(timeIntervalSince1970: 0)
            for chunk in chunks {
                guard records.count < configuration.maximumChunkCount else {
                    throw FileMemoryError.limitExceeded(
                        .chunkCount,
                        limit: configuration.maximumChunkCount
                    )
                }
                let headingCharacterCount = chunk.headingPath.reduce(into: 0) {
                    $0 += $1.count
                }
                let (contentAndHeading, contributionOverflow) = chunk.content.count
                    .addingReportingOverflow(headingCharacterCount)
                let (nextGeneratedCharacterCount, totalOverflow) = generatedCharacterCount
                    .addingReportingOverflow(contentAndHeading)
                guard !contributionOverflow,
                      !totalOverflow,
                      nextGeneratedCharacterCount
                        <= configuration.maximumGeneratedCharacterCount else {
                    throw FileMemoryError.limitExceeded(
                        .generatedCharacters,
                        limit: configuration.maximumGeneratedCharacterCount
                    )
                }
                generatedCharacterCount = nextGeneratedCharacterCount
                let headingValues = chunk.headingPath.map(JSONValue.string)
                let provenanceMetadata: [String: JSONValue] = [
                    "fileMemory.version": "1",
                    "fileMemory.sourceID": .string(configuration.sourceID),
                    "fileMemory.relativePath": .string(entry.path.relativePath),
                    "fileMemory.anchor": .string(chunk.anchor),
                    "fileMemory.fileSHA256": .string(fileHash),
                    "fileMemory.chunkSHA256": .string(chunk.contentSHA256),
                    "fileMemory.headingPath": .array(headingValues),
                    "fileMemory.paragraphIndex": .number(Double(chunk.paragraphIndex)),
                    "fileMemory.segmentIndex": .number(Double(chunk.segmentIndex)),
                ]
                let proposal = MemoryProposal(
                    scope: configuration.scope,
                    kind: configuration.memoryKind,
                    content: chunk.content,
                    sensitivity: configuration.maximumSensitivity,
                    provenance: MemoryProvenance(
                        source: "file-memory",
                        sourceID: chunk.id,
                        capturedAt: capturedAt,
                        metadata: provenanceMetadata
                    ),
                    confidence: configuration.confidence,
                    importance: configuration.importance,
                    deduplicationKey: "file-memory:\(configuration.sourceID):\(chunk.id)",
                    metadata: provenanceMetadata
                )
                records.append(MemorySourceSnapshotRecord(
                    sourceRecordID: chunk.id,
                    proposal: proposal
                ))
            }
        }

        return ScanResult(
            records: records,
            directoriesScanned: directoriesScanned,
            filesScanned: filesScanned,
            bytesRead: bytesRead,
            generatedCharacterCount: generatedCharacterCount,
            skipped: skipped.sorted(by: issueOrder),
            rejected: rejected.sorted(by: issueOrder)
        )
    }

    private func validateRuntimeConfiguration() throws {
        guard configuration.maximumSensitivity != .secret else {
            throw FileMemoryError.invalidConfiguration(
                "Secret files must use a secret store and cannot be indexed as memory."
            )
        }
        guard !configuration.sourceID.isEmpty,
              configuration.sourceID
                == configuration.sourceID.trimmingCharacters(in: .whitespacesAndNewlines),
              configuration.sourceID.utf8.count <= 512,
              configuration.sourceID.utf8.elementsEqual(
                configuration.sourceID.precomposedStringWithCanonicalMapping.utf8
              ) else {
            throw FileMemoryError.invalidConfiguration("sourceID is invalid at the synchronization boundary.")
        }
        guard !configuration.sourceID.unicodeScalars.contains(where: {
            $0.value == 0 || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw FileMemoryError.invalidConfiguration(
                "sourceID must not contain NUL or control characters."
            )
        }
        guard configuration.maximumDepth >= 0,
              configuration.maximumDepth <= 128,
              configuration.maximumEntryCount > 0,
              configuration.maximumDirectoryCount > 0,
              configuration.maximumFileCount > 0,
              configuration.maximumFileByteCount > 0,
              configuration.maximumTotalByteCount >= configuration.maximumFileByteCount,
              configuration.maximumChunkCharacterCount >= 128,
              configuration.maximumChunkCount > 0,
              configuration.maximumGeneratedCharacterCount > 0,
              !configuration.includedExtensions.isEmpty,
              configuration.confidence.isFinite,
              (0...1).contains(configuration.confidence),
              configuration.importance.isFinite,
              (0...1).contains(configuration.importance),
              (0...20).contains(configuration.maximumGenerationRetries),
              configuration.includedExtensions.allSatisfy({ fileExtensionIsCanonical($0) }) else {
            throw FileMemoryError.invalidConfiguration(
                "Decoded file-memory configuration contains an unsafe limit or value."
            )
        }
    }

    private func fileExtension(of path: FileMemoryPath) -> String {
        guard let name = path.name, let separator = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: separator)...]).lowercased()
    }

    private func fileExtensionIsCanonical(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.lowercased()
            && value.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    private func isBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        var suspicious = 0
        for byte in data {
            if byte == 0 { return true }
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0C, byte != 0x0D {
                suspicious += 1
            }
        }
        return suspicious > max(0, data.count / 100)
    }

    private func issueOrder(_ lhs: FileMemoryIssue, _ rhs: FileMemoryIssue) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.reason.rawValue < rhs.reason.rawValue
    }
}
