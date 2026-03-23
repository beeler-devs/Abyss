# Nova to Claude Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Amazon Nova (Bedrock) with Claude (Anthropic) as the sole text LLM, including a new streaming provider, tiered model routing, and MemoryService refactoring.

**Architecture:** New `claudeProvider.ts` calls Anthropic Messages API with SSE streaming, buffers the full response internally, and returns `ModelResponse` compatible with the existing conductor contract. Provider factory simplified to Claude-only. MemoryService switches from direct Bedrock SDK calls to `ModelProvider` abstraction via a new `systemPrompt` override parameter.

**Tech Stack:** TypeScript, Node.js `fetch`, Anthropic Messages API (SSE streaming), existing `ModelProvider` interface

**Spec:** `docs/superpowers/specs/2026-03-23-nova-to-claude-migration-design.md`

---

## File Structure

**Create:**
- `server/src/providers/claudeProvider.ts` — New Claude provider with SSE streaming
- `server/tests/claudeProvider.test.ts` — Unit tests for the new provider

**Modify:**
- `server/src/core/types.ts` — Add `systemPrompt` parameter to `ModelProvider`
- `server/src/providers/index.ts` — Simplified factory (Claude-only)
- `server/src/server.ts` — New env vars, rewire proModelId
- `server/src/core/memory/memoryService.ts` — Inject `ModelProvider`, remove `BedrockRuntimeClient`
- `server/tests/memoryService.test.ts` — Rewrite mocks from Bedrock to `ModelProvider`
- `server/.env.example` — Updated env var documentation
- `CLAUDE.md` — Updated architecture sections

**Delete:**
- `server/src/providers/bedrockNovaProvider.ts`
- `server/src/providers/anthropicProvider.ts`
- `server/src/providers/chunking.ts`
- `server/tests/bedrockNovaProvider.test.ts`

---

### Task 1: Add `systemPrompt` to `ModelProvider` Interface

**Files:**
- Modify: `server/src/core/types.ts:147-156`

- [ ] **Step 1: Add optional `systemPrompt` parameter to `ModelProvider.generateResponse()`**

In `server/src/core/types.ts`, update the `ModelProvider` interface (lines 147-156):

```typescript
export interface ModelProvider {
  readonly name: string;
  generateResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
    userPreferences?: Record<string, string>,
    canvasCourseContext?: string,
    modelOverride?: string,
    systemPrompt?: string,
  ): Promise<ModelResponse>;
}
```

- [ ] **Step 2: Verify existing providers still compile**

Run: `cd server && npx tsc --noEmit`
Expected: PASS (new parameter is optional, existing implementations ignore it)

- [ ] **Step 3: Commit**

```bash
git add server/src/core/types.ts
git commit -m "Add optional systemPrompt parameter to ModelProvider interface"
```

---

### Task 2: Build `claudeProvider.ts` — Message Building & Tool Name Translation

**Files:**
- Create: `server/src/providers/claudeProvider.ts`
- Create: `server/tests/claudeProvider.test.ts`

- [ ] **Step 1: Write failing tests for `buildMessages()` and tool name translation**

Create `server/tests/claudeProvider.test.ts`:

