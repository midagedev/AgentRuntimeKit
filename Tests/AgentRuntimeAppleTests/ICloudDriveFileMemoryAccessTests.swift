#if os(iOS) || os(macOS)
@testable import AgentRuntimeApple
import AgentRuntimeFileMemory
import Foundation
import XCTest

final class ICloudDriveFileMemoryAccessTests: XCTestCase {
    func testNoIdentityFailsWithoutCreatingALocalFallback() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let locator = FakeICloudContainerLocator(locations: [nil])
        let access = try makeAccess(
            containerURL: temporary.url.appendingPathComponent("never-used"),
            locator: locator
        )

        do {
            _ = try await access.listDirectory(at: .root)
            XCTFail("Expected iCloud identity failure")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .iCloudIdentityUnavailable)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporary.url.appendingPathComponent("never-used").path
            )
        )
    }

    func testEntitledIdentityWithUnavailableContainerFailsClosed() async throws {
        let locator = FakeICloudContainerLocator(locations: [
            ICloudDriveContainerLocation(containerURL: nil, identityGeneration: 1),
        ])
        let access = try makeAccess(
            containerURL: FileManager.default.temporaryDirectory,
            locator: locator
        )

        do {
            _ = try await access.listDirectory(at: .root)
            XCTFail("Expected unavailable container failure")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .containerUnavailable)
        }
    }

    func testConcreteAccessWritesListsAndReadsThroughReadOnlyProtocol() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = temporary.url.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let itemManager = FakeICloudItemManager(states: [
            .init(downloadStatus: .notUbiquitous),
        ])
        let access = try makeAccess(containerURL: container, itemManager: itemManager)
        let file = try FileMemoryPath("profiles/user.md")

        try await access.writeUTF8(
            "# User\n\nLikes tea.",
            at: file,
            mode: .createOrReplace
        )
        let provider: any FileMemoryFileAccess = access
        let entries = try await provider.listDirectory(at: try FileMemoryPath("profiles"))
        let result = try await provider.readFile(at: file, maximumByteCount: 1_024)
        let description = await provider.rootDescription

        XCTAssertEqual(description, "iCloud://iCloud.example.memory/Documents/AgentMemory")
        XCTAssertEqual(entries.map(\.path), [file])
        XCTAssertEqual(entries.map(\.kind), [.regularFile])
        XCTAssertEqual(String(data: result.data, encoding: .utf8), "# User\n\nLikes tea.")
        XCTAssertNotNil(result.modifiedAt)
    }

    func testReadRequestsDownloadAndWaitsForCurrentVersion() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "remote"
        )
        let itemManager = FakeICloudItemManager(states: [
            .init(downloadStatus: .notDownloaded),
            .init(downloadStatus: .current),
        ])
        let access = try makeAccess(containerURL: container, itemManager: itemManager)

        let result = try await access.readFile(
            at: try FileMemoryPath("note.md"),
            maximumByteCount: 100
        )

        XCTAssertEqual(String(data: result.data, encoding: .utf8), "remote")
        let requestCount = await itemManager.downloadRequestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testReadFailsWhenItemDoesNotBecomeCurrentByDeadline() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "possibly stale"
        )
        let itemManager = FakeICloudItemManager(
            states: [.init(downloadStatus: .notDownloaded)],
            repeatsLastState: true
        )
        let access = try makeAccess(
            containerURL: container,
            itemManager: itemManager,
            downloadTimeout: .zero
        )

        do {
            _ = try await access.readFile(
                at: try FileMemoryPath("note.md"),
                maximumByteCount: 100
            )
            XCTFail("Expected download timeout")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .downloadTimedOut)
        }
    }

    func testReadingRootFailsWithoutEnteringCoordinatedFileAccess() async throws {
        let locator = FakeICloudContainerLocator(locations: [nil])
        let access = try makeAccess(
            containerURL: FileManager.default.temporaryDirectory,
            locator: locator
        )

        do {
            _ = try await access.readFile(at: .root, maximumByteCount: 100)
            XCTFail("Expected root to be rejected as a non-file path")
        } catch let error as FileMemoryError {
            XCTAssertEqual(error, .notRegularFile(.root))
        }
    }

    func testUnresolvedVersionsFailClosedForReadAndWrite() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "conflicted"
        )
        let conflicted = ICloudDriveItemState(
            downloadStatus: .current,
            hasUnresolvedConflicts: true
        )
        let itemManager = FakeICloudItemManager(
            states: [conflicted],
            repeatsLastState: true
        )
        let access = try makeAccess(containerURL: container, itemManager: itemManager)
        let path = try FileMemoryPath("note.md")

        do {
            _ = try await access.readFile(at: path, maximumByteCount: 100)
            XCTFail("Expected unresolved-version failure")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .unresolvedVersionConflict)
        }
        do {
            try await access.writeUTF8(
                "replacement",
                at: path,
                mode: .replaceExisting
            )
            XCTFail("Expected unresolved-version failure")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .unresolvedVersionConflict)
        }
    }

    func testIdentityGenerationChangeAbortsBeforeDirectoryEnumeration() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = temporary.url.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let first = ICloudDriveContainerLocation(
            containerURL: container,
            identityGeneration: 1
        )
        let second = ICloudDriveContainerLocation(
            containerURL: container,
            identityGeneration: 2
        )
        let locator = FakeICloudContainerLocator(
            locations: [first, second],
            repeatsLastLocation: true
        )
        let access = try makeAccess(containerURL: container, locator: locator)

        do {
            _ = try await access.listDirectory(at: .root)
            XCTFail("Expected account-generation change")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .containerChangedDuringOperation)
        }
    }

    func testSymlinkedRootAndIntermediateDirectoryCannotEscapeContainer() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = temporary.url.appendingPathComponent("container", isDirectory: true)
        let outside = temporary.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: container.appendingPathComponent("Documents"),
            withDestinationURL: outside
        )
        let access = try makeAccess(containerURL: container)

        do {
            _ = try await access.listDirectory(at: .root)
            XCTFail("Expected symbolic-link rejection")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .symbolicLinkNotAllowed)
        }

        try FileManager.default.removeItem(at: container.appendingPathComponent("Documents"))
        let root = container.appendingPathComponent("Documents/AgentMemory", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        do {
            _ = try await access.readFile(
                at: try FileMemoryPath("link/secret.md"),
                maximumByteCount: 100
            )
            XCTFail("Expected intermediate symbolic-link rejection")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .symbolicLinkNotAllowed)
        }
    }

    func testWriteLimitIsEnforcedBeforeRootMutation() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = temporary.url.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let access = try makeAccess(containerURL: container, maximumWriteByteCount: 3)

        do {
            try await access.writeFile(
                Data([0, 1, 2, 3]),
                at: try FileMemoryPath("large.md"),
                mode: .createOnly
            )
            XCTFail("Expected write limit")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .writeTooLarge(limit: 3))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent("Documents").path
            )
        )
    }

    func testWriteModesPreventSilentOverwriteOfUserEditedDocument() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "user edit"
        )
        let access = try makeAccess(containerURL: container)
        let path = try FileMemoryPath("note.md")

        do {
            try await access.writeUTF8("app edit", at: path, mode: .createOnly)
            XCTFail("Expected create-only precondition failure")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .writePreconditionFailed)
        }
        do {
            try await access.writeUTF8(
                "app edit",
                at: path,
                mode: .replaceIfUnmodified(modifiedAt: .distantPast)
            )
            XCTFail("Expected stale revision precondition failure")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .writePreconditionFailed)
        }

        let unchanged = try Data(
            contentsOf: container.appendingPathComponent("Documents/AgentMemory/note.md")
        )
        XCTAssertEqual(String(data: unchanged, encoding: .utf8), "user edit")
    }

    func testReplacingExistingItemDownloadsAndWaitsForCurrentVersion() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "placeholder"
        )
        let itemManager = FakeICloudItemManager(states: [
            .init(downloadStatus: .notDownloaded),
            .init(downloadStatus: .current),
        ])
        let access = try makeAccess(containerURL: container, itemManager: itemManager)

        try await access.writeUTF8(
            "current replacement",
            at: try FileMemoryPath("note.md"),
            mode: .replaceExisting
        )

        let downloadRequestCount = await itemManager.downloadRequestCount
        XCTAssertEqual(downloadRequestCount, 1)
        let written = try Data(
            contentsOf: container.appendingPathComponent("Documents/AgentMemory/note.md")
        )
        XCTAssertEqual(String(data: written, encoding: .utf8), "current replacement")
    }

    func testFailedDownloadPreventsStaleOverwrite() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "placeholder"
        )
        let itemManager = FakeICloudItemManager(
            states: [.init(downloadStatus: .failed)],
            repeatsLastState: true
        )
        let access = try makeAccess(containerURL: container, itemManager: itemManager)

        do {
            try await access.writeUTF8(
                "must not publish",
                at: try FileMemoryPath("note.md"),
                mode: .createOrReplace
            )
            XCTFail("Expected failed-download write rejection")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .downloadFailed)
        }
        let unchanged = try Data(
            contentsOf: container.appendingPathComponent("Documents/AgentMemory/note.md")
        )
        XCTAssertEqual(String(data: unchanged, encoding: .utf8), "placeholder")
    }

    func testCoordinatedStateRegressionPreventsStaleOverwriteAndRemoval() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "current before coordination"
        )
        let itemManager = FakeICloudItemManager(
            states: [.init(downloadStatus: .current)],
            repeatsLastState: true
        )
        let access = try makeAccess(
            containerURL: container,
            itemManager: itemManager,
            coordinatedItemValidator: { _ in
                throw ICloudDriveFileMemoryError.itemNotCurrent
            }
        )
        let path = try FileMemoryPath("note.md")

        do {
            try await access.writeUTF8("stale overwrite", at: path, mode: .createOrReplace)
            XCTFail("Expected the in-coordinator current-version check to fail")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .itemNotCurrent)
        }
        do {
            _ = try await access.removeFile(at: path, mode: .ifExists)
            XCTFail("Expected the in-coordinator current-version check to fail")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .itemNotCurrent)
        }

        let unchanged = try Data(
            contentsOf: container.appendingPathComponent("Documents/AgentMemory/note.md")
        )
        XCTAssertEqual(
            String(data: unchanged, encoding: .utf8),
            "current before coordination"
        )
    }

    func testCoordinatedStateRegressionPreventsStaleRead() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "possibly stale"
        )
        let itemManager = FakeICloudItemManager(
            states: [.init(downloadStatus: .current)],
            repeatsLastState: true
        )
        let access = try makeAccess(
            containerURL: container,
            itemManager: itemManager,
            coordinatedItemValidator: { _ in
                throw ICloudDriveFileMemoryError.itemNotCurrent
            }
        )

        do {
            _ = try await access.readFile(
                at: try FileMemoryPath("note.md"),
                maximumByteCount: 100
            )
            XCTFail("Expected the in-coordinator current-version check to fail")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .itemNotCurrent)
        }
    }

    func testNonCurrentReadRemainsAllowedWhenCurrentVersionIsNotRequired() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "note.md",
            contents: "downloaded copy"
        )
        let itemManager = FakeICloudItemManager(
            states: [.init(downloadStatus: .downloaded)],
            repeatsLastState: true
        )
        let access = try makeAccess(
            containerURL: container,
            itemManager: itemManager,
            requireCurrentVersion: false,
            coordinatedItemValidator: { _ in
                throw ICloudDriveFileMemoryError.itemNotCurrent
            }
        )

        let result = try await access.readFile(
            at: try FileMemoryPath("note.md"),
            maximumByteCount: 100
        )

        XCTAssertEqual(String(data: result.data, encoding: .utf8), "downloaded copy")
    }

    func testRootRelativeRemovalIsRetryableAndChecksModificationDate() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = try prepareFile(
            in: temporary.url,
            relativePath: "managed/note.md",
            contents: "managed"
        )
        let access = try makeAccess(containerURL: container)
        let path = try FileMemoryPath("managed/note.md")
        let listed = try await access.listDirectory(
            at: try FileMemoryPath("managed"),
            maximumEntryCount: 10
        )
        let modifiedAt = try XCTUnwrap(listed.first?.modifiedAt)

        do {
            _ = try await access.removeFile(
                at: path,
                mode: .ifUnmodified(modifiedAt: .distantPast)
            )
            XCTFail("Expected stale removal precondition")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .removePreconditionFailed)
        }
        let removed = try await access.removeFile(
            at: path,
            mode: .ifUnmodified(modifiedAt: modifiedAt)
        )
        let removedAgain = try await access.removeFile(at: path, mode: .ifExists)
        XCTAssertTrue(removed)
        XCTAssertFalse(removedAgain)
    }

    func testMissingRetryableRemovalStillChecksContainerIdentity() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = temporary.url.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let locator = FakeICloudContainerLocator(
            locations: [
                ICloudDriveContainerLocation(
                    containerURL: container,
                    identityGeneration: 1
                ),
                ICloudDriveContainerLocation(
                    containerURL: container,
                    identityGeneration: 1
                ),
                ICloudDriveContainerLocation(
                    containerURL: container,
                    identityGeneration: 2
                ),
            ],
            repeatsLastLocation: true
        )
        let access = try makeAccess(containerURL: container, locator: locator)

        do {
            _ = try await access.removeFile(
                at: try FileMemoryPath("missing.md"),
                mode: .ifExists
            )
            XCTFail("Expected identity change to invalidate the missing result")
        } catch let error as ICloudDriveFileMemoryError {
            XCTAssertEqual(error, .containerChangedDuringOperation)
        }
    }

    func testFinalSymlinkCannotRedirectWriteOrRemoval() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let container = temporary.url.appendingPathComponent("container", isDirectory: true)
        let root = container.appendingPathComponent("Documents/AgentMemory", isDirectory: true)
        let outside = temporary.url.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.md"),
            withDestinationURL: outside
        )
        let access = try makeAccess(containerURL: container)
        let path = try FileMemoryPath("link.md")

        do {
            try await access.writeUTF8("escape", at: path, mode: .createOrReplace)
            XCTFail("Expected final symlink rejection")
        } catch let error as FileMemoryError {
            XCTAssertEqual(error, .symbolicLink(path))
        }
        do {
            _ = try await access.removeFile(at: path)
            XCTFail("Expected final symlink rejection")
        } catch let error as FileMemoryError {
            XCTAssertEqual(error, .symbolicLink(path))
        }
        XCTAssertEqual(String(data: try Data(contentsOf: outside), encoding: .utf8), "outside")
    }

    func testConfigurationRejectsAmbiguousOrUnsafeContainerIdentifiers() throws {
        for identifier in ["", " iCloud.example", "iCloud/example", "iCloud.example\n"] {
            XCTAssertThrowsError(try ICloudDriveFileMemoryAccess.Configuration(
                containerIdentifier: identifier,
                documentsSubdirectory: .root
            )) { error in
                XCTAssertEqual(error as? ICloudDriveFileMemoryError, .invalidConfiguration)
            }
        }
    }

    func testConfigurationExposesValidatedValuesAndRejectsUnsafeOperationalLimits() throws {
        let subdirectory = try FileMemoryPath("AgentMemory")
        let configuration = try ICloudDriveFileMemoryAccess.Configuration(
            containerIdentifier: "iCloud.example.memory",
            documentsSubdirectory: subdirectory,
            requireCurrentVersion: false,
            downloadTimeout: .seconds(7),
            downloadPollInterval: .milliseconds(125),
            maximumWriteByteCount: 4_096
        )

        XCTAssertEqual(configuration.containerIdentifier, "iCloud.example.memory")
        XCTAssertEqual(configuration.documentsSubdirectory, subdirectory)
        XCTAssertFalse(configuration.requireCurrentVersion)
        XCTAssertEqual(configuration.downloadTimeout, .seconds(7))
        XCTAssertEqual(configuration.downloadPollInterval, .milliseconds(125))
        XCTAssertEqual(configuration.maximumWriteByteCount, 4_096)

        let invalidConfigurations: [() throws -> ICloudDriveFileMemoryAccess.Configuration] = [
            {
                try ICloudDriveFileMemoryAccess.Configuration(
                    containerIdentifier: "iCloud.example.memory",
                    documentsSubdirectory: subdirectory,
                    downloadTimeout: .seconds(-1)
                )
            },
            {
                try ICloudDriveFileMemoryAccess.Configuration(
                    containerIdentifier: "iCloud.example.memory",
                    documentsSubdirectory: subdirectory,
                    downloadPollInterval: .zero
                )
            },
            {
                try ICloudDriveFileMemoryAccess.Configuration(
                    containerIdentifier: "iCloud.example.memory",
                    documentsSubdirectory: subdirectory,
                    maximumWriteByteCount: 0
                )
            },
        ]
        for makeConfiguration in invalidConfigurations {
            XCTAssertThrowsError(try makeConfiguration()) { error in
                XCTAssertEqual(error as? ICloudDriveFileMemoryError, .invalidConfiguration)
            }
        }
    }

    func testRescanObservationSupportsInjectedHintsAndIdempotentCancellation() async {
        let pair = AsyncStream<ICloudDriveRescanHint>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let recorder = CancellationRecorder()
        let observation = ICloudDriveRescanObservation(hints: pair.stream) {
            recorder.record()
            pair.continuation.finish()
        }
        var iterator = observation.hints.makeAsyncIterator()

        pair.continuation.yield(ICloudDriveRescanHint(reason: .metadataUpdated))
        let hint = await iterator.next()
        XCTAssertEqual(hint, ICloudDriveRescanHint(reason: .metadataUpdated))

        observation.cancel()
        observation.cancel()
        let end = await iterator.next()
        XCTAssertNil(end)
        XCTAssertEqual(recorder.count, 1)
    }

    @MainActor
    func testRescanObservationStopsStartedQueryWhenContainerChangesDuringLookup() async throws {
        let temporary = try ICloudTemporaryDirectory()
        let initialContainer = temporary.url.appendingPathComponent(
            "initial-container",
            isDirectory: true
        )
        let replacementContainer = temporary.url.appendingPathComponent(
            "replacement-container",
            isDirectory: true
        )
        let initialLocation = ICloudDriveContainerLocation(
            containerURL: initialContainer,
            identityGeneration: 1
        )
        let changedLocations = [
            ICloudDriveContainerLocation(
                containerURL: initialContainer,
                identityGeneration: 2
            ),
            ICloudDriveContainerLocation(
                containerURL: replacementContainer,
                identityGeneration: 1
            ),
        ]
        let configuration = try ICloudDriveFileMemoryAccess.Configuration(
            containerIdentifier: "iCloud.example.memory",
            documentsSubdirectory: try FileMemoryPath("AgentMemory")
        )

        for changedLocation in changedLocations {
            let locator = FakeICloudContainerLocator(locations: [
                initialLocation,
                changedLocation,
            ])
            var createdSession: FakeICloudMetadataObservationSession?
            let source = SystemICloudDriveRescanHintSource(
                configuration: configuration,
                locator: locator
            ) { _, continuation in
                let session = FakeICloudMetadataObservationSession(
                    continuation: continuation
                )
                createdSession = session
                return session
            }

            do {
                _ = try await source.makeRescanObservation()
                XCTFail("Expected a post-start container identity check to fail closed")
            } catch let error as ICloudDriveFileMemoryError {
                XCTAssertEqual(error, .containerChangedDuringOperation)
            }

            let session = try XCTUnwrap(createdSession)
            XCTAssertEqual(session.startCount, 1)
            XCTAssertEqual(session.stopCount, 1)
            let locationRequestCount = await locator.locationRequestCount
            XCTAssertEqual(locationRequestCount, 2)
        }
    }

    private func makeAccess(
        containerURL: URL,
        locator: (any ICloudDriveContainerLocating)? = nil,
        itemManager: (any ICloudDriveItemManaging)? = nil,
        downloadTimeout: Duration = .seconds(1),
        maximumWriteByteCount: Int = 1_024,
        requireCurrentVersion: Bool = true,
        coordinatedItemValidator: (@Sendable (URL) throws -> Void)? = nil
    ) throws -> ICloudDriveFileMemoryAccess {
        let configuration = try ICloudDriveFileMemoryAccess.Configuration(
            containerIdentifier: "iCloud.example.memory",
            documentsSubdirectory: FileMemoryPath("AgentMemory"),
            requireCurrentVersion: requireCurrentVersion,
            downloadTimeout: downloadTimeout,
            downloadPollInterval: .milliseconds(1),
            maximumWriteByteCount: maximumWriteByteCount
        )
        let resolvedLocator = locator ?? FakeICloudContainerLocator(locations: [
                ICloudDriveContainerLocation(
                    containerURL: containerURL,
                    identityGeneration: 1
                ),
            ], repeatsLastLocation: true)
        let resolvedItemManager = itemManager ?? FakeICloudItemManager(
            states: [.init(downloadStatus: .notUbiquitous)],
            repeatsLastState: true
        )
        if let coordinatedItemValidator {
            return ICloudDriveFileMemoryAccess(
                configuration: configuration,
                locator: resolvedLocator,
                itemManager: resolvedItemManager,
                coordinatedItemValidator: coordinatedItemValidator
            )
        }
        return ICloudDriveFileMemoryAccess(
            configuration: configuration,
            locator: resolvedLocator,
            itemManager: resolvedItemManager
        )
    }

    private func prepareFile(
        in temporaryURL: URL,
        relativePath: String,
        contents: String
    ) throws -> URL {
        let container = temporaryURL.appendingPathComponent("container", isDirectory: true)
        let root = container.appendingPathComponent("Documents/AgentMemory", isDirectory: true)
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: file)
        return container
    }
}

