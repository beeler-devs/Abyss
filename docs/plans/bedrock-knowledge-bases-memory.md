# BEE-45: Bedrock Knowledge Bases — Semantic Conversation Memory

## Overview

Add persistent, semantically-searchable memory to Abyss using AWS Bedrock Knowledge Bases. When a session ends, key facts and decisions are summarized and stored in S3, indexed by Bedrock Knowledge Bases, and retrieved at the start of future sessions to give the assistant prior context.

---

## Architecture

```
Session ends
    │
    ▼
MemoryService.summarizeAndStore(sessionId, history)
    │
    ├── Nova generates a summary → S3 (abyss-memory bucket)
    │
    └── Bedrock KB sync job picks up new S3 document
            │
            ▼
        OpenSearch Serverless (vector store)

New session starts
    │
    ▼
MemoryService.retrieveContext(sessionId, firstMessage?)
    │
    └── Bedrock KB RetrieveAndGenerate → injects into system prompt
```

---

## Integration Points with Existing Code

### 1. `SessionStore` (server/src/core/sessionStore.ts)
- `getOrCreate()` is the session creation point — this is where we inject retrieved memory into the initial system prompt turn
- `appendTurn()` tracks history — no changes needed here
- The session `history: ConversationTurn[]` is the source material for summarization

### 2. `ConductorService` (server/src/core/conductorService.ts)
- Add `memoryService?: MemoryService` to `ConductorServiceDependencies`
- On `handleEvent` for `user.speech.final` — if it's the **first turn** of a session, call `memoryService.retrieveContext()` and prepend results as a system turn in history before calling the LLM
- Add a `finalizeSession(sessionId)` method that triggers summarization — called from `server.ts` on WebSocket close

### 3. `server.ts`
- On WebSocket `close` event (iOS disconnect) — call `conductor.finalizeSession(sessionId)` after the existing `voiceProvider.closeSession()` call
- Pass `memoryService` into `ConductorService` constructor
- Add `MEMORY_BUCKET_NAME`, `MEMORY_KB_ID`, `MEMORY_ENABLED` env vars

### 4. New file: `server/src/core/memory/memoryService.ts`
- Self-contained module, injected as a dependency — no coupling to voice, bridge, or Cursor systems
- Optional: if `MEMORY_ENABLED` is false or KB is not configured, all methods are no-ops

---

## Implementation Plan

### Phase 1 — AWS Infrastructure

**S3 Bucket**
```
Bucket: abyss-memory
Region: us-east-1
Prefix structure: memories/{sessionId}/{timestamp}.json
```

Document schema stored in S3:
```json
{
  "sessionId": "abc123",
  "timestamp": "2026-03-15T20:00:00Z",
  "summary": "User worked on auth refactor. Decided to use JWT with 24h expiry. Branch: feature/auth-v2. Nova Sonic hands-free mode was working correctly.",
  "topics": ["auth", "jwt", "nova-sonic"],
  "toolsUsed": ["bridge.git.commit", "agent.spawn"],
  "turnCount": 14
}
```

**Bedrock Knowledge Base**
- Data source: S3 bucket `abyss-memory`
- Embedding model: `amazon.titan-embed-text-v2:0`
- Vector store: Amazon OpenSearch Serverless (auto-provisioned by Bedrock KB)
- Sync: on-demand after each new S3 document is written (call `StartIngestionJob` API)

**IAM — add to `abyss-ecs-task-role`**
```json
{
  "Effect": "Allow",
  "Action": [
    "s3:PutObject", "s3:GetObject", "s3:ListBucket",
    "bedrock:RetrieveAndGenerate", "bedrock:Retrieve",
    "bedrock:StartIngestionJob"
  ],
  "Resource": [
    "arn:aws:s3:::abyss-memory/*",
    "arn:aws:bedrock:us-east-1::knowledge-base/*"
  ]
}
```

---

### Phase 2 — `MemoryService` Module

**File:** `server/src/core/memory/memoryService.ts`

```typescript
export interface MemoryServiceConfig {
  bucketName: string;
  knowledgeBaseId: string;
  region: string;
  modelArn: string; // e.g. "arn:aws:bedrock:us-east-1::foundation-model/us.amazon.nova-2-lite-v1:0"
}

export class MemoryService {
  constructor(private config: MemoryServiceConfig) {}

  // Called at session end — summarize history and store to S3
  async summarizeAndStore(
    sessionId: string,
    history: ConversationTurn[],
  ): Promise<void>

  // Called at session start — retrieve relevant prior context
  // Returns a formatted string to inject as a system prompt addition
  async retrieveContext(
    sessionId: string,
    firstMessage?: string,
  ): Promise<string | null>
}
```

**`summarizeAndStore` flow:**
1. Filter history to only `user` and `assistant` turns (skip tool calls/results for brevity)
2. If fewer than 3 turns, skip (not worth summarizing a short session)
3. Call Nova (via AWS Bedrock `InvokeModel`) with a summarization prompt:
   > "Summarize this conversation in 3-5 sentences. Focus on: what was accomplished, decisions made, tools used, and any important context for future sessions."
