# Contributing to AgentRuntimeKit

Thank you for helping make native Apple agents safer and easier to reuse.

## Before opening an issue

- Search existing issues and discussions.
- Use a security advisory instead of a public issue for credential exposure,
  privacy boundary failures, or tool-execution vulnerabilities.
- Reduce bug reports to a deterministic provider, tool, memory, or checkpoint
  contract whenever possible.

## Development setup

Requirements are Swift 6 and Xcode 16 or later.

```sh
git clone https://github.com/midagedev/AgentRuntimeKit.git
cd AgentRuntimeKit
swift build -Xswiftc -warnings-as-errors
swift test
```

Before submitting a pull request, also build the Apple adapter for every
platform touched by the change.

```sh
xcodebuild -scheme AgentRuntimeApple \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
```

## Design invariants

Changes must preserve these rules:

- Core remains headless and independent of SwiftUI, Security, SQLite, and any
  concrete provider.
- Provider continuation data is opaque, adapter-bound, and never shown in UI or
  audit output.
- Unsupported tool schemas fail closed.
- Non-idempotent work is never replayed without explicit reconciliation.
- Session approval is bound to the exact tool descriptor that was approved.
- Memory reads and deletion never widen app, user, agent, workspace, or session
  scope.
- Provider credentials, request bodies, memory content, and raw provider errors
  do not enter logs or audit records.
- Public API changes include compatibility analysis and migration notes.

## Pull requests

Keep changes focused and include:

- the problem and security or compatibility impact;
- tests for the success, cancellation, timeout, and failure paths;
- documentation for new public API;
- `swift test` and warnings-as-errors evidence;
- API-breaking-change output when public symbols change.

By contributing, you agree that your contribution is licensed under the MIT
License and follows the project Code of Conduct.
