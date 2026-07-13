# ``AgentRuntimeFileMemory``

Index canonical Markdown and plain-text directories into a rebuildable,
generation-checked AgentRuntimeKit memory store.

## Overview

Create a ``FileMemoryConfiguration`` for one stable source identifier and one
exact memory scope. Supply a ``FileMemoryFileAccess`` implementation and a
`MemorySourceReconciliationStore` to ``FileMemorySynchronizer``. Each call to
``FileMemorySynchronizer/synchronize(at:)`` performs a complete bounded scan
before atomically replacing that source generation.

``LocalDirectoryFileMemoryAccess`` is the hardened local adapter. It pins the
selected root and rejects symbolic-link traversal and files that change while
being read. Apple applications can import `AgentRuntimeApple` and substitute
`ICloudDriveFileMemoryAccess` at the same read-only seam.

Use ``FileMemoryRescanController`` to debounce filesystem or cloud-change hints.
Hints never become an edit log; every scheduled refresh remains a complete scan.

## Topics

### Configure and synchronize

- ``FileMemoryConfiguration``
- ``FileMemorySynchronizer``
- ``FileMemorySyncReport``
- ``FileMemoryRescanController``

### File access

- ``FileMemoryFileAccess``
- ``LocalDirectoryFileMemoryAccess``
- ``FileMemoryPath``
- ``FileMemoryDirectoryEntry``
- ``FileMemoryReadResult``

### Chunking and diagnostics

- ``FileMemoryChunker``
- ``FileMemoryChunk``
- ``FileMemoryIssue``
- ``FileMemoryIssueReason``
- ``FileMemoryLimit``
- ``FileMemoryError``
