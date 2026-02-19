# Implementation Prompt: Server-Side LLM Tool Calling for Abyss Conductor

## Context

You are working in the repo at `/Users/bentontameling/Dev/VoiceBot2`. The relevant code is in `server/src/`. The server is a Node.js/TypeScript WebSocket conductor that sits between an iOS voice app and an LLM (Claude via Anthropic API). The server is already running — `tsx watch src/server.ts` hot-reloads on file changes.

The iOS app has 5 Cursor Cloud Agent tools fully implemented and registered in its `ToolRouter`: `agent.spawn`, `agent.status`, `agent.cancel`, `agent.followup`, `agent.list`. The iOS app will execute ANY `tool.call` event the server sends over WebSocket and reply with a `tool.result`. The server just needs to start using LLM tool calling so Claude can decide to invoke these tools.

---

## Current State (what exists today)

**`server/src/core/types.ts`** — `ModelProvider` interface only does text generation:

```typescript
interface ModelProvider {
  readonly name: string;
  generateResponse(conversation: ConversationTurn[]): Promise<ModelResponse>;
}
```

`ConversationTurn` has `role: "user" | "assistant" | "system"` and `content: string`. There is no concept of tool calls in the history.

**`server/src/providers/anthropicProvider.ts`** — Makes a plain POST to `https://api.anthropic.com/v1/messages` with `messages` and `system` fields. No `tools` field. Parses only `content[].type === "text"` blocks. Uses a 30-second `AbortSignal.timeout`.

**`server/src/core/conductorService.ts`** — `runConductorLoop()` is a single `async` function that:
1. Calls `this.provider.generateResponse(session.history)` and awaits the full response
2. Streams partial chunks to iOS via `assistant.speech.partial` events
3. Emits `assistant.speech.final`, appends to history, then fires `convo.appendMessage`, `convo.setState(speaking)`, `tts.speak`, `convo.setState(idle)` tool calls to iOS

The `tool.result` handler in `handleEvent` already logs received results and deletes them from `session.pendingToolCalls`, but does nothing with the result payload — it's stub logic only.

**`server/src/core/sessionStore.ts`** — `SessionState` already has `pendingToolCalls: Map<string, PendingToolCall>`. `PendingToolCall` has `{ callId, toolName, emittedAt }`. This map is the hook point for the suspend/resume pattern.

---

## What You Need to Build

### 1. Extend `types.ts` — Add tool calling types

Add the following to `types.ts`:

```typescript
export interface ToolDefinition {
  name: string;
  description: string;
  input_schema: {
    type: "object";
    properties: Record<string, unknown>;
    required?: string[];
  };
}

export interface ToolCallRequest {
  id: string;       // Anthropic's tool_use block id
  name: string;
  input: Record<string, unknown>;
}

// Extend ConversationTurn to support tool use in history
// role "tool" is used for tool results fed back to the model
export interface ConversationTurn {
  role: "user" | "assistant" | "system" | "tool";
  content: string | ToolCallRequest[];  // string for text, array for tool use turns
  tool_use_id?: string;   // set when role === "tool"
  tool_name?: string;     // set when role === "tool"
}

// New ModelProvider interface — extends to support tool calling
export interface ModelProvider {
  readonly name: string;
  generateResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
  ): Promise<ModelResponse>;
}

// Extend ModelResponse to include optional tool calls
export interface ModelResponse {
  fullText: string;
  chunks: AsyncIterable<string>;
  toolCalls?: ToolCallRequest[];   // present when model wants to call tools
}

// Add to SessionState:
export interface SessionState {
  sessionId: string;
  history: ConversationTurn[];
  pendingToolCalls: Map<string, PendingToolCall>;
  toolResultResolvers: Map<string, (result: string | null, error: string | null) => void>;
  recentTranscriptTrace: string[];
  transcriptCount: number;
}
```

---

### 2. Update `sessionStore.ts` — Initialize `toolResultResolvers`

In `getOrCreate()`, add to the created state object:

```typescript
toolResultResolvers: new Map(),
```

---

### 3. Update `anthropicProvider.ts` — Support tool use API

Rewrite `AnthropicProvider` to:

- Accept optional `tools?: ToolDefinition[]` in `generateResponse()`
- Include `tools` in the Anthropic API request body when provided (non-empty)
- Parse the response `content` array for both `type === "text"` blocks AND `type === "tool_use"` blocks
- Return `toolCalls` in `ModelResponse` when tool use blocks are present
- When the response is a tool use (no text), return `fullText: ""` and `toolCalls: [...]`
- Map Anthropic's `tool_use` block shape `{ id, name, input }` to `ToolCallRequest`
- Increase `max_tokens` when tools are active — suggest `Math.min(config.maxTokens * 4, 4096)` as a ceiling

