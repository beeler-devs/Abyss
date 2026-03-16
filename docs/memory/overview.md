# Memory System Overview

The memory system gives the assistant context from prior sessions. When an iOS WebSocket session ends, a structured summary is stored in S3. When a new session begins, recent summaries are retrieved and injected into the system prompt before the first LLM call.

## Why `memoryUserKey` instead of `sessionId`

`sessionId` is generated fresh on every WebSocket connection. A single user reconnecting after a network drop gets a new `sessionId`, so memory keyed by `sessionId` would never be found on reconnect.

`memoryUserKey` is a stable identifier chosen by the iOS client (e.g. a hashed device ID or user account ID) and sent in the `session.start` payload. It stays the same across reconnects and app restarts, so memories written under one session are retrievable in the next.

## How It Works

```
session.start (with memoryUserKey)
    │
    ▼
first user.speech.final
    │
    └── MemoryService.retrieveContext(memoryUserKey, firstUtterance?)
            ├── S3 list recent summaries → fetch top N (fast path, always runs)
            └── Bedrock KB Retrieve (semantic, optional — runs if KB configured)
                    │
                    ▼
            inject as user turn (prefixed "[Prior context from previous sessions]") before first LLM call

... conversation ...

iOS socket closes
    │
    └── MemoryService.summarizeAndStore(memoryUserKey, sessionId, history)
            ├── Nova 2 Lite generates structured JSON summary
            └── S3 PutObject → optional KB ingestion job triggered
```

## Two Retrieval Modes

**S3 recent-memory fast path** (always active when `MEMORY_ENABLED=true`): lists the most recent `MEMORY_RECENT_COUNT` objects under `memories/{memoryUserKey}/`, fetches them in parallel, formats the summaries into a short context block. No KB required.

**Bedrock KB semantic search** (optional): if `MEMORY_KB_ID` is set and a first-turn transcript is available, a `Retrieve` call finds semantically relevant memories beyond just the most recent ones. Useful for users with long history where the most relevant session was not the most recent.

Both paths share a single `MEMORY_RETRIEVE_TIMEOUT_MS` budget (default 1500ms). If retrieval exceeds the budget, it returns `null` and the session proceeds without prior context — the user is never blocked.

## Why Full Transcripts Are Never Stored

- **Privacy**: full conversation history is PII-sensitive. Structured summaries contain only what is actionable.
- **Cost**: raw transcripts are large. Storing many sessions per user in S3 and indexing them in a vector store would be expensive.
- **Signal quality**: KB semantic search works better on dense, structured summaries than on verbose raw transcripts.

The summarization prompt explicitly requests: goal/task, repo/branch, decisions, blockers, and next steps. Tool call details are replaced with `[tool: name]` placeholders.

Sessions with fewer than 3 user turns (or no tool calls or decision keywords) are not summarized — they are considered too short to be worth storing.

## Feature Flag

Memory is **off by default**. Set `MEMORY_ENABLED=true` to enable it. All `MemoryService` methods return early without AWS calls when disabled, so existing sessions are completely unaffected.
