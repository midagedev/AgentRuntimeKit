import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MCPHTTPRequest: Sendable, Hashable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 60
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct MCPHTTPResponse: Sendable, Hashable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct MCPHTTPStreamingResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>
    private let cancellation: @Sendable () -> Void

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, Error>,
        cancellation: @escaping @Sendable () -> Void = {}
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.cancellation = cancellation
    }

    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Stops the response producer. Clients should call this as soon as a
    /// matching JSON-RPC event is found instead of waiting for an SSE stream to close.
    public func cancel() {
        cancellation()
    }
}

public protocol MCPHTTPTransport: Sendable {
    func send(_ request: MCPHTTPRequest) async throws -> MCPHTTPResponse
    func stream(_ request: MCPHTTPRequest) async throws -> MCPHTTPStreamingResponse
}

public extension MCPHTTPTransport {
    /// Compatibility path for small custom transports and deterministic tests.
    /// Production URLSession transport overrides this with true incremental I/O.
    func stream(_ request: MCPHTTPRequest) async throws -> MCPHTTPStreamingResponse {
        let response = try await send(request)
        return MCPHTTPStreamingResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: AsyncThrowingStream { continuation in
                if !response.body.isEmpty { continuation.yield(response.body) }
                continuation.finish()
            }
        )
    }
}

public struct URLSessionMCPHTTPTransport: MCPHTTPTransport, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: MCPHTTPRequest) async throws -> MCPHTTPResponse {
        let urlRequest = makeURLRequest(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw MCPClientError.nonHTTPResponse
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
        return MCPHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    }

    public func stream(_ request: MCPHTTPRequest) async throws -> MCPHTTPStreamingResponse {
        let (bytes, response) = try await session.bytes(for: makeURLRequest(request))
        guard let response = response as? HTTPURLResponse else {
            throw MCPClientError.nonHTTPResponse
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        let producer = Task {
            do {
                var chunk = Data()
                chunk.reserveCapacity(4_096)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    chunk.append(byte)
                    if chunk.count >= 4_096 {
                        pair.continuation.yield(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { pair.continuation.yield(chunk) }
                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish(throwing: CancellationError())
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { @Sendable _ in producer.cancel() }
        return MCPHTTPStreamingResponse(
            statusCode: response.statusCode,
            headers: headers,
            body: pair.stream,
            cancellation: { producer.cancel() }
        )
    }

    private func makeURLRequest(_ request: MCPHTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }
}
