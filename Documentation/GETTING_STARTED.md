# Getting Started

AgentRuntimeKit is split into small products so applications import only the
capabilities they need.

## Add the package

In Xcode, add:

```text
https://github.com/midagedev/AgentRuntimeKit.git
```

Use a semantic version requirement starting at `0.1.0`. Select
`AgentRuntimeCore` and the provider, memory, Apple, or MCP products required by
your app.

## Build the host boundary

1. Resolve a user-owned credential from Keychain or a service-owned credential
   from an authenticated proxy.
2. Register only explicitly allowed providers and tools.
3. Choose a stable app, user, agent, and session identity.
4. Use a durable checkpoint store before enabling non-idempotent tools.
   A custom store must implement complete unresolved-execution enumeration and
   atomic reconciliation; inherited defaults intentionally fail closed.
5. Present every approval request with the exact descriptor and permitted
   arguments.
6. Treat context as untrusted reference data and apply a sensitivity ceiling.
7. Persist the completed host transcript before acknowledging or removing its
   checkpoint.
8. Provide user-facing reconciliation and privacy-purge controls.

See [Architecture](ARCHITECTURE.md) and the repository [Security Model](../SECURITY.md)
before shipping a tool that writes data or calls an external system.
