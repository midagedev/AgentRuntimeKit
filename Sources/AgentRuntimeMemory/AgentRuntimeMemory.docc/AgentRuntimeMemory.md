# ``AgentRuntimeMemory``

Store and retrieve explicitly scoped agent memory with policy and provenance.

## Overview

Memory records are isolated by complete application, user, workspace, agent, or
session scopes. ``SQLiteMemoryStore`` provides durable lexical and full-text
retrieval, while ``InMemoryMemoryStore`` is useful for previews and tests.

Secret proposals fail closed. Sensitive durable memory should pass through a host
approval flow, and privacy erasure should use hard-purge APIs rather than the
recoverable deleted status.

Use ``MemoryContextProvider/init(identifier:store:maximumSensitivity:minimumConfidence:minimumImportance:limit:workspaceMetadataKey:recordEligibility:eligibilityCandidateLimit:)``
to apply a host `@Sendable` eligibility policy over durable record provenance and
metadata. Candidate overscan is bounded, while policy exclusions occur before the
final model-context result limit and character budget.

## Topics

### Stores and retrieval

- ``MemoryStore``
- ``SQLiteMemoryStore``
- ``SQLiteLegacyScopeSummary``
- ``InMemoryMemoryStore``
- ``MemoryContextProvider``

### Policy and tools

- ``MemoryPolicy``
- ``DefaultMemoryPolicy``
- ``MemoryToolFactory``