```typescript
import test from "node:test";
import assert from "node:assert/strict";
import { ClaudeProvider } from "../src/providers/claudeProvider.js";
import { ConversationTurn, ToolDefinition } from "../src/core/types.js";

// Helper to access private methods for unit testing.
// We test through the public interface where possible, but buildMessages
// and tool name logic are internal and need direct testing.
function createProvider() {
  return new ClaudeProvider({
    apiKey: "test-key",
    model: "claude-haiku-4-5",
    maxTokens: 4096,
  });
}

test("buildMessages skips system turns", () => {
  const provider = createProvider() as any;
  const turns: ConversationTurn[] = [
    { role: "system", content: "You are a helpful assistant" },
    { role: "user", content: "Hello" },
    { role: "assistant", content: "Hi there" },
  ];
  const messages = provider.buildMessages(turns);
  assert.equal(messages.length, 2);
  assert.equal(messages[0].role, "user");
  assert.equal(messages[1].role, "assistant");
});

test("buildMessages batches consecutive tool results into one user message", () => {
  const provider = createProvider() as any;
  const turns: ConversationTurn[] = [
    { role: "user", content: "Do stuff" },
    {
      role: "assistant",
      content: [
        { id: "tc1", name: "gmail_inbox", input: {} },
        { id: "tc2", name: "calendar_list", input: {} },
      ],
    },
    { role: "tool", content: '{"emails":[]}', tool_use_id: "tc1", tool_name: "gmail_inbox" },
    { role: "tool", content: '{"events":[]}', tool_use_id: "tc2", tool_name: "calendar_list" },
  ];
  const messages = provider.buildMessages(turns);
  // user, assistant (tool_use), user (batched tool_results)
  assert.equal(messages.length, 3);
  const toolResultMsg = messages[2];
  assert.equal(toolResultMsg.role, "user");
  assert.ok(Array.isArray(toolResultMsg.content));
  assert.equal(toolResultMsg.content.length, 2);
  assert.equal(toolResultMsg.content[0].type, "tool_result");
  assert.equal(toolResultMsg.content[1].type, "tool_result");
});

test("buildMessages drops orphaned tool calls", () => {
  const provider = createProvider() as any;
  const turns: ConversationTurn[] = [
    { role: "user", content: "Hello" },
    {
      role: "assistant",
      content: [
        { id: "tc1", name: "tool_a", input: {} },
        { id: "tc2", name: "tool_b", input: {} },
      ],
    },
    // Only tc1 has a result — tc2 is orphaned
    { role: "tool", content: "result1", tool_use_id: "tc1", tool_name: "tool_a" },
    { role: "user", content: "Continue" },
  ];
  const messages = provider.buildMessages(turns);
  // user, assistant (only tc1 — tc2 filtered), user (tool_result for tc1), user
  const assistantMsg = messages[1];
  assert.ok(Array.isArray(assistantMsg.content));
  assert.equal(assistantMsg.content.length, 1);
  assert.equal(assistantMsg.content[0].id, "tc1");
});

test("buildMessages ensures first message is user role", () => {
  const provider = createProvider() as any;
  const turns: ConversationTurn[] = [
    { role: "assistant", content: "I start" },
    { role: "user", content: "Hello" },
  ];
  const messages = provider.buildMessages(turns);
  assert.equal(messages[0].role, "user");
});

test("tool names: dots replaced with underscores", () => {
  const provider = createProvider() as any;
  const tools: ToolDefinition[] = [
    { name: "gmail.inbox", description: "Get inbox", input_schema: { type: "object", properties: {} } },
    { name: "bridge.exec.run", description: "Run cmd", input_schema: { type: "object", properties: {} } },
  ];
  const { safeTools, toolNameToOriginal } = provider.prepareTools(tools);
  assert.equal(safeTools[0].name, "gmail_inbox");
  assert.equal(safeTools[1].name, "bridge_exec_run");
  assert.equal(toolNameToOriginal.get("gmail_inbox"), "gmail.inbox");
  assert.equal(toolNameToOriginal.get("bridge_exec_run"), "bridge.exec.run");
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && npx tsx --test tests/claudeProvider.test.ts`
Expected: FAIL — `ClaudeProvider` does not exist

- [ ] **Step 3: Create `claudeProvider.ts` with types, config, `buildMessages()`, and `prepareTools()`**

Create `server/src/providers/claudeProvider.ts` with the message building and tool name logic. Port the `buildMessages()` logic from the existing `anthropicProvider.ts` (lines 99-191) — it is already correct for the Anthropic API format. Add `prepareTools()` for dot→underscore translation.

```typescript
import {
  ConversationTurn,
  ModelProvider,
  ModelResponse,
  ToolCallRequest,
  ToolDefinition,
} from "../core/types.js";

export interface ClaudeConfig {
  apiKey: string;
  model: string;
  proModel?: string;
  maxTokens: number;
}

type AnthropicRequestRole = "user" | "assistant";

interface AnthropicTextBlock {
  type: "text";
  text: string;
}

interface AnthropicToolUseBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}

interface AnthropicToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  content: string;
}

type AnthropicContentBlock =
  | AnthropicTextBlock
  | AnthropicToolUseBlock
  | AnthropicToolResultBlock;

interface AnthropicRequestMessage {
  role: AnthropicRequestRole;
  content: string | AnthropicContentBlock[];
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return value.trim().length ? value : null;
}

export class ClaudeProvider implements ModelProvider {
  readonly name = "claude";
  private readonly config: ClaudeConfig;

  constructor(config: ClaudeConfig) {
    this.config = config;
  }

  async generateResponse(
    _conversation: ConversationTurn[],
    _tools?: ToolDefinition[],
    _userPreferences?: Record<string, string>,
    _canvasCourseContext?: string,
    _modelOverride?: string,
    _systemPrompt?: string,
  ): Promise<ModelResponse> {
    // Stub — implemented in Task 3
    throw new Error("Not implemented");
  }

  /** Exposed for testing. */
  prepareTools(tools: ToolDefinition[]): {
    safeTools: ToolDefinition[];
    toolNameToOriginal: Map<string, string>;
  } {
    const toolNameToOriginal = new Map<string, string>();
    const safeTools = tools
      .filter((t) => Boolean(t.name))
      .map((tool) => {
        const safeName = tool.name.replace(/\./g, "_");
        if (safeName !== tool.name) {
          toolNameToOriginal.set(safeName, tool.name);
        }
        return { ...tool, name: safeName };
      });
    return { safeTools, toolNameToOriginal };
  }

  /** Exposed for testing. */
  buildMessages(conversation: ConversationTurn[]): AnthropicRequestMessage[] {
    // Collect all resolved tool_use IDs from tool result turns.
    const resolvedToolUseIds = new Set<string>();
    for (const turn of conversation) {
      if (turn.role === "tool" && turn.tool_use_id) {
        resolvedToolUseIds.add(turn.tool_use_id);
      }
    }

    // Identify orphaned tool_use IDs (no matching tool result).
    const skippedToolUseIds = new Set<string>();
    for (const turn of conversation) {
      if (turn.role === "assistant" && Array.isArray(turn.content)) {
        for (const tc of turn.content) {
          if (!resolvedToolUseIds.has(tc.id)) {
            skippedToolUseIds.add(tc.id);
          }
        }
      }
    }

    const messages: AnthropicRequestMessage[] = [];
    let pendingToolResults: AnthropicToolResultBlock[] = [];

    const flushToolResults = () => {
      if (pendingToolResults.length > 0) {
        messages.push({ role: "user", content: pendingToolResults });
        pendingToolResults = [];
      }
    };

    for (const turn of conversation) {
      if (turn.role === "system") continue;

      if (turn.role === "tool") {
        const toolUseId = asNonEmptyString(turn.tool_use_id);
        const content =
          typeof turn.content === "string" ? turn.content : JSON.stringify(turn.content);

        if (!toolUseId) {
          flushToolResults();
          messages.push({ role: "user", content });
          continue;
        }

        if (skippedToolUseIds.has(toolUseId)) continue;

        pendingToolResults.push({ type: "tool_result", tool_use_id: toolUseId, content });
        continue;
      }

      flushToolResults();

      if (turn.role === "assistant" && Array.isArray(turn.content)) {
        const resolved = turn.content.filter((tc) => !skippedToolUseIds.has(tc.id));
        if (resolved.length === 0) continue;
        messages.push({
          role: "assistant",
          content: resolved.map((tc) => ({
            type: "tool_use" as const,
            id: tc.id,
            name: tc.name,
            input: tc.input,
          })),
        });
        continue;
      }

      if ((turn.role === "user" || turn.role === "assistant") && typeof turn.content === "string") {
        messages.push({ role: turn.role, content: turn.content });
      }
    }

    flushToolResults();

    // Anthropic requires the first message to be from the user.
    while (messages.length > 0 && messages[0].role !== "user") {
      messages.shift();
    }

    return messages;
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && npx tsx --test tests/claudeProvider.test.ts`
Expected: PASS (all 5 tests)

