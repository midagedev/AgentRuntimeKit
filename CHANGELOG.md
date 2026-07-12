# Changelog

All notable changes to AgentRuntimeKit are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/midagedev/AgentRuntimeKit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/midagedev/AgentRuntimeKit/releases/tag/v0.1.0
