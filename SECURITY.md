# Security Model

## Credentials

- A user-provided provider key may be stored through `AgentRuntimeApple` in the
  Keychain with a host-selected service, account, access group, and accessibility
  class.
- A developer or service-owned key must never ship in an application bundle.
  Public applications should resolve it through an authenticated server proxy.
- Secrets are fetched only when a provider builds a request. They are not part
  of messages, run checkpoints, memory records, errors, or audit payloads.
- Provider errors must not include request bodies, authorization headers, or raw
  response data that may echo credentials.
- OpenAI Responses requests default to `store: false` and request encrypted
  reasoning items for stateless continuation. Provider-visible metadata is a
  separate opt-in field from local runtime metadata.
- On macOS, Data Protection Keychain access requires the appropriate Keychain
  Sharing entitlement and provisioning. The default client uses the login Keychain;
  iOS-family platforms use Data Protection by default.

## Tools

- Only host-registered native tools or explicitly configured remote MCP tools
  can execute. The package does not download or execute code.
- Tool schemas are validated fail-closed at every registration boundary and again
  before execution. Unsupported validation keywords cannot be silently ignored.
- `safe`, `sensitive`, and `restricted` risk levels are policy inputs, not UI
  decoration. Sensitive tools require approval by default; restricted tools are
  denied unless the host allowlists them and the user approves.
- Non-idempotent tools require durable write-ahead checkpoints and are never
  retried by the core runtime. Started or indeterminate executions require host
  reconciliation before resume.
- A tool receives a scoped execution context but never provider credentials.
- Unknown native errors are generalized before they are returned to a model. Only
  errors explicitly conforming to `AgentModelSafeError` may expose a chosen message.

## Context and memory

- Context providers label every block with sensitivity. Blocks above the agent's
  configured ceiling are excluded; `secret` blocks are always excluded.
- Context is explicitly marked as reference data rather than instructions to
  reduce indirect prompt-injection risk.
- Context and system instructions exist only in provider requests. Neither ephemeral
  nor durable context blocks are copied into run results or checkpoints.
- Memory records are isolated by application, user, workspace, agent, and
  session scope. Reads must provide the same namespace.
- Secret memory proposals are rejected. Health and financial memory requires
  explicit policy approval unless it is short-lived session data.
- Records carry provenance, revision, confidence, importance, and optional TTL.
  Expired records are not returned as active context.
- Apple hosts handling sensitive data should use `ProtectedSQLiteMemoryStore`,
  which reapplies permissions and Data Protection attributes to the database,
  WAL, and SHM files.
- Privacy erasure uses hard-purge APIs, not the recoverable deleted status. Exact
  purge never widens a namespace. Owner purge requires an exact app/user pair and
  excludes application-wide and user-unbound records while covering that user's
  historical session scopes.
- SQLite hard purge removes related events and FTS entries transactionally, enables
  secure deletion, rebuilds FTS, vacuums obsolete FTS shadow pages, and truncates
  the WAL. `MemoryPurgeCleanupError` explicitly distinguishes a committed logical
  purge from an incomplete post-commit cleanup. Hosts remain responsible for
  retention and erasure policies of backups or filesystem snapshots.
- `AgentRuntimeApple` declares file-metadata reason C617.1. Protected store URLs
  used in distributed apps must remain inside the app, app-group, or CloudKit
  container covered by that reason.

## Checkpoints and audit

- Checkpoints are isolated by application, optional user, session, agent, provider,
  and model identity before resume. Provider continuations are opaque and replayed
  only to their originating adapter.
- Audit failures store normalized codes and categories, never free-form error text.
  Hosts must use opaque non-PII session and agent identifiers because those fields
  are structural audit fields rather than redacted detail values.
- JSON numbers larger than IEEE-754's exact integer range and high-precision decimal
  values use exact representations instead of being coerced through `Double`.

## MCP

- Mobile clients use Streamable HTTP. Local process spawning and stdio servers
  are outside the package's iOS security model.
- Hosts must use TLS (except explicitly trusted loopback development endpoints),
  authenticate the endpoint, constrain allowed tool names,
  and still pass discovered tools through the normal local policy and approval
  pipeline.

## Reporting

Do not open a public issue containing API keys, health data, provider request
bodies, or tool arguments. Rotate an exposed provider key before reporting the
incident.
