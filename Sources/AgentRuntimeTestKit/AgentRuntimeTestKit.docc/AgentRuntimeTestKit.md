# ``AgentRuntimeTestKit``

Test host integrations without network calls or real credentials.

## Overview

Use ``ScriptedModelProvider`` to define deterministic provider event sequences,
``ClosureAgentTool`` to exercise tool policy and state transitions, and
``InMemorySecretStore`` to validate credential resolution. These test doubles are
safe to use from Swift concurrency tests and do not require a live provider.

## Topics

### Test doubles

- ``ScriptedModelProvider``
- ``ClosureAgentTool``
- ``InMemorySecretStore``
- ``FixedToolApprovalHandler``
