#if os(iOS) || os(macOS)
import AgentRuntimeFileMemory
import Darwin
import Foundation

/// A content-free error reported by the iCloud Drive file-memory boundary.
///
/// Errors deliberately omit absolute container paths and underlying Foundation
/// diagnostics. Hosts can log the operation and error case without disclosing a
/// user's account-specific iCloud path or memory contents.
public enum ICloudDriveFileMemoryError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration
    case iCloudIdentityUnavailable
    case containerUnavailable
    case containerChangedDuringOperation
    case rootUnavailable
    case symbolicLinkNotAllowed
    case unresolvedVersionConflict
    case downloadFailed
    case downloadTimedOut
    case itemNotCurrent
    case coordinatedReadFailed
    case coordinatedWriteFailed
    case coordinatedRemoveFailed
    case metadataQueryUnavailable
    case writeTooLarge(limit: Int)
    case writePreconditionFailed
    case removePreconditionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The iCloud Drive file-memory configuration is invalid."
        case .iCloudIdentityUnavailable:
            "iCloud Drive is unavailable because there is no active iCloud identity."
        case .containerUnavailable:
            "The configured iCloud container is unavailable. Verify the signed entitlements and device account."
        case .containerChangedDuringOperation:
            "The active iCloud container changed during the file operation. Rescan before retrying."
        case .rootUnavailable:
            "The configured iCloud Drive memory root is unavailable."
        case .symbolicLinkNotAllowed:
            "Symbolic links are not allowed in the iCloud Drive memory root."
        case .unresolvedVersionConflict:
            "The iCloud Drive item has unresolved file versions. Resolve the conflict before retrying."
        case .downloadFailed:
            "The iCloud Drive item could not be downloaded."
        case .downloadTimedOut:
            "The iCloud Drive item did not become current before the download deadline."
        case .itemNotCurrent:
            "The iCloud Drive item changed from its current version before the coordinated operation. Retry after it finishes downloading."
        case .coordinatedReadFailed:
            "The coordinated iCloud Drive read failed."
        case .coordinatedWriteFailed:
            "The coordinated iCloud Drive write failed."
        case .coordinatedRemoveFailed:
            "The coordinated iCloud Drive removal failed."
        case .metadataQueryUnavailable:
            "The iCloud Drive metadata query could not be started."
        case .writeTooLarge(let limit):
            "The iCloud Drive write exceeds the configured \(limit)-byte limit."
        case .writePreconditionFailed:
            "The iCloud Drive item no longer satisfies the requested write precondition."
        case .removePreconditionFailed:
            "The iCloud Drive item no longer satisfies the requested removal precondition."
        }
    }
}

/// An explicit overwrite policy for app-authored iCloud Drive files.
public enum ICloudDriveWriteMode: Sendable, Equatable {
    /// The destination must not exist.
    case createOnly
    /// The destination must already exist.
    case replaceExisting
    /// The destination must exist with the modification date returned by the
    /// caller's preceding coordinated read or directory listing.
    case replaceIfUnmodified(modifiedAt: Date)
    /// Create or replace regardless of its current modification date.
    ///
    /// Reserve this for files wholly owned by the app. User-editable documents
    /// should use ``replaceIfUnmodified(modifiedAt:)``.
    case createOrReplace
}

/// An explicit deletion policy for an app-owned iCloud Drive file.
public enum ICloudDriveRemoveMode: Sendable, Equatable {
    /// Missing is a successful no-op, which makes privacy cleanup retryable.
    case ifExists
    /// The destination must be an existing regular file.
    case requireExisting
    /// The destination must still have the coordinated modification date that
    /// the caller previously observed.
    case ifUnmodified(modifiedAt: Date)
}

private enum ICloudDriveRemovalPolicy: Sendable {
    case mode(ICloudDriveRemoveMode)
    case ifPresentAndUnmodified(modifiedAt: Date)

    var allowsMissingFile: Bool {
        switch self {
        case .mode(.ifExists), .ifPresentAndUnmodified:
            true
        case .mode(.requireExisting), .mode(.ifUnmodified):
            false
        }
    }

    var expectedModificationDate: Date? {
        switch self {
        case .mode(.ifUnmodified(let modifiedAt)),
             .ifPresentAndUnmodified(let modifiedAt):
            modifiedAt
        case .mode(.ifExists), .mode(.requireExisting):
            nil
        }
    }
}

private enum ICloudDriveDescriptorTraversalError: Error {
    case missingIntermediateDirectory
}

/// One entitlement-scoped iCloud container lookup.
///
/// `identityGeneration` is process-local and changes when the locator observes
/// a different ubiquity identity. It is not a user identifier and must not be
/// persisted or used for analytics.
public struct ICloudDriveContainerLocation: Sendable, Equatable {
    public var containerURL: URL?
    public var identityGeneration: UInt64

    public init(containerURL: URL?, identityGeneration: UInt64) {
        self.containerURL = containerURL
        self.identityGeneration = identityGeneration
    }
}

/// Locates only the explicitly requested, entitlement-scoped iCloud container.
///
/// Returning `nil` means that no iCloud identity is active. A location whose
/// `containerURL` is `nil` means that an identity exists but the requested
/// container could not be opened, commonly because its entitlement is absent.
public protocol ICloudDriveContainerLocating: Sendable {
    func location(
        forContainerIdentifier containerIdentifier: String
    ) async -> ICloudDriveContainerLocation?
}