- [ ] **Step 5: Commit**

```bash
git add server/src/providers/claudeProvider.ts server/tests/claudeProvider.test.ts
git commit -m "Add ClaudeProvider with message building and tool name translation"
```

---

### Task 3: Build `claudeProvider.ts` — SSE Streaming & Response Parsing

**Files:**
- Modify: `server/src/providers/claudeProvider.ts`
- Modify: `server/tests/claudeProvider.test.ts`

- [ ] **Step 1: Write failing tests for SSE parsing and response assembly**

Add to `server/tests/claudeProvider.test.ts`:

```typescript
test("parseSSEStream assembles text from text_delta events", async () => {
  const provider = createProvider() as any;
  const events = [
    { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello " } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "world" } },
    { type: "content_block_stop", index: 0 },
    { type: "message_stop" },
  ];
  const result = provider.parseSSEEvents(events, new Map());
  assert.equal(result.fullText, "Hello world");
  assert.equal(result.toolCalls.length, 0);
});

test("parseSSEStream extracts tool calls from tool_use events", async () => {
  const provider = createProvider() as any;
  const toolNameToOriginal = new Map([["gmail_inbox", "gmail.inbox"]]);
  const events = [
    { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "tu_1", name: "gmail_inbox" } },
    { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"max' } },
    { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: 'Results":5}' } },
    { type: "content_block_stop", index: 0 },
    { type: "message_stop" },
  ];
  const result = provider.parseSSEEvents(events, toolNameToOriginal);
  assert.equal(result.toolCalls.length, 1);
  assert.equal(result.toolCalls[0].id, "tu_1");
  assert.equal(result.toolCalls[0].name, "gmail.inbox");
  assert.deepEqual(result.toolCalls[0].input, { maxResults: 5 });
});

test("parseSSEStream handles mixed text + tool_use response", async () => {
  const provider = createProvider() as any;
  const events = [
    { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Let me check." } },
    { type: "content_block_stop", index: 0 },
    { type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "tu_2", name: "web_search" } },
    { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: '{"query":"test"}' } },
    { type: "content_block_stop", index: 1 },
    { type: "message_stop" },
  ];
  const result = provider.parseSSEEvents(events, new Map());
  assert.equal(result.fullText, "Let me check.");
  assert.equal(result.toolCalls.length, 1);
  assert.equal(result.toolCalls[0].name, "web_search");
});

test("model override selects pro model", () => {
  const provider = new ClaudeProvider({
    apiKey: "test-key",
    model: "claude-haiku-4-5",
    proModel: "claude-sonnet-4-5-20250514",
    maxTokens: 4096,
  }) as any;
  assert.equal(provider.resolveModel(undefined), "claude-haiku-4-5");
  assert.equal(provider.resolveModel("claude-sonnet-4-5-20250514"), "claude-sonnet-4-5-20250514");
});

test("parseSSEStream handles empty tool input JSON", async () => {
  const provider = createProvider() as any;
  const events = [
    { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "tu_3", name: "test_tool" } },
    // No input_json_delta events — empty input
    { type: "content_block_stop", index: 0 },
    { type: "message_stop" },
  ];
  const result = provider.parseSSEEvents(events, new Map());
  assert.equal(result.toolCalls.length, 1);
  assert.deepEqual(result.toolCalls[0].input, {});
});

test("max tokens multiplied by 4 when tools present, capped at 16384", () => {
  const provider = createProvider() as any;
  assert.equal(provider.resolveMaxTokens(false), 4096);
  assert.equal(provider.resolveMaxTokens(true), 16384);
  // Provider with small maxTokens
  const smallProvider = new ClaudeProvider({
    apiKey: "test-key",
    model: "claude-haiku-4-5",
    maxTokens: 1024,
  }) as any;
  assert.equal(smallProvider.resolveMaxTokens(true), 4096);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && npx tsx --test tests/claudeProvider.test.ts`