4. Write the resulting JSON document to S3
5. Call `StartIngestionJob` to trigger KB re-sync

**`retrieveContext` flow:**
1. Call Bedrock KB `Retrieve` API with query: `"Recent work and context for this user"` (optionally include the first message as the query for better relevance)
2. Take top 3 results, format as:
   > "Prior context from past sessions: [summary 1]. [summary 2]..."
3. Return the formatted string — caller injects it as a system `ConversationTurn` before the first user message

---

### Phase 3 — ConductorService Integration

**In `ConductorServiceDependencies`:**
```typescript
export interface ConductorServiceDependencies {
  // ... existing fields ...
  memoryService?: MemoryService;
}
```

**In `handleEvent` — inject memory on first turn:**
```typescript
// In the user.speech.final handler, before calling the LLM:
const session = this.sessionStore.getOrCreate(event.sessionId);
if (session.history.length === 0 && this.deps.memoryService) {
  const priorContext = await this.deps.memoryService.retrieveContext(
    event.sessionId,
    speechText,
  );
  if (priorContext) {
    this.sessionStore.appendTurn(session, {
      role: "system",
      content: priorContext,
    });
  }
}
```

**New public method `finalizeSession`:**
```typescript
async finalizeSession(sessionId: string): Promise<void> {
  if (!this.deps.memoryService) return;
  const session = this.sessionStore.getOrCreate(sessionId);
  if (session.history.length < 3) return;
  await this.deps.memoryService.summarizeAndStore(sessionId, session.history);
}
```

---

### Phase 4 — server.ts Wiring

**On iOS socket close:**
```typescript
socket.on("close", () => {
  const context = socketContexts.get(socket);
  if (context?.kind === "ios" && context.sessionId) {
    // ... existing cleanup ...
    void conductor.finalizeSession(context.sessionId); // NEW
  }
  // ... rest of close handler ...
});
```

**New env vars in `.env.example`:**
```
MEMORY_ENABLED=false
MEMORY_BUCKET_NAME=abyss-memory
MEMORY_KB_ID=                   # Bedrock Knowledge Base ID (from AWS console)
MEMORY_MODEL_ARN=arn:aws:bedrock:us-east-1::foundation-model/us.amazon.nova-2-lite-v1:0
```

**Constructor in `server.ts`:**
```typescript
const memoryService = parseBoolean(process.env.MEMORY_ENABLED, false)
  ? new MemoryService({
      bucketName: process.env.MEMORY_BUCKET_NAME ?? "abyss-memory",
      knowledgeBaseId: process.env.MEMORY_KB_ID ?? "",
      region: process.env.AWS_REGION ?? "us-east-1",
      modelArn: process.env.MEMORY_MODEL_ARN ?? "...",
    })
  : undefined;

const conductor = new ConductorService(provider, config, {
  // ... existing deps ...
  memoryService,
});
```

---

### Phase 5 — iOS (Optional Polish)

No functional iOS changes are required. The memory is transparent — the LLM simply has more context. Optional additions:

- A small "memory active" indicator in the conversation header when prior context was injected (server can emit a `session.memory.loaded` event on first turn with retrieved context)
- The existing `ConversationViewModel` event handling can listen for this and show a subtle UI hint

---

## Environment Variables Summary

| Variable | Default | Notes |
|---|---|---|
| `MEMORY_ENABLED` | `false` | Set to `true` to enable memory |
| `MEMORY_BUCKET_NAME` | `abyss-memory` | S3 bucket for conversation summaries |
| `MEMORY_KB_ID` | — | Bedrock Knowledge Base ID |
| `MEMORY_MODEL_ARN` | Nova 2 Lite ARN | Model used for summarization and retrieval |

---

## AWS Services Used

| Service | Purpose |
|---|---|
| Amazon S3 | Stores raw conversation summary documents |
| Amazon Bedrock Knowledge Bases | Manages chunking, embeddings, and vector indexing |
| Amazon OpenSearch Serverless | Vector store (auto-managed by Bedrock KB) |
| Amazon Titan Embed Text v2 | Embedding model for semantic search |
| Amazon Nova 2 Lite | Summarization LLM (reuses existing Bedrock setup) |

---

## What to Avoid

- **Do not** store full conversation history in S3 — only summaries. Full history is PII-sensitive and expensive to index.
- **Do not** block the session close on summarization — fire-and-forget with `void`.
- **Do not** block the first LLM call if KB retrieval is slow — set a 2s timeout on `retrieveContext` and proceed without context if it times out.
- **Do not** change the `ConversationTurn` type or `SessionStore` interface — memory is injected as a standard system turn, using existing infrastructure.

---

## Testing

- Unit test `MemoryService` with mocked S3 and Bedrock clients
- Integration test: mock KB returns a prior summary → verify it appears as a system turn before the first user message in `conductorService`
- Gate behind `MEMORY_ENABLED=false` default so existing tests are unaffected