/// Production locator backed by `FileManager` ubiquity APIs.
///
/// Apple documents `url(forUbiquityContainerIdentifier:)` as potentially slow
/// and says not to invoke it on the main thread. This actor is not main-actor
/// isolated, and callers await it from the file-access boundary.
public actor SystemICloudDriveContainerLocator: ICloudDriveContainerLocating {
    private var previousIdentity: NSObject?
    private var identityGeneration: UInt64 = 0

    public init() {}

    public func location(
        forContainerIdentifier containerIdentifier: String
    ) -> ICloudDriveContainerLocation? {
        let fileManager = FileManager.default
        guard let identity = fileManager.ubiquityIdentityToken as? NSObject else {
            previousIdentity = nil
            return nil
        }

        if let previousIdentity {
            if !previousIdentity.isEqual(identity) {
                identityGeneration &+= 1
            }
        } else {
            identityGeneration &+= 1
        }
        previousIdentity = identity.copy() as? NSObject

        return ICloudDriveContainerLocation(
            containerURL: fileManager.url(
                forUbiquityContainerIdentifier: containerIdentifier
            ),
            identityGeneration: identityGeneration
        )
    }
}

public enum ICloudDriveItemDownloadStatus: Sendable, Equatable {
    case notUbiquitous
    case notDownloaded
    case downloaded
    case current
    case failed
}

public struct ICloudDriveItemState: Sendable, Equatable {
    public var downloadStatus: ICloudDriveItemDownloadStatus
    public var hasUnresolvedConflicts: Bool

    public init(
        downloadStatus: ICloudDriveItemDownloadStatus,
        hasUnresolvedConflicts: Bool = false
    ) {
        self.downloadStatus = downloadStatus
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
    }
}

/// Injectable ubiquitous-item state and download operations.
public protocol ICloudDriveItemManaging: Sendable {
    func state(of url: URL) async throws -> ICloudDriveItemState
    func startDownloadingItem(at url: URL) async throws
}

public struct SystemICloudDriveItemManager: ICloudDriveItemManaging {
    public init() {}

    public func state(of url: URL) async throws -> ICloudDriveItemState {
        try await Task.detached {
            let values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemDownloadingErrorKey,
                .ubiquitousItemHasUnresolvedConflictsKey,
            ])
            if values.ubiquitousItemDownloadingError != nil {
                return ICloudDriveItemState(
                    downloadStatus: .failed,
                    hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts == true
                )
            }
            guard values.isUbiquitousItem == true else {
                return ICloudDriveItemState(
                    downloadStatus: .notUbiquitous,
                    hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts == true
                )
            }

            let status: ICloudDriveItemDownloadStatus
            switch values.ubiquitousItemDownloadingStatus {
            case .current?: status = .current
            case .downloaded?: status = .downloaded
            default: status = .notDownloaded
            }
            return ICloudDriveItemState(
                downloadStatus: status,
                hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts == true
            )
        }.value
    }

    public func startDownloadingItem(at url: URL) async throws {
        try await Task.detached {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }.value
    }
}

