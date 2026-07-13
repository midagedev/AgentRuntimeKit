#if os(iOS) || os(macOS)
import AgentRuntimeFileMemory
import Foundation

/// A hint to perform a complete file-memory rescan.
///
/// Metadata query notifications are intentionally not interpreted as an exact
/// edit log. iCloud can coalesce, reorder, or omit intermediate local states;
/// consumers should pass every hint to `FileMemoryRescanController` so the
/// canonical directory is enumerated and reconciled as one complete snapshot.
public struct ICloudDriveRescanHint: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case initialMetadataGatheringCompleted
        case metadataUpdated
        case identityChanged
    }

    public var reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }
}

/// A cancellable stream of rescan hints.
public final class ICloudDriveRescanObservation: @unchecked Sendable {
    public let hints: AsyncStream<ICloudDriveRescanHint>

    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    public init(
        hints: AsyncStream<ICloudDriveRescanHint>,
        cancellation: @escaping @Sendable () -> Void
    ) {
        self.hints = hints
        self.cancellation = cancellation
    }

    public func cancel() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    deinit {
        cancel()
    }
}

public protocol ICloudDriveRescanHintSource: Sendable {
    @MainActor
    func makeRescanObservation() async throws -> ICloudDriveRescanObservation
}

@MainActor
protocol ICloudMetadataObservationSession: AnyObject, Sendable {
    func start() -> Bool
    func stop()
    nonisolated func requestStop()
}

typealias ICloudMetadataObservationSessionFactory = @MainActor (
    URL,
    AsyncStream<ICloudDriveRescanHint>.Continuation
) -> any ICloudMetadataObservationSession

/// Metadata-query-backed rescan hints for one explicit iCloud Drive container.
///
/// An iCloud identity change emits one final hint and then finishes the stream.
/// The host must discard account-scoped derived state as its policy requires and
/// create a new observation; the old query is never silently rebound to another
/// account. Cancelling the observation before the app enters the background and
/// recreating it after foreground activation gives hosts an explicit lifecycle
/// boundary for long-running queries.
///
/// Before shipping, validate this source in a signed build on two physical
/// devices logged in to the same iCloud account. Exercise create, replace,
/// rename, delete, offline-to-online download, background/foreground, iCloud
/// logout, and account switching. A fake locator or Simulator test cannot prove
/// server propagation, entitlement provisioning, or conflict-version behavior.
@MainActor
public final class SystemICloudDriveRescanHintSource: ICloudDriveRescanHintSource {
    private let configuration: ICloudDriveFileMemoryAccess.Configuration
    private let locator: any ICloudDriveContainerLocating
    private let sessionFactory: ICloudMetadataObservationSessionFactory

    public init(
        configuration: ICloudDriveFileMemoryAccess.Configuration,
        locator: any ICloudDriveContainerLocating = SystemICloudDriveContainerLocator()
    ) {
        self.configuration = configuration
        self.locator = locator
        self.sessionFactory = { rootURL, continuation in
            SystemICloudMetadataObservationSession(
                rootURL: rootURL,
                continuation: continuation
            )
        }
    }

    init(
        configuration: ICloudDriveFileMemoryAccess.Configuration,
        locator: any ICloudDriveContainerLocating,
        sessionFactory: @escaping ICloudMetadataObservationSessionFactory
    ) {
        self.configuration = configuration
        self.locator = locator
        self.sessionFactory = sessionFactory
    }

    public func makeRescanObservation() async throws -> ICloudDriveRescanObservation {
        guard let initialLocation = await locator.location(
            forContainerIdentifier: configuration.containerIdentifier
        ) else {
            throw ICloudDriveFileMemoryError.iCloudIdentityUnavailable
        }
        guard let containerURL = initialLocation.containerURL?.standardizedFileURL,
              containerURL.isFileURL
        else {
            throw ICloudDriveFileMemoryError.containerUnavailable
        }

        let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
        let rootURL = configuration.documentsSubdirectory.components.reduce(documentsURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL

        let pair = AsyncStream<ICloudDriveRescanHint>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let session = sessionFactory(rootURL, pair.continuation)
        guard session.start() else {
            pair.continuation.finish()
            throw ICloudDriveFileMemoryError.metadataQueryUnavailable
        }

        guard let currentLocation = await locator.location(
            forContainerIdentifier: configuration.containerIdentifier
        ),
        currentLocation.identityGeneration == initialLocation.identityGeneration,
        currentLocation.containerURL?.standardizedFileURL == containerURL
        else {
            session.stop()
            throw ICloudDriveFileMemoryError.containerChangedDuringOperation
        }

        pair.continuation.onTermination = { @Sendable _ in
            session.requestStop()
        }
        return ICloudDriveRescanObservation(hints: pair.stream) {
            session.requestStop()
        }
    }
}

@MainActor
private final class SystemICloudMetadataObservationSession: ICloudMetadataObservationSession {
    private let query: NSMetadataQuery
    private let continuation: AsyncStream<ICloudDriveRescanHint>.Continuation
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    init(
        rootURL: URL,
        continuation: AsyncStream<ICloudDriveRescanHint>.Continuation
    ) {
        query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K == %@ OR %K BEGINSWITH %@",
            NSMetadataItemPathKey,
            rootURL.path,
            NSMetadataItemPathKey,
            rootURL.path + "/"
        )
        query.operationQueue = .main
        self.continuation = continuation
    }

    func start() -> Bool {
        let notificationCenter = NotificationCenter.default
        observers = [
            notificationCenter.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.yield(.initialMetadataGatheringCompleted)
                }
            },
            notificationCenter.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.yield(.metadataUpdated)
                }
            },
            notificationCenter.addObserver(
                forName: Notification.Name.NSUbiquityIdentityDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.yield(.identityChanged)
                    self.stop()
                }
            },
        ]

        guard query.start() else {
            stop()
            return false
        }
        return true
    }

    func yield(_ reason: ICloudDriveRescanHint.Reason) {
        guard !stopped else { return }
        continuation.yield(ICloudDriveRescanHint(reason: reason))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        query.stop()
        let notificationCenter = NotificationCenter.default
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        continuation.finish()
    }

    nonisolated func requestStop() {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}
#endif