Expected: FAIL — `parseSSEEvents`, `resolveModel`, `resolveMaxTokens` not defined

- [ ] **Step 3: Implement SSE parsing, model resolution, and token resolution**

Add these methods to `ClaudeProvider` in `server/src/providers/claudeProvider.ts`:

```typescript
  /** Exposed for testing. */
  resolveModel(modelOverride?: string): string {
    return modelOverride ?? this.config.model;
  }

  /** Exposed for testing. */
  resolveMaxTokens(withTools: boolean): number {
    if (!withTools) return this.config.maxTokens;
    return Math.min(this.config.maxTokens * 4, 16384);
  }

  /** Exposed for testing. Parses pre-parsed SSE event objects into text + tool calls. */
  parseSSEEvents(
    events: Array<Record<string, any>>,
    toolNameToOriginal: Map<string, string>,
  ): { fullText: string; toolCalls: ToolCallRequest[] } {
    const textParts: string[] = [];
    const toolCalls: ToolCallRequest[] = [];

    // Accumulators keyed by content block index
    const toolInputBuffers = new Map<number, string>();
    const toolMeta = new Map<number, { id: string; name: string }>();

    for (const event of events) {
      if (event.type === "content_block_start") {
        const block = event.content_block;
        if (block?.type === "tool_use") {
          toolMeta.set(event.index, { id: block.id, name: block.name });
          toolInputBuffers.set(event.index, "");
        }
      } else if (event.type === "content_block_delta") {
        const delta = event.delta;
        if (delta?.type === "text_delta" && typeof delta.text === "string") {
          textParts.push(delta.text);
        } else if (delta?.type === "input_json_delta" && typeof delta.partial_json === "string") {
          const existing = toolInputBuffers.get(event.index) ?? "";
          toolInputBuffers.set(event.index, existing + delta.partial_json);
        }
      } else if (event.type === "content_block_stop") {
        const meta = toolMeta.get(event.index);
        if (meta) {
          const jsonStr = toolInputBuffers.get(event.index) ?? "{}";
          let input: Record<string, unknown> = {};
          try {
            input = JSON.parse(jsonStr);
          } catch {
            // Malformed tool input — use empty object
          }
          const originalName = toolNameToOriginal.get(meta.name) ?? meta.name;
          toolCalls.push({ id: meta.id, name: originalName, input });
          toolMeta.delete(event.index);
          toolInputBuffers.delete(event.index);
        }
      }
    }

    return { fullText: textParts.join("").trim(), toolCalls };
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && npx tsx --test tests/claudeProvider.test.ts`
Expected: PASS (all 10 tests)

- [ ] **Step 5: Commit**

```bash
git add server/src/providers/claudeProvider.ts server/tests/claudeProvider.test.ts
git commit -m "Add SSE parsing, model routing, and token resolution to ClaudeProvider"
```

---

### Task 4: Build `claudeProvider.ts` — System Prompt, `fetchSSE()`, and `generateResponse()`

**Files:**
- Modify: `server/src/providers/claudeProvider.ts`

This task wires up the actual API call. No new tests — the SSE fetch depends on a live API. Integration testing is manual (Task 9).

- [ ] **Step 1: Add the system prompt**

Port the system prompt from `server/src/providers/anthropicProvider.ts:194-253`. This is the version with underscored tool names. Add it as `buildSystemPrompt()` in `claudeProvider.ts`:

```typescript
  private buildSystemPrompt(userPreferences?: Record<string, string>, canvasCourseContext?: string): string {
    const parts: string[] = [
      // Copy the entire parts array from anthropicProvider.ts lines 196-242.
      // These already use underscored tool names (cursor_agent_spawn, gmail_inbox, etc.)
    ];

    if (userPreferences && Object.keys(userPreferences).length > 0) {
      const prefLines = Object.entries(userPreferences).map(([k, v]) => `- ${k}: ${v}`);
      parts.push(`User preferences (apply throughout):\n${prefLines.join("\n")}`);
    }

    if (canvasCourseContext) {
      parts.push(canvasCourseContext);
    }

    return parts.join(" ");
  }
```

- [ ] **Step 2: Implement `fetchSSE()` — the raw SSE streaming API call**

Add to `claudeProvider.ts`:

