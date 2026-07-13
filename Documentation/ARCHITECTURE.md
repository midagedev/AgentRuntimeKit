# AgentRuntimeKit Architecture

AgentRuntimeKit is a headless agent runtime for Apple applications. It owns the
provider-neutral execution contract and leaves product behavior in the host app.

## Dependency direction

```text
Host application domain tools and context sources
                         │
       AgentRuntimeApple │ AgentRuntimeMCP
                         │ AgentRuntimeFileMemory
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
   are recomposed for each request and never enter the durable transcript. A host
   can persist an opaque `resumeContextFingerprint` so an identity, consent,
   privacy projection, or tool-policy change invalidates recovery before any
   provider call without persisting those raw inputs.
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
- scoped memory storage, retrieval, expiry, provenance, and privacy purge;
- atomic source reconciliation and a read-only file-to-memory indexing layer;
- Keychain and protected-file adapters;
- optional remote MCP discovery and calls.

The host app owns:

- prompts and persona;
- domain tools and their side effects;
- consent for sensitive context;
- UI, voice, avatar, notifications, and background behavior;
- whether credentials are user-provided or resolved by a server proxy.

## File-memory boundary

File memory uses canonical user-owned Markdown or text files and a rebuildable
`MemorySourceReconciliationStore` index. A scan is a complete source snapshot:
stable source record IDs preserve memory UUIDs across edits, while a generation
compare-and-swap prevents stale scans from replacing a newer inventory. Missing
records are archived by default. A purge policy is available only for products
whose deletion and backup semantics make physical removal appropriate.

The scanner is read-only and bounded. It rejects symbolic links, traversal,
hidden and non-regular entries, binary or invalid UTF-8 data, files that mutate
during a scan, and inventories beyond configured depth, count, or byte limits.
Filesystem notifications are hints to start another full scan, never a mutation
log. iCloud Drive is an Apple adapter at the same file-access seam; selecting it
never introduces an implicit local fallback.

## Memory deletion boundary

Normal memory deletion changes a record's status and retains content-free mutation
evidence. Privacy purge is a separate, idempotent operation. Record purge requires
both UUID and exact scope; multi-scope purge validates every complete scope before
starting one transaction. Owner purge is deliberately narrower than a scope-prefix
query: it matches one exact app ID and non-empty user ID across user, agent,
workspace, and historical session scopes, while excluding application-wide and
user-unbound records.

The SQLite implementation removes record, event, deduplication, and FTS state in
one write transaction. Append-only event guards are transactionally relaxed only
inside that purge, then restored before commit. Secure-delete overwrites released
ordinary cells, FTS is rebuilt from remaining eligible records, the database is
vacuumed to remove obsolete FTS shadow pages, and the WAL is truncated. If a busy
reader blocks either post-commit step, `MemoryPurgeCleanupError` carries the
already-committed counts and the caller can safely retry the same purge. This
boundary covers the live store artifacts, not platform backups or filesystem
snapshots controlled outside the process.

Databases created by 0.1.x may contain scope identifiers that 0.2 no longer
accepts for new writes. SQLite ordinary reads and erasures retain exact-byte
compatibility for safely preserved legacy identifiers, but never reproduce the
old NUL-terminated binding or treat a present-empty optional as `nil`. Hosts can
inspect non-canonical persisted namespaces with `legacyScopeInventory()` and
purge an exact returned namespace with `purgeLegacyPersistedScope(_:)`. This
administrative path is intentionally separate from ordinary scope selection.

## Compatibility

The baseline is Swift 6, iOS 17, macOS 14, watchOS 10, and tvOS 17. Products
that use unavailable platform services should depend only on the modules they
need. Foundation Models can be added as an optional provider without raising the
core deployment target.
