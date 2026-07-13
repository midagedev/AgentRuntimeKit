import AgentRuntimeCore
import AgentRuntimeMemory
import Foundation

/// A validated path relative to a file-memory root.
///
/// Absolute paths, empty components, traversal components, backslashes, NULs,
/// and control characters are rejected at construction and decoding time. The
/// root itself is represented by ``root``.
public struct FileMemoryPath: Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    public let components: [String]

    public static let root = FileMemoryPath(validatedComponents: [])

    public init(_ relativePath: String) throws {
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else {
            throw FileMemoryError.invalidPath("Paths must be relative to the configured root.")
        }
        guard !relativePath.contains("\\") else {
            throw FileMemoryError.invalidPath("Backslashes are not permitted in portable relative paths.")
        }
        guard !relativePath.unicodeScalars.contains(where: {
            $0.value == 0 || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw FileMemoryError.invalidPath("Paths must not contain NUL or control characters.")
        }

        if relativePath.isEmpty {
            self = .root
            return
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        try Self.validate(components)
        self.init(validatedComponents: components)
    }

    public var relativePath: String { components.joined(separator: "/") }
    public var description: String { relativePath.isEmpty ? "." : relativePath }
    public var name: String? { components.last }
    public var depth: Int { components.count }
    public var parent: FileMemoryPath? {
        guard !components.isEmpty else { return nil }
        return FileMemoryPath(validatedComponents: Array(components.dropLast()))
    }

    public func appending(_ component: String) throws -> FileMemoryPath {
        var updated = components
        updated.append(component)
        try Self.validate(updated)
        return FileMemoryPath(validatedComponents: updated)
    }

    /// Filesystem paths preserve their supplied UTF-8 bytes. Swift `String`
    /// equality uses canonical Unicode equivalence, which would otherwise make
    /// two byte-distinct names compare equal while this type's ordering keeps
    /// them distinct. Define equality and hashing over the same byte identity
    /// used by ordering so `Set`, sorting, and provider inventory checks agree.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(relativePath.utf8.count)
        for byte in relativePath.utf8 {
            hasher.combine(byte)
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid root-relative file-memory path."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(relativePath)
    }

    private init(validatedComponents: [String]) {
        self.components = validatedComponents
    }

    private static func validate(_ components: [String]) throws {
        guard !components.isEmpty else { return }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw FileMemoryError.invalidPath("Paths must not contain empty or traversal components.")
            }
            guard component != "/", !component.contains("/"), !component.contains("\\") else {
                throw FileMemoryError.invalidPath("Each path component must contain a single file name.")
            }
            guard !component.unicodeScalars.contains(where: {
                $0.value == 0 || CharacterSet.controlCharacters.contains($0)
            }) else {
                throw FileMemoryError.invalidPath("Path components must not contain NUL or control characters.")
            }
        }
    }
}

public enum FileMemoryEntryKind: String, Sendable, Codable, Hashable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

/// Metadata returned by an injected read-only file provider.
public struct FileMemoryDirectoryEntry: Sendable, Codable, Hashable {
    public var path: FileMemoryPath
    public var kind: FileMemoryEntryKind
    public var isHidden: Bool
    public var byteCount: Int?
    public var modifiedAt: Date?

