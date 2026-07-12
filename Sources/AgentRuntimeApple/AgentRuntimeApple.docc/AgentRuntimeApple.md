# ``AgentRuntimeApple``

Use Keychain credentials and protected durable stores in Apple applications.

## Overview

``KeychainAgentSecretStore`` implements the core secret-store contract without
placing credentials in host preferences or transcripts. Protected checkpoint and
SQLite adapters keep their database, WAL, and SHM files inside a host-selected
container and reapply the configured file-protection boundary.

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
