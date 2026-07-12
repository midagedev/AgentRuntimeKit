import Foundation

/// A dependency-free JSON-RPC client for MCP's Streamable HTTP transport.
public actor MCPStreamableHTTPClient {
    private let configuration: MCPStreamableHTTPConfiguration
    private let transport: any MCPHTTPTransport
    private let decoder = JSONDecoder()

    private var nextRequestID = 1
    private var initializationIsInProgress = false
    private var initializationResult: MCPInitializeResult?
    private var selectedProtocolVersion: String?
    private var sessionIdentifier: String?

    public init(
        configuration: MCPStreamableHTTPConfiguration,
        transport: any MCPHTTPTransport = URLSessionMCPHTTPTransport()
    ) throws {
        guard let scheme = configuration.endpoint.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && configuration.allowsInsecureHTTP),
              configuration.endpoint.host?.isEmpty == false,
              configuration.endpoint.user == nil,
              configuration.endpoint.password == nil
        else {
            throw MCPClientError.invalidEndpoint
        }
        self.configuration = configuration
        self.transport = transport
    }

    public var isInitialized: Bool { initializationResult != nil }
    public var sessionID: String? { sessionIdentifier }
    public var negotiatedProtocolVersion: String? { selectedProtocolVersion }
    public var serverInfo: MCPImplementationInfo? { initializationResult?.serverInfo }

    /// Performs `initialize`, captures an optional MCP session ID, then sends
    /// `notifications/initialized`. Repeated calls return the negotiated result.
    public func initialize() async throws -> MCPInitializeResult {
        if let initializationResult { return initializationResult }
        guard !initializationIsInProgress else {
            throw MCPClientError.initializationInProgress
        }
        initializationIsInProgress = true
        defer { initializationIsInProgress = false }

        do {
            let params: JSONValue = .object([
                "protocolVersion": .string(configuration.protocolVersion),
                "capabilities": configuration.capabilities,
                "clientInfo": .object([
                    "name": .string(configuration.clientInfo.name),
                    "version": .string(configuration.clientInfo.version),
                ]),
            ])
            let value = try await sendRequest(
                method: "initialize",
                params: params,
                sendsCancellationNotification: false
            )
            let result: MCPInitializeResult = try decode(
                MCPInitializeResult.self,
                from: value,
                context: "initialize result"
            )
            guard result.protocolVersion == configuration.protocolVersion else {
                throw MCPClientError.protocolVersionMismatch(
                    requested: configuration.protocolVersion,
                    received: result.protocolVersion
                )
            }

            selectedProtocolVersion = result.protocolVersion
            try await sendNotification(method: "notifications/initialized", params: nil)
            initializationResult = result
            return result
        } catch {
            initializationResult = nil
            selectedProtocolVersion = nil
            sessionIdentifier = nil
            throw error
        }
    }

    /// Lists all remote tools, following MCP cursor pagination and rejecting loops.
    public func listTools() async throws -> [MCPToolDefinition] {
        try requireInitialization()
        var tools: [MCPToolDefinition] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        repeat {
            let params: JSONValue = if let cursor {
                .object(["cursor": .string(cursor)])
            } else {
                .object([:])
            }
            let value = try await sendRequest(method: "tools/list", params: params)
            let page: MCPToolListPage = try decode(
                MCPToolListPage.self,
                from: value,
                context: "tools/list result"
            )
            tools.append(contentsOf: page.tools)
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw MCPClientError.invalidResponse("tools/list repeated a pagination cursor")
            }
        } while cursor != nil

        return tools
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> MCPToolCallResult {
        try requireInitialization()
        let value = try await sendRequest(
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": arguments,
            ])
        )
        return try decode(
            MCPToolCallResult.self,
            from: value,
            context: "tools/call result"
        )
    }

    /// Terminates the current Streamable HTTP session when the server issued one.
    public func close() async throws {
        guard !initializationIsInProgress else {
            throw MCPClientError.initializationInProgress
        }
        guard let sessionIdentifier else {
            resetSession()
            return
        }
        let request = try makeHTTPRequest(
            method: "DELETE",
            body: nil,
            sessionID: sessionIdentifier
        )
        defer { resetSession() }
        let response = try await performTransport(request)
        if response.statusCode != 405 {
            try validateHTTPStatus(response.statusCode)
        }
    }

    private func resetSession() {
        initializationResult = nil
        selectedProtocolVersion = nil
        sessionIdentifier = nil
    }

    private func requireInitialization() throws {
        guard initializationResult != nil else { throw MCPClientError.notInitialized }
    }

    private func sendRequest(
        method: String,
        params: JSONValue?,
        sendsCancellationNotification: Bool = true
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        let requestID = nextRequestID
        nextRequestID += 1

        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(requestID)),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        let body = try JSONValue.object(object).encodedData()
        let request = try makeHTTPRequest(
            method: "POST",
            body: body,
            sessionID: sessionIdentifier
        )

        let cancellationRequest: MCPHTTPRequest? = if sendsCancellationNotification {
            try makeHTTPRequest(
                method: "POST",
                body: try JSONValue.object([
                    "jsonrpc": .string("2.0"),
                    "method": .string("notifications/cancelled"),
                    "params": .object([
                        "requestId": .number(Double(requestID)),
                        "reason": .string("Client request cancelled"),
                    ]),
                ]).encodedData(),
                sessionID: sessionIdentifier
            )
        } else {
            nil
        }

        let responseObject = try await performRPCTransport(
            request,
            requestID: requestID,
            mayEstablishSession: method == "initialize",
            cancellationRequest: cancellationRequest
        )

        let result = responseObject["result"]
        let errorValue = responseObject["error"]
        guard (result == nil) != (errorValue == nil) else {
            throw MCPClientError.invalidResponse(
                "JSON-RPC response must contain exactly one of result or error"
            )
        }
        if let errorValue {
            throw try remoteError(from: errorValue)
        }
        return result!
    }

    private func sendNotification(method: String, params: JSONValue?) async throws {
        try Task.checkCancellation()
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        let request = try makeHTTPRequest(
            method: "POST",
            body: try JSONValue.object(object).encodedData(),
            sessionID: sessionIdentifier
        )
        let response = try await performTransport(request)
        try validateHTTPStatus(response.statusCode)
        try updateSession(from: response)
    }

    private func makeHTTPRequest(
        method: String,
        body: Data?,
        sessionID: String?
    ) throws -> MCPHTTPRequest {
        var headers = configuration.additionalHeaders
        if let authentication = configuration.authentication {
            for (name, value) in authentication.values {
                setHeader(value, named: name, in: &headers)
            }
        }
        setHeader("application/json, text/event-stream", named: "Accept", in: &headers)
        if body != nil {
            setHeader("application/json", named: "Content-Type", in: &headers)
        }
        if let version = selectedProtocolVersion {
            setHeader(version, named: "MCP-Protocol-Version", in: &headers)
        }
        if let sessionID {
            guard isValidSessionID(sessionID) else {
                throw MCPClientError.invalidResponse("session ID contained an invalid character")
            }
            setHeader(sessionID, named: "Mcp-Session-Id", in: &headers)
        }
        guard headers.allSatisfy({ isValidHeader(name: $0.key, value: $0.value) }) else {
            throw MCPClientError.invalidResponse("an HTTP header contained an invalid character")
        }
        return MCPHTTPRequest(
            url: configuration.endpoint,
            method: method,
            headers: headers,
            body: body,
            timeout: configuration.requestTimeout
        )
    }

    private func setHeader(
        _ value: String,
        named name: String,
        in headers: inout [String: String]
    ) {
        for key in headers.keys where key.caseInsensitiveCompare(name) == .orderedSame {
            headers[key] = nil
        }
        headers[name] = value
    }

    private func performTransport(
        _ request: MCPHTTPRequest,
        cancellationRequest: MCPHTTPRequest? = nil
    ) async throws -> MCPHTTPResponse {
        let transport = self.transport
        do {
            let response: MCPHTTPResponse
            if let cancellationRequest {
                response = try await withTaskCancellationHandler {
                    try await transport.send(request)
                } onCancel: {
                    Task.detached(priority: .utility) {
                        _ = try? await transport.send(cancellationRequest)
                    }
                }
            } else {
                response = try await transport.send(request)
            }
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            if let cancellationRequest {
                Task.detached(priority: .utility) {
                    _ = try? await transport.send(cancellationRequest)
                }
            }
            throw MCPClientError.requestTimedOut
        } catch let error as MCPClientError {
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MCPClientError.transportFailure
        }
    }

    private func performRPCTransport(
        _ request: MCPHTTPRequest,
        requestID: Int,
        mayEstablishSession: Bool,
        cancellationRequest: MCPHTTPRequest?
    ) async throws -> [String: JSONValue] {
        let transport = self.transport
        let notifyCancellation: @Sendable () -> Void = {
            guard let cancellationRequest else { return }
            Task.detached(priority: .utility) {
                _ = try? await transport.send(cancellationRequest)
            }
        }

        do {
            let response = try await withTaskCancellationHandler {
                try await transport.stream(request)
            } onCancel: {
                notifyCancellation()
            }
            defer { response.cancel() }
            try Task.checkCancellation()
            try validateHTTPStatus(response.statusCode)
            try updateSession(
                headers: response.headers,
                mayEstablishSession: mayEstablishSession
            )
            return try await withTaskCancellationHandler {
                try await responseObject(for: requestID, response: response)
            } onCancel: {
                response.cancel()
                notifyCancellation()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            notifyCancellation()
            throw MCPClientError.requestTimedOut
        } catch let error as MCPClientError {
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MCPClientError.transportFailure
        }
    }

    private func validateHTTPStatus(_ status: Int) throws {
        guard (200..<300).contains(status) else {
            if status == 404, sessionIdentifier != nil {
                resetSession()
                throw MCPClientError.sessionExpired
            }
            if status == 401 || status == 403 {
                throw MCPClientError.unauthorized(status: status)
            }
            throw MCPClientError.httpStatus(status)
        }
    }

    private func updateSession(
        from response: MCPHTTPResponse,
        mayEstablishSession: Bool = false
    ) throws {
        try updateSession(headers: response.headers, mayEstablishSession: mayEstablishSession)
    }

    private func updateSession(
        headers: [String: String],
        mayEstablishSession: Bool = false
    ) throws {
        guard let received = headers.first(where: {
            $0.key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame
        })?.value else { return }
        guard isValidSessionID(received) else {
            throw MCPClientError.invalidResponse("server returned an invalid session ID")
        }
        if let sessionIdentifier, sessionIdentifier != received {
            throw MCPClientError.invalidResponse("server changed the active session ID")
        }
        guard sessionIdentifier != nil || mayEstablishSession else {
            throw MCPClientError.invalidResponse("server established a session outside initialization")
        }
        sessionIdentifier = received
    }

    private func isValidSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private func isValidHeader(name: String, value: String) -> Bool {
        let tokenPunctuation = "!#$%&'*+-.^_`|~".unicodeScalars
        let validName = !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar)
                    || tokenPunctuation.contains(scalar))
        }
        let validValue = value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value != 0x7F)
        }
        return validName && validValue
    }

    private func responseObject(
        for requestID: Int,
        response: MCPHTTPResponse
    ) throws -> [String: JSONValue] {
        let payloads = try responsePayloads(response.body)
        if let matched = try matchingResponseObject(for: requestID, payloads: payloads) {
            return matched
        }
        throw MCPClientError.invalidResponse("no response matched the JSON-RPC request ID")
    }

    private func responseObject(
        for requestID: Int,
        response: MCPHTTPStreamingResponse
    ) async throws -> [String: JSONValue] {
        let maximumBodyBytes = 8 * 1_024 * 1_024
        let contentType = response.header(named: "Content-Type")?.lowercased() ?? ""
        var usesEventStream: Bool? = contentType.contains("text/event-stream") ? true : nil
        var buffered = Data()
        var eventDecoder = MCPIncrementalEventStreamDecoder(
            maximumBufferedBytes: maximumBodyBytes
        )

        for try await chunk in response.body {
            try Task.checkCancellation()
            guard !chunk.isEmpty else { continue }
            if usesEventStream == true {
                let payloads = try eventDecoder.append(chunk)
                if let matched = try matchingResponseObject(for: requestID, payloads: payloads) {
                    return matched
                }
                continue
            }

            buffered.append(chunk)
            guard buffered.count <= maximumBodyBytes else {
                throw MCPClientError.invalidResponse("response body exceeded the safety limit")
            }
            if usesEventStream == nil, Self.looksLikeEventStream(buffered) {
                usesEventStream = true
                let payloads = try eventDecoder.append(buffered)
                buffered.removeAll(keepingCapacity: false)
                if let matched = try matchingResponseObject(for: requestID, payloads: payloads) {
                    return matched
                }
            } else if let payload = try? JSONValue.parse(buffered),
                      let matched = try matchingResponseObject(
                          for: requestID,
                          payloads: [payload]
                      ) {
                return matched
            }
        }

        if usesEventStream == true {
            let payloads = try eventDecoder.finish()
            if let matched = try matchingResponseObject(for: requestID, payloads: payloads) {
                return matched
            }
        } else {
            let payloads = try responsePayloads(buffered)
            if let matched = try matchingResponseObject(for: requestID, payloads: payloads) {
                return matched
            }
        }
        throw MCPClientError.invalidResponse("no response matched the JSON-RPC request ID")
    }

    private func matchingResponseObject(
        for requestID: Int,
        payloads: [JSONValue]
    ) throws -> [String: JSONValue]? {
        for payload in payloads {
            let candidates: [JSONValue]
            if case .array(let batch) = payload {
                candidates = batch
            } else {
                candidates = [payload]
            }
            for candidate in candidates {
                guard let object = candidate.objectValue else { continue }
                guard object["id"] == .number(Double(requestID)) else { continue }
                guard object["result"] != nil || object["error"] != nil else { continue }
                guard object["jsonrpc"] == .string("2.0") else {
                    throw MCPClientError.invalidResponse("JSON-RPC version was not 2.0")
                }
                return object
            }
        }
        return nil
    }

    private static func looksLikeEventStream(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(1_024), encoding: .utf8) else { return false }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("data:")
            || trimmed.hasPrefix("event:")
            || trimmed.hasPrefix("id:")
            || trimmed.hasPrefix(":")
    }

    private func responsePayloads(_ body: Data) throws -> [JSONValue] {
        if let value = try? JSONValue.parse(body) { return [value] }
        guard let text = String(data: body, encoding: .utf8) else {
            throw MCPClientError.invalidResponse("body was neither JSON nor UTF-8 event stream")
        }

        var payloads: [JSONValue] = []
        var dataLines: [String] = []
        func flush() throws {
            guard !dataLines.isEmpty else { return }
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            guard !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            payloads.append(try JSONValue.parse(data))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
            if line.isEmpty {
                try flush()
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                dataLines.append(String(value))
            }
        }
        try flush()
        guard !payloads.isEmpty else {
            throw MCPClientError.invalidResponse("event stream contained no JSON data events")
        }
        return payloads
    }

    private func remoteError(from value: JSONValue) throws -> MCPClientError {
        guard let object = value.objectValue,
              let codeValue = object["code"],
              let code = Self.integerValue(codeValue),
              let message = object["message"]?.stringValue
        else {
            throw MCPClientError.invalidResponse("JSON-RPC error object was malformed")
        }
        return .remoteError(code: code, message: message, data: object["data"])
    }

    private static func integerValue(_ value: JSONValue) -> Int? {
        switch value {
        case .number(let value): Int(exactly: value)
        case .integer(let value): Int(exactly: value)
        case .unsignedInteger(let value): Int(exactly: value)
        case .decimal(let value):
            Decimal(Int(NSDecimalNumber(decimal: value).int64Value)) == value
                ? Int(exactly: NSDecimalNumber(decimal: value).int64Value)
                : nil
        default: nil
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from value: JSONValue,
        context: String
    ) throws -> T {
        do {
            return try decoder.decode(type, from: value.encodedData())
        } catch {
            throw MCPClientError.invalidResponse("could not decode \(context)")
        }
    }
}