    public init(
        path: FileMemoryPath,
        kind: FileMemoryEntryKind,
        isHidden: Bool = false,
        byteCount: Int? = nil,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.kind = kind
        self.isHidden = isHidden
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

/// A bounded read result. Providers can return refreshed metadata so a scan can
/// detect files that changed between enumeration and reading.
public struct FileMemoryReadResult: Sendable, Codable, Hashable {
    public var data: Data
    public var modifiedAt: Date?

    public init(data: Data, modifiedAt: Date? = nil) {
        self.data = data
        self.modifiedAt = modifiedAt
    }
}

/// The scanner deliberately has no write operation. Canonical files remain
/// user-owned, while the memory store is a rebuildable derived index.
public protocol FileMemoryFileAccess: Sendable {
    var rootDescription: String { get async }
    /// Lists at most `maximumEntryCount` immediate children.
    ///
    /// Providers must stop enumeration and throw ``FileMemoryError/limitExceeded(_:limit:)``
    /// before materializing more entries. This keeps a hostile single directory
    /// from bypassing the scanner's aggregate inventory limit.
    func listDirectory(
        at path: FileMemoryPath,
        maximumEntryCount: Int
    ) async throws -> [FileMemoryDirectoryEntry]
    func readFile(
        at path: FileMemoryPath,
        maximumByteCount: Int
    ) async throws -> FileMemoryReadResult
}

public extension FileMemoryFileAccess {
    /// Convenience for direct inspection outside a bounded synchronization.
    func listDirectory(at path: FileMemoryPath) async throws -> [FileMemoryDirectoryEntry] {
        try await listDirectory(at: path, maximumEntryCount: Int.max)
    }
}

public struct FileMemoryConfiguration: Sendable, Codable, Hashable {
    public let sourceID: String
    public let scope: MemoryScope
    public let includedExtensions: Set<String>
    public let recursive: Bool
    public let maximumDepth: Int
    public let maximumEntryCount: Int
    public let maximumDirectoryCount: Int
    public let maximumFileCount: Int
    public let maximumFileByteCount: Int
    public let maximumTotalByteCount: Int
    public let maximumChunkCharacterCount: Int
    public let maximumChunkCount: Int
    public let maximumGeneratedCharacterCount: Int
    public let maximumSensitivity: AgentDataSensitivity
    public let missingPolicy: MemorySourceMissingPolicy
    public let memoryKind: MemoryKind
    public let confidence: Double
    public let importance: Double
    public let maximumGenerationRetries: Int

    public init(
        sourceID: String,
        scope: MemoryScope,
        includedExtensions: Set<String> = ["md", "markdown", "txt", "text"],
        recursive: Bool = true,
        maximumDepth: Int = 8,
        maximumEntryCount: Int = 10_000,
        maximumDirectoryCount: Int = 2_000,
        maximumFileCount: Int = 2_000,
        maximumFileByteCount: Int = 1_048_576,
        maximumTotalByteCount: Int = 16_777_216,
        maximumChunkCharacterCount: Int = 4_000,
        maximumChunkCount: Int = 10_000,
        maximumGeneratedCharacterCount: Int = 33_554_432,
        maximumSensitivity: AgentDataSensitivity = .privateData,
        missingPolicy: MemorySourceMissingPolicy = .archive,
        memoryKind: MemoryKind = .observation,
        confidence: Double = 1,
        importance: Double = 0.5,
        maximumGenerationRetries: Int = 3
    ) throws {
        let trimmedSourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourceID.isEmpty,
              sourceID == trimmedSourceID,
              sourceID.utf8.count <= 512 else {
            throw FileMemoryError.invalidConfiguration("sourceID must contain 1...512 UTF-8 bytes.")
        }
        guard sourceID.utf8.elementsEqual(
            sourceID.precomposedStringWithCanonicalMapping.utf8
        ) else {
            throw FileMemoryError.invalidConfiguration("sourceID must use NFC Unicode normalization.")
        }
        guard !sourceID.unicodeScalars.contains(where: {
            $0.value == 0 || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw FileMemoryError.invalidConfiguration("sourceID must not contain control characters.")
        }
        guard maximumDepth >= 0, maximumDepth <= 128 else {
            throw FileMemoryError.invalidConfiguration("maximumDepth must be in 0...128.")
        }
        guard maximumEntryCount > 0 else {
            throw FileMemoryError.invalidConfiguration("maximumEntryCount must be greater than zero.")
        }
        guard maximumDirectoryCount > 0 else {
            throw FileMemoryError.invalidConfiguration("maximumDirectoryCount must be greater than zero.")
        }
        guard maximumFileCount > 0 else {
            throw FileMemoryError.invalidConfiguration("maximumFileCount must be greater than zero.")
        }
        guard maximumFileByteCount > 0, maximumTotalByteCount >= maximumFileByteCount else {
            throw FileMemoryError.invalidConfiguration(
                "Byte limits must be positive and the total limit must cover at least one file."
            )
        }
        guard maximumChunkCharacterCount >= 128 else {
            throw FileMemoryError.invalidConfiguration(
                "maximumChunkCharacterCount must be at least 128."
            )
        }
        guard maximumChunkCount > 0, maximumGeneratedCharacterCount > 0 else {
            throw FileMemoryError.invalidConfiguration(
                "Chunk count and generated-character limits must be greater than zero."
            )
        }
        guard maximumSensitivity != .secret else {
            throw FileMemoryError.invalidConfiguration(
                "Secret files must use a secret store and cannot be indexed as memory."
            )
        }
        guard confidence.isFinite, (0...1).contains(confidence),
              importance.isFinite, (0...1).contains(importance) else {
            throw FileMemoryError.invalidConfiguration("confidence and importance must be in 0...1.")
        }
        guard (0...20).contains(maximumGenerationRetries) else {
            throw FileMemoryError.invalidConfiguration("maximumGenerationRetries must be in 0...20.")
        }

        let extensions = Set(includedExtensions.compactMap { value -> String? in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard !normalized.isEmpty,
                  normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
            else { return nil }
            return normalized
        })
        guard !extensions.isEmpty, extensions.count == includedExtensions.count else {
            throw FileMemoryError.invalidConfiguration(
                "includedExtensions must contain only unique alphanumeric extensions."
            )
        }

        self.sourceID = sourceID
        self.scope = scope
        self.includedExtensions = extensions
        self.recursive = recursive
        self.maximumDepth = maximumDepth
        self.maximumEntryCount = maximumEntryCount
        self.maximumDirectoryCount = maximumDirectoryCount
        self.maximumFileCount = maximumFileCount
        self.maximumFileByteCount = maximumFileByteCount
        self.maximumTotalByteCount = maximumTotalByteCount
        self.maximumChunkCharacterCount = maximumChunkCharacterCount
        self.maximumChunkCount = maximumChunkCount
        self.maximumGeneratedCharacterCount = maximumGeneratedCharacterCount
        self.maximumSensitivity = maximumSensitivity
        self.missingPolicy = missingPolicy
        self.memoryKind = memoryKind
        self.confidence = confidence
        self.importance = importance
        self.maximumGenerationRetries = maximumGenerationRetries
    }
}

public enum FileMemoryIssueReason: String, Sendable, Codable, Hashable {
    case hidden
    case unsupportedExtension
    case depthLimit
    case symbolicLink
    case nonRegularFile
    case tooLarge
    case binaryContent
    case invalidUTF8
    case emptyContent
    case changedDuringScan
    case invalidProviderEntry
}

/// Content-free scan diagnostics. Paths are relative and no file contents are
/// copied into logs or error reports.
public struct FileMemoryIssue: Sendable, Codable, Hashable {
    public var path: FileMemoryPath
    public var reason: FileMemoryIssueReason

    public init(path: FileMemoryPath, reason: FileMemoryIssueReason) {
        self.path = path
        self.reason = reason
    }
}

public struct FileMemorySyncReport: Sendable, Codable, Hashable {
    public var sourceID: String
    public var previousGeneration: Int
    public var generation: Int
    public var directoriesScanned: Int
    public var filesScanned: Int
    public var bytesRead: Int
    public var chunkCount: Int
    public var generatedCharacterCount: Int
    public var created: Int
    public var updated: Int
    public var unchanged: Int
    public var archived: Int
    public var purged: Int
    public var generationConflictCount: Int
    public var skipped: [FileMemoryIssue]
    public var rejected: [FileMemoryIssue]

    public var skippedCount: Int { skipped.count }
    public var rejectedCount: Int { rejected.count }

    public init(
        sourceID: String,
        previousGeneration: Int,
        generation: Int,
        directoriesScanned: Int,
        filesScanned: Int,
        bytesRead: Int,
        chunkCount: Int,
        generatedCharacterCount: Int,
        created: Int,
        updated: Int,
        unchanged: Int,
        archived: Int,
        purged: Int,
        generationConflictCount: Int,
        skipped: [FileMemoryIssue],
        rejected: [FileMemoryIssue]
    ) {
        self.sourceID = sourceID
        self.previousGeneration = previousGeneration
        self.generation = generation
        self.directoriesScanned = directoriesScanned
        self.filesScanned = filesScanned
        self.bytesRead = bytesRead
        self.chunkCount = chunkCount
        self.generatedCharacterCount = generatedCharacterCount
        self.created = created
        self.updated = updated
        self.unchanged = unchanged
        self.archived = archived
        self.purged = purged
        self.generationConflictCount = generationConflictCount
        self.skipped = skipped
        self.rejected = rejected
    }
}

public enum FileMemoryLimit: String, Sendable, Codable, Hashable {
    case entryCount
    case directoryCount
    case fileCount
    case totalBytes
    case chunkCount
    case generatedCharacters
}

public enum FileMemoryError: Error, Sendable, Equatable, LocalizedError {
    case invalidPath(String)
    case invalidConfiguration(String)
    case invalidRoot(String)
    case accessDenied(FileMemoryPath)
    case notDirectory(FileMemoryPath)
    case notRegularFile(FileMemoryPath)
    case symbolicLink(FileMemoryPath)
    case fileTooLarge(path: FileMemoryPath, limit: Int)
    case limitExceeded(FileMemoryLimit, limit: Int)
    case changedDuringScan(FileMemoryPath)
    case generationConflictExhausted(attempts: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let reason): "Invalid file-memory path: \(reason)"
        case .invalidConfiguration(let reason): "Invalid file-memory configuration: \(reason)"
        case .invalidRoot(let reason): "Invalid file-memory root: \(reason)"
        case .accessDenied(let path): "Access to file-memory path \(path) was denied."
        case .notDirectory(let path): "File-memory path \(path) is not a directory."
        case .notRegularFile(let path): "File-memory path \(path) is not a regular file."
        case .symbolicLink(let path): "Symbolic links are not allowed at file-memory path \(path)."
        case .fileTooLarge(let path, let limit):
            "File-memory path \(path) exceeds the \(limit)-byte read limit."
        case .limitExceeded(let kind, let limit):
            "The file-memory scan exceeded its \(kind.rawValue) limit of \(limit)."
        case .changedDuringScan(let path): "File-memory path \(path) changed during the scan."
        case .generationConflictExhausted(let attempts):
            "The file-memory source changed concurrently across \(attempts) reconcile attempts."
        }
    }
}
