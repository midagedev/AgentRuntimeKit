# Production Integration Checklist

## Identity and credentials

- [ ] App, user, agent, workspace, and session identifiers are stable and
      non-PII where audit records use them.
- [ ] User-owned keys are stored in Keychain with an appropriate accessibility
      class.
- [ ] Service-owned keys remain behind an authenticated server proxy.
- [ ] Account changes replace or clear account-scoped transcripts and context.

## Providers and context

- [ ] Every provider capability used by the request is preflighted.
- [ ] Opaque continuation is replayed only through its originating adapter.
- [ ] Sensitive context has separate user consent from OS data access.
- [ ] Provider errors are normalized before display or logging.

## Tools and recovery

- [ ] Tool names, schemas, risk, and side effects are versioned as one
      descriptor identity.
- [ ] Restricted and sensitive tools have a reviewed approval experience.
- [ ] Non-idempotent tools use a durable write-ahead checkpoint store.
- [ ] Unresolved work blocks new execution until explicit reconciliation.
- [ ] A custom checkpoint store completely enumerates older unresolved work and
      atomically persists reconciliation with the matching tool result.
- [ ] Local fallback logic cannot repeat a completed tool side effect.

## Persistence and privacy

- [ ] The host transcript is durable before a completed checkpoint is removed.
- [ ] Memory scope and owner isolation have adversarial tests.
- [ ] The product exposes exact-record and owner-bound privacy purge.
- [ ] Backup and filesystem snapshot retention is documented separately.
- [ ] Logs and audit records contain no credentials, memory bodies, health data,
      provider continuation, or raw provider errors.
