# ``AgentRuntimeCore``

Build bounded, provider-neutral agent loops with explicit tool policy, approval,
checkpoint, context, and audit boundaries.

## Overview

Create an ``AgentRuntime`` from registries of model providers and native tools,
then consume the events from ``AgentRuntime/run(_:)``. The core module has no UI,
network adapter, database, or Apple Security dependency, so hosts retain control
of product behavior and platform integration.

Treat provider continuation as opaque, require durable checkpoints before
non-idempotent work, and persist the host transcript before removing a completed
checkpoint. See the repository's production integration checklist for the full
host contract.

## Topics

### Running an agent

- ``AgentRuntime``
- ``AgentRunRequest``
- ``AgentDefinition``
- ``AgentEvent``
- ``AgentRunResult``
- ``AgentRunLimits``

### Providers and messages

- ``ModelProvider``
- ``ModelProviderRegistry``
- ``ModelRequest``
- ``ModelStreamEvent``
- ``AgentMessage``
- ``ProviderContinuation``

### Tools and approval

- ``AgentTool``
- ``AgentToolRegistry``
- ``AgentToolDescriptor``
- ``AgentToolPolicy``
- ``AgentToolApprovalHandler``
- ``AgentToolApprovalBroker``

### Durable recovery

- ``AgentCheckpointStore``
- ``AgentRunCheckpoint``
- ``AgentToolExecutionReconciliation``
- ``AgentUnresolvedToolExecution``