**Anthropic tool use request shape:**

```json
{
  "model": "...",
  "max_tokens": 1024,
  "system": "...",
  "tools": [{ "name": "agent.spawn", "description": "...", "input_schema": { ... } }],
  "messages": [...]
}
```

**Anthropic response `content` block for tool use:**

```json
{ "type": "tool_use", "id": "toolu_abc123", "name": "agent.spawn", "input": { ... } }
```

**Message format for tool history turns** — when building the `messages` array, handle three cases:

- `role === "user" | "assistant"` with `content: string` → `{ role, content: string }` (existing)
- `role === "assistant"` with `content: ToolCallRequest[]` → `{ role: "assistant", content: [{ type: "tool_use", id, name, input }] }`
- `role === "tool"` → `{ role: "user", content: [{ type: "tool_result", tool_use_id, content }] }` (Anthropic wraps tool results in a "user" role message)

**System prompt addition:**

```
When the user asks you to work on code, create a PR, analyze a repository, or run any coding task, use the agent.spawn tool. By default set autoCreatePr: false and autoBranch: false unless the user explicitly asks to create a PR or branch. Always confirm the repository with the user if not specified.
```

---

### 4. Update `conductorService.ts` — Suspend/resume conductor loop

#### Define agent tool schemas as a module-level constant

```typescript
const AGENT_TOOLS: ToolDefinition[] = [
  {
    name: "agent.spawn",
    description: "Launch a new Cursor Cloud Agent to work on a repository. Use for coding tasks, PR creation, analysis. Requires a prompt and either repository (format: owner/repo) or prUrl.",
    input_schema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "The task for the agent to perform" },
        repository: { type: "string", description: "GitHub repository in owner/repo format" },
        ref: { type: "string", description: "Git ref/branch to work from" },
        prUrl: { type: "string", description: "Existing PR URL to work on instead of a repo" },
        model: { type: "string", description: "Model to use (optional)" },
        autoCreatePr: { type: "boolean", description: "Whether to auto-create a PR. Default false for safety." },
        autoBranch: { type: "boolean", description: "Whether to auto-create a branch. Default false for safety." },
        skipReviewerRequest: { type: "boolean" },
        branchName: { type: "string" }
      },
      required: ["prompt"]
    }
  },
  {
    name: "agent.status",
    description: "Get the current status of a running Cursor Cloud Agent by its ID.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID returned from agent.spawn" }
      },
      required: ["id"]
    }
  },
  {
    name: "agent.cancel",
    description: "Stop a running Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID to cancel" }
      },
      required: ["id"]
    }
  },
  {
    name: "agent.followup",
    description: "Add a follow-up instruction to an existing Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID" },
        prompt: { type: "string", description: "Follow-up instruction" }
      },
      required: ["id", "prompt"]
    }
  },
  {
    name: "agent.list",
    description: "List Cursor Cloud Agents for the authenticated user.",
    input_schema: {
      type: "object",
      properties: {
        limit: { type: "number" },
        cursor: { type: "string" },
        prUrl: { type: "string" }
      }
    }
  }
];
```

#### Add `waitForToolResult` helper function

```typescript
function waitForToolResult(
  session: SessionState,
  callId: string,
  timeoutMs: number,
): Promise<{ result: string | null; error: string | null }> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      session.toolResultResolvers.delete(callId);
      resolve({ result: null, error: "tool_result_timeout" });
    }, timeoutMs);

    session.toolResultResolvers.set(callId, (result, error) => {
      clearTimeout(timer);
      session.toolResultResolvers.delete(callId);
      resolve({ result, error });
    });
  });
}
```

#### Rewrite `runConductorLoop` as a multi-turn loop