private actor FakeICloudContainerLocator: ICloudDriveContainerLocating {
    private let locations: [ICloudDriveContainerLocation?]
    private let repeatsLastLocation: Bool
    private var index = 0
    private(set) var locationRequestCount = 0

    init(
        locations: [ICloudDriveContainerLocation?],
        repeatsLastLocation: Bool = false
    ) {
        self.locations = locations
        self.repeatsLastLocation = repeatsLastLocation
    }

    func location(
        forContainerIdentifier containerIdentifier: String
    ) -> ICloudDriveContainerLocation? {
        locationRequestCount += 1
        guard !locations.isEmpty else { return nil }
        let selected = min(index, locations.count - 1)
        if index < locations.count - 1 || !repeatsLastLocation {
            index += 1
        }
        if index > locations.count, !repeatsLastLocation { return nil }
        return locations[selected]
    }
}

@MainActor
private final class FakeICloudMetadataObservationSession: ICloudMetadataObservationSession {
    private let continuation: AsyncStream<ICloudDriveRescanHint>.Continuation
    private var stopped = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(continuation: AsyncStream<ICloudDriveRescanHint>.Continuation) {
        self.continuation = continuation
    }

    func start() -> Bool {
        startCount += 1
        return true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        stopCount += 1
        continuation.finish()
    }

    nonisolated func requestStop() {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}

private actor FakeICloudItemManager: ICloudDriveItemManaging {
    private let states: [ICloudDriveItemState]
    private let repeatsLastState: Bool
    private var stateIndex = 0
    private(set) var downloadRequestCount = 0

    init(states: [ICloudDriveItemState], repeatsLastState: Bool = false) {
        self.states = states
        self.repeatsLastState = repeatsLastState
    }

    func state(of url: URL) throws -> ICloudDriveItemState {
        guard !states.isEmpty else { throw ICloudDriveFileMemoryError.downloadFailed }
        let selected = min(stateIndex, states.count - 1)
        if stateIndex < states.count - 1 || !repeatsLastState {
            stateIndex += 1
        }
        return states[selected]
    }

    func startDownloadingItem(at url: URL) {
        downloadRequestCount += 1
    }
}

private final class ICloudTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeICloudTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func record() {
        lock.lock()
        storedCount += 1
        lock.unlock()
    }
}
#endif
