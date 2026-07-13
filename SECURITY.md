# Security Policy and Model

## Supported versions

Security fixes are provided for the latest minor release. Before 1.0, a fix may
include a narrowly scoped source-compatible hardening change in a patch release.

| Version | Supported |
| --- | --- |
| 0.2.x | Yes |
| 0.1.x | No |
| Earlier/unreleased snapshots | No |

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/midagedev/AgentRuntimeKit/security/advisories/new).
Do not open a public issue for a credential leak, privacy-scope violation,
approval bypass, unsafe tool replay, checkpoint corruption, or remote transport
vulnerability.

Include the affected version, platform, smallest sanitized reproduction, impact,
and whether exploitation requires a malicious provider, tool, MCP endpoint, or
host integration. Do not include real API keys, provider request bodies, memory
content, health data, or private tool arguments.

The maintainers will acknowledge a complete report within seven days, coordinate
a fix and disclosure window, and credit reporters who request attribution.

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
- File-memory scans accept only validated root-relative paths and bounded UTF-8
  Markdown/text inputs. Hidden entries, symbolic links, traversal, non-regular
  files, binary data, and files that mutate during a scan are rejected rather
  than partially reconciled.
- Chunk count, generated characters, and bounded Markdown heading context limit
  output amplification independently of source byte limits.
- Source snapshots commit records, mappings, missing-record handling, and the
  next generation atomically. An unavailable local or iCloud source must not be
  represented as an empty snapshot, because that would incorrectly archive or
  purge the prior index.
- Scope, source, and source-record identities reject controls, ambiguous empty
  optionals, surrounding whitespace, and non-NFC Unicode so in-memory and SQLite
  backends preserve the same exact isolation boundary.
- SQLite keeps exact-byte read, update, and erasure compatibility for 0.1.x
  scopes containing whitespace, non-NFC text, or non-NUL controls, while all new
  writes remain strict. Standard APIs reject NUL and present-empty aliases.
  Irrecoverably truncated or empty legacy storage keys are available only through
  `legacyScopeInventory()` and the explicit `purgeLegacyPersistedScope(_:)`
  administrative erasure path; that path never reinterprets a discarded suffix.
- The iCloud Drive adapter requires one explicit entitled container, coordinates
  file access, waits for requested downloads, and fails on unresolved versions.
  It never falls back to a local directory. Hosts remain responsible for storage
  consent, conflict UI, iCloud retention, and account-change handling.
- Apple hosts handling sensitive data should use `ProtectedSQLiteMemoryStore`,
  which reapplies permissions and Data Protection attributes to the database,
  WAL, and SHM files. iOS-family platforms apply the selected Data Protection
  class; macOS enforces owner-only POSIX modes because ordinary macOS paths do
  not support `NSFileProtection` attributes.
- Privacy erasure uses hard-purge APIs, not the recoverable deleted status. Exact
  purge never widens a namespace. Owner purge requires an exact app/user pair and
  excludes application-wide and user-unbound records while covering that user's
  historical session scopes.
- SQLite hard purge removes related events and FTS entries transactionally, enables
  secure deletion, rebuilds FTS, vacuums obsolete FTS shadow pages, and truncates
  the WAL. `MemoryPurgeCleanupError` explicitly distinguishes a committed logical
  purge from an incomplete post-commit cleanup. Hosts remain responsible for
  retention and erasure policies of backups or filesystem snapshots.
- `AgentRuntimeApple` declares file-metadata reason C617.1. Protected store and
  explicit iCloud-container URLs used in distributed apps must remain inside a
  container covered by that reason.
- `AgentRuntimeFileMemory` ships its own privacy manifest and declares C617.1
  for app/container roots plus 3B52.1 for roots the person explicitly grants to
  the host. Products must not pass arbitrary ungranted filesystem locations.

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
