# ``AgentRuntimeMCP``

Discover and call remote MCP tools through Streamable HTTP.

## Overview

The MCP adapter is dependency-free and routes discovered tools back through the
same schema validation, allowlist, risk policy, approval, timeout, and audit path
as native tools. Production endpoints should use TLS and explicit authentication;
local process spawning and stdio transports are outside the package's mobile
security model.

## Topics

### Client and tools

- ``MCPStreamableHTTPClient``
- ``MCPToolAdapter``
- ``MCPHTTPTransport``
