import AgentRuntimeProviders
import Foundation
import XCTest

final class URLSessionStreamingHTTPClientTests: XCTestCase {
    func testStreamsURLSessionResponseInBoundedChunks() async throws {
        URLProtocolFixture.install(
            statusCode: 206,
            headers: ["X-Fixture": "yes"],
            bodyChunks: [Data("abc".utf8), Data("def".utf8)]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = URLSessionStreamingHTTPClient(session: session, chunkSize: 2)

        let response = try await client.stream(StreamingHTTPRequest(
            url: URL(string: "https://fixture.invalid/stream")!,
            headers: ["X-Request": "fixture"]
        ))
        var chunks: [Data] = []
        for try await chunk in response.body { chunks.append(chunk) }

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.header(named: "x-fixture"), "yes")
        XCTAssertEqual(chunks.map(\.count), [2, 2, 2])
        XCTAssertEqual(Data(chunks.joined()), Data("abcdef".utf8))
        XCTAssertEqual(URLProtocolFixture.lastRequestHeader(named: "X-Request"), "fixture")
    }

    func testCancellingBodyConsumerCancelsUnderlyingURLSessionTask() async throws {
        let stopLoadingProbe = StopLoadingProbe()
        URLProtocolFixture.install(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            bodyChunks: [],
            stallsAfterResponse: true,
            onStopLoading: { stopLoadingProbe.record() }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = URLSessionStreamingHTTPClient(session: session)
        let response = try await client.stream(StreamingHTTPRequest(
            url: URL(string: "https://fixture.invalid/stalled-stream")!
        ))

        let consumer = Task {
            for try await _ in response.body {}
        }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()

        do {
            try await consumer.value
            XCTFail("Cancelling the body consumer must terminate iteration")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(
            stopLoadingProbe.waitForStopLoading(timeout: 2),
            "Cancelling body iteration must eventually invoke URLProtocol.stopLoading()"
        )
        XCTAssertEqual(stopLoadingProbe.count, 1)
    }
}

private final class StopLoadingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstStop = DispatchSemaphore(value: 0)
    private var stopCount = 0

    var count: Int {
        lock.withLock { stopCount }
    }

    func record() {
        let isFirstStop = lock.withLock { () -> Bool in
            stopCount += 1
            return stopCount == 1
        }
        if isFirstStop {
            firstStop.signal()
        }
    }

    func waitForStopLoading(timeout: TimeInterval) -> Bool {
        firstStop.wait(timeout: .now() + timeout) == .success
    }
}

private final class URLProtocolFixture: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var bodyChunks: [Data]
        var stallsAfterResponse: Bool
        var onStopLoading: (@Sendable () -> Void)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture = Response(
        statusCode: 200,
        headers: [:],
        bodyChunks: [],
        stallsAfterResponse: false,
        onStopLoading: nil
    )
    nonisolated(unsafe) private static var capturedRequest: URLRequest?
    private var onStopLoading: (@Sendable () -> Void)?

    static func install(
        statusCode: Int,
        headers: [String: String],
        bodyChunks: [Data],
        stallsAfterResponse: Bool = false,
        onStopLoading: (@Sendable () -> Void)? = nil
    ) {
        lock.withLock {
            fixture = Response(
                statusCode: statusCode,
                headers: headers,
                bodyChunks: bodyChunks,
                stallsAfterResponse: stallsAfterResponse,
                onStopLoading: onStopLoading
            )
            capturedRequest = nil
        }
    }

    static func lastRequestHeader(named name: String) -> String? {
        lock.withLock { capturedRequest?.value(forHTTPHeaderField: name) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.lock.withLock { () -> Response in
            Self.capturedRequest = request
            return Self.fixture
        }
        onStopLoading = response.onStopLoading
        guard let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: ProviderTestError.fixtureFailure)
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        guard !response.stallsAfterResponse else { return }
        for chunk in response.bodyChunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        onStopLoading?()
    }
}
