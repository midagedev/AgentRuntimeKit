# Changelog

All notable changes to AgentRuntimeKit are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-07-13

### Added

- Added an optional host-computed `resumeContextFingerprint` to run requests and
  checkpoints. Resume now requires exact optional-value equality before any
  provider call, while legacy fingerprint-free checkpoints remain decodable.
- Added bounded `MemoryContextProvider` eligibility filtering over complete
  durable records so hosts can apply provenance and metadata policy before the
  final model-context result limit and character budget.

### Security

- Resume fingerprints are checkpoint-only opaque values: they are not included
  in provider requests or audit detail, and mismatches report only the field
  name rather than either value.
- SQLite candidate overscan now saturates safely for maximum-integer retrieval
  limits instead of overflowing before applying its operational ceiling.

## [0.2.1] - 2026-07-13

### Added

- Added `ICloudDriveFileMemoryAccess.removeFileIfPresent(at:matchingModifiedAt:)`
  for crash-retryable cleanup: a missing file returns `false`, a matching file
  is deleted and returns `true`, and an existing changed file fails closed.
- Added the digest-bound
  `removeFileIfPresent(at:matchingModifiedAt:matchingSHA256:maximumByteCount:)`
  overload for cleanup after a bounded coordinated read. It requires an exact
  64-character lowercase SHA-256 digest and an explicit positive byte limit;
  missing-file retries return `false`, while invalid or oversized requests
  throw the content-free `ICloudDriveDigestRemovalError`.

### Security

- Recheck the coordinated file's descriptor-rooted full snapshot and
  modification date immediately before removal so stale listings and changes
  observed during coordinated validation fail closed. Current-version,
  unresolved-conflict, symbolic-link, and iCloud container-identity fences
  remain enforced.
- Digest-bound removal hashes through descriptor-rooted, `O_NOFOLLOW`, bounded
  access inside `NSFileCoordinator` deletion coordination, with full-snapshot
  checks before and after hashing and immediately before unlinking. Digest,
  date, snapshot, or identity mismatches fail with
  `ICloudDriveFileMemoryError.removePreconditionFailed`, including same-size,
  same-modification-date content replacement. Caller cancellation is forwarded
  to the coordinated worker and rechecked before unlinking; digest syntax is
  rejected through bounded UTF-8 inspection before container lookup.

## [0.2.0] - 2026-07-13

### Added

- Added `AgentRuntimeFileMemory`, a bounded read-only Markdown/text directory
  scanner with deterministic chunk identity, content hashes, and structured
  scan diagnostics.
- Added atomic source snapshot reconciliation with stable record mappings,
  generation compare-and-swap, and archive-or-purge missing-record policies for
  both in-memory and SQLite stores.
- Added an Apple iCloud Drive file-memory adapter with an injectable container
  locator, coordinated reads/writes/removals, current-version download checks,
  explicit mutation preconditions, and no silent local fallback.
- Added public construction surfaces for community-owned `MemoryStore`
  implementations.

### Changed

- Source reconciliation now supports atomic deduplication-key changes, swaps,
  and cycles while preserving stable mapped UUIDs.
- Large source purges now remove mapped records, events, and deduplication state
  in bounded batches instead of repeatedly scanning the full store.
- SQLite privacy-purge cleanup is durably scheduled and skipped for later no-op
  purges after a successful compaction.
- Existing 0.1.x SQLite rows retain exact-byte lookup and erasure compatibility,
  with an explicit inventory-and-purge path for non-canonical persisted scopes.

### Security

- Reject hidden entries, symbolic links, traversal paths, binary content,
  invalid UTF-8, oversized inventories (including non-file entries), and
  secret-sensitivity file indexes.
- Bound chunk count, generated characters, and repeated Markdown heading context,
  and split long paragraphs in linear time.
- Added a dedicated file-memory privacy manifest and descriptor-rooted local
  and iCloud path traversal that does not follow symbolic links.
- Enforced backend-consistent scope/source identity validation and length-aware,
  fail-closed SQLite text serialization.
- Preserved byte-distinct Unicode filesystem path identities across equality,
  hashing, ordering, and inventory deduplication.
- Made validated iCloud configuration immutable and rechecked container identity
  after a metadata query starts so account transitions fail closed.
- Reject lossy NUL and present-empty legacy scope aliases in ordinary APIs while
  keeping strict validation for every new memory and file-source write.

## [0.1.1] - 2026-07-13

### Fixed

- Made the URLSession cancellation contract test wait for the asynchronous
  `URLProtocol.stopLoading()` callback while still requiring exactly one
  underlying-task cancellation.

## [0.1.0] - 2026-07-13

### Added

- Provider-neutral, bounded agent execution with streaming and tool approval.
- Anthropic Messages, OpenAI Responses and Chat Completions, Gemini, and
  OpenAI-compatible provider adapters.
- Provider-owned opaque continuation support for reasoning and tool loops.
- Cancellation-safe, line-incremental URLSession streaming for SSE and NDJSON.
- Scoped memory with SQLite/FTS retrieval, provenance, TTL, policy, and
  privacy-safe hard purge.
- Keychain credentials, protected checkpoints and SQLite files, and redacted
  JSONL audit records for Apple platforms.
- MCP Streamable HTTP discovery and policy-compatible tool adapters.
- Write-ahead protection and explicit reconciliation for non-idempotent tools.
- Public contribution, security, CI, and release policies.
- Opt-in live Anthropic contracts for streaming, continuation, tools,
  cancellation, and sanitized authentication failures.

[Unreleased]: https://github.com/midagedev/AgentRuntimeKit/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/midagedev/AgentRuntimeKit/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/midagedev/AgentRuntimeKit/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/midagedev/AgentRuntimeKit/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/midagedev/AgentRuntimeKit/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/midagedev/AgentRuntimeKit/releases/tag/v0.1.0
