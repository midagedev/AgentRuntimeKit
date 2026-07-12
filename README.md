# AgentRuntimeKit

A headless, provider-neutral agent runtime for Swift applications. It gives an
Apple app one bounded execution model for streaming LLMs, native tools, user
approval, scoped memory, Keychain credentials, checkpoints, audit records, and
optional remote MCP tools.

AgentRuntimeKit intentionally contains no SwiftUI. Dochi and YKPT are the first
two host applications and keep their own domain models, interfaces, and consent
flows.

## Requirements

- Swift 6
- iOS 17+
- macOS 14+
- watchOS 10+
- tvOS 17+

## Products

| Product | Responsibility |
| --- | --- |
| `AgentRuntimeCore` | Messages, providers, bounded agent loop, tool schemas, policy, approval, context, checkpoints, audit contracts |
| `AgentRuntimeProviders` | Anthropic Messages, OpenAI Responses and Chat Completions, Gemini, OpenAI-compatible endpoints, retries and fallback |
| `AgentRuntimeMemory` | In-memory and SQLite stores, scope isolation, TTL, revisions, FTS/lexical retrieval, policy-controlled memory tools |
| `AgentRuntimeApple` | Keychain secret store, protected checkpoints, protected SQLite memory, redacted JSONL audit sink |
| `AgentRuntimeMCP` | Dependency-free MCP Streamable HTTP client and policy-compatible tool adapters |
| `AgentRuntimeTestKit` | Scripted providers, closure tools, and in-memory secrets for host-app tests |

## Minimal native agent

```swift
import AgentRuntimeApple
import AgentRuntimeCore
import AgentRuntimeMemory
import AgentRuntimeProviders

let secrets = KeychainAgentSecretStore()
let credentials = ProviderCredentialResolver(
    secretStore: secrets,
    namespace: "com.example.myapp",
    accounts: ["anthropic": "anthropic-api-key"]
)
let provider = AnthropicMessagesProvider(credentialResolver: credentials)

let memory = try ProtectedSQLiteMemoryStore(configuration: .init(
    databaseURL: memoryDatabaseURL
))
let memoryTools = MemoryToolFactory.make(store: memory)
let toolRegistry = try AgentToolRegistry(tools: memoryTools.tools + appTools)

let runtime = AgentRuntime(
    providers: ModelProviderRegistry(providers: [provider]),
    tools: toolRegistry,
    approvalHandler: approvalBroker,
    contextProviders: [MemoryContextProvider(store: memory)],
    checkpointStore: checkpointStore,
    auditSink: auditSink
)

let request = AgentRunRequest(
    sessionID: sessionID,
    appID: "com.example.myapp",
    userID: userID,
    agent: AgentDefinition(
        id: "coach",
        providerID: "anthropic",
        model: model,
        instructions: systemPrompt,
        allowedTools: Set(appTools.map { $0.descriptor.name })
    ),
    messages: history + [AgentMessage(role: .user, text: input)]
)

for try await event in runtime.run(request) {
    switch event {
    case .assistantTextDelta(let text):
        render(text)
    case .toolApprovalRequested(let request):
        presentApproval(request)
    case .completed(let result):
        saveConversation(result.messages)
    default:
        break
    }
}
```

## Credential rule

Keychain storage is appropriate for a user's own BYOK credential. A service-owned
credential must not be bundled with a distributed app; resolve it through an
authenticated server proxy instead. Provider request bodies, authorization
headers, secrets, and memory content are excluded from runtime audit records.
On macOS, the system client defaults to the login Keychain; opt into the Data
Protection Keychain only when the app has the required Keychain Sharing entitlement
and provisioning profile. iOS-family platforms use Data Protection by default.

`OpenAIResponsesProvider` defaults to `store: false`, requests encrypted reasoning
continuation state, and only sends explicitly separated `providerMetadata`.
Runtime, context, and tool metadata never becomes provider API metadata implicitly.

## Memory rule

Every record belongs to an exact application, user, workspace, agent, or session
scope and carries provenance, confidence, importance, revision, sensitivity, and
optional expiry. The default policy rejects secrets. Durable health, financial,
application-wide, and instruction memories require explicit approval. HealthKit
or similarly sensitive source data should normally be supplied as ephemeral
context rather than written to long-term memory. Context and system instructions
are composed only for provider requests; they never enter run results or checkpoints.

## Resume and side-effect rule

Provider-signed or encrypted continuation items are stored opaquely on assistant
messages so Gemini, Anthropic, and OpenAI reasoning tool loops can resume exactly.
They are never emitted in UI or audit events and are replayed only by the adapter
whose identifier and format match.

Non-idempotent tools require a durable checkpoint store. The runtime writes a
`started` ledger record before execution and a `completed` record with the tool
result immediately afterward. A crash, timeout, or uncertain native failure leaves
an unresolved or indeterminate record and stops the run for host reconciliation;
it is never silently replayed.

See [Architecture](Documentation/ARCHITECTURE.md) and [Security](SECURITY.md).

## Validation

```sh
swift build
swift build -Xswiftc -warnings-as-errors
swift test
```

Provider, memory, Apple adapter, MCP, core loop, and test-kit suites use mocked
network, Keychain, and temporary-file boundaries. No test requires a live API key.
