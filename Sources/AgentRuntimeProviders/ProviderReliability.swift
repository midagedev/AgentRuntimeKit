import AgentRuntimeCore
import Foundation

public enum ProviderFailureCategory: String, Sendable, Codable, Hashable {
    case authentication
    case permission
    case invalidRequest
    case rateLimited
    case unavailable
    case server
    case unknown
}

/// Normalized rate-limit information from common provider headers.
public struct ProviderRateLimit: Sendable, Codable, Hashable {
    public var requestLimit: Int?
    public var remainingRequests: Int?
    public var tokenLimit: Int?
    public var remainingTokens: Int?
    public var retryAfterSeconds: Double?
    public var requestResetSeconds: Double?
    public var tokenResetSeconds: Double?

    public init(
        requestLimit: Int? = nil,
        remainingRequests: Int? = nil,
        tokenLimit: Int? = nil,
        remainingTokens: Int? = nil,
        retryAfterSeconds: Double? = nil,
        requestResetSeconds: Double? = nil,
        tokenResetSeconds: Double? = nil
    ) {
        self.requestLimit = requestLimit
        self.remainingRequests = remainingRequests
        self.tokenLimit = tokenLimit
        self.remainingTokens = remainingTokens
        self.retryAfterSeconds = retryAfterSeconds
        self.requestResetSeconds = requestResetSeconds
        self.tokenResetSeconds = tokenResetSeconds
    }

    public var isEmpty: Bool {
        requestLimit == nil && remainingRequests == nil && tokenLimit == nil
            && remainingTokens == nil && retryAfterSeconds == nil
            && requestResetSeconds == nil && tokenResetSeconds == nil
    }

    var metadataValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let requestLimit { object["requestLimit"] = .number(Double(requestLimit)) }
        if let remainingRequests { object["remainingRequests"] = .number(Double(remainingRequests)) }
        if let tokenLimit { object["tokenLimit"] = .number(Double(tokenLimit)) }
        if let remainingTokens { object["remainingTokens"] = .number(Double(remainingTokens)) }
        if let retryAfterSeconds { object["retryAfterSeconds"] = .number(retryAfterSeconds) }
        if let requestResetSeconds { object["requestResetSeconds"] = .number(requestResetSeconds) }
        if let tokenResetSeconds { object["tokenResetSeconds"] = .number(tokenResetSeconds) }
        return .object(object)
    }
}

/// Retry policy applied to connection failures, 408/409/429, and 5xx responses.
/// Streaming failures after a 2xx response are deliberately not retried because doing so
/// could replay already-delivered model output.
public struct ProviderRetryPolicy: Sendable, Hashable {
    public var maximumAttempts: Int
    public var baseDelaySeconds: Double
    public var maximumDelaySeconds: Double
    public var jitterRatio: Double
    public var retriesTransportErrors: Bool

    public init(
        maximumAttempts: Int = 3,
        baseDelaySeconds: Double = 0.5,
        maximumDelaySeconds: Double = 8,
        jitterRatio: Double = 0.2,
        retriesTransportErrors: Bool = true
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelaySeconds = max(0, baseDelaySeconds)
        self.maximumDelaySeconds = max(0, maximumDelaySeconds)
        self.jitterRatio = min(max(0, jitterRatio), 1)
        self.retriesTransportErrors = retriesTransportErrors
    }

    public static let none = ProviderRetryPolicy(
        maximumAttempts: 1,
        baseDelaySeconds: 0,
        maximumDelaySeconds: 0,
        jitterRatio: 0,
        retriesTransportErrors: false
    )

    func delaySeconds(forAttempt attempt: Int, retryAfter: Double?) -> Double {
        if let retryAfter, retryAfter >= 0 {
            return min(retryAfter, maximumDelaySeconds)
        }
        let exponent = max(0, attempt - 1)
        let unjittered = min(maximumDelaySeconds, baseDelaySeconds * pow(2, Double(exponent)))
        guard jitterRatio > 0, unjittered > 0 else { return unjittered }
        let multiplier = Double.random(in: (1 - jitterRatio)...(1 + jitterRatio))
        return min(maximumDelaySeconds, max(0, unjittered * multiplier))
    }
}

/// Header-based BYOK authentication backed by a `ProviderCredentialResolving` implementation.
public struct ProviderHeaderAuthentication: Sendable {
    public var resolver: any ProviderCredentialResolving
    public var headerName: String
    public var prefix: String

    public init(
        resolver: any ProviderCredentialResolving,
        headerName: String = "authorization",
        prefix: String = "Bearer "
    ) {
        self.resolver = resolver
        self.headerName = headerName
        self.prefix = prefix
    }

    func apply(to headers: inout [String: String], providerIdentifier: String) async throws {
        let credential = try await resolver.credential(for: providerIdentifier)
        headers[headerName] = prefix + credential
    }
}

