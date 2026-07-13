import AgentRuntimeCore
import AgentRuntimeFileMemory
import AgentRuntimeMemory
import Foundation
import XCTest

final class FileMemorySynchronizerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testCreateUpdateRenameArchiveDeleteAndReappearanceKeepExpectedIdentities() async throws {
        let root = try temporaryDirectory()
        let source = root.appending(path: "memory.md")
        try write("# Profile\n\nLikes green tea.", to: source)

        let store = InMemoryMemoryStore()
        let scope = MemoryScope.user(appID: "product", userID: "person")
        let synchronizer = try makeSynchronizer(root: root, store: store, scope: scope)

        let created = try await synchronizer.synchronize()
        XCTAssertEqual(created.created, 1)
        XCTAssertEqual(created.chunkCount, 1)
        XCTAssertEqual(created.generation, 1)
        let createdRecords = try await allRecords(store, scope: scope)
        let original = try XCTUnwrap(createdRecords.first)
        XCTAssertEqual(original.status, .active)
        XCTAssertEqual(original.provenance.metadata["fileMemory.relativePath"], "memory.md")

        try write("# Profile\n\nLikes jasmine tea.", to: source)
        let updated = try await synchronizer.synchronize()
        XCTAssertEqual(updated.updated, 1)
        let updatedRecords = try await allRecords(store, scope: scope)
        let replacement = try XCTUnwrap(updatedRecords.first)
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.revision, original.revision + 1)
        XCTAssertTrue(replacement.content.contains("jasmine"))

        let renamed = root.appending(path: "person.md")
        try FileManager.default.moveItem(at: source, to: renamed)
        let renameReport = try await synchronizer.synchronize()
        XCTAssertEqual(renameReport.created, 1)
        XCTAssertEqual(renameReport.archived, 1)
        let afterRename = try await allRecords(store, scope: scope)
        let renamedRecord = try XCTUnwrap(afterRename.first { $0.status == .active })
        XCTAssertNotEqual(renamedRecord.id, original.id)
        XCTAssertEqual(afterRename.first { $0.id == original.id }?.status, .archived)

        try FileManager.default.removeItem(at: renamed)
        let deleteReport = try await synchronizer.synchronize()
        XCTAssertEqual(deleteReport.archived, 1)
        let activeAfterDelete = try await activeRecords(store, scope: scope)
        XCTAssertTrue(activeAfterDelete.isEmpty)

        try write("# Profile\n\nLikes jasmine tea.", to: renamed)
        let restored = try await synchronizer.synchronize()
        XCTAssertEqual(restored.updated, 1)
        let restoredRecords = try await activeRecords(store, scope: scope)
        let activeAgain = try XCTUnwrap(restoredRecords.first)
        XCTAssertEqual(activeAgain.id, renamedRecord.id)
    }

    func testPurgePolicyPhysicallyRemovesMissingSourceRecordAndAudit() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "memory.txt")
        try write("One durable paragraph.", to: file)
        let store = InMemoryMemoryStore()
        let scope = MemoryScope.user(appID: "product", userID: "person")
        let synchronizer = try makeSynchronizer(
            root: root,
            store: store,
            scope: scope,
            missingPolicy: .purge
        )

        _ = try await synchronizer.synchronize()
        let initialRecords = try await activeRecords(store, scope: scope)
        let record = try XCTUnwrap(initialRecords.first)
        try FileManager.default.removeItem(at: file)
        let report = try await synchronizer.synchronize()

        XCTAssertEqual(report.purged, 1)
        let purgedRecord = try await store.fetch(id: record.id, scope: scope, includeExpired: true)
        let purgedEvents = try await store.events(scope: scope, recordID: record.id)
        XCTAssertNil(purgedRecord)
        XCTAssertTrue(purgedEvents.isEmpty)
    }

    func testLocalAccessRejectsTraversalRootSymlinkAndNestedSymlink() async throws {
        for path in ["/private.md", "../private.md", "folder//file.md", "folder\\file.md", "~/.memory"] {
            XCTAssertThrowsError(try FileMemoryPath(path), "Expected unsafe path to fail: \(path)")
        }

        let parent = try temporaryDirectory()
        let root = parent.appending(path: "root", directoryHint: .isDirectory)
        let outside = parent.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("Must not be indexed.", to: outside.appending(path: "secret.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "escape.md"),
            withDestinationURL: outside.appending(path: "secret.md")
        )
        try write("Hidden.", to: root.appending(path: ".hidden.md"))

        let rootLink = parent.appending(path: "root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        XCTAssertThrowsError(try LocalDirectoryFileMemoryAccess(rootURL: rootLink))

        let store = InMemoryMemoryStore()
        let scope = MemoryScope.application(appID: "product")
        let synchronizer = try makeSynchronizer(root: root, store: store, scope: scope)
        let report = try await synchronizer.synchronize()

        XCTAssertEqual(report.rejectedCount, 2)
        XCTAssertEqual(Set(report.rejected.map(\.reason)), [.symbolicLink, .hidden])
        let indexed = try await activeRecords(store, scope: scope)
        XCTAssertTrue(indexed.isEmpty)
    }

    func testCanonicalUnicodeVariantsRemainDistinctPathIdentitiesAndInventoryEntries() async throws {
        let composed = try FileMemoryPath("\u{00E9}.md")
        let decomposed = try FileMemoryPath("e\u{0301}.md")
        XCTAssertNotEqual(Array(composed.relativePath.utf8), Array(decomposed.relativePath.utf8))
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
        let sorted = [composed, decomposed].sorted()
        XCTAssertEqual(sorted.count, 2)
        XCTAssertTrue(sorted[0] < sorted[1])
        XCTAssertFalse(sorted[1] < sorted[0])

        let store = InMemoryMemoryStore()
        let scope = MemoryScope.application(appID: "canonical-path-test")
        let synchronizer = FileMemorySynchronizer(
            configuration: try FileMemoryConfiguration(
                sourceID: "canonical-path-source",
                scope: scope
            ),
            fileAccess: CanonicalVariantFileAccess(
                composed: composed,
                decomposed: decomposed
            ),
            store: store
        )

        let report = try await synchronizer.synchronize()
        XCTAssertEqual(report.filesScanned, 2)
        XCTAssertEqual(report.created, 2)
        XCTAssertTrue(report.rejected.isEmpty)
        let records = try await activeRecords(store, scope: scope)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            Set(records.compactMap {
                guard let path = $0.provenance.metadata["fileMemory.relativePath"]?.stringValue else {
                    return nil
                }
                return Data(path.utf8)
            }),
            Set([Data(composed.relativePath.utf8), Data(decomposed.relativePath.utf8)])
        )
    }

    func testRejectsOversizedBinaryAndInvalidUTF8WithoutPartialContent() async throws {
        let root = try temporaryDirectory()
        try Data([0x61, 0x00, 0x62]).write(to: root.appending(path: "binary.md"))
        try Data([0xC3, 0x28]).write(to: root.appending(path: "invalid.md"))
        try Data(repeating: 0x61, count: 257).write(to: root.appending(path: "large.md"))
        try write("", to: root.appending(path: "empty.md"))
        try write("ignored", to: root.appending(path: "image.png"))

        let store = InMemoryMemoryStore()
        let scope = MemoryScope.application(appID: "product")
        let synchronizer = try makeSynchronizer(
            root: root,
            store: store,
            scope: scope,
            maximumFileByteCount: 256,
            maximumTotalByteCount: 1_024
        )
        let report = try await synchronizer.synchronize()

        XCTAssertEqual(
            Set(report.rejected.map(\.reason)),
            [.binaryContent, .invalidUTF8, .tooLarge]
        )
        XCTAssertEqual(
            Set(report.skipped.map(\.reason)),
            [.emptyContent, .unsupportedExtension]
        )
        let indexed = try await activeRecords(store, scope: scope)
        XCTAssertTrue(indexed.isEmpty)
    }

    func testChunkIdentityIsStableAcrossContentChangesAndHashesAreDeterministic() throws {
        let path = try FileMemoryPath("notes/profile.md")
        let original = try FileMemoryChunker.chunks(
            in: "# Profile\r\n\r\nLikes tea.\r\n\r\n## Work\r\n\r\nBuilds apps.",
            path: path,
            maximumCharacterCount: 256
        )
        let changed = try FileMemoryChunker.chunks(
            in: "# Profile\n\nLikes coffee.\n\n## Work\n\nBuilds apps.",
            path: path,
            maximumCharacterCount: 256
        )
        let normalizedOriginal = try FileMemoryChunker.chunks(
            in: "# Profile\n\nLikes tea.\n\n## Work\n\nBuilds apps.",
            path: path,
            maximumCharacterCount: 256
        )

        XCTAssertEqual(original.map(\.id), changed.map(\.id))
        XCTAssertNotEqual(original[0].contentSHA256, changed[0].contentSHA256)
        XCTAssertEqual(original[1].contentSHA256, changed[1].contentSHA256)
        XCTAssertEqual(original, normalizedOriginal)
        XCTAssertEqual(Set(original.map(\.id)).count, original.count)
    }

    func testFencedMarkdownHeadingDoesNotChangeStructuralChunkingAndLongTextIsBounded() throws {
        let path = try FileMemoryPath("memory.md")
        let text = """
        # Real heading

        ```swift
        # not a heading
        let value = 1
        ```

        \(String(repeating: "word ", count: 300))
        """
        let chunks = try FileMemoryChunker.chunks(
            in: text,
            path: path,
            maximumCharacterCount: 160
        )

        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.headingPath == ["Real heading"] })
        // Context headings add characters after bounded source splitting.
        XCTAssertTrue(chunks.allSatisfy { $0.content.count <= 160 + 32 })
        XCTAssertEqual(Set(chunks.map(\.id)).count, chunks.count)
    }

    func testLongHeadingIsCappedAndGeneratedCharacterAmplificationIsBounded() throws {
        let path = try FileMemoryPath("memory.md")
        let heading = String(repeating: "H", count: 20_000)
        let text = "# \(heading)\n\nbody"
        let chunks = try FileMemoryChunker.chunks(
            in: text,
            path: path,
            maximumCharacterCount: 128,
            maximumChunkCount: 10,
            maximumGeneratedCharacterCount: 1_000
        )

        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunk.headingPath.count, 1)
        XCTAssertEqual(
            chunk.headingPath[0].count,
            FileMemoryChunker.maximumHeadingComponentCharacterCount
        )
        XCTAssertEqual(
            chunk.headingPath[0],
            String(heading.prefix(FileMemoryChunker.maximumHeadingComponentCharacterCount))
        )

        XCTAssertThrowsError(try FileMemoryChunker.chunks(
            in: text,
            path: path,
            maximumCharacterCount: 128,
            maximumChunkCount: 10,
            maximumGeneratedCharacterCount: 500
        )) { error in
            XCTAssertEqual(
                error as? FileMemoryError,
                .limitExceeded(.generatedCharacters, limit: 500)
            )
        }
    }

    func testMillionCharacterParagraphChunksWithinLinearTimeAndBudgets() throws {
        let path = try FileMemoryPath("memory.txt")
        let text = String(repeating: "x", count: 1_000_000)
        let clock = ContinuousClock()
        let startedAt = clock.now

        let chunks = try FileMemoryChunker.chunks(
            in: text,
            path: path,
            maximumCharacterCount: 128,
            maximumChunkCount: 10_000,
            maximumGeneratedCharacterCount: 2_000_000
        )
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(chunks.count, 7_813)
        XCTAssertLessThanOrEqual(chunks.count, 10_000)
        XCTAssertLessThanOrEqual(
            chunks.reduce(into: 0) { $0 += $1.content.count },
            2_000_000
        )
        XCTAssertLessThan(elapsed, .seconds(5), "Chunking took \(elapsed)")
    }

    func testRecursiveDepthAndMoreThanTwoThousandFilesAreBoundedBeforeReconcile() async throws {
        let root = try temporaryDirectory()
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("nested content", to: nested.appending(path: "nested.md"))
        for index in 0..<2_001 {
            try write("x", to: root.appending(path: "\(index).txt"))
        }

        let store = InMemoryMemoryStore()
        let scope = MemoryScope.application(appID: "product")
        let configuration = try FileMemoryConfiguration(
            sourceID: "bounded-source",
            scope: scope,
            maximumDepth: 0,
            maximumFileCount: 2_000,
            maximumFileByteCount: 128,
            maximumTotalByteCount: 1_000_000,
            maximumChunkCharacterCount: 128
        )
        let synchronizer = FileMemorySynchronizer(
            configuration: configuration,
            fileAccess: try LocalDirectoryFileMemoryAccess(rootURL: root),
            store: store
        )

        do {
            _ = try await synchronizer.synchronize()
            XCTFail("Expected file-count enforcement before reconcile")
        } catch let error as FileMemoryError {
            XCTAssertEqual(error, .limitExceeded(.fileCount, limit: 2_000))
        }
        let state = try await store.sourceState(identifier: "bounded-source", scope: scope)
        XCTAssertNil(state)
    }

    func testAllDirectoryEntriesCountTowardInventoryLimitBeforeReconcile() async throws {
        let root = try temporaryDirectory()
        try write("hidden", to: root.appending(path: ".one.txt"))
        try write("unsupported", to: root.appending(path: "two.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "three-link"),
            withDestinationURL: root.appending(path: ".one.txt")
        )

        let store = InMemoryMemoryStore()
        let scope = MemoryScope.application(appID: "product")
        let configuration = try FileMemoryConfiguration(
            sourceID: "entry-bounded-source",
            scope: scope,
            maximumEntryCount: 2
        )
        let synchronizer = FileMemorySynchronizer(
            configuration: configuration,
            fileAccess: try LocalDirectoryFileMemoryAccess(rootURL: root),
            store: store
        )

        do {
            _ = try await synchronizer.synchronize()
            XCTFail("Expected every directory entry to consume the inventory budget")
        } catch let error as FileMemoryError {
            XCTAssertEqual(error, .limitExceeded(.entryCount, limit: 2))
        }
        let state = try await store.sourceState(
            identifier: "entry-bounded-source",
            scope: scope
        )
        XCTAssertNil(state)
    }

    func testMaximumChunkCountFailsBeforeReconcile() async throws {
        let root = try temporaryDirectory()
        try write(String(repeating: "x", count: 385), to: root.appending(path: "memory.txt"))
        let store = InMemoryMemoryStore()
        let scope = MemoryScope.application(appID: "product")
        let configuration = try FileMemoryConfiguration(
            sourceID: "chunk-bounded-source",
            scope: scope,
            maximumChunkCharacterCount: 128,
            maximumChunkCount: 2
        )
        let synchronizer = FileMemorySynchronizer(
            configuration: configuration,
            fileAccess: try LocalDirectoryFileMemoryAccess(rootURL: root),
            store: store
        )

        do {
            _ = try await synchronizer.synchronize()
            XCTFail("Expected chunk-count enforcement before reconcile")
        } catch let error as FileMemoryError {
            XCTAssertEqual(error, .limitExceeded(.chunkCount, limit: 2))
        }
        let state = try await store.sourceState(
            identifier: "chunk-bounded-source",
            scope: scope
        )
        XCTAssertNil(state)
    }

    func testMalformedProviderEntryIsRejectedAndNeverRead() async throws {
        let store = InMemoryMemoryStore()
        let scope = MemoryScope.application(appID: "product")
        let access = MalformedFileAccess()
        let configuration = try FileMemoryConfiguration(sourceID: "malformed", scope: scope)
        let synchronizer = FileMemorySynchronizer(
            configuration: configuration,
            fileAccess: access,
            store: store
        )

        let report = try await synchronizer.synchronize()
        XCTAssertEqual(report.rejected.map(\.reason), [.invalidProviderEntry])
        let readCount = await access.readCount
        XCTAssertEqual(readCount, 0)
    }

    func testLocalReadRejectsSameSizeInPlaceMutationDuringRead() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "racing.md")
        let byteCount = 16 * 1_024 * 1_024
        try Data(repeating: 0x61, count: byteCount).write(to: file)
        let access = try LocalDirectoryFileMemoryAccess(rootURL: root)
        let path = try FileMemoryPath("racing.md")

        let writer = Task.detached { () throws -> Void in
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            for index in 0..<2_000 {
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64((index * 8_191) % byteCount))
                try handle.write(contentsOf: Data([index.isMultiple(of: 2) ? 0x62 : 0x63]))
                try await Task.sleep(for: .microseconds(100))
            }
        }
        try await Task.sleep(for: .milliseconds(2))

        do {
            _ = try await access.readFile(at: path, maximumByteCount: byteCount)
            XCTFail("A torn same-size read must not be accepted as a stable snapshot")
        } catch let error as FileMemoryError {
            XCTAssertEqual(error, .changedDuringScan(path))
        }
        writer.cancel()
        _ = try? await writer.value
    }

    func testDecodedMaximumIntegerReadLimitDoesNotOverflow() async throws {
        let root = try temporaryDirectory()
        try write("bounded content", to: root.appending(path: "memory.md"))
        let scope = MemoryScope.application(appID: "product")
        let configuration = try FileMemoryConfiguration(
            sourceID: "maximum-integer-limit",
            scope: scope,
            maximumFileByteCount: .max,
            maximumTotalByteCount: .max
        )
        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(FileMemoryConfiguration.self, from: encoded)
        let store = InMemoryMemoryStore()
        let synchronizer = FileMemorySynchronizer(
            configuration: decoded,
            fileAccess: try LocalDirectoryFileMemoryAccess(rootURL: root),
            store: store
        )

        let report = try await synchronizer.synchronize()

        XCTAssertEqual(report.filesScanned, 1)
        XCTAssertEqual(report.created, 1)
    }

    func testDecodedControlCharacterSourceIDFailsBeforeScanningOrReconcile() async throws {
        let root = try temporaryDirectory()
        try write("must not be scanned", to: root.appending(path: "memory.md"))
        let valid = try FileMemoryConfiguration(
            sourceID: "valid-source",
            scope: .application(appID: "product")
        )
        let encoded = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["sourceID"] = "source\0identity"
        let decoded = try JSONDecoder().decode(
            FileMemoryConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let store = InMemoryMemoryStore()
        let synchronizer = FileMemorySynchronizer(
            configuration: decoded,
            fileAccess: try LocalDirectoryFileMemoryAccess(rootURL: root),
            store: store
        )

        do {
            _ = try await synchronizer.synchronize()
            XCTFail("Expected decoded control character to fail at the runtime boundary")
        } catch let error as FileMemoryError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let state = try await store.sourceState(
            identifier: "valid-source",
            scope: .application(appID: "product")
        )
        XCTAssertNil(state)
    }

    func testLocalAccessPinsSelectedRootAgainstLaterPathReplacement() async throws {
        let parent = try temporaryDirectory()
        let selected = parent.appending(path: "selected", directoryHint: .isDirectory)
        let outside = parent.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("selected", to: selected.appending(path: "selected.md"))
        try write("outside", to: outside.appending(path: "outside.md"))
        let access = try LocalDirectoryFileMemoryAccess(rootURL: selected)

        let pinned = parent.appending(path: "pinned", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: selected, to: pinned)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        let entries = try await access.listDirectory(at: .root)

        XCTAssertEqual(entries.map(\.path.relativePath), ["selected.md"])
    }

    func testRescanControllerDebouncesHintsIntoOneCompleteGeneration() async throws {
        let root = try temporaryDirectory()
        try write("Memory value", to: root.appending(path: "memory.md"))
        let store = InMemoryMemoryStore()
        let scope = MemoryScope.application(appID: "product")
        let synchronizer = try makeSynchronizer(root: root, store: store, scope: scope)
        let controller = FileMemoryRescanController(
            synchronizer: synchronizer,
            debounceInterval: .milliseconds(10)
        )

        for _ in 0..<20 {
            await controller.signalChange()
        }
        let report = try await controller.waitForPendingRescan()

        XCTAssertEqual(report?.generation, 1)
        let state = try await store.sourceState(identifier: "test-source", scope: scope)
        XCTAssertEqual(state?.generation, 1)
    }

    func testGenerationConflictRetriesWithFreshFullScanInsteadOfStaleSnapshot() async throws {
        let scope = MemoryScope.application(appID: "product")
        let access = ChangingFileAccess()
        let store = ConflictOnceStore()
        let configuration = try FileMemoryConfiguration(
            sourceID: "conflict-source",
            scope: scope,
            maximumGenerationRetries: 1
        )
        let synchronizer = FileMemorySynchronizer(
            configuration: configuration,
            fileAccess: access,
            store: store
        )

        let report = try await synchronizer.synchronize()
        let records = try await store.records(scope: scope)
        let listCount = await access.listCount

        XCTAssertEqual(report.generationConflictCount, 1)
        XCTAssertEqual(report.generation, 1)
        XCTAssertEqual(listCount, 2)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].content.contains("version 2"))
    }

    func testConcurrentSynchronizersRescanAfterGenerationConflictWithoutRollback() async throws {
        let scope = MemoryScope.application(appID: "product")
        let configuration = try FileMemoryConfiguration(
            sourceID: "shared-source",
            scope: scope,
            maximumGenerationRetries: 1
        )
        let store = InMemoryMemoryStore()
        let contents = MutableFileMemoryContents("old snapshot")
        let staleReadStarted = AsyncTestGate()
        let resumeStaleRead = AsyncTestGate()
        let staleAccess = CoordinatedSnapshotFileAccess(
            contents: contents,
            pauseFirstRead: true,
            firstReadStarted: staleReadStarted,
            resumeFirstRead: resumeStaleRead
        )
        let freshAccess = CoordinatedSnapshotFileAccess(contents: contents)
        let staleSynchronizer = FileMemorySynchronizer(
            configuration: configuration,
            fileAccess: staleAccess,
            store: store
        )
        let freshSynchronizer = FileMemorySynchronizer(
            configuration: configuration,
            fileAccess: freshAccess,
            store: store
        )

        let staleTask = Task.detached {
            try await staleSynchronizer.synchronize()
        }
        await staleReadStarted.wait()
        await contents.replace(with: "new snapshot")

        do {
            let freshReport = try await freshSynchronizer.synchronize()
            XCTAssertEqual(freshReport.generation, 1)

            await resumeStaleRead.open()
            let staleReport = try await staleTask.value
            let records = try await activeRecords(store, scope: scope)
            let staleReadCount = await staleAccess.readCount

            XCTAssertEqual(staleReport.generationConflictCount, 1)
            XCTAssertEqual(staleReport.previousGeneration, 1)
            XCTAssertEqual(staleReport.generation, 2)
            XCTAssertEqual(staleReport.unchanged, 1)
            XCTAssertEqual(staleReadCount, 2)
            XCTAssertEqual(records.count, 1)
            XCTAssertTrue(records[0].content.contains("new snapshot"))
            XCTAssertFalse(records[0].content.contains("old snapshot"))
        } catch {
            await resumeStaleRead.open()
            staleTask.cancel()
            _ = try? await staleTask.value
            throw error
        }
    }

    private func makeSynchronizer(
        root: URL,
        store: InMemoryMemoryStore,
        scope: MemoryScope,
        missingPolicy: MemorySourceMissingPolicy = .archive,
        maximumFileByteCount: Int = 1_048_576,
        maximumTotalByteCount: Int = 16_777_216
    ) throws -> FileMemorySynchronizer {
        let configuration = try FileMemoryConfiguration(
            sourceID: "test-source",
            scope: scope,
            maximumFileByteCount: maximumFileByteCount,
            maximumTotalByteCount: maximumTotalByteCount,
            missingPolicy: missingPolicy
        )
        return FileMemorySynchronizer(
            configuration: configuration,
            fileAccess: try LocalDirectoryFileMemoryAccess(rootURL: root),
            store: store
        )
    }

    private func activeRecords(
        _ store: InMemoryMemoryStore,
        scope: MemoryScope
    ) async throws -> [MemoryRecord] {
        try await store.retrieve(MemoryQuery(
            scopes: [scope],
            statuses: [.active],
            maximumSensitivity: .financial,
            limit: 10_000,
            characterBudget: 10_000_000,
            includeExpired: true
        )).records
    }

    private func allRecords(
        _ store: InMemoryMemoryStore,
        scope: MemoryScope
    ) async throws -> [MemoryRecord] {
        try await store.retrieve(MemoryQuery(
            scopes: [scope],
            statuses: Set(MemoryStatus.allCases),
            maximumSensitivity: .financial,
            limit: 10_000,
            characterBudget: 10_000_000,
            includeExpired: true
        )).records
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentRuntimeFileMemoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
    }
}

