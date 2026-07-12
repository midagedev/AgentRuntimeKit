import Foundation

public extension OpenAIChatCompletionsProvider {
    /// OpenRouter preset. `referer` and `applicationName` become the optional attribution headers.
    static func openRouter(
        credentialResolver: any ProviderCredentialResolving,
        referer: URL? = nil,
        applicationName: String? = nil,
        retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(),
        httpClient: any StreamingHTTPClient = URLSessionStreamingHTTPClient()
    ) -> OpenAIChatCompletionsProvider {
        var headers: [String: String] = [:]
        if let referer { headers["HTTP-Referer"] = referer.absoluteString }
        if let applicationName, !applicationName.isEmpty { headers["X-Title"] = applicationName }
        return OpenAIChatCompletionsProvider(
            identifier: "openrouter",
            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            credentialResolver: credentialResolver,
            maxOutputTokensParameter: "max_tokens",
            additionalHeaders: headers,
            retryPolicy: retryPolicy,
            httpClient: httpClient
        )
    }

    /// xAI preset using its OpenAI-compatible Chat Completions endpoint.
    static func xAI(
        credentialResolver: any ProviderCredentialResolving,
        retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(),
        httpClient: any StreamingHTTPClient = URLSessionStreamingHTTPClient()
    ) -> OpenAIChatCompletionsProvider {
        OpenAIChatCompletionsProvider(
            identifier: "xai",
            endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
            credentialResolver: credentialResolver,
            maxOutputTokensParameter: "max_tokens",
            retryPolicy: retryPolicy,
            httpClient: httpClient
        )
    }

    /// Local Ollama preset. The base URL can point at a remote or reverse-proxied Ollama host.
    static func ollama(
        baseURL: URL = URL(string: "http://127.0.0.1:11434/v1")!,
        additionalHeaders: [String: String] = [:],
        retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(),
        httpClient: any StreamingHTTPClient = URLSessionStreamingHTTPClient()
    ) -> OpenAIChatCompletionsProvider {
        OpenAIChatCompletionsProvider(
            identifier: "ollama",
            endpoint: baseURL.appendingPathComponent("chat/completions"),
            credentialResolver: nil,
            maxOutputTokensParameter: "max_tokens",
            includeUsageInStream: false,
            additionalHeaders: additionalHeaders,
            retryPolicy: retryPolicy,
            httpClient: httpClient
        )
    }
}