```typescript
  private async fetchSSE(
    messages: AnthropicRequestMessage[],
    system: string,
    model: string,
    maxTokens: number,
    tools?: ToolDefinition[],
  ): Promise<Array<Record<string, any>>> {
    const body: Record<string, unknown> = {
      model,
      max_tokens: maxTokens,
      temperature: 0.3,
      system,
      messages,
      stream: true,
    };

    if (tools && tools.length > 0) {
      body.tools = tools;
    }

    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": this.config.apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(120_000),
    });

    if (!response.ok) {
      const bodyText = await response.text();
      throw new Error(`anthropic_http_${response.status}:${bodyText.slice(0, 200)}`);
    }

    if (!response.body) {
      throw new Error("anthropic_no_body: Response has no body");
    }

    // Parse SSE stream — the connection timeout no longer applies once we start reading.
    const events: Array<Record<string, any>> = [];
    const decoder = new TextDecoder();
    let buffer = "";

    for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
      buffer += decoder.decode(chunk, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        if (line.startsWith("data: ")) {
          const data = line.slice(6).trim();
          if (data === "[DONE]") continue;
          try {
            events.push(JSON.parse(data));
          } catch {
            // Skip malformed SSE lines
          }
        }
      }
    }

    return events;
  }
```

- [ ] **Step 3: Implement `generateResponse()`**

Replace the stub `generateResponse()` in `claudeProvider.ts`:

```typescript
  async generateResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
    userPreferences?: Record<string, string>,
    canvasCourseContext?: string,
    modelOverride?: string,
    systemPrompt?: string,
  ): Promise<ModelResponse> {
    const messages = this.buildMessages(conversation);
    const system = systemPrompt ?? this.buildSystemPrompt(userPreferences, canvasCourseContext);
    const toolList = tools ?? [];
    const { safeTools, toolNameToOriginal } = this.prepareTools(toolList);
    const withTools = safeTools.length > 0;
    const model = this.resolveModel(modelOverride);
    const maxTokens = this.resolveMaxTokens(withTools);

    const sseEvents = await this.fetchSSE(
      messages,
      system,
      model,
      maxTokens,
      withTools ? safeTools : undefined,
    );

    const { fullText, toolCalls } = this.parseSSEEvents(sseEvents, toolNameToOriginal);

    // Build chunks from buffered text for conductor's assistant.speech.partial emission.
    const textChunks = chunkBufferedText(fullText);

    const response: ModelResponse = {
      fullText: fullText || (toolCalls.length > 0 ? "" : "I heard you, but the model returned an empty response. Could you try again?"),
      chunks: streamFromBuffer(textChunks),
    };

    if (toolCalls.length > 0) {
      response.toolCalls = toolCalls;
    }

    return response;
  }
```

- [ ] **Step 4: Add helper functions for buffered text streaming**

Add at the top of `claudeProvider.ts` (outside the class):

```typescript
function chunkBufferedText(text: string, minChunk = 30, maxChunk = 80): string[] {
  if (!text.trim()) return [];
  const chunks: string[] = [];
  let cursor = 0;
  while (cursor < text.length) {
    const remaining = text.length - cursor;
    const target = Math.min(remaining, Math.floor(Math.random() * (maxChunk - minChunk + 1)) + minChunk);
    let end = cursor + target;
    if (end < text.length) {
      const breakpoint = text.lastIndexOf(" ", end);
      if (breakpoint > cursor + Math.floor(minChunk / 2)) {
        end = breakpoint;
      }
    }
    if (end <= cursor) end = cursor + target;
    const chunk = text.slice(cursor, end);
    if (chunk.length > 0) chunks.push(chunk);
    cursor = end;
  }
  return chunks;
}

async function* streamFromBuffer(chunks: string[]): AsyncIterable<string> {
  for (const chunk of chunks) {
    yield chunk;
  }
}
```

- [ ] **Step 5: Verify compilation**

Run: `cd server && npx tsc --noEmit`
Expected: PASS

- [ ] **Step 6: Run all unit tests to check nothing is broken**

Run: `cd server && npx tsx --test tests/claudeProvider.test.ts`
Expected: PASS (all 10 tests)

- [ ] **Step 7: Commit**

```bash
git add server/src/providers/claudeProvider.ts
git commit -m "Implement generateResponse with SSE streaming and system prompt in ClaudeProvider"
```

---

### Task 5: Simplify Provider Factory and Server Wiring

**Files:**
- Modify: `server/src/providers/index.ts`
- Modify: `server/src/server.ts`

- [ ] **Step 1: Rewrite `providers/index.ts`**

Replace the entire contents of `server/src/providers/index.ts`:

```typescript
import { ModelProvider } from "../core/types.js";
import { ClaudeProvider } from "./claudeProvider.js";

export interface ProviderConfig {
  anthropicApiKey: string;
  model: string;
  proModel?: string;
  maxTokens: number;
}

export function buildProvider(config: ProviderConfig): ModelProvider {
  if (!config.anthropicApiKey) {
    throw new Error("ANTHROPIC_API_KEY is required");
  }

  return new ClaudeProvider({
    apiKey: config.anthropicApiKey,
    model: config.model,
    proModel: config.proModel,
    maxTokens: config.maxTokens,
  });
}
```