```typescript
private async runConductorLoop(
  session: SessionState,
  transcript: string,
  emit: (event: EventEnvelope) => void,
  sourceEventId: string,
): Promise<void> {
  session.transcriptCount += 1;
  session.recentTranscriptTrace = [];

  // ... existing tracePush and emitToolCall helpers ...

  this.sessions.appendTurn(session, { role: "user", content: transcript });
  emitToolCall("convo.setState", { state: "thinking" });
  emitToolCall("convo.appendMessage", { role: "user", text: transcript, isPartial: false });

  const MAX_TOOL_ROUNDS = 8;
  let toolRound = 0;

  while (toolRound < MAX_TOOL_ROUNDS) {
    toolRound++;

    let modelResponse: ModelResponse;
    try {
      modelResponse = await this.provider.generateResponse(session.history, AGENT_TOOLS);
    } catch (error) {
      // ... existing error handling: emit error event, convo.setState(idle), return ...
    }

    if (modelResponse.toolCalls && modelResponse.toolCalls.length > 0) {
      // Append assistant's tool_use turn to history so the model sees it next round
      session.history.push({ role: "assistant", content: modelResponse.toolCalls });

      for (const tc of modelResponse.toolCalls) {
        const callId = crypto.randomUUID();
        const envelope = makeEvent("tool.call", session.sessionId, {
          callId,
          name: tc.name,
          arguments: JSON.stringify(tc.input),
        });
        session.pendingToolCalls.set(callId, { callId, toolName: tc.name, emittedAt: envelope.timestamp });
        emit(envelope);
        tracePush(`tool.call:${tc.name}`);

        // Suspend until iOS sends tool.result (30s timeout)
        const { result, error } = await waitForToolResult(session, callId, 30_000);

        // Append tool result to history for the next LLM turn
        session.history.push({
          role: "tool",
          content: result ?? `Error: ${error ?? "unknown"}`,
          tool_use_id: tc.id,
          tool_name: tc.name,
        });
      }
      // Loop: LLM now sees tool results and decides what to do next

    } else {
      // Text response — proceed with speech as before
      let responseText = "";
      for await (const chunk of modelResponse.chunks) {
        responseText += chunk;
        emit(makeEvent("assistant.speech.partial", session.sessionId, { text: responseText }));
        tracePush("assistant.speech.partial");
      }
      if (!responseText.trim()) {
        responseText = modelResponse.fullText;
      }
      responseText = responseText.trim();

      emit(makeEvent("assistant.speech.final", session.sessionId, { text: responseText }));
      tracePush("assistant.speech.final");
      this.sessions.appendTurn(session, { role: "assistant", content: responseText });
      emitToolCall("convo.appendMessage", { role: "assistant", text: responseText, isPartial: false });
      emitToolCall("convo.setState", { state: "speaking" });
      emitToolCall("tts.speak", { text: responseText });
      emitToolCall("convo.setState", { state: "idle" });
      break;
    }
  }

  logger.info(
    `transcript.final trace #${session.transcriptCount}: ${session.recentTranscriptTrace.join(" -> ")}`,
    { sessionId: session.sessionId, eventId: sourceEventId },
  );
}
```

#### Update the `tool.result` handler to unblock the conductor loop

In `handleEvent`, the `tool.result` case must now call the resolver if one is registered:

```typescript
case "tool.result": {
  const callId = asString(event.payload.callId);
  const resultPayload = asString(event.payload.result);
  const errorText = asString(event.payload.error);

  if (callId) {
    const pending = session.pendingToolCalls.get(callId);
    session.pendingToolCalls.delete(callId);
    logger.info(
      errorText ? `tool.result error: ${errorText}` : "tool.result ok",
      { sessionId: session.sessionId, eventId: event.id, callId, trace: pending?.toolName },
    );

    // Unblock the conductor loop if it is waiting for this result
    const resolver = session.toolResultResolvers.get(callId);
    if (resolver) {
      resolver(resultPayload ?? null, errorText ?? null);
    }
  }
  return;
}
```

---

## Files to Modify

| File | Change |
|------|--------|
| `server/src/core/types.ts` | Add `ToolDefinition`, `ToolCallRequest`, extend `ConversationTurn`, `ModelProvider`, `ModelResponse`, add `toolResultResolvers` to `SessionState` |
| `server/src/core/sessionStore.ts` | Initialize `toolResultResolvers: new Map()` in `getOrCreate()` |
| `server/src/core/conductorService.ts` | Add `AGENT_TOOLS` constant, add `waitForToolResult` helper, rewrite `runConductorLoop` as multi-turn loop, wire `tool.result` resolver |
| `server/src/providers/anthropicProvider.ts` | Add `tools` parameter, parse `tool_use` blocks, build correct message format for tool history, update system prompt |

## Files to Leave Unchanged

- `server/src/server.ts`
- `server/src/providers/bedrockNovaProvider.ts` — just add the optional `tools` param and ignore it
- `server/src/core/events.ts`
- `server/src/core/rateLimiter.ts`
- All iOS Swift files — the iOS side is already complete

---

## Constraints

- Keep TypeScript strict. Use `unknown` and narrow rather than `any` for Anthropic API response shapes.
- `tsx watch` hot-reloads on save — no manual server restarts needed during development.
- The `MAX_TURNS` env var (default `20`) still applies as a history sliding window via `sessionStore.appendTurn`.
- The tool calling loop has its own `MAX_TOOL_ROUNDS = 8` guard to prevent runaway loops.
- All existing behavior for non-tool responses (streaming `assistant.speech.partial` chunks, `tts.speak`, etc.) must remain exactly unchanged.