public typealias MCPClient = MCPStreamableHTTPClient

private struct MCPIncrementalEventStreamDecoder {
    private var lineBuffer = Data()
    private var dataLines: [String] = []
    private var bufferedEventBytes = 0
    private let maximumBufferedBytes: Int

    init(maximumBufferedBytes: Int) {
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    mutating func append(_ chunk: Data) throws -> [JSONValue] {
        lineBuffer.append(chunk)
        try enforceLimit()
        var payloads: [JSONValue] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            if let payload = try consume(line: line) { payloads.append(payload) }
        }
        return payloads
    }

    mutating func finish() throws -> [JSONValue] {
        var payloads: [JSONValue] = []
        if !lineBuffer.isEmpty {
            let line = lineBuffer
            lineBuffer.removeAll(keepingCapacity: false)
            if let payload = try consume(line: line) { payloads.append(payload) }
        }
        if let payload = try flushEvent() { payloads.append(payload) }
        return payloads
    }

    private mutating func consume(line rawLine: Data) throws -> JSONValue? {
        var line = rawLine
        if line.last == 0x0D { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else {
            throw MCPClientError.invalidResponse("event stream was not valid UTF-8")
        }
        if text.isEmpty { return try flushEvent() }
        guard text.hasPrefix("data:") else { return nil }
        var value = String(text.dropFirst(5))
        if value.first == " " { value.removeFirst() }
        dataLines.append(value)
        bufferedEventBytes += value.utf8.count
        try enforceLimit()
        return nil
    }

    private mutating func flushEvent() throws -> JSONValue? {
        guard !dataLines.isEmpty else { return nil }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        bufferedEventBytes = 0
        guard !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try JSONValue.parse(data)
        } catch {
            throw MCPClientError.invalidResponse("event stream contained malformed JSON data")
        }
    }

    private func enforceLimit() throws {
        guard lineBuffer.count + bufferedEventBytes <= maximumBufferedBytes else {
            throw MCPClientError.invalidResponse("event stream event exceeded the safety limit")
        }
    }
}