func performProviderRequest(
    _ request: StreamingHTTPRequest,
    using client: any StreamingHTTPClient,
    retryPolicy: ProviderRetryPolicy
) async throws -> StreamingHTTPResponse {
    var attempt = 1
    while true {
        try Task.checkCancellation()
        do {
            let response = try await client.stream(request)
            do {
                try await validateSuccessfulResponse(response)
                return response
            } catch let error as ProviderHTTPError {
                guard error.isRetryable, attempt < retryPolicy.maximumAttempts else { throw error }
                let delay = retryPolicy.delaySeconds(
                    forAttempt: attempt,
                    retryAfter: error.rateLimit.retryAfterSeconds
                )
                attempt += 1
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderHTTPError {
            throw error
        } catch {
            guard retryPolicy.retriesTransportErrors,
                  attempt < retryPolicy.maximumAttempts else { throw error }
            let delay = retryPolicy.delaySeconds(forAttempt: attempt, retryAfter: nil)
            attempt += 1
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
    }
}

func normalizedRateLimit(from response: StreamingHTTPResponse) -> ProviderRateLimit {
    ProviderRateLimit(
        requestLimit: integerHeader(response, names: ["x-ratelimit-limit-requests", "ratelimit-limit"]),
        remainingRequests: integerHeader(response, names: ["x-ratelimit-remaining-requests", "ratelimit-remaining"]),
        tokenLimit: integerHeader(response, names: ["x-ratelimit-limit-tokens"]),
        remainingTokens: integerHeader(response, names: ["x-ratelimit-remaining-tokens"]),
        retryAfterSeconds: retryAfter(response.header(named: "retry-after")),
        requestResetSeconds: durationHeader(response, names: ["x-ratelimit-reset-requests", "ratelimit-reset"]),
        tokenResetSeconds: durationHeader(response, names: ["x-ratelimit-reset-tokens"])
    )
}

private func integerHeader(_ response: StreamingHTTPResponse, names: [String]) -> Int? {
    for name in names {
        if let value = response.header(named: name),
           let first = value.split(separator: ",").first,
           let parsed = Int(first.trimmingCharacters(in: .whitespaces)) {
            return parsed
        }
    }
    return nil
}

private func durationHeader(_ response: StreamingHTTPResponse, names: [String]) -> Double? {
    for name in names {
        if let value = response.header(named: name), let parsed = parseDuration(value) {
            return parsed
        }
    }
    return nil
}

private func retryAfter(_ value: String?) -> Double? {
    guard let value else { return nil }
    if let seconds = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return max(0, seconds)
    }
    // RFC 7231 IMF-fixdate. A formatter is created per rare error response to remain Sendable.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    guard let date = formatter.date(from: value) else { return nil }
    return max(0, date.timeIntervalSinceNow)
}

private func parseDuration(_ value: String) -> Double? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.hasSuffix("ms"), let number = Double(trimmed.dropLast(2)) {
        return max(0, number / 1_000)
    }
    if trimmed.hasSuffix("s"), let number = Double(trimmed.dropLast()) {
        return max(0, number)
    }
    if let number = Double(trimmed) {
        // Large reset values are normally Unix timestamps; small values are durations.
        if number > 10_000_000 { return max(0, number - Date().timeIntervalSince1970) }
        return max(0, number)
    }
    return nil
}

/// Tries providers in order. A fallback is attempted only if the current provider fails
/// before emitting text, reasoning, a tool call, or a finish event.
public struct FallbackModelProvider: ModelProvider, Sendable {
    public let identifier: String
    public let providers: [any ModelProvider]
    public let capabilities: ProviderCapabilities

    public init(identifier: String = "fallback", providers: [any ModelProvider]) {
        self.identifier = identifier
        self.providers = providers
        if let first = providers.first {
            self.capabilities = providers.dropFirst().reduce(first.capabilities) {
                $0.intersection($1.capabilities)
            }
        } else {
            self.capabilities = []
        }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        makeModelEventStream { continuation in
            guard !providers.isEmpty else {
                throw AgentRuntimeError.providerNotFound(identifier)
            }

            for (index, provider) in providers.enumerated() {
                var staged: [ModelStreamEvent] = [
                    .metadata(["fallbackProvider": .string(provider.identifier)]),
                ]
                var committed = false
                do {
                    for try await event in provider.stream(request) {
                        try Task.checkCancellation()
                        if committed {
                            continuation.yield(event)
                        } else {
                            staged.append(event)
                            if event.commitsFallback {
                                for stagedEvent in staged { continuation.yield(stagedEvent) }
                                staged.removeAll()
                                committed = true
                            }
                        }
                    }
                    if !committed {
                        for stagedEvent in staged { continuation.yield(stagedEvent) }
                    }
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if committed || index == providers.index(before: providers.endIndex) {
                        throw error
                    }
                    // Drop metadata/usage from the failed, uncommitted provider and try next.
                }
            }
        }
    }
}

private extension ModelStreamEvent {
    var commitsFallback: Bool {
        switch self {
        case .textDelta, .reasoningDelta, .toolCall, .providerContinuation, .finish:
            true
        case .usage, .metadata:
            false
        }
    }
}
