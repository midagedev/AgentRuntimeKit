# ``AgentRuntimeApple``

Use Keychain credentials and protected durable stores in Apple applications.

## Overview

``KeychainAgentSecretStore`` implements the core secret-store contract without
placing credentials in host preferences or transcripts. Protected checkpoint and
SQLite adapters keep their database, WAL, and SHM files inside a host-selected
container and reapply the configured file-protection boundary.

On iOS and macOS, ``ICloudDriveFileMemoryAccess`` connects the read-only
file-memory scanner to one explicit iCloud Documents container. It waits for
current ubiquitous items, coordinates access, fails on unresolved versions,
and never redirects an unavailable cloud source to local storage. Its narrow
write API requires an explicit overwrite mode for app-authored documents. In
AgentRuntimeKit 0.2.1,
``ICloudDriveFileMemoryAccess/removeFileIfPresent(at:matchingModifiedAt:)``
combines a modification-date precondition with missing-file idempotence for
crash-retryable cleanup, while retaining coordinated current-version,
object-identity, and container-identity checks. For cleanup after a bounded
coordinated read, prefer
``ICloudDriveFileMemoryAccess/removeFileIfPresent(at:matchingModifiedAt:matchingSHA256:maximumByteCount:)``.
It additionally verifies an exact 64-character lowercase SHA-256 digest through
descriptor-rooted, bounded access inside the deletion coordination and applies
snapshot fences around hashing and immediately before unlinking.

A user-owned BYOK credential can be stored in Keychain. Never bundle a developer
or service-owned provider credential in a distributed application.

## Topics

### Credentials

- ``KeychainAgentSecretStore``
- ``KeychainAgentSecretStore/Configuration``

### Protected persistence

- ``ProtectedFileAgentCheckpointStore``
- ``ProtectedSQLiteMemoryStore``
- ``AgentFileProtection``

### iCloud Drive file memory

- ``ICloudDriveFileMemoryAccess``
- ``ICloudDriveFileMemoryAccess/Configuration``
- ``ICloudDriveFileMemoryAccess/removeFileIfPresent(at:matchingModifiedAt:)``
- ``ICloudDriveFileMemoryAccess/removeFileIfPresent(at:matchingModifiedAt:matchingSHA256:maximumByteCount:)``
- ``ICloudDriveDigestRemovalError``
- ``ICloudDriveWriteMode``
- ``ICloudDriveRemoveMode``
- ``SystemICloudDriveContainerLocator``
- ``SystemICloudDriveRescanHintSource``
- ``ICloudDriveRescanObservation``
