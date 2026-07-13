# File-based Memory

`AgentRuntimeFileMemory` indexes user-owned Markdown and plain-text files into
an `AgentRuntimeMemory` store. Files remain canonical; the memory store is a
derived search index that can be deleted and rebuilt.

This boundary is intentionally one-way. The scanner never rewrites a source
file, resolves an edit conflict, or turns model output into a file implicitly.
A host that offers file editing must own its save UI, authorization, version
history, and conflict presentation.

## Storage model

- One source identifier and one exact `MemoryScope` define an isolated source.
- A full scan produces deterministic chunks with stable source record IDs and
  content hashes.
- The store commits creates, updates, missing-record handling, and a new source
  generation in one transaction.
- Concurrent scanners use generation compare-and-swap. A stale scanner retries
  from the new state instead of overwriting it.
- Missing chunks are archived by default. Physical purge is an explicit option
  for hosts whose retention and backup policy permits it.
- Directory notifications and iCloud metadata updates are rescan hints only. A
  complete bounded scan remains authoritative.

## Safety limits

The default configuration accepts `.md`, `.markdown`, `.txt`, and `.text` files
and applies limits for traversal depth, total directory entries, directory and
file counts, bytes per file, total bytes, and chunk size. Hidden entries,
symbolic links, non-regular files, binary data,
invalid UTF-8, traversal paths, and files that change while being read are not
indexed. Secret sensitivity is rejected; secrets belong in Keychain or another
purpose-built secret store.

Root-relative paths retain their supplied UTF-8 byte identity. Canonically
equivalent but byte-distinct names remain separate inventory entries on filesystems
that permit both; path equality, hashing, and ordering use the same bytewise rule.

Chunking separately bounds total chunk count and generated characters before a
snapshot can reach the store. Markdown heading context is depth-limited by the
format and each visible heading component is capped, preventing a long heading
from being copied without bound into every chunk. Long paragraphs are split by
a forward-only linear scan.

Choose lower limits for background or extension processes. Treat skipped and
rejected entries in `FileMemorySyncReport` as user-visible diagnostics rather
than copying file bodies into logs.

## Local directory

Create the application-owned directory before constructing
`LocalDirectoryFileMemoryAccess`. The provider roots every operation at a pinned
directory descriptor, opens each component without following symbolic links,
and bounds enumeration before materializing a directory listing. Construct a
`FileMemorySynchronizer` with a `MemorySourceReconciliationStore`, then call
`synchronize()` at launch, when the scene becomes active, and immediately before
a model run that requires fresh file context.

```swift
import AgentRuntimeFileMemory
import AgentRuntimeMemory

let access = try LocalDirectoryFileMemoryAccess(rootURL: memoryDirectory)
let configuration = try FileMemoryConfiguration(
    sourceID: "user-notes-v1",
    scope: .user(appID: "com.example.myapp", userID: userID)
)
let synchronizer = FileMemorySynchronizer(
    configuration: configuration,
    fileAccess: access,
    store: memoryStore
)
let report = try await synchronizer.synchronize()
```

The exact scope used by the file source must also be among the scopes retrieved
for the model request. Do not use a broad application scope for files that belong
to one signed-in user.

## iCloud Drive

`AgentRuntimeApple` provides an iCloud Drive file-access adapter for iOS and
macOS. Configure one explicit ubiquity-container identifier and a validated
directory below its `Documents` directory. The host target must enable iCloud
Documents and declare the same container in its entitlements and
`NSUbiquitousContainers` metadata.

```swift
import AgentRuntimeApple
import AgentRuntimeFileMemory

let cloud = ICloudDriveFileMemoryAccess(
    configuration: try .init(
        containerIdentifier: "iCloud.com.example.myapp",
        documentsSubdirectory: try FileMemoryPath("AgentMemory")
    )
)
let synchronizer = FileMemorySynchronizer(
    configuration: fileMemoryConfiguration,
    fileAccess: cloud,
    store: memoryStore
)
let report = try await synchronizer.synchronize()
```

The scanner sees the adapter through its read-only protocol. A host that owns a
generated document can retain the concrete actor and use `writeUTF8`,
`writeFile`, or `removeFile`; every write must explicitly choose create-only,
replace-existing, compare-and-swap by modification date, or create-or-replace
semantics. Removal is limited to a regular root-relative file and supports
idempotent or modification-date-preconditioned cleanup. Existing ubiquitous
items must be current and conflict-free before a write or removal proceeds.

AgentRuntimeKit 0.2.1 adds a retry-safe conditional removal for cleanup journals:

```swift
let removed = try await cloud.removeFileIfPresent(
    at: generatedDocumentPath,
    matchingModifiedAt: lastPublishedModificationDate
)
```

The result is `true` only when that matching file was deleted. It is `false` if
the file is already absent, including a retry after deletion succeeded but the
host crashed before committing its journal. An existing file with a different
modification date, or a snapshot/identity change observed during coordinated
removal, fails with
`ICloudDriveFileMemoryError.removePreconditionFailed`; symbolic links,
non-current items, unresolved versions, and container identity changes keep
their typed fail-closed errors. Do not replace this API with `ifExists` for
user-editable or cross-device files: `ICloudDriveRemoveMode.ifExists`
intentionally has no modification-date precondition. The observed `Date` is not
an account-bound `NSFileVersion` token. After an iCloud identity or
container-change error, throw it away and obtain a new value from a fresh
coordinated read or listing rather than replaying it against a different
account.

iCloud selection should be explicit and reversible in the host UI. If the user
is signed out, the entitlement is missing, or the container cannot be resolved,
the adapter returns an error and does not use a local fallback. This avoids two
independent canonical directories. Existing indexed records remain unchanged
until a valid source can be scanned; an unavailable source must never be treated
as an empty snapshot. A host that changes storage locations must also omit the
previous location's index from model retrieval until the newly selected source
completes a successful scan; preserving an old generation is not permission to
use it as a silent fallback.

Tests should inject a fake container locator and a temporary directory. A
simulator build verifies API and entitlement wiring, but a signed physical-device
test is still required to verify account availability, upload/download behavior,
and conflict UI with the product's real container.

## Product checklist

- Keep file storage consent separate from model-provider data-sharing consent.
- Display the selected storage location and the last successful generation.
- Show unavailable, partial-download, skipped-file, and limit errors without
  exposing file content in telemetry.
- Rescan after foreground activation, explicit refresh, relevant file events,
  and before a run that must observe current files.
- Never reconcile an empty snapshot when source discovery failed.
- Gate model retrieval on a successful scan of the currently selected source.
- Document whether deleting an index, deleting a source file, and deleting an
  iCloud backup are separate actions.
