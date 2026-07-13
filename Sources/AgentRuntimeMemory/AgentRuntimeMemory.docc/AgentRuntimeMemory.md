# ``AgentRuntimeMemory``

Store and retrieve explicitly scoped agent memory with policy and provenance.

## Overview

Memory records are isolated by complete application, user, workspace, agent, or
session scopes. ``SQLiteMemoryStore`` provides durable lexical and full-text
retrieval, while ``InMemoryMemoryStore`` is useful for previews and tests.

Secret proposals fail closed. Sensitive durable memory should pass through a host
approval flow, and privacy erasure should use hard-purge APIs rather than the
recoverable deleted status.

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