private actor CanonicalVariantFileAccess: FileMemoryFileAccess {
    private let composed: FileMemoryPath
    private let decomposed: FileMemoryPath

    init(composed: FileMemoryPath, decomposed: FileMemoryPath) {
        self.composed = composed
        self.decomposed = decomposed
    }

    var rootDescription: String { "canonical-variant-test" }

    func listDirectory(
        at path: FileMemoryPath,
        maximumEntryCount: Int
    ) async throws -> [FileMemoryDirectoryEntry] {
        guard path == .root else { return [] }
        guard maximumEntryCount >= 2 else {
            throw FileMemoryError.limitExceeded(.entryCount, limit: maximumEntryCount)
        }
        return [
            FileMemoryDirectoryEntry(
                path: composed,
                kind: .regularFile,
                byteCount: Data("composed memory".utf8).count
            ),
            FileMemoryDirectoryEntry(
                path: decomposed,
                kind: .regularFile,
                byteCount: Data("decomposed memory".utf8).count
            ),
        ]
    }

    func readFile(
        at path: FileMemoryPath,
        maximumByteCount: Int
    ) async throws -> FileMemoryReadResult {
        let data: Data
        if path == composed {
            data = Data("composed memory".utf8)
        } else if path == decomposed {
            data = Data("decomposed memory".utf8)
        } else {
            throw FileMemoryError.accessDenied(path)
        }
        guard data.count <= maximumByteCount else {
            throw FileMemoryError.fileTooLarge(path: path, limit: maximumByteCount)
        }
        return FileMemoryReadResult(data: data)
    }
}

