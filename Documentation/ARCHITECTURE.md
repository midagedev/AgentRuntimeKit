# AgentRuntimeKit Architecture

AgentRuntimeKit is a headless agent runtime for Apple applications. It owns the
provider-neutral execution contract and leaves product behavior in the host app.

## Dependency direction

```text
Host application domain tools and context sources
                         │
       AgentRuntimeApple │ AgentRuntimeMCP
                    └────┼────┘
                         ▼
 AgentRuntimeProviders  AgentRuntimeMemory
                    └────┼────┘
                         ▼
                  AgentRuntimeCore
```

`AgentRuntimeCore` has no SwiftUI, Observation, Security, SQLite, or provider
dependency. UI code consumes `AgentEvent` on its own actor, normally the main
actor. Network, database, and native tool work remain off the main actor.

## Run lifecycle

1. Resolve the requested provider and its declared capabilities.
2. Load context blocks and reject blocks above the agent's sensitivity ceiling.
3. Delimit context as untrusted reference data before provider submission.
4. Stream a model step into normalized text, reasoning, tool calls, usage, and
   finish events while retaining provider-owned signed or encrypted continuation
   state as an opaque assistant-message field.
5. Validate the complete tool batch and every argument against a fail-closed schema.
6. Apply host allowlists, risk policy, and optional user approval.
7. For non-idempotent tools, persist a write-ahead `started` ledger entry.
8. Execute the native tool with cancellation and a deadline, then return only a
   model-safe result. Persist non-idempotent completion immediately.
9. Save a resumable checkpoint after each step. Instructions and retrieved context
   are recomposed for each request and never enter the durable transcript.
10. Stop on a final assistant message or a configured step, tool, token, or time
   budget.

Safe or idempotent tool failures are returned as generalized structured results so
the model may recover. Non-idempotent uncertain failures, runtime, provider, and
budget failures terminate the run.

## Host boundaries

The package owns:

- provider request and streaming normalization;
- the bounded tool-call loop;
- schema validation, permission decisions, approvals, and audit events;
- scoped memory storage, retrieval, expiry, and provenance;
- Keychain and protected-file adapters;
- optional remote MCP discovery and calls.

The host app owns:

- prompts and persona;
- domain tools and their side effects;
- consent for sensitive context;
- UI, voice, avatar, notifications, and background behavior;
- whether credentials are user-provided or resolved by a server proxy.

## Compatibility

The baseline is Swift 6, iOS 17, macOS 14, watchOS 10, and tvOS 17. Products
that use unavailable platform services should depend only on the modules they
need. Foundation Models can be added as an optional provider without raising the
core deployment target.
