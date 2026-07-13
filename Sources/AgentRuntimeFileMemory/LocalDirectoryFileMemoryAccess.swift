import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A local, read-only file provider rooted at one explicitly selected
/// directory. Every component is opened with `O_NOFOLLOW`; symbolic-link swaps
/// cannot escape the selected root between enumeration and reading.
public actor LocalDirectoryFileMemoryAccess: FileMemoryFileAccess {
    private let rootURL: URL
    private let rootDescriptor: Int32

    public init(rootURL: URL) throws {
        guard rootURL.isFileURL else {
            throw FileMemoryError.invalidRoot("The local root must be a file URL.")
        }

        let standardized = rootURL.standardizedFileURL
        var information = stat()
        guard lstat(standardized.path, &information) == 0 else {
            throw FileMemoryError.invalidRoot("The local root does not exist or is inaccessible.")
        }
        guard Self.fileType(information.st_mode) != S_IFLNK else {
            throw FileMemoryError.invalidRoot("The local root must not be a symbolic link.")
        }
        guard Self.fileType(information.st_mode) == S_IFDIR else {
            throw FileMemoryError.invalidRoot("The local root must be a directory.")
        }
        let descriptor = open(
            standardized.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw FileMemoryError.invalidRoot("The local root could not be opened safely.")
        }
        var openedInformation = stat()
        guard fstat(descriptor, &openedInformation) == 0,
              Self.representsSameObject(information, openedInformation) else {
            close(descriptor)
            throw FileMemoryError.invalidRoot("The local root changed while it was being opened.")
        }
        self.rootURL = standardized
        self.rootDescriptor = descriptor
    }

    deinit { close(rootDescriptor) }

    public var rootDescription: String { rootURL.path }

    public func listDirectory(
        at path: FileMemoryPath,
        maximumEntryCount: Int
    ) async throws -> [FileMemoryDirectoryEntry] {
        guard maximumEntryCount > 0 else {
            throw FileMemoryError.limitExceeded(.entryCount, limit: maximumEntryCount)
        }
        try Task.checkCancellation()
        let descriptor = try openPath(path, requireDirectory: true)
        defer { close(descriptor) }

        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw FileMemoryError.accessDenied(path)
        }
        defer { closedir(directory) }

        var entries: [FileMemoryDirectoryEntry] = []
        errno = 0
        while let rawEntry = readdir(directory) {
            try Task.checkCancellation()
            let name = Self.name(of: rawEntry)
            guard name != ".", name != ".." else { continue }
            guard entries.count < maximumEntryCount else {
                throw FileMemoryError.limitExceeded(
                    .entryCount,
                    limit: maximumEntryCount
                )
            }

            let childPath: FileMemoryPath
            do {
                childPath = try path.appending(name)
            } catch {
                // A provider cannot safely represent this file name. Surface a
                // content-free path error instead of silently indexing it.
                throw FileMemoryError.invalidPath("A directory entry has an unsafe file name.")
            }

            var information = stat()
            let status = name.withCString {
                fstatat(descriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                throw FileMemoryError.changedDuringScan(childPath)
            }

            let rawType = Self.fileType(information.st_mode)
            let kind: FileMemoryEntryKind
            switch rawType {
            case S_IFREG: kind = .regularFile
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symbolicLink
            default: kind = .other
            }

            let isHidden: Bool
            #if canImport(Darwin)
            isHidden = name.hasPrefix(".") || (information.st_flags & UInt32(UF_HIDDEN)) != 0
            #else
            isHidden = name.hasPrefix(".")
            #endif

            entries.append(FileMemoryDirectoryEntry(
                path: childPath,
                kind: kind,
                isHidden: isHidden,
                byteCount: kind == .regularFile ? Self.nonnegativeInt(information.st_size) : nil,
                modifiedAt: Self.modificationDate(information)
            ))
        }
        guard errno == 0 else {
            throw FileMemoryError.accessDenied(path)
        }

        return entries.sorted { $0.path < $1.path }
    }

    public func readFile(
        at path: FileMemoryPath,
        maximumByteCount: Int
    ) async throws -> FileMemoryReadResult {
        guard maximumByteCount > 0 else {
            throw FileMemoryError.fileTooLarge(path: path, limit: maximumByteCount)
        }
        try Task.checkCancellation()

        let descriptor = try openPath(path, requireDirectory: false)
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            close(descriptor)
            throw FileMemoryError.accessDenied(path)
        }
        guard Self.fileType(information.st_mode) == S_IFREG else {
            close(descriptor)
            throw FileMemoryError.notRegularFile(path)
        }
        guard let byteCount = Self.nonnegativeInt(information.st_size),
              byteCount <= maximumByteCount else {
            close(descriptor)
            throw FileMemoryError.fileTooLarge(path: path, limit: maximumByteCount)
        }

        let modifiedAt = Self.modificationDate(information)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var data = Data()
        data.reserveCapacity(min(byteCount, 64 * 1_024))
        while true {
            try Task.checkCancellation()
            let remaining = maximumByteCount - data.count
            let requested = remaining > 0 ? min(64 * 1_024, remaining) : 1
            guard let chunk = try handle.read(upToCount: requested),
                  !chunk.isEmpty else {
                break
            }
            guard remaining > 0 else {
                throw FileMemoryError.fileTooLarge(path: path, limit: maximumByteCount)
            }
            data.append(chunk)
        }

        var finalInformation = stat()
        guard fstat(descriptor, &finalInformation) == 0 else {
            try? handle.close()
            throw FileMemoryError.accessDenied(path)
        }
        guard Self.representsSameSnapshot(information, finalInformation),
              data.count == byteCount else {
            try? handle.close()
            throw FileMemoryError.changedDuringScan(path)
        }
        try handle.close()

        guard data.count <= maximumByteCount else {
            throw FileMemoryError.fileTooLarge(path: path, limit: maximumByteCount)
        }
        return FileMemoryReadResult(data: data, modifiedAt: modifiedAt)
    }

    private func openPath(_ path: FileMemoryPath, requireDirectory: Bool) throws -> Int32 {
        // `dup` would share a directory-stream offset with the pinned root and
        // make later scans appear empty after the first `readdir`. Opening `.`
        // relative to the pinned descriptor creates an independent open-file
        // description without re-resolving the original absolute path.
        var descriptor = ".".withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        }
        guard descriptor >= 0 else {
            throw FileMemoryError.invalidRoot("The local root is no longer accessible.")
        }

        if path.components.isEmpty { return descriptor }

        for (index, component) in path.components.enumerated() {
            let isLast = index == path.components.count - 1
            var flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            if !isLast || requireDirectory { flags |= O_DIRECTORY }
            let next = component.withCString { openat(descriptor, $0, flags) }
            if next < 0 {
                let failure = errno
                close(descriptor)
                if failure == ELOOP {
                    throw FileMemoryError.symbolicLink(path)
                }
                if failure == ENOTDIR {
                    throw requireDirectory
                        ? FileMemoryError.notDirectory(path)
                        : FileMemoryError.notRegularFile(path)
                }
                throw FileMemoryError.accessDenied(path)
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func fileType(_ mode: mode_t) -> mode_t {
        mode & mode_t(S_IFMT)
    }

    private static func nonnegativeInt<T: BinaryInteger>(_ value: T) -> Int? {
        guard value >= 0, value <= T(Int.max) else { return nil }
        return Int(value)
    }

    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        var name = entry.pointee.d_name
        return withUnsafePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func modificationDate(_ information: stat) -> Date {
        #if canImport(Darwin)
        let seconds = TimeInterval(information.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
        #else
        let seconds = TimeInterval(information.st_mtim.tv_sec)
        let nanoseconds = TimeInterval(information.st_mtim.tv_nsec) / 1_000_000_000
        #endif
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }

    private static func representsSameSnapshot(_ before: stat, _ after: stat) -> Bool {
        guard representsSameObject(before, after),
              before.st_mode == after.st_mode,
              before.st_size == after.st_size else {
            return false
        }
        #if canImport(Darwin)
        return before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        #else
        return before.st_mtim.tv_sec == after.st_mtim.tv_sec
            && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
            && before.st_ctim.tv_sec == after.st_ctim.tv_sec
            && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec
        #endif
    }

    private static func representsSameObject(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino
    }
}
