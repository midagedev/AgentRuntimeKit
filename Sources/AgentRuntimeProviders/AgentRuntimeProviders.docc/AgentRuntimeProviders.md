# ``AgentRuntimeProviders``

Connect AgentRuntimeKit to hosted and OpenAI-compatible model APIs.

## Overview

The module includes streaming adapters for Anthropic Messages, OpenAI Responses,
OpenAI Chat Completions, and Gemini GenerateContent. Credentials are resolved at
request time through ``ProviderCredentialResolving`` and never become part of an
agent message, checkpoint, memory record, or audit event.

Configure ``ProviderRetryPolicy`` on an adapter for bounded transient retries and
use ``FallbackModelProvider`` for an ordered provider route. Fallback continuation
is pinned to the child adapter that issued it so signed or encrypted reasoning
state cannot cross provider boundaries.

## Topics

### Hosted providers

- ``AnthropicMessagesProvider``
- ``OpenAIResponsesProvider``
- ``OpenAIChatCompletionsProvider``
- ``GeminiGenerateContentProvider``

### Credentials and reliability

- ``ProviderCredentialResolving``
- ``ProviderCredentialResolver``
- ``ProviderRetryPolicy``
- ``FallbackModelProvider``
