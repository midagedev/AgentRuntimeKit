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
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(chunkSize)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if chunk.count >= chunkSize {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

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
