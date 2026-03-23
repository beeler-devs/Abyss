# Nova to Claude Migration Design

## Summary

Replace Amazon Nova (Bedrock) as the text LLM with Claude (Anthropic API) across the entire server. Build a new `claudeProvider.ts` from scratch with true streaming, tiered model routing, and full feature parity. Refactor `MemoryService` to route through the `ModelProvider` abstraction instead of calling Bedrock directly. Delete all Nova/Bedrock text provider code. Voice (Nova Sonic), embeddings (Titan), and graph (Neptune) remain on AWS unchanged.

## Motivation

Switch the conversational AI backbone from Amazon Nova to Claude for improved reasoning, tool use, and response quality. The existing `anthropicProvider.ts` is ~90% functional but has gaps (no real streaming, ignored model override, low max tokens). Rather than patching it, build a clean provider that's production-ready from the start.

## Decisions

- **Approach:** New `claudeProvider.ts` from scratch (Approach 2), then delete both old providers.
- **Model tiering:** Haiku (default/lite) for normal turns, title generation, summarization. Sonnet (pro) for heavy tool-using turns. Same routing logic as the existing Pro/Lite pattern — routing is based on **tool availability**, not actual tool invocation (i.e., if heavy tools are in the available set, the entire request uses pro even if the LLM doesn't call them). This is the existing behavior and we accept it for this migration.
- **Streaming:** True token-by-token streaming via Anthropic SSE API (`stream: true`).
- **Max tokens:** 4096 base, 16384 for tool-using turns (4x multiplier).
- **Temperature:** 0.3 (matching current Nova behavior).
- **MemoryService:** Refactored to use `ModelProvider` abstraction, removing direct Bedrock SDK dependency.
- **Scope boundary:** Voice pipeline (Nova Sonic), embeddings (Titan), and context graph (Neptune) are untouched.

## Design

### 1. New `claudeProvider.ts`

**Location:** `server/src/providers/claudeProvider.ts`

**Implements:** `ModelProvider` interface from `server/src/core/types.ts`

**Core behavior:**

- Calls Anthropic Messages API (`POST /v1/messages`) via raw `fetch` with `stream: true`
- Returns `ModelResponse` with `fullText`, `chunks`, and `toolCalls` populated from the stream
- SSE event parsing: `content_block_start` (type `tool_use` creates a new tool call), `content_block_delta` (type `text_delta` for text tokens, `input_json_delta` for tool input JSON fragments), `content_block_stop` (finalize and JSON-parse accumulated tool input), `message_stop` (end of response)
- Tool call JSON arrives as incremental string fragments that must be accumulated per content block index and parsed after `content_block_stop`
- **Timeout strategy:** Use a 120-second `AbortSignal.timeout` on the full fetch+stream operation. This covers both connection establishment and the entire SSE stream. 120s is generous enough for long tool-using responses from Claude while still catching stuck connections. `AbortSignal.timeout` applies to the whole operation (not just connection), so this is the effective ceiling for any single LLM call.

**Streaming + tool call interaction with the conductor:**

The conductor's current contract (in `runConductorLoop`) branches on `modelResponse.toolCalls`:
- If `toolCalls` is non-empty: takes the tool branch, appends tool calls to history, dispatches tools. **Does not consume `chunks`.**
- If `toolCalls` is empty: iterates `chunks`, emitting `assistant.speech.partial` for each chunk, then emits `assistant.speech.final`.

Anthropic can return **both text and tool_use blocks in the same message**. The provider must handle this:

- **Buffering strategy:** The provider internally consumes the full SSE stream before returning `ModelResponse`. It accumulates text content and tool call content separately. This means `generateResponse()` is not truly "streaming to the caller during generation" — it streams from the API to an internal buffer, then exposes the buffered text via `chunks` and the parsed tool calls via `toolCalls`.
- **Why full buffering:** The conductor checks `toolCalls` length *before* consuming `chunks`. If we yielded text chunks while tool calls were still arriving, the conductor would take the text-only branch and miss tool calls. Buffering the full response preserves the existing conductor contract with no conductor changes.
- **`chunks` behavior:** `chunks` is an `AsyncIterable<string>` that yields the buffered text content in small segments (simulating streaming from the buffer). This preserves the `assistant.speech.partial` emission pattern. True token-by-token streaming can be added later if the conductor is refactored to handle interleaved text+tools.
- **`fullText`:** Set to the complete text content after buffering.
- **Mixed responses:** If the API returns both text and tool_use blocks, `fullText`/`chunks` contain the text portion and `toolCalls` contains the parsed tools. The conductor's tool branch takes precedence (text is appended to history but not emitted as speech — same as current behavior).
- **Error on disconnect:** If the SSE stream disconnects mid-response, throw an error. Since we buffer internally, no partial chunks have been emitted to the conductor yet, so no `assistant.speech.partial` events leak on failure.

**Model routing:**

- Constructor receives `model` (default/lite) and `proModel` (heavy) config
- `generateResponse()` respects the `modelOverride` parameter — uses it when provided, falls back to `this.config.model`
- `classifyModelTier()` in `conductorService.ts` continues to return the pro model ID when heavy tools are **available** (not when invoked — routing is based on the tool list passed to `generateResponse()`, meaning sessions with bridge/Cursor tools enabled will route most turns to pro)

**Configuration:**

- `temperature: 0.3`
- `max_tokens: 4096` base, multiplied by 4 (capped at 16384) when tools are present
- `anthropic-version: 2023-06-01` header

**Tool name translation:**

- Dots → underscores when registering tools (e.g. `gmail.inbox` → `gmail_inbox`)
- Reverse map applied to tool call names in responses
- Same pattern as both existing providers

**Message building (`buildMessages()`):**

- Converts `ConversationTurn[]` to Anthropic message format
- Batches consecutive tool-result turns into a single user message with `tool_result` content blocks
- Drops orphaned tool calls (assistant `tool_use` with no matching `tool_result`)
- Skips system-role turns (system prompt goes in the top-level `system` field)

**System prompt (`buildSystemPrompt()`):**

- Returns a single `string`
- **Must use underscored tool names** throughout (matching Anthropic's registered names, e.g. `cursor_agent_spawn`, `gmail_inbox`). Port from the existing `anthropicProvider.ts` prompt, NOT the Bedrock version which uses dotted names.
- Same instructional content as current providers, consolidated into one copy
- Accepts `userPreferences` and `canvasCourseContext` for dynamic injection

### 2. Provider Factory & Server Wiring

**`providers/index.ts`:**

- `buildProvider()` constructs only `ClaudeProvider`
- `ProviderConfig` simplified to: `anthropicApiKey`, `model`, `proModel`, `maxTokens`
- `MODEL_PROVIDER` env var removed

**`server.ts`:**

- Reads: `ANTHROPIC_API_KEY` (required), `ANTHROPIC_MODEL_ID` (default: `claude-haiku-4-5`), `ANTHROPIC_PRO_MODEL_ID` (default: `claude-sonnet-4-5-20250514`), `ANTHROPIC_MAX_TOKENS` (default: `4096`)
- **Rewires `proModelId`** from `BEDROCK_PRO_MODEL_ID` to `ANTHROPIC_PRO_MODEL_ID` when constructing the conductor
- Drops: `BEDROCK_TEXT_MODEL_ID`, `BEDROCK_PRO_MODEL_ID`, `MODEL_PROVIDER`
- Keeps all AWS config for voice, embeddings, Neptune
- Note: `healthz` endpoint reports `provider.name` — this will change from `"bedrock"` to `"claude"`

**`conductorService.ts`:**

- No changes needed — already provider-agnostic (the `proModelId` wiring change is in `server.ts`)
- `classifyModelTier()` unchanged, returns pro model ID for heavy tools
- Title generation and summarization continue to pass no `modelOverride` (uses default/lite)

### 3. MemoryService Refactoring

**Current:** `memoryService.ts` imports `BedrockRuntimeClient` and calls `InvokeModelCommand` directly with Nova-specific request format in `summarizeAndStore()` (line 176).

**Problem:** The `ModelProvider.generateResponse()` interface always injects the voice-first assistant system prompt (via `buildSystemPrompt()`). `MemoryService` needs a bare summarization call with no system prompt — just a user turn with the summarization prompt that returns JSON. The existing `contextSummarizer.ts` already uses `generateResponse()` for a similar internal task, but that works because the summarizer's prompt is strong enough to override the system prompt's voice-assistant framing. Memory summarization also requests JSON output, which could conflict with the voice prompt's "never read structured data" instruction.

**Design:** Add an optional `systemPrompt` parameter to `ModelProvider.generateResponse()`:

```typescript
generateResponse(
  conversation: ConversationTurn[],
  tools?: ToolDefinition[],
  userPreferences?: Record<string, string>,
  canvasCourseContext?: string,
  modelOverride?: string,
  systemPrompt?: string,  // override default system prompt
): Promise<ModelResponse>;
```

When `systemPrompt` is provided, the provider uses it instead of calling `buildSystemPrompt()`. When omitted (all existing call sites), behavior is unchanged. `MemoryService.summarizeAndStore()` passes a minimal system prompt like `"You are a conversation summarizer. Respond with JSON only."` and the summarization user turn. No tools, no model override.

**Removed:** Direct `BedrockRuntimeClient` import, `InvokeModelCommand` usage, `MEMORY_SUMMARY_MODEL_ID` env var, Nova-specific request format (`max_new_tokens` field).

**Note:** `MemoryService` retains its other AWS SDK dependencies (`BedrockAgentRuntimeClient` for Knowledge Base retrieval, `BedrockAgentClient` for KB ingestion, S3 for storage). Only the `BedrockRuntimeClient` text model call is removed.

### 4. Files to Delete

- `server/src/providers/bedrockNovaProvider.ts` — Nova text provider
- `server/src/providers/anthropicProvider.ts` — Old incomplete Anthropic provider
- `server/src/providers/chunking.ts` — Simulated streaming utilities (no longer needed)
- `server/tests/bedrockNovaProvider.test.ts` — Tests for deleted provider

**Pre-deletion check:** Verify no other files import from `chunking.ts` (specifically `streamSingle`, `chunkText`, `streamFromChunks`) before deleting.

### 5. Files to Modify

- `server/src/core/types.ts` — Add optional `systemPrompt` parameter to `ModelProvider.generateResponse()`
- `server/src/providers/index.ts` — Simplified factory
- `server/src/server.ts` — New env vars, drop Bedrock text config, rewire `proModelId`
- `server/src/core/memory/memoryService.ts` — Inject `ModelProvider`, remove `BedrockRuntimeClient`
- `server/tests/memoryService.test.ts` — Rewrite mocks from Bedrock to `ModelProvider`
- `server/.env.example` — Updated env var documentation
- `CLAUDE.md` — Updated architecture sections

### 6. Environment Variables

**Naming convention:** The existing codebase uses `ANTHROPIC_MODEL` (no `_ID` suffix) in `server.ts` line 67 and `.env.example`. This migration adopts the `_ID` suffix (`ANTHROPIC_MODEL_ID`) for consistency with `BEDROCK_TEXT_MODEL_ID` and to distinguish from the API key. The old `ANTHROPIC_MODEL` name is removed in one shot (no temporary compatibility).

| Action | Variable | Default | Notes |
|--------|----------|---------|-------|
| Add (required) | `ANTHROPIC_API_KEY` | — | Already exists in `.env.example`, now required |
| Add | `ANTHROPIC_MODEL_ID` | `claude-haiku-4-5` | Replaces `ANTHROPIC_MODEL` |
| Add | `ANTHROPIC_PRO_MODEL_ID` | `claude-sonnet-4-5-20250514` | New: heavy-task model |
| Add | `ANTHROPIC_MAX_TOKENS` | `4096` | Already exists, default changes from 512 to 4096 |
| Remove | `MODEL_PROVIDER` | — | No longer needed (Claude only) |
| Remove | `ANTHROPIC_MODEL` | — | Replaced by `ANTHROPIC_MODEL_ID` |
| Remove | `ANTHROPIC_PARTIAL_DELAY_MS` | — | Simulated streaming delay, no longer needed with real streaming |
| Remove | `BEDROCK_TEXT_MODEL_ID` | — | |
| Remove | `BEDROCK_PRO_MODEL_ID` | — | |
| Remove | `BEDROCK_MAX_TOKENS` | — | |
| Remove | `BEDROCK_PARTIAL_DELAY_MS` | — | |
| Remove | `MEMORY_SUMMARY_MODEL_ID` | — | Memory uses ModelProvider now |
| Keep | All AWS creds, `VOICE_PROVIDER`, `NEPTUNE_*`, `EMBEDDING_*` | unchanged | Still needed for voice, embeddings, Neptune |

`/healthz` endpoint will report `provider: "claude"` (was `"bedrock"` or `"anthropic"`).

## What's NOT Changing

- **Voice pipeline** — Nova Sonic (`bedrockNovaSonicVoiceProvider.ts`) is a separate `VoiceProvider` interface, fully independent of the text model. Untouched.
- **Context graph** — Neptune Analytics + Titan embeddings. Untouched.
- **iOS client** — No changes needed. Provider selection is server-side only.
- **`conductorService.ts`** — Already provider-agnostic. No modifications beyond what's needed for cleanup.
- **Tool definitions** — All tool schemas in `conductorService.ts` already use `input_schema` (Anthropic-native format). No changes.

## Testing & Validation

**Unit tests:**
- Existing `server/tests/` should pass unchanged EXCEPT:
  - `bedrockNovaProvider.test.ts` — deleted (provider removed)
  - `memoryService.test.ts` — **must be rewritten**. Currently mocks `BedrockRuntimeClient` with Nova-specific response format (`output.message.content[0].text`). Must be updated to mock a `ModelProvider` instead, providing `ModelResponse` with `fullText`/`chunks`/`toolCalls`. Tests at lines 64-87 and 89+ that construct `mockBedrock` all need updating.
- New `claudeProvider.test.ts`: message building, tool name translation, tool result batching, orphan cleanup, streaming token assembly, model override routing

**Integration validation (manual):**
- Normal conversation turn (no tools) — verify true streaming works
- Tool-using turn (gmail, bridge, etc.) — verify tool calls parse from streamed response
- Title generation — verify uses lite model (Haiku)
- Context summarization — verify routes through provider abstraction
- MemoryService summarization — verify routes through Claude instead of Bedrock

## Risks

- **Behavioral differences:** Claude at temperature 0.3 may behave differently from Nova at 0.3. System prompt may need tuning for Claude's style. Mitigated by keeping the same prompt content initially and iterating.
- **Token costs:** Claude Haiku/Sonnet pricing differs from Nova Lite/Pro. 4096 max tokens is more generous than the previous 512 default. Monitor costs after switching.
- **Streaming complexity:** True SSE streaming adds parsing complexity (partial JSON in tool_use deltas). Must handle edge cases like interrupted streams and malformed events.
- **No rollback:** Deleting the Bedrock provider means reverting via git is the only rollback path. Mitigated by building and validating the new provider before deleting old ones.
- **Max tokens increase:** Base max tokens jumps from 512 to 4096 (effective tool max from 2048/8192 to 16384). This is deliberate but will increase per-request cost. Monitor token usage after switching.
- **Deployment ordering:** ECS task definition must be updated with `ANTHROPIC_API_KEY` and new env vars BEFORE deploying the new container image, or the server will crash on startup.
