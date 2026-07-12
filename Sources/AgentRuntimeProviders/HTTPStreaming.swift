import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transport-neutral HTTP request used by model providers.
public struct StreamingHTTPRequest: Sendable, Hashable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(
        url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// The response head and a single-consumer stream of body chunks.
public struct StreamingHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Injectable streaming transport. Tests can provide fixtures without opening a socket.
public protocol StreamingHTTPClient: Sendable {
    func stream(_ request: StreamingHTTPRequest) async throws -> StreamingHTTPResponse
}

public enum StreamingHTTPError: LocalizedError, Sendable, Equatable {
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server did not return an HTTP response."
        }
    }
}

/// `URLSession` implementation that preserves incremental delivery and cancellation.
public struct URLSessionStreamingHTTPClient: StreamingHTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let chunkSize: Int

    public init(session: URLSession = .shared, chunkSize: Int = 8 * 1_024) {
        self.session = session
        self.chunkSize = max(1, chunkSize)
    }

    public func stream(_ request: StreamingHTTPRequest) async throws -> StreamingHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request.urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamingHTTPError.invalidResponse
        }

        let chunkSize = self.chunkSize
        let sessionTask = bytes.task
        let reader = URLSessionByteChunkReader(bytes: bytes, chunkSize: chunkSize)
        let body = AsyncThrowingStream<Data, Error>(unfolding: {
            do {
                return try await withTaskCancellationHandler {
                    try await reader.next()
                } onCancel: {
                    sessionTask.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    sessionTask.cancel()
                    throw CancellationError()
                }
                throw error
            }
        })

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return StreamingHTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }
}

/// Mutable iterator state for the documented single-consumer response body.
/// `AsyncThrowingStream` serializes calls to its unfolding closure; the box is
/// never exposed and therefore cannot be iterated concurrently.
private final class URLSessionByteChunkReader: @unchecked Sendable {
    private var iterator: URLSession.AsyncBytes.Iterator
    private let chunkSize: Int

    init(bytes: URLSession.AsyncBytes, chunkSize: Int) {
        self.iterator = bytes.makeAsyncIterator()
        self.chunkSize = chunkSize
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        var chunk = Data()
        chunk.reserveCapacity(chunkSize)
        while chunk.count < chunkSize {
            guard let byte = try await iterator.next() else {
                return chunk.isEmpty ? nil : chunk
            }
            try Task.checkCancellation()
            chunk.append(byte)
            // Provider streams are line-oriented (SSE or NDJSON). Flushing at
            // a newline preserves real incremental delivery even when a short
            // response never reaches the byte bound.
            if byte == 0x0A {
                return chunk
            }
        }
        return chunk
    }
}