/// A read-only file-memory provider with an explicit, narrowly scoped write API
/// for app-authored documents.
///
/// The scanner sees this value only through `FileMemoryFileAccess`, whose
/// contract has no mutation operations. Products that intentionally author a
/// Markdown or text document can retain the concrete actor and call
/// ``writeFile(_:at:mode:createParentDirectories:)``. Every path is validated and
/// root-relative, every read/write is coordinated, and no local fallback is
/// attempted when iCloud is unavailable.
public actor ICloudDriveFileMemoryAccess: FileMemoryFileAccess {
    /// Runtime configuration. `containerIdentifier` must exactly match a value
    /// embedded in the signed app's
    /// `com.apple.developer.ubiquity-container-identifiers` entitlement. The
    /// adapter never asks for the implicit first container because doing so can
    /// route different products to different roots when entitlement ordering
    /// changes.
    public struct Configuration: Sendable, Hashable {
        /// Configuration is immutable after its throwing initializer validates
        /// every value. This prevents a caller from creating a valid value and
        /// later mutating an operational limit or entitlement identifier into
        /// an invalid state before an access operation begins.
        public let containerIdentifier: String
        public let documentsSubdirectory: FileMemoryPath
        public let requireCurrentVersion: Bool
        public let downloadTimeout: Duration
        public let downloadPollInterval: Duration
        public let maximumWriteByteCount: Int

        public init(
            containerIdentifier: String,
            documentsSubdirectory: FileMemoryPath,
            requireCurrentVersion: Bool = true,
            downloadTimeout: Duration = .seconds(30),
            downloadPollInterval: Duration = .milliseconds(250),
            maximumWriteByteCount: Int = 16 * 1_024 * 1_024
        ) throws {
            let permitted = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: ".-_")
            )
            guard !containerIdentifier.isEmpty,
                  containerIdentifier == containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
                  containerIdentifier.utf8.count <= 255,
                  containerIdentifier.unicodeScalars.allSatisfy({ permitted.contains($0) }),
                  downloadTimeout >= .zero,
                  downloadPollInterval > .zero,
                  maximumWriteByteCount > 0
            else {
                throw ICloudDriveFileMemoryError.invalidConfiguration
            }
            self.containerIdentifier = containerIdentifier
            self.documentsSubdirectory = documentsSubdirectory
            self.requireCurrentVersion = requireCurrentVersion
            self.downloadTimeout = downloadTimeout
            self.downloadPollInterval = downloadPollInterval
            self.maximumWriteByteCount = maximumWriteByteCount
        }
    }

    private let configuration: Configuration
    private let locator: any ICloudDriveContainerLocating
    private let itemManager: any ICloudDriveItemManaging
    private let coordinatedItemValidator: @Sendable (URL) throws -> Void

    public init(
        configuration: Configuration,
        locator: any ICloudDriveContainerLocating = SystemICloudDriveContainerLocator(),
        itemManager: any ICloudDriveItemManaging = SystemICloudDriveItemManager()
    ) {
        self.configuration = configuration
        self.locator = locator
        self.itemManager = itemManager
        self.coordinatedItemValidator = { url in
            try Self.validateCurrentCoordinatedItem(at: url)
        }
    }

    init(
        configuration: Configuration,
        locator: any ICloudDriveContainerLocating,
        itemManager: any ICloudDriveItemManaging,
        coordinatedItemValidator: @escaping @Sendable (URL) throws -> Void
    ) {
        self.configuration = configuration
        self.locator = locator
        self.itemManager = itemManager
        self.coordinatedItemValidator = coordinatedItemValidator
    }

    public var rootDescription: String {
        let suffix = configuration.documentsSubdirectory.relativePath
        return "iCloud://\(configuration.containerIdentifier)/Documents"
            + (suffix.isEmpty ? "" : "/\(suffix)")
    }

    public func listDirectory(
        at path: FileMemoryPath,
        maximumEntryCount: Int
    ) async throws -> [FileMemoryDirectoryEntry] {
        guard maximumEntryCount > 0 else {
            throw FileMemoryError.limitExceeded(.entryCount, limit: maximumEntryCount)
        }
        try Task.checkCancellation()
        let resolved = try await resolveAndPrepareRoot()
        let target = targetURL(for: path, rootURL: resolved.rootURL)
        let entries = try await Self.coordinatedListDirectory(
            at: target,
            path: path,
            rootURL: resolved.rootURL,
            maximumEntryCount: maximumEntryCount
        )
        try await ensureContainerUnchanged(resolved.location)
        return entries
    }

    public func readFile(
        at path: FileMemoryPath,
        maximumByteCount: Int
    ) async throws -> FileMemoryReadResult {
        guard !path.components.isEmpty else {
            throw FileMemoryError.notRegularFile(path)
        }
        guard maximumByteCount > 0 else {
            throw FileMemoryError.fileTooLarge(path: path, limit: maximumByteCount)
        }
        try Task.checkCancellation()
        let resolved = try await resolveAndPrepareRoot()
        let target = targetURL(for: path, rootURL: resolved.rootURL)
        try await awaitDownloadReadiness(
            at: target,
            requireCurrentVersion: configuration.requireCurrentVersion
        )
        let result = try await Self.coordinatedReadFile(
            at: target,
            path: path,
            rootURL: resolved.rootURL,
            maximumByteCount: maximumByteCount,
            requireCurrentVersion: configuration.requireCurrentVersion,
            coordinatedItemValidator: coordinatedItemValidator
        )
        try await ensureContainerUnchanged(resolved.location)
        return result
    }

    /// Atomically creates or replaces one root-relative file.
    ///
    /// Writes and root-relative removals are the only mutation boundaries
    /// intentionally exposed by the adapter. This operation does not move,
    /// delete, or merge documents and never resolves version conflicts by
    /// choosing a winner silently.
    public func writeFile(
        _ data: Data,
        at path: FileMemoryPath,
        mode: ICloudDriveWriteMode,
        createParentDirectories: Bool = true
    ) async throws {
        guard !path.components.isEmpty else {
            throw FileMemoryError.notRegularFile(path)
        }
        guard data.count <= configuration.maximumWriteByteCount else {
            throw ICloudDriveFileMemoryError.writeTooLarge(
                limit: configuration.maximumWriteByteCount
            )
        }
        try Task.checkCancellation()
        let resolved = try await resolveAndPrepareRoot()
        let target = targetURL(for: path, rootURL: resolved.rootURL)
        if createParentDirectories, let parentPath = path.parent {
            try await Self.coordinatedPrepareDirectory(
                rootURL: resolved.rootURL,
                relativeComponents: parentPath.components
            )
        }

        let itemExists = try await Self.coordinatedItemExists(
            at: target,
            path: path,
            rootURL: resolved.rootURL
        )
        if itemExists {
            // A replace must never use a stale placeholder or merely downloaded
            // version as its compare-and-swap baseline.
            try await awaitDownloadReadiness(at: target, requireCurrentVersion: true)
        }
        try await Self.coordinatedWriteFile(
            data,
            at: target,
            path: path,
            rootURL: resolved.rootURL,
            replacingExistingItem: itemExists,
            mode: mode,
            coordinatedItemValidator: coordinatedItemValidator
        )
        try await ensureContainerUnchanged(resolved.location)
    }

    /// Convenience for app-authored Markdown and text documents.
    public func writeUTF8(
        _ text: String,
        at path: FileMemoryPath,
        mode: ICloudDriveWriteMode,
        createParentDirectories: Bool = true
    ) async throws {
        try await writeFile(
            Data(text.utf8),
            at: path,
            mode: mode,
            createParentDirectories: createParentDirectories
        )
    }

    /// Removes one app-owned regular file through the same coordinated,
    /// root-relative boundary as reads and writes.
    ///
    /// Directories and symbolic links are never removed. Existing ubiquitous
    /// files must be current and conflict-free before deletion.
    @discardableResult
    public func removeFile(
        at path: FileMemoryPath,
        mode: ICloudDriveRemoveMode = .ifExists
    ) async throws -> Bool {
        try await removeFile(at: path, policy: .mode(mode))
    }

    /// Removes an app-owned regular file only when it still has the modification
    /// date previously returned by a coordinated read or directory listing.
    ///
    /// A missing file returns `false`, including a retry after a prior call
    /// deleted the file but the host crashed before recording success. A matching
    /// file is deleted and returns `true`; a modification-date mismatch or a
    /// snapshot/identity change observed during coordinated removal fails with
    /// ``ICloudDriveFileMemoryError/removePreconditionFailed``. Callers must
    /// discard the observed date and rescan after an iCloud identity or container
    /// change.
    @discardableResult
    public func removeFileIfPresent(
        at path: FileMemoryPath,
        matchingModifiedAt modifiedAt: Date
    ) async throws -> Bool {
        try await removeFile(
            at: path,
            policy: .ifPresentAndUnmodified(modifiedAt: modifiedAt)
        )
    }

    private func removeFile(
        at path: FileMemoryPath,
        policy: ICloudDriveRemovalPolicy
    ) async throws -> Bool {
        guard !path.components.isEmpty else {
            throw FileMemoryError.notRegularFile(path)
        }
        try Task.checkCancellation()
        let resolved = try await resolveAndPrepareRoot()
        let target = targetURL(for: path, rootURL: resolved.rootURL)
        let itemExists = try await Self.coordinatedItemExists(
            at: target,
            path: path,
            rootURL: resolved.rootURL
        )
        guard itemExists else {
            if policy.allowsMissingFile {
                try await ensureContainerUnchanged(resolved.location)
                return false
            }
            throw ICloudDriveFileMemoryError.removePreconditionFailed
        }
        do {
            try await awaitDownloadReadiness(at: target, requireCurrentVersion: true)
        } catch let error as ICloudDriveFileMemoryError
            where policy.allowsMissingFile && error == .downloadFailed
        {
            // The item may have disappeared after the coordinated existence
            // check but before ubiquitous-item metadata could be read. Only
            // convert that specific race to the documented missing no-op; a
            // still-present item keeps the original current-version failure.
            let stillExists = try await Self.coordinatedItemExists(
                at: target,
                path: path,
                rootURL: resolved.rootURL
            )
            guard !stillExists else { throw error }
            try await ensureContainerUnchanged(resolved.location)
            return false
        }
        try await ensureContainerUnchanged(resolved.location)
        let removed = try await Self.coordinatedRemoveFile(
            at: target,
            path: path,
            rootURL: resolved.rootURL,
            policy: policy,
            coordinatedItemValidator: coordinatedItemValidator
        )
        try await ensureContainerUnchanged(resolved.location)
        return removed
    }

    private struct ResolvedRoot: Sendable {
        var location: ICloudDriveContainerLocation
        var rootURL: URL
    }

    private func resolveAndPrepareRoot() async throws -> ResolvedRoot {
        guard let location = await locator.location(
            forContainerIdentifier: configuration.containerIdentifier
        ) else {
            throw ICloudDriveFileMemoryError.iCloudIdentityUnavailable
        }
        guard let containerURL = location.containerURL?.standardizedFileURL,
              containerURL.isFileURL
        else {
            throw ICloudDriveFileMemoryError.containerUnavailable
        }

        let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
        let rootURL = configuration.documentsSubdirectory.components.reduce(documentsURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL

        try await Self.coordinatedPrepareDirectory(
            rootURL: containerURL,
            relativeComponents: ["Documents"] + configuration.documentsSubdirectory.components
        )
        try await ensureContainerUnchanged(location)
        return ResolvedRoot(location: location, rootURL: rootURL)
    }

    private func ensureContainerUnchanged(
        _ initial: ICloudDriveContainerLocation
    ) async throws {
        guard let current = await locator.location(
            forContainerIdentifier: configuration.containerIdentifier
        ),
        current.identityGeneration == initial.identityGeneration,
        current.containerURL?.standardizedFileURL == initial.containerURL?.standardizedFileURL
        else {
            throw ICloudDriveFileMemoryError.containerChangedDuringOperation
        }
    }

    private func awaitDownloadReadiness(
        at url: URL,
        requireCurrentVersion: Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.downloadTimeout)
        var downloadRequested = false

        while true {
            try Task.checkCancellation()
            let state: ICloudDriveItemState
            do {
                state = try await itemManager.state(of: url)
            } catch {
                throw ICloudDriveFileMemoryError.downloadFailed
            }
            guard !state.hasUnresolvedConflicts else {
                throw ICloudDriveFileMemoryError.unresolvedVersionConflict
            }

            switch state.downloadStatus {
            case .notUbiquitous, .current:
                return
            case .downloaded where !requireCurrentVersion:
                return
            case .failed:
                throw ICloudDriveFileMemoryError.downloadFailed
            case .notDownloaded, .downloaded:
                if !downloadRequested {
                    do {
                        try await itemManager.startDownloadingItem(at: url)
                    } catch {
                        throw ICloudDriveFileMemoryError.downloadFailed
                    }
                    downloadRequested = true
                    continue
                }
            }

            guard clock.now < deadline else {
                throw ICloudDriveFileMemoryError.downloadTimedOut
            }
            try await clock.sleep(for: configuration.downloadPollInterval)
        }
    }

    private func targetURL(for path: FileMemoryPath, rootURL: URL) -> URL {
        path.components.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
    }

    private static func coordinatedPrepareDirectory(
        rootURL: URL,
        relativeComponents: [String]
    ) async throws {
        try await Task.detached {
            var coordinationError: NSError?
            var operationError: (any Error)?
            let destination = relativeComponents.reduce(rootURL) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            NSFileCoordinator().coordinate(
                writingItemAt: destination,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    guard coordinatedURL.standardizedFileURL == destination.standardizedFileURL else {
                        throw ICloudDriveFileMemoryError.containerChangedDuringOperation
                    }
                    let descriptor = try openDirectory(
                        rootURL: rootURL,
                        relativeComponents: relativeComponents,
                        createMissing: true
                    )
                    close(descriptor)
                } catch {
                    operationError = error
                }
            }
            if let operationError {
                throw sanitized(
                    operationError,
                    fallback: ICloudDriveFileMemoryError.coordinatedWriteFailed
                )
            }
            if coordinationError != nil {
                throw ICloudDriveFileMemoryError.coordinatedWriteFailed
            }
        }.value
    }

    private static func coordinatedListDirectory(
        at url: URL,
        path: FileMemoryPath,
        rootURL: URL,
        maximumEntryCount: Int
    ) async throws -> [FileMemoryDirectoryEntry] {
        try await Task.detached {
            var coordinationError: NSError?
            var result: Result<[FileMemoryDirectoryEntry], any Error>?
            NSFileCoordinator().coordinate(
                readingItemAt: url,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                result = Result {
                    guard coordinatedURL.standardizedFileURL == url.standardizedFileURL else {
                        throw ICloudDriveFileMemoryError.containerChangedDuringOperation
                    }
                    let descriptor = try openDirectory(
                        rootURL: rootURL,
                        relativeComponents: path.components,
                        createMissing: false
                    )
                    let duplicate = dup(descriptor)
                    close(descriptor)
                    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                        if duplicate >= 0 { close(duplicate) }
                        throw FileMemoryError.accessDenied(path)
                    }
                    defer { closedir(directory) }

                    var entries: [FileMemoryDirectoryEntry] = []
                    while true {
                        errno = 0
                        guard let rawEntry = readdir(directory) else {
                            guard errno == 0 else {
                                throw FileMemoryError.accessDenied(path)
                            }
                            break
                        }
                        let name = directoryEntryName(rawEntry)
                        guard name != ".", name != ".." else { continue }
                        guard entries.count < maximumEntryCount else {
                            throw FileMemoryError.limitExceeded(
                                .entryCount,
                                limit: maximumEntryCount
                            )
                        }
                        let childPath = try path.appending(name)
                        var information = stat()
                        let status = name.withCString {
                            fstatat(dirfd(directory), $0, &information, AT_SYMLINK_NOFOLLOW)
                        }
                        guard status == 0 else {
                            throw FileMemoryError.changedDuringScan(childPath)
                        }
                        let rawType = fileType(information.st_mode)
                        let kind: FileMemoryEntryKind
                        switch rawType {
                        case S_IFREG: kind = .regularFile
                        case S_IFDIR: kind = .directory
                        case S_IFLNK: kind = .symbolicLink
                        default: kind = .other
                        }
                        let isHidden = name.hasPrefix(".")
                            || (information.st_flags & UInt32(UF_HIDDEN)) != 0
                        entries.append(FileMemoryDirectoryEntry(
                            path: childPath,
                            kind: kind,
                            isHidden: isHidden,
                            byteCount: kind == .regularFile
                                ? nonnegativeInt(information.st_size)
                                : nil,
                            modifiedAt: modificationDate(information)
                        ))
                    }
                    return entries.sorted { $0.path < $1.path }
                }
            }
            if let result {
                do {
                    return try result.get()
                } catch {
                    throw sanitized(
                        error,
                        fallback: ICloudDriveFileMemoryError.coordinatedReadFailed
                    )
                }
            }
            if coordinationError != nil {
                throw ICloudDriveFileMemoryError.coordinatedReadFailed
            }
            throw ICloudDriveFileMemoryError.coordinatedReadFailed
        }.value
    }

    private static func coordinatedReadFile(
        at url: URL,
        path: FileMemoryPath,
        rootURL: URL,
        maximumByteCount: Int,
        requireCurrentVersion: Bool,
        coordinatedItemValidator: @escaping @Sendable (URL) throws -> Void
    ) async throws -> FileMemoryReadResult {
        try await Task.detached {
            var coordinationError: NSError?
            var result: Result<FileMemoryReadResult, any Error>?
            NSFileCoordinator().coordinate(
                readingItemAt: url,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                result = Result {
                    guard coordinatedURL.standardizedFileURL == url.standardizedFileURL else {
                        throw ICloudDriveFileMemoryError.containerChangedDuringOperation
                    }
                    if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(
                        at: coordinatedURL
                    ), !versions.isEmpty {
                        throw ICloudDriveFileMemoryError.unresolvedVersionConflict
                    }
                    if requireCurrentVersion {
                        try coordinatedItemValidator(coordinatedURL)
                    }

                    let parent = try openDirectory(
                        rootURL: rootURL,
                        relativeComponents: path.parent?.components ?? [],
                        createMissing: false
                    )
                    let descriptor = path.name!.withCString {
                        openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                    }
                    close(parent)
                    guard descriptor >= 0 else {
                        if errno == ELOOP { throw FileMemoryError.symbolicLink(path) }
                        throw FileMemoryError.accessDenied(path)
                    }
                    var information = stat()
                    guard fstat(descriptor, &information) == 0 else {
                        close(descriptor)
                        throw FileMemoryError.accessDenied(path)
                    }
                    guard fileType(information.st_mode) == S_IFREG else {
                        close(descriptor)
                        throw FileMemoryError.notRegularFile(path)
                    }
                    guard let fileSize = nonnegativeInt(information.st_size),
                          fileSize <= maximumByteCount else {
                        close(descriptor)
                        throw FileMemoryError.fileTooLarge(
                            path: path,
                            limit: maximumByteCount
                        )
                    }

                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var data = Data()
                    data.reserveCapacity(min(fileSize, 64 * 1_024))
                    while true {
                        let remaining = maximumByteCount - data.count
                        let requested = remaining > 0 ? min(64 * 1_024, remaining) : 1
                        guard let chunk = try handle.read(upToCount: requested),
                              !chunk.isEmpty else {
                            break
                        }
                        guard remaining > 0 else {
                            throw FileMemoryError.fileTooLarge(
                                path: path,
                                limit: maximumByteCount
                            )
                        }
                        data.append(chunk)
                    }
                    var finalInformation = stat()
                    guard fstat(descriptor, &finalInformation) == 0,
                          representsSameSnapshot(information, finalInformation),
                          data.count == fileSize else {
                        throw FileMemoryError.changedDuringScan(path)
                    }
                    return FileMemoryReadResult(
                        data: data,
                        modifiedAt: modificationDate(information)
                    )
                }
            }
            if let result {
                do {
                    return try result.get()
                } catch {
                    throw sanitized(
                        error,
                        fallback: ICloudDriveFileMemoryError.coordinatedReadFailed
                    )
                }
            }
            if coordinationError != nil {
                throw ICloudDriveFileMemoryError.coordinatedReadFailed
            }
            throw ICloudDriveFileMemoryError.coordinatedReadFailed
        }.value
    }

    private static func coordinatedWriteFile(
        _ data: Data,
        at url: URL,
        path: FileMemoryPath,
        rootURL: URL,
        replacingExistingItem: Bool,
        mode: ICloudDriveWriteMode,
        coordinatedItemValidator: @escaping @Sendable (URL) throws -> Void
    ) async throws {
        try await Task.detached {
            var coordinationError: NSError?
            var operationError: (any Error)?
            NSFileCoordinator().coordinate(
                writingItemAt: url,
                options: replacingExistingItem ? .forReplacing : [],
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    guard coordinatedURL.standardizedFileURL == url.standardizedFileURL else {
                        throw ICloudDriveFileMemoryError.containerChangedDuringOperation
                    }
                    if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(
                        at: coordinatedURL
                    ), !versions.isEmpty {
                        throw ICloudDriveFileMemoryError.unresolvedVersionConflict
                    }
                    let parent = try openDirectory(
                        rootURL: rootURL,
                        relativeComponents: path.parent?.components ?? [],
                        createMissing: false
                    )
                    defer { close(parent) }
                    let name = path.name!
                    let existing = try fileInformation(
                        parentDescriptor: parent,
                        name: name,
                        path: path
                    )
                    if existing != nil {
                        try coordinatedItemValidator(coordinatedURL)
                    }

                    switch mode {
                    case .createOnly where existing != nil:
                        throw ICloudDriveFileMemoryError.writePreconditionFailed
                    case .replaceExisting where existing == nil:
                        throw ICloudDriveFileMemoryError.writePreconditionFailed
                    case .replaceIfUnmodified(let expected):
                        guard let existing,
                              modificationDate(existing) == expected else {
                            throw ICloudDriveFileMemoryError.writePreconditionFailed
                        }
                    case .createOnly, .replaceExisting, .createOrReplace:
                        break
                    }
                    try atomicWrite(
                        data,
                        parentDescriptor: parent,
                        name: name,
                        path: path,
                        mode: mode
                    )
                } catch {
                    operationError = error
                }
            }
            if let operationError {
                throw sanitized(
                    operationError,
                    fallback: ICloudDriveFileMemoryError.coordinatedWriteFailed
                )
            }
            if coordinationError != nil {
                throw ICloudDriveFileMemoryError.coordinatedWriteFailed
            }
        }.value
    }

    private static func coordinatedRemoveFile(
        at url: URL,
        path: FileMemoryPath,
        rootURL: URL,
        policy: ICloudDriveRemovalPolicy,
        coordinatedItemValidator: @escaping @Sendable (URL) throws -> Void
    ) async throws -> Bool {
        try await Task.detached {
            var coordinationError: NSError?
            var result: Result<Bool, any Error>?
            NSFileCoordinator().coordinate(
                writingItemAt: url,
                options: .forDeleting,
                error: &coordinationError
            ) { coordinatedURL in
                result = Result {
                    guard coordinatedURL.standardizedFileURL == url.standardizedFileURL else {
                        throw ICloudDriveFileMemoryError.containerChangedDuringOperation
                    }
                    if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(
                        at: coordinatedURL
                    ), !versions.isEmpty {
                        throw ICloudDriveFileMemoryError.unresolvedVersionConflict
                    }
                    let parent: Int32
                    do {
                        parent = try openDirectory(
                            rootURL: rootURL,
                            relativeComponents: path.parent?.components ?? [],
                            createMissing: false,
                            missingIntermediateIsAbsent: true
                        )
                    } catch ICloudDriveDescriptorTraversalError.missingIntermediateDirectory {
                        if policy.allowsMissingFile { return false }
                        throw ICloudDriveFileMemoryError.removePreconditionFailed
                    }
                    defer { close(parent) }
                    let name = path.name!
                    guard let initialInformation = try fileInformation(
                        parentDescriptor: parent,
                        name: name,
                        path: path
                    ) else {
                        if policy.allowsMissingFile { return false }
                        throw ICloudDriveFileMemoryError.removePreconditionFailed
                    }
                    try coordinatedItemValidator(coordinatedURL)

                    // Coordination serializes participating presenters. The
                    // descriptor-rooted full-snapshot recheck also detects a
                    // local mutation or replacement observed while coordinated
                    // validation runs, even when it restores the expected mtime.
                    guard let currentInformation = try fileInformation(
                        parentDescriptor: parent,
                        name: name,
                        path: path
                    ) else {
                        if policy.allowsMissingFile { return false }
                        throw ICloudDriveFileMemoryError.removePreconditionFailed
                    }
                    guard representsSameSnapshot(initialInformation, currentInformation) else {
                        throw ICloudDriveFileMemoryError.removePreconditionFailed
                    }
                    if let expected = policy.expectedModificationDate,
                       modificationDate(currentInformation) != expected {
                        throw ICloudDriveFileMemoryError.removePreconditionFailed
                    }
                    let status = name.withCString { unlinkat(parent, $0, 0) }
                    if status != 0 {
                        if errno == ENOENT, policy.allowsMissingFile { return false }
                        throw ICloudDriveFileMemoryError.coordinatedRemoveFailed
                    }
                    return true
                }
            }
            if let result {
                do {
                    return try result.get()
                } catch {
                    throw sanitized(
                        error,
                        fallback: ICloudDriveFileMemoryError.coordinatedRemoveFailed
                    )
                }
            }
            if coordinationError != nil {
                throw ICloudDriveFileMemoryError.coordinatedRemoveFailed
            }
            throw ICloudDriveFileMemoryError.coordinatedRemoveFailed
        }.value
    }

    private static func coordinatedItemExists(
        at url: URL,
        path: FileMemoryPath,
        rootURL: URL
    ) async throws -> Bool {
        try await Task.detached {
            let parentURL = url.deletingLastPathComponent()
            var coordinationError: NSError?
            var result: Result<Bool, any Error>?
            NSFileCoordinator().coordinate(
                readingItemAt: parentURL,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                result = Result {
                    guard coordinatedURL.standardizedFileURL == parentURL.standardizedFileURL else {
                        throw ICloudDriveFileMemoryError.containerChangedDuringOperation
                    }
                    let parent: Int32
                    do {
                        parent = try openDirectory(
                            rootURL: rootURL,
                            relativeComponents: path.parent?.components ?? [],
                            createMissing: false,
                            missingIntermediateIsAbsent: true
                        )
                    } catch ICloudDriveDescriptorTraversalError.missingIntermediateDirectory {
                        return false
                    }
                    defer { close(parent) }
                    return try fileInformation(
                        parentDescriptor: parent,
                        name: path.name!,
                        path: path
                    ) != nil
                }
            }
            if let result {
                do {
                    return try result.get()
                } catch {
                    throw sanitized(
                        error,
                        fallback: ICloudDriveFileMemoryError.coordinatedReadFailed
                    )
                }
            }
            if coordinationError != nil {
                throw ICloudDriveFileMemoryError.coordinatedReadFailed
            }
            throw ICloudDriveFileMemoryError.coordinatedReadFailed
        }.value
    }

    /// Opens every component relative to a pinned root descriptor. Unlike URL
    /// metadata checks followed by path-based I/O, `O_NOFOLLOW` keeps a
    /// symlink substitution from redirecting the operation outside the root.
    private static func openDirectory(
        rootURL: URL,
        relativeComponents: [String],
        createMissing: Bool,
        missingIntermediateIsAbsent: Bool = false
    ) throws -> Int32 {
        var before = stat()
        guard lstat(rootURL.path, &before) == 0 else {
            throw ICloudDriveFileMemoryError.rootUnavailable
        }
        guard fileType(before.st_mode) != S_IFLNK else {
            throw ICloudDriveFileMemoryError.symbolicLinkNotAllowed
        }
        guard fileType(before.st_mode) == S_IFDIR else {
            throw ICloudDriveFileMemoryError.rootUnavailable
        }
        var descriptor = open(
            rootURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw ICloudDriveFileMemoryError.rootUnavailable
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              representsSameObject(before, opened) else {
            close(descriptor)
            throw ICloudDriveFileMemoryError.rootUnavailable
        }

        for component in relativeComponents {
            var componentInformation = stat()
            let inspection = component.withCString {
                fstatat(descriptor, $0, &componentInformation, AT_SYMLINK_NOFOLLOW)
            }
            if inspection == 0 {
                guard fileType(componentInformation.st_mode) != S_IFLNK else {
                    close(descriptor)
                    throw ICloudDriveFileMemoryError.symbolicLinkNotAllowed
                }
                guard fileType(componentInformation.st_mode) == S_IFDIR else {
                    close(descriptor)
                    throw ICloudDriveFileMemoryError.rootUnavailable
                }
            } else if errno != ENOENT {
                close(descriptor)
                throw ICloudDriveFileMemoryError.rootUnavailable
            }
            var next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
            }
            if next < 0, errno == ENOENT, createMissing {
                let creation = component.withCString {
                    mkdirat(descriptor, $0, mode_t(S_IRWXU))
                }
                guard creation == 0 || errno == EEXIST else {
                    close(descriptor)
                    throw ICloudDriveFileMemoryError.coordinatedWriteFailed
                }
                next = component.withCString {
                    openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
                }
            }
            guard next >= 0 else {
                let failure = errno
                close(descriptor)
                if failure == ENOENT, missingIntermediateIsAbsent {
                    throw ICloudDriveDescriptorTraversalError.missingIntermediateDirectory
                }
                if failure == ELOOP || failure == ENOTDIR {
                    throw ICloudDriveFileMemoryError.symbolicLinkNotAllowed
                }
                throw ICloudDriveFileMemoryError.rootUnavailable
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func fileInformation(
        parentDescriptor: Int32,
        name: String,
        path: FileMemoryPath
    ) throws -> stat? {
        var information = stat()
        let status = name.withCString {
            fstatat(parentDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw FileMemoryError.accessDenied(path)
        }
        guard fileType(information.st_mode) != S_IFLNK else {
            throw FileMemoryError.symbolicLink(path)
        }
        guard fileType(information.st_mode) == S_IFREG else {
            throw FileMemoryError.notRegularFile(path)
        }
        return information
    }

    private static func atomicWrite(
        _ data: Data,
        parentDescriptor: Int32,
        name: String,
        path: FileMemoryPath,
        mode: ICloudDriveWriteMode
    ) throws {
        let temporaryName = ".agentruntime-write-\(UUID().uuidString)"
        let temporaryDescriptor = temporaryName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw ICloudDriveFileMemoryError.coordinatedWriteFailed
        }
        var temporaryExists = true
        defer {
            close(temporaryDescriptor)
            if temporaryExists {
                _ = temporaryName.withCString { unlinkat(parentDescriptor, $0, 0) }
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            var written = 0
            while written < rawBuffer.count {
                guard let base = rawBuffer.baseAddress else { break }
                let count = Darwin.write(
                    temporaryDescriptor,
                    base.advanced(by: written),
                    rawBuffer.count - written
                )
                guard count > 0 else {
                    throw ICloudDriveFileMemoryError.coordinatedWriteFailed
                }
                written += count
            }
        }
        guard fsync(temporaryDescriptor) == 0 else {
            throw ICloudDriveFileMemoryError.coordinatedWriteFailed
        }

        // Recheck caller-visible preconditions immediately before publication.
        let current = try fileInformation(
            parentDescriptor: parentDescriptor,
            name: name,
            path: path
        )
        switch mode {
        case .createOnly where current != nil:
            throw ICloudDriveFileMemoryError.writePreconditionFailed
        case .replaceExisting where current == nil:
            throw ICloudDriveFileMemoryError.writePreconditionFailed
        case .replaceIfUnmodified(let expected):
            guard let current, modificationDate(current) == expected else {
                throw ICloudDriveFileMemoryError.writePreconditionFailed
            }
        case .createOnly, .replaceExisting, .createOrReplace:
            break
        }

        let renameStatus = temporaryName.withCString { temporaryCString in
            name.withCString { destinationCString in
                if case .createOnly = mode {
                    renameatx_np(
                        parentDescriptor,
                        temporaryCString,
                        parentDescriptor,
                        destinationCString,
                        UInt32(RENAME_EXCL)
                    )
                } else {
                    renameat(
                        parentDescriptor,
                        temporaryCString,
                        parentDescriptor,
                        destinationCString
                    )
                }
            }
        }
        guard renameStatus == 0 else {
            if errno == EEXIST {
                throw ICloudDriveFileMemoryError.writePreconditionFailed
            }
            throw ICloudDriveFileMemoryError.coordinatedWriteFailed
        }
        temporaryExists = false
    }

    /// Rechecks the ubiquitous item's state after the file coordinator grants
    /// access. A preflight download check alone is insufficient because a sync
    /// daemon or another device can publish a newer version while this process
    /// waits for coordination.
    private static func validateCurrentCoordinatedItem(at url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemDownloadingErrorKey,
                .ubiquitousItemHasUnresolvedConflictsKey,
            ])
        } catch {
            throw ICloudDriveFileMemoryError.downloadFailed
        }
        guard values.ubiquitousItemHasUnresolvedConflicts != true else {
            throw ICloudDriveFileMemoryError.unresolvedVersionConflict
        }
        guard values.ubiquitousItemDownloadingError == nil else {
            throw ICloudDriveFileMemoryError.downloadFailed
        }
        guard values.isUbiquitousItem == true else { return }
        guard case .current? = values.ubiquitousItemDownloadingStatus else {
            throw ICloudDriveFileMemoryError.itemNotCurrent
        }
    }

    private static func fileType(_ mode: mode_t) -> mode_t {
        mode & mode_t(S_IFMT)
    }

    private static func nonnegativeInt<T: BinaryInteger>(_ value: T) -> Int? {
        guard value >= 0, value <= T(Int.max) else { return nil }
        return Int(value)
    }

    private static func modificationDate(_ information: stat) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(information.st_mtimespec.tv_sec)
                + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    private static func representsSameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func representsSameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        representsSameObject(lhs, rhs)
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func directoryEntryName(
        _ entry: UnsafeMutablePointer<dirent>
    ) -> String {
        var name = entry.pointee.d_name
        return withUnsafePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func sanitized(
        _ error: any Error,
        fallback: ICloudDriveFileMemoryError
    ) -> any Error {
        if let error = error as? ICloudDriveFileMemoryError { return error }
        if let error = error as? FileMemoryError { return error }
        if error is CancellationError { return CancellationError() }
        return fallback
    }
}
#endif
