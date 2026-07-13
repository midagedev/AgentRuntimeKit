import Foundation

/// Coalesces file-system notification hints into complete source rescans.
///
/// Notification payloads are never interpreted as source truth. After the
/// debounce interval, ``FileMemorySynchronizer`` enumerates the entire root and
/// atomically reconciles that complete snapshot.
public actor FileMemoryRescanController {
    private let synchronizer: FileMemorySynchronizer
    private let debounceInterval: Duration
    private var pending: Task<FileMemorySyncReport, Error>?
    private var pendingID: UUID?

    public init(
        synchronizer: FileMemorySynchronizer,
        debounceInterval: Duration = .milliseconds(350)
    ) {
        self.synchronizer = synchronizer
        self.debounceInterval = max(.zero, debounceInterval)
    }

    /// Signals that the canonical source may have changed. Repeated hints
    /// replace the pending delay rather than attempting lossy per-event edits.
    public func signalChange() {
        pending?.cancel()
        let id = UUID()
        pendingID = id
        let synchronizer = synchronizer
        let delay = debounceInterval
        pending = Task {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            return try await synchronizer.synchronize()
        }
    }

    /// Waits for the currently scheduled rescan, if any.
    public func waitForPendingRescan() async throws -> FileMemorySyncReport? {
        guard let pending, let id = pendingID else { return nil }
        do {
            let report = try await pending.value
            if pendingID == id {
                self.pending = nil
                pendingID = nil
            }
            return report
        } catch {
            if pendingID == id {
                self.pending = nil
                pendingID = nil
            }
            throw error
        }
    }

    /// Cancels a delayed hint and immediately performs a complete rescan.
    public func rescanNow() async throws -> FileMemorySyncReport {
        pending?.cancel()
        pending = nil
        pendingID = nil
        return try await synchronizer.synchronize()
    }

    public func cancelPendingRescan() {
        pending?.cancel()
        pending = nil
        pendingID = nil
    }
}