private actor MalformedFileAccess: FileMemoryFileAccess {
    var readCount = 0
    var rootDescription: String { "malformed-test" }

    func listDirectory(
        at path: FileMemoryPath,
        maximumEntryCount: Int
    ) async throws -> [FileMemoryDirectoryEntry] {
        guard path == .root else { return [] }
        return [FileMemoryDirectoryEntry(
            path: try FileMemoryPath("unexpected/grandchild.md"),
            kind: .regularFile,
            byteCount: 3
        )]
    }

    func readFile(
        at path: FileMemoryPath,
        maximumByteCount: Int
    ) async throws -> FileMemoryReadResult {
        readCount += 1
        return FileMemoryReadResult(data: Data("bad".utf8))
    }
}

private actor ChangingFileAccess: FileMemoryFileAccess {
    private(set) var listCount = 0
    private var currentData = Data()
    var rootDescription: String { "changing-test" }

    func listDirectory(
        at path: FileMemoryPath,
        maximumEntryCount: Int
    ) async throws -> [FileMemoryDirectoryEntry] {
        guard path == .root else { return [] }
        listCount += 1
        currentData = Data("version \(listCount)".utf8)
        return [FileMemoryDirectoryEntry(
            path: try FileMemoryPath("memory.md"),
            kind: .regularFile,
            byteCount: currentData.count
        )]
    }

    func readFile(
        at path: FileMemoryPath,
        maximumByteCount: Int
    ) async throws -> FileMemoryReadResult {
        FileMemoryReadResult(data: currentData)
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor MutableFileMemoryContents {
    private var data: Data

    init(_ value: String) {
        data = Data(value.utf8)
    }

    func snapshot() -> Data {
        data
    }

    func replace(with value: String) {
        data = Data(value.utf8)
    }
}

private actor CoordinatedSnapshotFileAccess: FileMemoryFileAccess {
    private let contents: MutableFileMemoryContents
    private let pauseFirstRead: Bool
    private let firstReadStarted: AsyncTestGate?
    private let resumeFirstRead: AsyncTestGate?
    private var didPauseFirstRead = false
    private(set) var readCount = 0

    var rootDescription: String { "coordinated-snapshot-test" }

    init(
        contents: MutableFileMemoryContents,
        pauseFirstRead: Bool = false,
        firstReadStarted: AsyncTestGate? = nil,
        resumeFirstRead: AsyncTestGate? = nil
    ) {
        self.contents = contents
        self.pauseFirstRead = pauseFirstRead
        self.firstReadStarted = firstReadStarted
        self.resumeFirstRead = resumeFirstRead
    }

    func listDirectory(
        at path: FileMemoryPath,
        maximumEntryCount: Int
    ) async throws -> [FileMemoryDirectoryEntry] {
        guard path == .root else { return [] }
        guard maximumEntryCount >= 1 else {
            throw FileMemoryError.limitExceeded(.entryCount, limit: maximumEntryCount)
        }
        let data = await contents.snapshot()
        return [FileMemoryDirectoryEntry(
            path: try FileMemoryPath("memory.md"),
            kind: .regularFile,
            byteCount: data.count
        )]
    }

    func readFile(
        at path: FileMemoryPath,
        maximumByteCount: Int
    ) async throws -> FileMemoryReadResult {
        let data = await contents.snapshot()
        guard data.count <= maximumByteCount else {
            throw FileMemoryError.fileTooLarge(path: path, limit: maximumByteCount)
        }
        readCount += 1
        if pauseFirstRead, !didPauseFirstRead {
            didPauseFirstRead = true
            await firstReadStarted?.open()
            await resumeFirstRead?.wait()
        }
        return FileMemoryReadResult(data: data)
    }
}

private actor ConflictOnceStore: MemorySourceReconciliationStore {
    private let base = InMemoryMemoryStore()
    private var shouldConflict = true

    func sourceState(identifier: String, scope: MemoryScope) async throws -> MemorySourceState? {
        try await base.sourceState(identifier: identifier, scope: scope)
    }

    func reconcileSourceSnapshot(
        _ snapshot: MemorySourceSnapshot,
        expectedGeneration: Int,
        missingPolicy: MemorySourceMissingPolicy,
        at date: Date
    ) async throws -> MemorySourceReconciliationReport {
        if shouldConflict {
            shouldConflict = false
            throw MemorySourceReconciliationError.generationConflict(
                expected: expectedGeneration,
                actual: expectedGeneration
            )
        }
        return try await base.reconcileSourceSnapshot(
            snapshot,
            expectedGeneration: expectedGeneration,
            missingPolicy: missingPolicy,
            at: date
        )
    }

    func upsert(
        _ proposal: MemoryProposal,
        status: MemoryStatus,
        expectedRevision: Int?,
        at date: Date
    ) async throws -> MemoryRecord {
        try await base.upsert(
            proposal,
            status: status,
            expectedRevision: expectedRevision,
            at: date
        )
    }

    func fetch(
        id: UUID,
        scope: MemoryScope,
        includeExpired: Bool,
        at date: Date
    ) async throws -> MemoryRecord? {
        try await base.fetch(id: id, scope: scope, includeExpired: includeExpired, at: date)
    }

    func update(
        id: UUID,
        scope: MemoryScope,
        patch: MemoryPatch,
        expectedRevision: Int,
        at date: Date
    ) async throws -> MemoryRecord {
        try await base.update(
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
        at date: Date
    ) async throws {
        try await base.delete(
            id: id,
            scope: scope,
            expectedRevision: expectedRevision,
            at: date
        )
    }

    func retrieve(_ query: MemoryQuery) async throws -> MemoryRetrievalResult {
        try await base.retrieve(query)
    }

    func events(
        scope: MemoryScope,
        recordID: UUID?,
        limit: Int
    ) async throws -> [MemoryEvent] {
        try await base.events(scope: scope, recordID: recordID, limit: limit)
    }

    func records(scope: MemoryScope) async throws -> [MemoryRecord] {
        try await base.retrieve(MemoryQuery(
            scopes: [scope],
            statuses: Set(MemoryStatus.allCases),
            maximumSensitivity: .financial,
            limit: 100,
            characterBudget: 100_000,
            includeExpired: true
        )).records
    }
}