- [ ] **Step 2: Update `server.ts` env vars and provider construction**

In `server/src/server.ts`:

Remove the `MODEL_PROVIDER` const (line 29):
```typescript
// DELETE: const MODEL_PROVIDER = (process.env.MODEL_PROVIDER ?? "bedrock").toLowerCase() === "anthropic" ? "anthropic" : "bedrock";
```

Remove `BEDROCK_PRO_MODEL_ID` (line 57) and `MEMORY_SUMMARY_MODEL_ID` (line 56). Replace with:
```typescript
const ANTHROPIC_PRO_MODEL_ID = process.env.ANTHROPIC_PRO_MODEL_ID ?? "";
```

Replace the `provider` construction (lines 64-74):
```typescript
const provider = buildProvider({
  anthropicApiKey: process.env.ANTHROPIC_API_KEY ?? "",
  model: process.env.ANTHROPIC_MODEL_ID ?? "claude-haiku-4-5",
  proModel: ANTHROPIC_PRO_MODEL_ID || undefined,
  maxTokens: parseInteger(process.env.ANTHROPIC_MAX_TOKENS, 4096),
});
```

Update `proModelId` wiring (line 207):
```typescript
proModelId: ANTHROPIC_PRO_MODEL_ID || undefined,
```

Remove unused imports: `BedrockNovaProvider`, `AnthropicProvider` if any remain in `server.ts` (there shouldn't be direct imports, but check).

- [ ] **Step 3: Verify compilation**

Run: `cd server && npx tsc --noEmit`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add server/src/providers/index.ts server/src/server.ts
git commit -m "Simplify provider factory to Claude-only and update server env wiring"
```

---

### Task 6: Refactor MemoryService

**Files:**
- Modify: `server/src/core/memory/memoryService.ts`
- Modify: `server/tests/memoryService.test.ts`
- Modify: `server/tests/conductorService.memory.test.ts`
- Modify: `server/src/server.ts` (inject provider into MemoryService)

- [ ] **Step 1: Write failing test for MemoryService with ModelProvider**

Rewrite the summarization test in `server/tests/memoryService.test.ts`. Update `makeConfig()` to remove `summaryModelId`. Update the "writes JSON to S3" test (lines 54-87) to use a mock `ModelProvider` instead of `mockBedrock`:

```typescript
// Replace the mockBedrock in the test at line 64-75 with:
function makeMockProvider(summaryJson: string): any {
  return {
    name: "test",
    async generateResponse() {
      return {
        fullText: summaryJson,
        chunks: (async function* () { yield summaryJson; })(),
      };
    },
  };
}

// In makeConfig(), remove summaryModelId:
function makeConfig(overrides: Partial<MemoryServiceConfig> = {}): MemoryServiceConfig {
  return {
    enabled: true,
    s3Bucket: "test-bucket",
    s3Prefix: "memories/",
    awsRegion: "us-east-1",
    retrieveTimeoutMs: 1500,
    maxInjectedChars: 900,
    recentMemoryCount: 3,
    ...overrides,
  };
}
```

Update the test at line 54 to pass the mock provider:

```typescript
test("summarizeAndStore writes JSON to S3 for meaningful session", async () => {
  let putBody = "";
  const mockS3 = {
    send: async (cmd: unknown) => {
      const c = cmd as { input?: { Body?: string } };
      if (c.input?.Body !== undefined) putBody = c.input.Body as string;
      return {};
    },
  };

  const summaryJson = '{"summary":"Fixed auth bug","decisions":["Use JWT"],"blockers":[],"nextSteps":["Deploy"]}';
  const mockProvider = makeMockProvider(summaryJson);

  const service = new MemoryService(makeConfig(), mockProvider, { s3: mockS3 as never });
  const result = await service.summarizeAndStore("user1", "sess1", threeUserTurns());
  assert.ok(result !== null);
  assert.equal(result!.memoryUserKey, "user1");
  assert.ok(result!.summary.length > 0);
  assert.ok(putBody.length > 0);
});
```

Similarly update the KB ingestion test (line 89+) to use `makeMockProvider`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && npx tsx --test tests/memoryService.test.ts`
Expected: FAIL — constructor signature changed

- [ ] **Step 3: Refactor `memoryService.ts`**

In `server/src/core/memory/memoryService.ts`:

1. Add `ModelProvider` import (from `../types.js`)
2. Remove `BedrockRuntimeClient` and `InvokeModelCommand` imports (lines 1-4)
3. Remove `summaryModelId` from `MemoryServiceConfig` (line 29)
4. Remove `bedrock` from `MemoryServiceClients` (line 105) and remove `this.bedrock` property (line 113)
5. Add `ModelProvider` as the second constructor parameter:

```typescript
export class MemoryService {
  private readonly config: MemoryServiceConfig;
  private readonly provider: ModelProvider;
  private readonly s3: S3Client;
  private readonly agentRuntime: BedrockAgentRuntimeClient;
  private readonly bedrockAgent: BedrockAgentClient;

  constructor(config: MemoryServiceConfig, provider: ModelProvider, clients?: MemoryServiceClients) {
    this.config = config;
    this.provider = provider;
    this.s3 = clients?.s3 ?? new S3Client({ region: config.awsRegion });
    this.agentRuntime = clients?.agentRuntime ?? new BedrockAgentRuntimeClient({ region: config.awsRegion });
    this.bedrockAgent = clients?.bedrockAgent ?? new BedrockAgentClient({ region: config.awsRegion });
  }
```

6. Replace the Bedrock `InvokeModelCommand` call in `summarizeAndStore()` (lines 176-196) with:

```typescript
    try {
      const response = await this.provider.generateResponse(
        [{ role: "user", content: prompt }],
        undefined, // no tools
        undefined, // no userPreferences
        undefined, // no canvasCourseContext
        undefined, // no modelOverride (uses default/lite)
        "You are a conversation summarizer. Respond with JSON only.",
      );

      // Collect the full response text
      let text = "";
      for await (const chunk of response.chunks) {
        text += chunk;
      }
      if (!text.trim()) text = response.fullText;

      const jsonMatch = text.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        parsedSummary = JSON.parse(jsonMatch[0]) as typeof parsedSummary;
      }
    } catch {
      parsedSummary = { summary: "Session summary unavailable." };
    }
```

- [ ] **Step 4: Update `server.ts` to inject `provider` into `MemoryService`**

In `server.ts`, find the `MemoryService` constructor call and update it. Remove the `MEMORY_SUMMARY_MODEL_ID` const (line 56) and `summaryModelId` from the config. Add `provider` as the second argument:

```typescript
// Before:
const memoryService = new MemoryService({
  enabled: MEMORY_ENABLED,
  s3Bucket: process.env.MEMORY_S3_BUCKET ?? "",
  s3Prefix: process.env.MEMORY_S3_PREFIX ?? "memories/",
  // ... other config
  summaryModelId: MEMORY_SUMMARY_MODEL_ID,  // REMOVE THIS
  // ...
});

// After:
const memoryService = new MemoryService({
  enabled: MEMORY_ENABLED,
  s3Bucket: process.env.MEMORY_S3_BUCKET ?? "",
  s3Prefix: process.env.MEMORY_S3_PREFIX ?? "memories/",
  // ... other config (no summaryModelId)
}, provider);  // inject the ModelProvider
```

- [ ] **Step 5: Update `conductorService.memory.test.ts`**

This file has 6 `MemoryService` constructor calls and a `makeConfig()` with `summaryModelId` that all need updating for the new `constructor(config, provider, clients?)` signature.

1. Remove `summaryModelId` from `makeConfig()` (line 29)

2. Create a mock provider helper at the top of the file (after existing `StubProvider`):

```typescript
function makeSummaryProvider(summaryJson?: string): ModelProvider {
  return {
    name: "mock-summary",
    async generateResponse(): Promise<ModelResponse> {
      const text = summaryJson ?? '{"summary":"test","decisions":[],"blockers":[],"nextSteps":[]}';
      return {
        fullText: text,
        chunks: (async function* () { yield text; })(),
      };
    },
  };
}
```

3. Update all 6 `new MemoryService(...)` calls to include a provider as the second argument:

- Line 62: `new MemoryService(makeConfig(), makeSummaryProvider(), { s3: mockS3 as never })`
- Line 122: `new MemoryService(makeConfig(), makeSummaryProvider(), { s3: mockS3 as never })`
- Line 144: `new MemoryService(makeConfig(), makeSummaryProvider())`
- Line 162: `new MemoryService(makeConfig(), makeSummaryProvider(), { s3: mockS3 as never })` (remove `bedrock: mockBedrock as never` from clients)
- Line 192: `new MemoryService(makeConfig(), makeSummaryProvider(), { s3: mockS3 as never })` (remove `bedrock: mockBedrock as never` from clients)
- Line 223: `new MemoryService(makeConfig(), makeSummaryProvider(summaryJson), { s3: mockS3 as never })` (remove `bedrock: mockBedrock as never`; delete the `mockBedrock` variable at lines 214-220)

- [ ] **Step 6: Run both memory test files to verify they pass**

Run: `cd server && npx tsx --test tests/memoryService.test.ts tests/conductorService.memory.test.ts`
Expected: PASS

- [ ] **Step 7: Verify full compilation**

Run: `cd server && npx tsc --noEmit`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add server/src/core/memory/memoryService.ts server/tests/memoryService.test.ts server/tests/conductorService.memory.test.ts server/src/server.ts
git commit -m "Refactor MemoryService to use ModelProvider instead of direct Bedrock calls"
```

---

### Task 7: Delete Old Providers

**Files:**
- Delete: `server/src/providers/bedrockNovaProvider.ts`
- Delete: `server/src/providers/anthropicProvider.ts`
- Delete: `server/src/providers/chunking.ts`
- Delete: `server/tests/bedrockNovaProvider.test.ts`

- [ ] **Step 1: Verify no other files import from `chunking.ts`**

Run: `cd server && grep -r "chunking" src/ --include="*.ts" | grep -v "node_modules"`
Expected: Only `anthropicProvider.ts` and `bedrockNovaProvider.ts` (both being deleted)

- [ ] **Step 2: Delete the files**

```bash
cd server
rm src/providers/bedrockNovaProvider.ts
rm src/providers/anthropicProvider.ts
rm src/providers/chunking.ts
rm tests/bedrockNovaProvider.test.ts
```

- [ ] **Step 3: Verify compilation**

Run: `cd server && npx tsc --noEmit`
Expected: PASS

- [ ] **Step 4: Run full test suite**

Run: `cd server && npm test`
Expected: PASS (all tests pass; the deleted test file is simply gone)

- [ ] **Step 5: Commit**

```bash
git add -u server/src/providers/ server/tests/bedrockNovaProvider.test.ts
git commit -m "Remove Bedrock text provider, old Anthropic provider, and simulated chunking"
```

---

### Task 8: Update `.env.example` and `CLAUDE.md`

**Files:**
- Modify: `server/.env.example`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `.env.example`**

Replace the provider section of `server/.env.example` (lines 1-28):

```env
PORT=8080
VOICE_PROVIDER=nova-sonic
MAX_EVENT_BYTES=65536
MAX_TURNS=20
SESSION_RATE_LIMIT_PER_MIN=300
TRANSCRIPT_TRACE_MAX_ENTRIES=120
VERBOSE_TOOL_ROUTING_LOGS=false
SUMMARIZE_AFTER_TURNS=30
SUMMARIZE_RECENT_KEEP=10

# Claude (Anthropic) — text LLM provider
ANTHROPIC_API_KEY=
ANTHROPIC_MODEL_ID=claude-haiku-4-5
ANTHROPIC_PRO_MODEL_ID=claude-sonnet-4-5-20250514
ANTHROPIC_MAX_TOKENS=4096

# Voice (Nova Sonic — separate from text LLM, stays on AWS)
BEDROCK_SONIC_MODEL_ID=amazon.nova-sonic-v1:0
BEDROCK_SONIC_VOICE_ID=tiffany
AWS_REGION=us-east-1
AWS_BEARER_TOKEN_BEDROCK=
AWS_PROFILE=
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_SESSION_TOKEN=
```

Keep the rest of the file (GitHub, Google, Cursor, Search, Canvas, Memory, Context Graph sections) unchanged except update the Memory section to remove `MEMORY_SUMMARY_MODEL_ID`:

```env
# Memory (S3 + Bedrock Knowledge Bases)
MEMORY_ENABLED=false
MEMORY_S3_BUCKET=
MEMORY_S3_PREFIX=memories/
MEMORY_KB_ID=
MEMORY_KB_DATA_SOURCE_ID=
MEMORY_RETRIEVE_TIMEOUT_MS=1500
MEMORY_MAX_INJECTED_CHARS=900
MEMORY_RECENT_COUNT=3
```

**Note:** The developer must also update their local `server/.env` (gitignored) with `ANTHROPIC_API_KEY` and the new env var names before running `npm run dev`.

- [ ] **Step 2: Update `CLAUDE.md`**

Update these sections:

1. **Model Providers** section: Replace the two-provider description with Claude-only.
2. **Dynamic Model Routing** section: Update to reference Anthropic model IDs.
3. **Environment Configuration** table: Update env vars (remove MODEL_PROVIDER, BEDROCK_TEXT_MODEL_ID, BEDROCK_PRO_MODEL_ID; add ANTHROPIC_MODEL_ID, ANTHROPIC_PRO_MODEL_ID, ANTHROPIC_MAX_TOKENS).
4. **Context Summarization** section: No change needed (already says "uses the LLM").
5. **MemoryService** mentions: Note it now uses ModelProvider abstraction, not direct Bedrock calls.

- [ ] **Step 3: Commit**

```bash
git add server/.env.example CLAUDE.md
git commit -m "Update env config and CLAUDE.md for Claude-only text provider"
```

---

### Task 9: Integration Validation

This task is manual — no code changes.

- [ ] **Step 1: Run full test suite**

Run: `cd server && npm test`
Expected: All tests pass

- [ ] **Step 2: Start local dev server**

Run: `cd server && npm run dev`
Expected: Server starts, logs show `provider: claude`

- [ ] **Step 3: Test normal conversation (no tools)**

Connect iOS app (or use a WebSocket client) and send a text message. Verify:
- Response streams back as `assistant.speech.partial` events
- Final `assistant.speech.final` event has complete text
- `/healthz` returns `{ "ok": true, "provider": "claude", ... }`

- [ ] **Step 4: Test tool-using turn**

Send a message that triggers a tool (e.g. "check my email" if Gmail is connected). Verify:
- Tool calls are emitted correctly
- Tool results are processed
- Follow-up response works

- [ ] **Step 5: Test title generation**

Start a new session and send a first message. Verify:
- `session.title` event is emitted with a short title
- Uses lite model (check server logs for model ID)

- [ ] **Step 6: Run smoke test**

Run: `cd server && npm run smoke`
Expected: PASS

- [ ] **Step 7: Final commit (if any fixes needed)**

```bash
git add -A
git commit -m "Fix integration issues from Claude migration validation"
```
