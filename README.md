# AgentRuntimeKit

[![CI](https://github.com/midagedev/AgentRuntimeKit/actions/workflows/ci.yml/badge.svg)](https://github.com/midagedev/AgentRuntimeKit/actions/workflows/ci.yml)
[![CodeQL](https://github.com/midagedev/AgentRuntimeKit/actions/workflows/codeql.yml/badge.svg)](https://github.com/midagedev/AgentRuntimeKit/actions/workflows/codeql.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138.svg?logo=swift)](https://www.swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2017%2B%20%7C%20macOS%2014%2B%20%7C%20watchOS%2010%2B%20%7C%20tvOS%2017%2B-lightgrey.svg)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A headless, provider-neutral agent runtime for Swift applications. It gives an
Apple app one bounded execution model for streaming LLMs, native tools, user
approval, scoped memory, Keychain credentials, checkpoints, audit records, and
optional remote MCP tools.

AgentRuntimeKit intentionally contains no SwiftUI or product-specific domain
model. Host applications keep ownership of their interfaces, business rules,
consent flows, and side effects.

The package is designed for apps that need more than a chat completion wrapper:
provider-owned reasoning continuation, bounded native tool execution, explicit
approval, crash-safe side-effect recovery, scoped local memory, and Apple-native
credential and file protection.

## Installation

Add the package URL in Xcode:

```text
https://github.com/midagedev/AgentRuntimeKit.git
```

Choose a version requirement starting at `0.2.0`, then add only the products
your target needs. SwiftPM consumers can declare:

```swift
.package(
    url: "https://github.com/midagedev/AgentRuntimeKit.git",
    from: "0.2.0"
)
```

See [Getting Started](Documentation/GETTING_STARTED.md) and the
[Production Integration Checklist](Documentation/INTEGRATION_CHECKLIST.md).

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
| `AgentRuntimeFileMemory` | Read-only Markdown/text directory scanning, deterministic chunking, and atomic source reconciliation into a derived memory index |
| `AgentRuntimeApple` | Keychain secrets, protected checkpoints/SQLite, redacted JSONL audit, and explicit iCloud Drive file-memory access |
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
        id: "assistant",
        providerID: "anthropic",
        model: model,
        instructions: systemPrompt,
        allowedTools: Set((memoryTools.tools + appTools).map { $0.descriptor.name })
    ),
    messages: history + [AgentMessage(role: .user, text: input)],
    // Hash a canonical host representation; never persist raw identity or
    // consent values as the fingerprint itself.
    resumeContextFingerprint: privacyProjectionDigest
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

The built-in persistent memory backend is SQLite. `AgentRuntimeFileMemory` can
treat a Markdown/text directory as canonical user-owned data and SQLite as a
rebuildable search index. Scans are deterministic and bounded, symbolic links
and unsafe paths are rejected, and each complete snapshot is reconciled in one
generation-checked transaction. Missing source chunks are archived by default.
The scanner is deliberately read-only: host applications remain responsible for
editing, conflict presentation, backup retention, and user-visible storage
controls. Apple hosts can opt into an explicit iCloud Drive container through
`AgentRuntimeApple`; unavailable iCloud never silently falls back to a second
local directory.

See [File-based Memory](Documentation/FILE_MEMORY.md) for local and iCloud Drive
integration, limits, rescan triggers, and conflict boundaries.

`delete` is a recoverable status transition. User-facing privacy deletion uses
the separate idempotent `purge(id:scope:)` or `purge(scopes:)` APIs, which remove
the record, deduplication identity, mutation events, and full-text artifacts only
from the exact requested namespace. A memory-management screen that must include
past sessions can call `recordsOwned(appID:userID:)` and `purgeOwned(appID:userID:)`.
Those owner-bound APIs include user, agent, workspace, and session records carrying
that exact app/user pair, while excluding application-wide and user-unbound data.
SQLite purge runs transactionally with secure deletion, rebuilds FTS, vacuums old
FTS shadow pages, and truncates the WAL; Apple hosts retain the protected
database/WAL/SHM boundary. A `MemoryPurgeCleanupError` means the logical delete
committed but a physical post-commit step must be retried. Existing custom
`MemoryStore` conformers remain source-compatible and fail closed until they
implement the purge requirements. Filesystem snapshots and backups remain the
host platform's retention responsibility.

When opening a 0.1.x SQLite database, new writes still require canonical scope
identities. Exact legacy scopes remain readable and erasable; hosts can use
`legacyScopeInventory()` plus `purgeLegacyPersistedScope(_:)` for an explicit
administrative cleanup of non-canonical persisted namespaces.

## Resume and side-effect rule

Provider-signed or encrypted continuation items are stored opaquely on assistant
messages so Gemini, Anthropic, and OpenAI reasoning tool loops can resume exactly.
They are never emitted in UI or audit events and are replayed only by the adapter
whose identifier and format match.

`resumeContextFingerprint` lets a host bind recovery to the identity, consent,
memory projection, and tool-policy inputs that were valid when a checkpoint was
written. The runtime persists only this host-computed opaque digest and requires
exact equality before any provider call. A legacy checkpoint without a fingerprint
can resume only when the new request also omits one.

`MemoryContextProvider` can also accept a `@Sendable` `recordEligibility` policy
over the full durable `MemoryRecord`. The provider performs bounded candidate
overscan, applies that policy before the final result limit and character budget,
and exposes neither provenance nor policy-only metadata to the model by default.

Non-idempotent tools require a durable checkpoint store. The runtime writes a
`started` ledger record before execution and a `completed` record with the tool
result immediately afterward. A crash, timeout, or uncertain native failure leaves
an unresolved or indeterminate record and stops the run for host reconciliation;
it is never silently replayed.

Custom `AgentCheckpointStore` conformers remain source-compatible, but the default
`unresolved` and `reconcile` implementations deliberately fail closed. A production
store must enumerate every unresolved execution for the complete identity, including
older checkpoints hidden by a newer save, and atomically append the matching tool
result when reconciliation succeeds.

See [Architecture](Documentation/ARCHITECTURE.md) and [Security](SECURITY.md).

## Validation

```sh
swift build
swift build -Xswiftc -warnings-as-errors
swift test
```

Provider, memory, Apple adapter, MCP, core loop, and test-kit suites use mocked
network, Keychain, and temporary-file boundaries. No test requires a live API key.
An opt-in Anthropic contract suite covers real streaming, usage, multi-turn opaque
continuation, a tool round trip, cancellation, and sanitized authentication errors:

```sh
AGENT_RUNTIME_LIVE_ANTHROPIC=1 \
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
swift test --filter AnthropicLiveTests
```

The live suite is skipped by default and CI never receives a provider credential.

## Community

- Read [Contributing](CONTRIBUTING.md) before proposing public API or safety
  changes.
- Use [GitHub Discussions](https://github.com/midagedev/AgentRuntimeKit/discussions)
  for integration questions.
- Report vulnerabilities through [private vulnerability reporting](SECURITY.md),
  never a public issue.
- Releases and migration notes are tracked in [CHANGELOG.md](CHANGELOG.md).

AgentRuntimeKit is available under the [MIT License](LICENSE).
