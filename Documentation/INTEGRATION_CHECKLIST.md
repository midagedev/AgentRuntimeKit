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
- [ ] Checkpoint recovery uses a canonical, opaque `resumeContextFingerprint`
      whenever identity, consent, memory projection, or tool policy can change.
- [ ] Fingerprints contain no raw private values, and legacy fingerprint-free
      checkpoints are accepted only under an intentional legacy policy.
- [ ] Local fallback logic cannot repeat a completed tool side effect.

## Persistence and privacy

- [ ] The host transcript is durable before a completed checkpoint is removed.
- [ ] Memory scope and owner isolation have adversarial tests.
- [ ] Durable memory eligibility is applied before the final model-context limit
      and character budget; candidate overscan remains explicitly bounded.
- [ ] File-memory roots are explicit, bounded, and never widened by a local or
      cloud fallback.
- [ ] A source discovery/read failure preserves the prior index instead of
      reconciling an empty snapshot.
- [ ] File events trigger a complete generation-checked rescan; they are not
      treated as an authoritative mutation log.
- [ ] iCloud storage consent is separate from provider data-sharing consent,
      and real-device account/download/conflict behavior has been verified.
- [ ] The product exposes exact-record and owner-bound privacy purge.
- [ ] Backup and filesystem snapshot retention is documented separately.
- [ ] Logs and audit records contain no credentials, memory bodies, health data,
      provider continuation, or raw provider errors.
