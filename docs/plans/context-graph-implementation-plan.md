# Abyss Context Graph & Knowledge Graph Implementation Plan

## Status of this plan

**Last verified against codebase: 2026-03-16**

This document is a **repo-specific implementation plan** for adding **context graphs / knowledge graphs** to Abyss. It is tailored to the current codebase shape:

- `ConductorService` (2,774 lines) owns the tool-calling loop, conversation orchestration, and 60+ server-side tools.
- `SessionStore` owns per-session history and execution state — already has `get()`, Cursor run tracking, and webhook queues.
- `server.ts` (876 lines) wires providers, sockets, bridge routing, and cleanup — already calls `conductor.finalizeSession()` on iOS disconnect.
- Abyss Bridge already supports streaming command execution, cancellation, file search, read-range, patching, git tooling, and Claude Code runs.
- Cursor, Gmail, GitHub, Google Calendar, and Canvas LMS are already integrated as optional server-side subsystems.
- **A `MemoryService` already exists** (`server/src/core/memory/memoryService.ts`) with S3 storage, Bedrock KB semantic retrieval, LLM-powered session summarization, and context injection on first transcript. The context graph must **compose with** this system, not duplicate it.

The plan synthesizes research around **graph-based RAG / context graphs / memory graphs / agent planning graphs**, especially:

- **Microsoft GraphRAG**
- **LangGraph**
- **LlamaIndex KnowledgeGraphIndex / property graph retrieval**
- **Neo4j + LLM graph retrieval patterns**
- **MemGPT / memory-tiered agent designs**
- graph-augmented conversational memory and graph-structured retrieval literature

---

## 1. Why Abyss should use a context graph

Abyss is not a normal chat app. It is a **voice-first, tool-calling, agentic development environment**.

That means the most valuable context is not just raw past conversation text. The most valuable context is the **relationship structure** between:

- the user's goals
- repos / branches / PRs
- files / symbols / tests
- bridge command runs
- cursor agent runs
- decisions / blockers / next steps
- browser validation runs
- memory summaries across sessions

A vector index alone can answer questions like:

- "Find semantically similar past work about auth."

But it is much weaker at answering questions like:

- "What repo and branch was the user in when they fixed the checkout failure?"
- "Which file edits were associated with the bridge test run that passed?"
- "What blocker is currently preventing merge of the PR that came from the latest Cursor run?"
- "What is the shortest path from the user's current goal to the most relevant test, file, decision, and open next step?"

Those are **graph questions**.

### 1.1 The specific value for Abyss

A context graph gives Abyss four things that fit the product directly:

1. **Resume continuity**
   - "You were working on `feature/auth-v2` in `storefront-web`; tests passed locally, but checkout validation still needs rerun."

2. **Execution-aware retrieval**
   - retrieve not only text, but also the chain of execution: user intent -> tool call -> file -> test -> result -> decision.

3. **Better long-horizon agent planning**
   - a graph can represent active work state, dependencies, blockers, and next steps in a more controllable way than stuffing everything into a prompt.

4. **Technical depth for the hackathon**
   - graph-augmented retrieval and graph memory are much more novel and defensible than a vanilla vector-memory layer.

---

## 2. What the current codebase already gives us

The graph system should **compose with** the existing architecture, not replace it.

### 2.1 Existing MemoryService — what's already built

**This is critical context the graph design must account for.** `server/src/core/memory/memoryService.ts` already implements:

- **S3-backed episodic memory**: `MemoryDocument` objects stored as JSON at `{prefix}{memoryUserKey}/{timestamp}-{sessionId}.json`
- **LLM-powered summarization**: Bedrock Nova extracts `summary`, `decisions[]`, `blockers[]`, `nextSteps[]` from conversation history
- **WorkingContext capture**: Already stores `repo`, `branch`, `prUrl`, `lastGoal`, `activeExecutor`
- **Timeout-protected retrieval**: Cascading timeout budgets across S3 list, fetch, and KB stages (default 1500ms total)
- **Bedrock KB semantic search**: Vector retrieval over S3 docs with deduplication by sessionId
- **Context injection**: Formatted as `"Prior context: • [date] summary..."` prepended as a user turn
- **Meaningful-conversation gating**: Only stores sessions with 3+ user turns OR tool calls OR decision/blocker keywords

**The `ContextGraphService` should wrap `MemoryService`, not replace it.** The existing S3 + KB pipeline is the long-term memory tier. The graph adds structural relationships on top.

### 2.2 Existing SessionState — already has graph-relevant fields

`SessionState` (in `server/src/core/types.ts`) **already has**:

- `memoryUserKey?: string` — user identifier for cross-session memory
- `memoryHydrated?: boolean` — true after first memory retrieval
- `workingContext?: { repo, branch, prUrl, lastGoal, activeExecutor }` — already populated
- `activeBridgeCommandId?: string` / `activeBridgeDeviceId?: string`
- `userPreferences?: Record<string, string>`

**Do not re-add these fields.** The graph needs only a few new additions:
- `graphContextCache?: string` — cached graph-derived context for mid-session use
- `lastGraphQueryTs?: number` — to throttle graph queries

### 2.3 ConductorService is the graph event source

`server/src/core/conductorService.ts` already sees:

- the first user utterance (`user.audio.transcript.final`)
- every model tool call (inside `runConductorLoop`, up to 8 tool rounds)
- every tool result (both server-side and iOS/bridge results)
- bridge tool execution routing (via `bridgeToolExecutor` callback)
- Cursor server-side agent creation/status/webhooks (`handleCursorWebhook`)
- GitHub PR/issue operations (9 tools)
- agent completion and follow-up summarization
- bridge interruption / cancel flows
- **Session finalization** — `finalizeSession(sessionId)` already calls `memoryService.summarizeAndStore()`

The conductor also already runs **fire-and-forget context summarization** via `trySummarizeHistory()` after each `runConductorLoop()` — compresses old turns when history exceeds 30 entries.

### 2.4 SessionStore already has `get()` and Cursor tracking

`SessionStore` (145 lines) already provides:

- `get(sessionId)` — returns `SessionState | undefined`
- `getOrCreate(sessionId)` — auto-creates if missing
- `appendTurn(session, turn)` — bounds history to `maxTurns * 2`
- Cursor agent run tracking: `upsertCursorRun`, `getCursorRun`, `getSessionIdForAgent`
- Cursor webhook queue: `storePendingWebhook`, `takePendingWebhook`

**Do not add `get()` or `delete()` — they already exist.**

### 2.5 server.ts already handles session lifecycle

`server.ts` already:

- Constructs all dependencies including `MemoryService` with full config
- Calls `conductor.finalizeSession(context.sessionId)` on iOS WebSocket close
- Handles bridge device registration, status changes, and disconnect cleanup

**Session finalization graph writes should extend `conductor.finalizeSession()`, not add a parallel path in `server.ts`.**

### 2.6 Bridge v1 gives us rich execution signals

Bridge v1 already exposes entities that should feed the context graph:

- `bridge.exec.start` / `bridge.exec.output` / `bridge.exec.finished`
- `bridge.fs.search` / `bridge.fs.readRange` / `bridge.fs.applyPatch`
- `bridge.git.status` / `bridge.git.diff` / `bridge.git.stage` / `bridge.git.commit` / `bridge.git.push`
- `bridge.claude.run` — with JSON-line tool progress parsing

The `BridgeToolRouter` already tracks:
- `activeCommandBySession` — current command per session
- `activeClaudeRunsByDeviceId` — Claude Code runs with timeout
- `pendingByCallId` — in-flight tool calls
- Command lifecycle with exit codes, stdout/stderr tails

### 2.7 GitHub integration (not in original plan)

The codebase now has a full `GitHubClient` with 9 tools:
- PR: `github.pr.list`, `github.pr.get`, `github.pr.reviews`, `github.pr.create`, `github.pr.merge`
- Issues: `github.issues.list`, `github.issues.create`
- Actions: `github.actions.status`
- Repos: `github.repos.list`

These are **high-value graph event sources** — PR creation/merge events, action results, and issue tracking should all feed the graph.

---

## 3. Research synthesis: what to borrow from existing graph-memory systems

This section turns the research landscape into concrete design guidance for Abyss.

## 3.1 Microsoft GraphRAG: use graph structure to organize long context

The GraphRAG family of ideas is useful for Abyss because it emphasizes:

- extracting entities and relationships from raw text or documents
- building graph structure over those entities
- using graph traversals / community summaries / hierarchical retrieval to answer questions that are hard for flat chunk retrieval

### What Abyss should borrow

Abyss should **not** copy GraphRAG wholesale. But it should borrow these ideas:

1. **Entity extraction into typed graph nodes**
   - repo, branch, PR, file, symbol, test, tool invocation, agent run, decision, blocker, next step

2. **Edge-centric retrieval**
   - not just "find similar text", but "find the repo/branch/test/file chain around this goal"

3. **Multi-hop retrieval for developer workflows**
   - current_goal -> decision -> branch -> failing_test -> file -> patch -> PR

4. **Graph summaries**
   - precompute short graph-derived summaries at session boundaries or task boundaries

### What Abyss should avoid

Avoid a giant entity-extraction batch pipeline over every raw utterance. For hackathon scope, a lot of the highest-value graph edges should come from **structured product events**, not from freeform extraction.

---

## 3.2 LangGraph: use graph thinking for stateful orchestration, not only retrieval

LangGraph is useful less because of its APIs and more because of its **mental model**:

- stateful agents
- explicit nodes / edges in execution flow
- resumable and inspectable graph-like workflows

### What Abyss should borrow

Use the graph not only as a retrieval layer, but also as an **execution memory substrate**:

- represent agent runs and bridge runs as graph nodes
- represent transitions and dependencies explicitly
- make the graph support resumability:
  - `Goal -> AgentRun -> ToolInvocation -> Artifact -> Decision -> NextStep`

This matches Abyss's existing event-driven architecture better than a plain memory cache.

---

## 3.3 LlamaIndex / Neo4j / knowledge-graph RAG patterns: hybrid graph + vector is the right design

The strongest production pattern across graph-RAG systems is **hybrid retrieval**:

- semantic vector lookup to find candidate neighborhoods
- graph traversal to refine and explain relationships
- optional graph summaries to compress long histories

### What Abyss should borrow

For Abyss, graph retrieval should almost never run alone.

Instead:

1. use semantic retrieval to find likely relevant nodes / memories / artifacts
2. expand the local neighborhood via graph traversal
3. re-rank by recency + execution relevance + graph proximity
4. format a compact context bundle for the conductor

That will outperform both:
- vector-only memory, and
- graph-only exact traversal

for the messy reality of developer workflows.

---

## 3.4 MemGPT / memory-tiered systems: use multiple memory tiers

Abyss should use **memory tiers**, not one giant memory bucket.

### Recommended tiers (mapped to existing + new systems)

1. **Working memory** (already exists)
   - current session in `SessionStore`
   - `session.history` + `session.historySummary` (via `contextSummarizer`)
   - what the current run/tool loop is doing now

2. **Operational graph memory** (new — the context graph)
   - live graph for current repo / task / branch / PR state
   - stored in graph DB or graph tables
   - populated from structured events, not LLM extraction

3. **Long-term episodic memory** (already exists — `MemoryService`)
   - session summaries / decisions / blockers / next steps
   - stored in S3 and indexed semantically via Bedrock KB
   - `MemoryDocument` format with structured fields

The graph is the **new middle tier** that bridges working memory and long-term memory.

---

## 4. Why vector-only RAG is not enough for Abyss

## 4.1 Where vector RAG helps

Vector retrieval is good for:

- semantically similar past tasks
- "find auth-related memories"
- pulling docs or conversation summaries into prompts

## 4.2 Where vector RAG breaks down in Abyss

Abyss is full of structured relationships that matter operationally:

- a branch belongs to a repo
- a PR belongs to a branch
- a file was changed by a patch
- a test failed before a patch and passed after another command
- a blocker belongs to a goal
- a next step follows a specific decision
- a bridge command belongs to a specific device/workspace

Vector search does not naturally preserve these relationships.

### Example failure mode

Query:
- "What should we do next for the auth work?"

Vector-only retrieval might fetch:
- a memory summary mentioning auth
- a diff mentioning refresh tokens
- an old conversation mentioning JWT expiry

But it may miss the actual live workflow chain:

- current repo = storefront-web
- current branch = feature/auth-v2
- last bridge exec succeeded = `npm test auth`
- last unresolved blocker = rerun checkout validation
- open PR = #42

That chain is graph-native.

---

## 5. The Abyss context graph: target architecture

## 5.1 Core principle

The Abyss context graph should be an **operational knowledge graph** built from **structured events first** and **LLM extraction second**.

That means:

- every tool call / result / agent event / bridge event can update the graph
- end-of-session memory summarization can add higher-level semantic nodes
- graph retrieval can power both memory injection and execution planning

## 5.2 High-level architecture

```text
                  +-----------------------------+
                  |         iOS Client          |
                  |  voice, UI, timeline, TTS   |
                  +-------------+---------------+
                                |
                                v
+------------------+   events / tools   +-----------------------------+
|  Abyss Bridge    | <----------------> |       ConductorService       |
| macOS execution  |                    |   tool loop + orchestration  |
+------------------+                    +------+-----------------------+
                                               |
                                               v
                                +-----------------------------+
                                |    ContextGraphService      |
                                |  graph updates + queries    |
                                |  wraps MemoryService        |
                                +--+-------+----------+------+
                                   |       |          |
                                   v       v          v
                   +----------------+ +---------+ +-----------+
                   | Neptune        | | S3      | | Bedrock   |
                   | Analytics      | | Memory  | | KB        |
                   | (graph+vector) | | (exist) | | (exist)   |
                   +-------+--------+ +---------+ +-----------+
                           |
                           v
                   +----------------+
                   | Titan Embed V2 |
                   | (via Bedrock)  |
                   | 256-dim vecs   |
                   +----------------+
```

**Architecture principles:**

1. `ContextGraphService` is a **single service that composes** Neptune Analytics with the existing `MemoryService`. The conductor talks to `ContextGraphService` only.
2. **Neptune Analytics** is both the graph store AND the vector index — no separate vector DB needed. Hybrid openCypher queries do graph traversal + vector similarity in one call.
3. **Titan Text Embeddings V2** generates 256-dimension embeddings for graph nodes (goals, episodes, decisions, blockers) and query-time embeddings for the user's utterance.
4. **S3 + Bedrock KB** (existing `MemoryService`) is retained as a fallback and for raw document storage.

---

## 6. Graph data model tailored to Abyss

## 6.1 Design goals

The graph model should:

- reflect current product concepts exactly
- be updatable from existing structured events
- support retrieval for both resume context and agent planning
- be simple enough for a hackathon MVP
- **separate MVP nodes from future-phase nodes clearly**

## 6.2 Node types

### MVP nodes (Phase 0–1)

#### Identity / session layer

- `User`
  - `memoryUserKey`

- `Session`
  - `sessionId`
  - `startedAt`
  - `endedAt`
  - `provider` (`anthropic`, `bedrock`)

#### Project layer

- `Repo`
  - `repoName`, `owner`

- `Branch`
  - `branchName`

- `PullRequest`
  - `prUrl`, `prNumber`, `status`

#### Execution layer

- `Goal`
  - normalized user objective (from `workingContext.lastGoal`)

#### Memory / planning layer

- `Decision`
- `Blocker`
- `NextStep`
- `MemoryEpisode`
  - the session-level or task-level summary document (links to S3 `MemoryDocument`)

### Phase 2 nodes (operational graph)

- `ToolInvocation`
  - tool name, callId, args hash, outcome

- `BridgeCommandRun`
  - commandId, command, cwd, start/end/exitCode

- `CursorAgentRun`
  - agentId, mode, status, runUrl, prUrl

- `Artifact`
  - logs, diff summaries, traces

- `Workspace`
  - bridge workspace root (from `BridgeDeviceRecord.workspaceRoot`)

### Phase 3 nodes (code context)

- `File`
  - path, extension, repo

- `Symbol`
  - function/class/module identifier

- `Test`
  - test name, suite, file path

- `Patch`
  - patch id / commit / summary

### Removed from original plan

- ~~`Device`~~ — bridge device info is ephemeral session state in `BridgeStateStore`, not worth persisting in the graph
- ~~`WebValidationRun`~~ — no web validation system exists in the codebase yet

## 6.3 Edge types

### MVP edges (Phase 0–1)

#### Identity/session edges

- `(:User)-[:STARTED]->(:Session)`
- `(:Session)-[:WORKED_ON]->(:Repo)`

#### Project edges

- `(:Repo)-[:HAS_BRANCH]->(:Branch)`
- `(:Branch)-[:HAS_PR]->(:PullRequest)`

#### Execution edges

- `(:Session)-[:HAS_GOAL]->(:Goal)`

#### Planning / memory edges

- `(:Goal)-[:LED_TO]->(:Decision)`
- `(:Goal)-[:BLOCKED_BY]->(:Blocker)`
- `(:Goal)-[:NEXT_ACTION]->(:NextStep)`
- `(:Session)-[:SUMMARIZED_AS]->(:MemoryEpisode)`
- `(:MemoryEpisode)-[:ABOUT]->(:Repo)`
- `(:MemoryEpisode)-[:ABOUT_BRANCH]->(:Branch)`
- `(:MemoryEpisode)-[:NOTES_DECISION]->(:Decision)`
- `(:MemoryEpisode)-[:NOTES_BLOCKER]->(:Blocker)`
- `(:MemoryEpisode)-[:NOTES_NEXT_STEP]->(:NextStep)`

### Phase 2 edges (operational)

- `(:Goal)-[:EXECUTED_VIA]->(:ToolInvocation)`
- `(:Session)-[:INVOKED]->(:ToolInvocation)`
- `(:ToolInvocation)-[:SPAWNED]->(:CursorAgentRun)`
- `(:ToolInvocation)-[:STARTED]->(:BridgeCommandRun)`
- `(:BridgeCommandRun)-[:PRODUCED]->(:Artifact)`
- `(:BridgeCommandRun)-[:RAN_IN]->(:Workspace)`
- `(:CursorAgentRun)-[:UPDATED]->(:PullRequest)`

### Phase 3 edges (code context)

- `(:Repo)-[:CONTAINS_FILE]->(:File)`
- `(:File)-[:DEFINES]->(:Symbol)`
- `(:Test)-[:COVERS]->(:Symbol)`
- `(:Patch)-[:MODIFIES]->(:File)`
- `(:BridgeCommandRun)-[:TESTED]->(:Test)`

---

## 7. Recommended storage architecture

## 7.1 Primary graph store: Amazon Neptune Analytics

### Why Neptune Analytics (not Neptune Database, not Neo4j)

**Amazon Neptune Analytics** is the right choice for Abyss because it uniquely combines **graph traversal and vector similarity search in a single openCypher query**. This is exactly the hybrid retrieval pattern the context graph needs.

| Feature | Neptune Analytics | Neptune Database (Serverless) | Neo4j AuraDB |
|---------|------------------|-------------------------------|--------------|
| Graph queries (openCypher) | Yes | Yes | Yes (Cypher) |
| **Native vector search** | **Yes — built-in** | No (manual via properties) | Requires plugin |
| Hybrid graph+vector queries | **Single query** | No | Separate systems |
| AWS-native | Yes | Yes | No — external |
| Pricing model | m-NCU per hour | NCU per second + I/O | Subscription |
| Provisioning | Create graph, load data | Cluster setup + VPC | Managed cloud |
| Embedding storage | Node properties | Manual | Manual |
| Vector algorithms | `topKByNode`, `topKByEmbedding` | None | Separate index |

Neptune Analytics lets you do things like:

```cypher
// Find goals semantically similar to the user's current utterance,
// then traverse to their blockers and next steps — in ONE query
CALL neptune.algo.vectors.topKByEmbedding($queryEmbedding)
  YIELD node AS goal, score
  WHERE labels(goal) = 'Goal' AND score > 0.7
MATCH (goal)<-[:HAS_GOAL]-(s:Session)-[:SUMMARIZED_AS]->(m:MemoryEpisode)
OPTIONAL MATCH (goal)-[:BLOCKED_BY]->(b:Blocker)
OPTIONAL MATCH (goal)-[:NEXT_ACTION]->(ns:NextStep)
OPTIONAL MATCH (m)-[:ABOUT]->(r:Repo)
RETURN goal, m, b, ns, r, score
ORDER BY score DESC
LIMIT 5
```

This is **not possible** with a JSON file, an in-memory graph, or separate graph + vector systems. The single-query hybrid pattern is the core technical differentiator.

### Embedding model: Amazon Titan Text Embeddings V2

Use `amazon.titan-embed-text-v2:0` via Bedrock to generate embeddings for graph nodes:

- **8,192 token context** — large enough for goal summaries, memory episodes, decisions
- **Configurable dimensions**: 256, 512, or 1024 — use **256** for graph nodes (fast, low storage) or **512** for richer similarity
- **Optimized for RAG** — pre-trained on 100+ languages
- **Already available in Bedrock** — no new service to enable, same AWS credentials

Nodes that should have embeddings:
- `Goal` — embed the normalized goal text
- `MemoryEpisode` — embed the session summary
- `Decision` — embed the decision text
- `Blocker` — embed the blocker description
- `NextStep` — embed the next step description
- `ToolInvocation` (Phase 2) — embed tool name + args summary

### Recommended stack

1. **Graph + vector store**: **Amazon Neptune Analytics** (openCypher + native vector search)
2. **Embeddings**: **Titan Text Embeddings V2** via Bedrock (`amazon.titan-embed-text-v2:0`, 256 or 512 dimensions)
3. **Long-term memory docs**: S3 JSON (existing `MemoryService` — retained for backward compatibility and raw doc storage)
4. **Semantic retrieval fallback**: Bedrock KB over S3 memories (existing — used as fallback if Neptune is unavailable)

## 7.2 Architecture: Neptune Analytics as the unified retrieval layer

```text
                    ContextGraphService
                           |
              +------------+------------+
              |            |            |
              v            v            v
    Neptune Analytics    S3 Memory    Bedrock KB
    (graph + vectors)    (raw docs)   (fallback search)
              |            |            |
              |   Titan Embed V2        |
              |   (via Bedrock)         |
              +-------------------------+
```

**Phase 0**: Neptune Analytics graph with basic node/edge operations (no embeddings yet)
**Phase 1**: Add Titan embeddings to Goal, MemoryEpisode, Decision, Blocker, NextStep nodes. Enable hybrid retrieval.
**Phase 2**: Add execution-layer nodes (ToolInvocation, BridgeCommandRun, CursorAgentRun) with embeddings. Full hybrid graph+vector retrieval.
**Phase 3**: Code-layer nodes, graph-derived summaries, planner support.

## 7.3 Neptune Analytics setup

### Graph creation

```bash
aws neptune-graph create-graph \
  --graph-name abyss-context-graph \
  --provisioned-memory 32 \
  --vector-search-configuration dimension=256 \
  --region us-east-1
```

- **32 m-NCU** is the minimum provisioned memory — sufficient for MVP
- **dimension=256** matches the Titan Embed V2 output dimension we'll use
- Graph is created in the same region as your existing infrastructure

### Environment variables to add

```env
NEPTUNE_GRAPH_ID=g-xxxxxxxxxx          # Neptune Analytics graph ID
NEPTUNE_GRAPH_ENDPOINT=g-xxx.us-east-1.neptune-graph.amazonaws.com
NEPTUNE_GRAPH_REGION=us-east-1
EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0
EMBEDDING_DIMENSIONS=256               # 256 for speed, 512 for accuracy
```

### IAM permissions (add to `abyss-ecs-task-role`)

```json
{
  "Effect": "Allow",
  "Action": [
    "neptune-graph:ExecuteQuery",
    "neptune-graph:ReadDataViaQuery",
    "neptune-graph:WriteDataViaQuery",
    "neptune-graph:GetGraph"
  ],
  "Resource": "arn:aws:neptune-graph:us-east-1:192440504332:graph/*"
}
```

Bedrock invoke permission for Titan Embed V2 (likely already granted for existing Bedrock usage):
```json
{
  "Effect": "Allow",
  "Action": "bedrock:InvokeModel",
  "Resource": "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
}
```

## 7.4 Why not in-memory / JSON graph

The original revision suggested an in-memory graph with S3 JSON persistence. This is inadequate because:

- **No vector search** — you'd need a separate vector index or brute-force cosine similarity
- **No hybrid queries** — can't combine graph traversal with semantic search in one operation
- **Loses data on server restart** — ECS tasks can be replaced at any time
- **No concurrent access** — multiple server instances (ECS scale-out) can't share an in-memory graph
- **Doesn't demonstrate real graph technology** — for a hackathon, Neptune Analytics is a much stronger technical story

## 7.5 Fallback and resilience

Neptune Analytics adds a network dependency. To keep voice latency safe:

1. **All graph writes are fire-and-forget** — never block the conductor loop
2. **Graph reads use the existing timeout pattern** from `MemoryService` (1500ms budget)
3. **If Neptune is unavailable**, fall back to existing `MemoryService.retrieveContext()` (S3 + Bedrock KB)
4. **Embedding generation is async** — compute embeddings in the background after node creation, then upsert the vector

---

## 8. How the graph should be updated in Abyss

## 8.1 Update sources

The graph should be updated from four main sources:

1. **Conductor events** (session lifecycle, memory hydration)
2. **Tool calls + tool results** (inside `runConductorLoop`)
3. **Bridge router / bridge exec events** (via callback, not direct coupling)
4. **Memory summarization at session boundaries** (extending existing `finalizeSession`)

## 8.2 Event-to-graph update rules

### A) On `session.start` (in `handleEvent`)

The conductor already processes `session.start` events. **Extend** the existing handler:

Create / upsert:
- `User(memoryUserKey)` if present
- `Session(sessionId)`
- `User-[:STARTED]->Session`

**Implementation note:** This hooks into the existing `handleEvent` case for `session.start`, after the existing token hydration and Canvas prefetch logic.

### B) On first user utterance (in `runConductorLoop`)

The conductor already updates `workingContext.lastGoal` on each transcript. **Extend** this:

Create / upsert:
- `Goal` (using `workingContext.lastGoal`)
- `Session-[:HAS_GOAL]->Goal`

**Important:** Goal nodes should be **deduped by semantic similarity**, not created per-utterance. A session about "fix the auth bug" should have one Goal, not 15.

### C) On every `tool.call` (Phase 2 — inside `runConductorLoop`)

Create:
- `ToolInvocation`

Link:
- `Session-[:INVOKED]->ToolInvocation`
- `Goal-[:EXECUTED_VIA]->ToolInvocation`

If tool is bridge-related:
- `ToolInvocation-[:STARTED]->BridgeCommandRun` (for exec)

If tool is cursor-related:
- `ToolInvocation-[:SPAWNED]->CursorAgentRun`

If tool is GitHub-related:
- Extract repo/PR/branch info and upsert project-layer nodes

### D) On every `tool.result` (Phase 2 — inside `runConductorLoop`)

Update:
- `ToolInvocation.outcome`
- attach any structured result metadata

If result contains:
- branch info -> upsert `Branch`
- PR info -> upsert `PullRequest`
- file paths -> upsert `File` (Phase 3)
- diff info -> create `Patch` (Phase 3)

### E) On `bridge.exec.finished` (Phase 2 — via callback)

Create / update:
- `BridgeCommandRun`
- `Artifact` nodes (log summary / execution tail if useful)
- edges to workspace

**Implementation note:** The `BridgeToolRouter` should emit graph updates via a callback injected at construction time, not by importing `ContextGraphService` directly. This keeps the bridge module decoupled.

### F) On Cursor webhook / `agent.completed` (Phase 2)

Create / update:
- `CursorAgentRun.status`
- `PullRequest`
- `Decision` / `NextStep` summaries if present

### G) On session finalize (extending existing `finalizeSession`)

The existing `finalizeSession` already:
1. Filters history (removes memory bootstrap turn)
2. Calls `memoryService.summarizeAndStore()`

**Extend** to also:
3. Create `MemoryEpisode` node linking to the S3 doc
4. Create edges to `Repo`, `Branch`, `Decision`, `Blocker`, `NextStep`
5. Persist graph snapshot to S3

---

## 9. How retrieval should work

## 9.1 Retrieval modes

Abyss should have **three retrieval modes**.

### Mode A — Resume-context retrieval
Used at session start (extending existing memory hydration).

Input:
- `memoryUserKey`
- first utterance
- optional repo/branch hints from working context

Output:
- short "Prior context" system block (same format as existing `MemoryService`)

**How it extends existing behavior:** Currently, `MemoryService.retrieveContext()` fetches recent S3 docs + KB search. With Neptune Analytics + Titan embeddings, this becomes:
1. **Embed** the user's first utterance via Titan Text Embeddings V2
2. **Run hybrid Neptune query** — `topKByEmbedding` finds semantically similar Goal/MemoryEpisode nodes, then graph traversal in the *same query* expands to related Repo, Branch, Blocker, NextStep nodes
3. **Format** graph-derived context into the same system-turn format
4. **Fall back** to existing `MemoryService.retrieveContext()` (S3 + Bedrock KB) if Neptune is unavailable

### Mode B — Active-task retrieval (Phase 2+)
Used during tool planning and problem solving.

Input:
- current goal
- current repo/branch (from `workingContext`)
- current run state

Output:
- graph neighborhood + semantically-ranked supporting memory

**Trigger:** This should NOT run on every turn. It should run:
- When the LLM explicitly requests context (via a new `context.query` tool)
- When `workingContext.repo` or `workingContext.branch` changes
- Throttled to at most once per 60 seconds per session

### Mode C — Explicit graph query / introspection (Phase 2+)
Used when user asks things like:
- "What happened last time?"
- "What's blocking this PR?"
- "Which test was failing before?"

**Implementation:** This is best exposed as a tool (`context.query`) the LLM can call, not an automatic injection. The tool accepts a natural-language query, translates it to a graph traversal, and returns a structured answer.

## 9.2 Hybrid retrieval algorithm (Neptune Analytics)

The key insight is that Neptune Analytics can do **vector similarity + graph traversal in a single openCypher query**. This eliminates the multi-step retrieve-then-expand pattern and does it all in one network round-trip.

### Step 1: Embed the query

Use Titan Text Embeddings V2 to embed the user's utterance into a 256-dimension vector.

### Step 2: Hybrid query (single Neptune call)

Run the hybrid openCypher query (see section 13.4):
1. `neptune.algo.vectors.topKByEmbedding` finds Goal and MemoryEpisode nodes whose embeddings are closest to the query
2. In the *same query*, traverse from matching goals → sessions → memory episodes → repos, branches, blockers, next steps
3. Filter: only include unresolved blockers and uncompleted next steps
4. Return everything in one result set, ranked by vector similarity score

### Step 3: Re-rank (post-query)

Re-rank the Neptune results by:
- vector similarity score (primary)
- recency (prefer recent sessions)
- same repo/branch as `workingContext` (boost)
- unresolved blockers (boost — these are the most actionable)

### Step 4: Build context bundle

Return a compact structure like:

```json
{
  "goal": "continue auth work",
  "repo": "storefront-web",
  "branch": "feature/auth-v2",
  "open_pr": "#42",
  "recent_decisions": [
    "Keep refresh-token rotation"
  ],
  "blockers": [
    "Checkout validation still pending"
  ],
  "next_steps": [
    "Re-run checkout validation on preview URL"
  ],
  "supporting_memories": [
    "Unit tests passed after refresh-token fix"
  ]
}
```

Then format that as a system turn for the conductor (same injection point as existing memory hydration).

---

## 10. Repo-specific implementation plan

## 10.1 New modules to add

### A) `server/src/contextGraph/types.ts`

Define graph entity types and graph update event types.

Suggested interfaces:

- `GraphNodeBase` — `{ type: string; key: string; props: Record<string, unknown> }`
- `GraphEdge` — `{ from: [type, key]; to: [type, key]; type: string; props?: Record<string, unknown> }`
- `GraphSubgraph` — `{ nodes: GraphNodeBase[]; edges: GraphEdge[] }`
- `ContextGraphUpdate` — typed union of graph update events (see section 11)
- Node-specific types: `UserNode`, `SessionNode`, `GoalNode`, `RepoNode`, `BranchNode`, `PullRequestNode`, `DecisionNode`, `BlockerNode`, `NextStepNode`, `MemoryEpisodeNode`

### B) `server/src/contextGraph/contextGraphService.ts`

Main service that **wraps** `MemoryService` and adds graph + embedding capabilities.

```ts
class ContextGraphService {
  constructor(
    private graphStore: GraphStore,           // NeptuneAnalyticsStore
    private embeddingService: EmbeddingService, // Titan Embed V2
    private memoryService: MemoryService,     // existing, injected
    private config: { retrieveTimeoutMs: number; maxInjectedChars: number },
  ) {}

  // Graph updates (fire-and-forget, non-blocking)
  async apply(update: ContextGraphUpdate): Promise<void>;

  // Retrieval — hybrid vector+graph via Neptune, fallback to MemoryService
  async retrieveResumeContext(input: ResumeContextInput): Promise<string | null>;
  async retrieveTaskContext(input: TaskContextInput): Promise<string | null>;

  // Delegation to existing MemoryService for S3 + KB
  async summarizeAndStore(...): Promise<void>;
}
```

### C) `server/src/contextGraph/store/graphStore.ts`

Interface abstraction:

```ts
interface GraphStore {
  // Node operations
  upsertNode(node: GraphNodeBase): Promise<void>;
  deleteNode(type: string, key: string): Promise<void>;

  // Edge operations
  upsertEdge(edge: GraphEdge): Promise<void>;

  // Vector operations
  upsertEmbedding(type: string, key: string, embedding: number[]): Promise<void>;
  topKByEmbedding(embedding: number[], k: number, labelFilter?: string): Promise<Array<{ node: GraphNodeBase; score: number }>>;

  // Graph queries
  queryNeighborhood(type: string, key: string, depth: number): Promise<GraphSubgraph>;
  queryByType(type: string, filter?: Record<string, unknown>, limit?: number): Promise<GraphNodeBase[]>;

  // Hybrid queries (graph traversal + vector similarity in one call)
  hybridResumeQuery(userKey: string, queryEmbedding: number[], limit: number): Promise<ResumeNeighborhood>;
}

interface ResumeNeighborhood {
  episodes: Array<{
    episode: MemoryEpisodeNode;
    repo?: RepoNode;
    branch?: BranchNode;
    blockers: BlockerNode[];
    nextSteps: NextStepNode[];
    score: number;  // vector similarity score
  }>;
  recentGoals: GoalNode[];
  unresolvedBlockers: BlockerNode[];
}
```

### D) `server/src/contextGraph/store/neptuneAnalyticsStore.ts`

Neptune Analytics implementation using the `@aws-sdk/client-neptune-graph` SDK.

Key responsibilities:
- Execute openCypher queries via `ExecuteQueryCommand`
- Manage vector embeddings via `neptune.algo.vectors.upsert` / `topKByEmbedding`
- Implement hybrid queries that combine graph traversal with vector similarity
- Connection pooling and error handling

### E) `server/src/contextGraph/embedding/embeddingService.ts`

Wraps Bedrock Titan Text Embeddings V2 for generating node embeddings.

```ts
class EmbeddingService {
  constructor(
    private bedrockClient: BedrockRuntimeClient,
    private modelId: string,  // "amazon.titan-embed-text-v2:0"
    private dimensions: number,  // 256 or 512
  ) {}

  async embed(text: string): Promise<number[]>;
  async embedBatch(texts: string[]): Promise<number[][]>;
}
```

Used by `ContextGraphService` to:
- Embed goal text when a new Goal node is created
- Embed memory episode summaries when sessions are finalized
- Embed decision/blocker/next-step text
- Embed the user's current utterance for similarity search at retrieval time

### F) `server/src/contextGraph/retrieval/hybridRetriever.ts`

Orchestrates the full hybrid retrieval pipeline:

1. **Embed the query** (user utterance) via `EmbeddingService`
2. **Run hybrid Neptune query** — vector similarity on Goal/MemoryEpisode nodes + graph traversal to related Repo/Branch/Blocker/NextStep nodes
3. **Fall back to `MemoryService`** if Neptune is unavailable
4. **Re-rank** by recency, repo match, and unresolved blockers
5. **Format** into compact context string for conductor injection

---

## 10.2 Changes to `server/src/core/types.ts`

**Only add new fields** (existing fields are already present):

```ts
// Add to SessionState:
graphContextCache?: string;    // cached graph-derived context for current session
lastGraphQueryTs?: number;     // timestamp of last graph query (throttling)
```

**Do NOT re-add:** `memoryUserKey`, `memoryHydrated`, `workingContext` — these already exist.

---

## 10.3 Changes to `server/src/core/sessionStore.ts`

**No changes needed for MVP.** `SessionStore` already has `get()`, `getOrCreate()`, and `appendTurn()`.

If needed later, add a `delete(sessionId)` for explicit session cleanup.

---

## 10.4 Changes to `server/src/core/conductorService.ts`

### Inject a new dependency

In `ConductorServiceDependencies`, replace:
```ts
memoryService?: MemoryService
```
with:
```ts
contextGraphService?: ContextGraphService  // wraps MemoryService
```

The conductor should only talk to `ContextGraphService`. The context graph service delegates to `MemoryService` internally for S3/KB operations.

### Hook points (extending existing code, not rewriting)

#### On `session.start` — extend existing handler

After the existing token hydration and Canvas prefetch, add:
```ts
if (session.memoryUserKey && this.deps.contextGraphService) {
  void this.deps.contextGraphService.apply({
    type: "session.start",
    sessionId: session.sessionId,
    payload: { memoryUserKey: session.memoryUserKey },
    timestamp: event.timestamp,
  });
}
```

#### On first `user.audio.transcript.final` — extend existing memory hydration

The existing code already does:
1. Check `!session.memoryHydrated && session.memoryUserKey`
2. Call `memoryService.retrieveContext()`
3. Prepend result as user turn
4. Set `session.memoryHydrated = true`

**Change:** Replace `memoryService.retrieveContext()` with `contextGraphService.retrieveResumeContext()`. The context graph service internally calls `memoryService.retrieveContext()` and augments with graph data.

#### Inside `runConductorLoop` — add graph event emissions

After the existing `workingContext.lastGoal` update:
```ts
void this.deps.contextGraphService?.apply({
  type: "goal.started",
  sessionId: session.sessionId,
  payload: { text: transcript },
  timestamp: new Date().toISOString(),
});
```

After tool calls are emitted (Phase 2):
```ts
for (const toolCall of response.toolCalls) {
  void this.deps.contextGraphService?.apply({
    type: "tool.call",
    sessionId: session.sessionId,
    payload: { callId: toolCall.id, toolName: toolCall.name, args: toolCall.input },
    timestamp: new Date().toISOString(),
  });
}
```

#### On `finalizeSession` — extend existing flow

After the existing `memoryService.summarizeAndStore()` call:
```ts
void this.deps.contextGraphService?.apply({
  type: "session.finalized",
  sessionId,
  payload: { memoryUserKey, workingContext: session.workingContext },
  timestamp: new Date().toISOString(),
});
```

---

## 10.5 Changes to `server/src/bridge/toolRouter.ts`

**Do not import `ContextGraphService` directly.** Instead, inject a callback at construction time:

```ts
interface BridgeToolRouterDeps {
  // ... existing deps ...
  onGraphEvent?: (update: ContextGraphUpdate) => void;
}
```

### Best hook points

- `execute()` — when a bridge tool starts, emit `bridge.exec.started`
- `handleBridgeEvent()` for `bridge.exec.finished` — emit `bridge.exec.finished` with exit code, command, workspace
- `executeClaudeRun()` — emit `claude.run.started` and `claude.run.finished`

The router already knows which session, device, command, and workspace. The callback just forwards structured data to the graph service.

---

## 10.6 Changes to `server/src/server.ts`

### Dependency wiring

Keep existing `MemoryService` construction, add Neptune + embedding services:

```ts
const memoryService = new MemoryService(memoryConfig);

const embeddingService = new EmbeddingService(
  bedrockClient,
  process.env.EMBEDDING_MODEL_ID || "amazon.titan-embed-text-v2:0",
  parseInt(process.env.EMBEDDING_DIMENSIONS || "256"),
);

const graphStore = new NeptuneAnalyticsStore(
  process.env.NEPTUNE_GRAPH_ID!,
  process.env.NEPTUNE_GRAPH_ENDPOINT!,
  process.env.NEPTUNE_GRAPH_REGION || "us-east-1",
);

const contextGraphService = new ContextGraphService(
  graphStore, embeddingService, memoryService,
  { retrieveTimeoutMs: 1500, maxInjectedChars: 900 },
);
```

Pass `contextGraphService` to conductor instead of `memoryService`.

### On iOS websocket close

**No changes needed.** `conductor.finalizeSession()` is already called. The conductor's extended `finalizeSession` handles graph updates internally.

### Bridge router wiring (Phase 2)

Wire the graph callback:
```ts
const bridgeRouter = new BridgeToolRouter({
  // ... existing deps ...
  onGraphEvent: (update) => contextGraphService.apply(update),
});
```

---

## 11. Graph update pipeline design

## 11.1 Recommended event model

Do not write to the graph directly from twenty places in an ad hoc way.

Instead, define a small internal update bus:

```ts
interface ContextGraphUpdate {
  type:
    | "session.start"
    | "goal.started"
    | "tool.call"          // Phase 2
    | "tool.result"        // Phase 2
    | "bridge.exec.started"  // Phase 2
    | "bridge.exec.finished" // Phase 2
    | "cursor.run.updated"   // Phase 2
    | "github.pr.updated"    // Phase 2
    | "session.finalized";
  sessionId: string;
  payload: Record<string, unknown>;
  timestamp: string;
}
```

Then `ContextGraphService.apply(update)` handles normalization and persistence.

### Error handling

All graph updates are **fire-and-forget**. The graph is a best-effort enrichment layer, not a critical path. If a graph write fails:
- Log the error
- Do not retry
- Do not block the conductor loop
- The system degrades gracefully to `MemoryService`-only retrieval

This keeps the system debuggable and testable without introducing latency risk.

---

## 12. Phased rollout plan

## Phase 0 — Neptune Analytics + schema + instrumentation

### Goal
Get Neptune Analytics running, graph-shaped data flowing, and embeddings being generated — without turning graph retrieval on in prompts yet.

### Deliverables
- Neptune Analytics graph provisioned in us-east-1
- `NeptuneAnalyticsStore` implementing `GraphStore` interface
- `EmbeddingService` wrapping Titan Text Embeddings V2
- `ContextGraphService` class wrapping existing `MemoryService` with pass-through
- `ContextGraphUpdate` type definitions
- Event capture hooks in `ConductorService` (session.start, goal.started, session.finalized)
- All existing `MemoryService` functionality passes through unchanged
- Tests: Neptune connectivity, node/edge CRUD, embedding generation, vector upsert

### Why
This lets you validate that Neptune is working and you're capturing the right facts with embeddings before introducing retrieval complexity. The system behaves identically to today from the user's perspective.

### Estimated scope
- 6 new files (~600 lines total)
- ~30 lines changed in `conductorService.ts`
- ~15 lines changed in `server.ts`
- ~5 lines changed in `types.ts`
- 1 new dependency: `@aws-sdk/client-neptune-graph`

---

## Phase 1 — hackathon MVP: hybrid vector+graph resume context

### Goal
Use Neptune's hybrid vector+graph queries to provide semantically-aware, structurally-rich session resume context.

### Scope
- Populate `User`, `Session`, `Goal`, `Repo`, `Branch`, `PullRequest`, `Decision`, `Blocker`, `NextStep`, `MemoryEpisode` nodes from session finalization
- Embed Goal text and MemoryEpisode summaries via Titan Embed V2
- `retrieveResumeContext()` embeds the user's utterance, runs hybrid Neptune query, formats result
- Falls back to existing `MemoryService.retrieveContext()` on failure
- One system-turn injection at session start (same injection point as existing)

### The demo moment
User says "pick up where I left off on the auth work" and gets:

> *Prior context from knowledge graph:*
> *• Fixed refresh-token rotation in storefront-web (feature/auth-v2). PR #42 open.*
> *  Blockers: Checkout validation still pending*
> *  Next: Re-run checkout validation on preview URL*

This is richer and more precise than the existing S3 memory retrieval because:
- **Semantic match**: "auth work" matches the embedded goal text even if the exact phrase wasn't used before
- **Structural context**: blockers, next steps, repo, and branch come from graph edges, not LLM extraction at query time
- **Single query**: Neptune does the vector search + graph traversal in one round-trip

---

## Phase 2 — operational graph for bridge + cursor + GitHub

### Goal
Make the graph aware of execution — every tool call, bridge command, and agent run becomes a queryable node with an embedding.

### Scope
Add:
- `ToolInvocation` — embedded with tool name + args summary
- `BridgeCommandRun` — embedded with command + exit status summary
- `CursorAgentRun` — embedded with agent mode + result summary
- `Artifact` — diff summaries, test output tails
- `Workspace` — bridge workspace roots

Wire bridge router callback for exec lifecycle events.
Wire GitHub tool results for PR/branch/issue updates.

Use it for:
- better mid-session retrieval (Mode B) — vector search over tool invocations
- expose `context.query` tool to the LLM for explicit graph introspection
- "what happened last?" — vector similarity on BridgeCommandRun nodes
- "what's blocking this PR?" — graph traversal from PR → goals → blockers

### Neptune scaling
- Monitor m-NCU usage; scale up from 32 if query latency increases
- Consider partitioning long-term archive nodes vs active session nodes

---

## Phase 3 — graph-assisted planning and code-context retrieval

### Goal
Use the graph to improve active task planning, not just memory.

### Scope
- connect files/tests/symbols into the graph
- use bridge search/read/applyPatch/git results to update code graph neighborhoods
- hybrid retrieval for current task context

This is where context graphs become a core agent capability.

---

## Phase 4 — graph-derived summaries / checkpoints

### Goal
Make the graph itself produce short checkpoint summaries:

- "Current objective"
- "Known blockers"
- "Most likely next action"

Use these to stabilize long voice sessions and subagent orchestration.

---

## 13. Concrete Neptune Analytics query patterns

All queries use **openCypher** executed via the `@aws-sdk/client-neptune-graph` `ExecuteQueryCommand`. Vector operations use Neptune's built-in `neptune.algo.vectors.*` functions.

## 13.1 Upsert a session and user

```cypher
MERGE (u:User {memoryUserKey: $memoryUserKey})
MERGE (s:Session {sessionId: $sessionId})
SET s.startedAt = coalesce(s.startedAt, $startedAt),
    s.provider = $provider
MERGE (u)-[:STARTED]->(s)
RETURN u, s
```

## 13.2 Record a goal with embedding

```cypher
MERGE (g:Goal {goalId: $goalId})
SET g.text = $text,
    g.createdAt = $createdAt,
    g.sessionId = $sessionId
MERGE (s:Session {sessionId: $sessionId})
MERGE (s)-[:HAS_GOAL]->(g)
RETURN g
```

Then upsert the embedding (separate call — Neptune vector ops):
```cypher
MATCH (g:Goal {goalId: $goalId})
CALL neptune.algo.vectors.upsert(g, $embedding)
RETURN g
```

## 13.3 Record a blocker and next step

```cypher
MERGE (b:Blocker {key: $blockerKey})
SET b.text = $blockerText,
    b.updatedAt = $updatedAt,
    b.resolved = false
MERGE (n:NextStep {key: $nextStepKey})
SET n.text = $nextStepText,
    n.updatedAt = $updatedAt,
    n.completed = false
MERGE (g:Goal {goalId: $goalId})
MERGE (g)-[:BLOCKED_BY]->(b)
MERGE (g)-[:NEXT_ACTION]->(n)
```

Then embed both:
```cypher
MATCH (b:Blocker {key: $blockerKey})
CALL neptune.algo.vectors.upsert(b, $blockerEmbedding)

MATCH (n:NextStep {key: $nextStepKey})
CALL neptune.algo.vectors.upsert(n, $nextStepEmbedding)
```

## 13.4 Hybrid resume-context retrieval (the key query)

This is the **core differentiating query** — graph traversal + vector similarity in one call:

```cypher
// Step 1: Find goals semantically similar to the user's current utterance
CALL neptune.algo.vectors.topKByEmbedding($queryEmbedding)
  YIELD node, score
  WHERE labels(node) = 'Goal' AND score > 0.6
WITH node AS goal, score

// Step 2: Traverse from matching goals to their sessions and memory episodes
MATCH (s:Session)-[:HAS_GOAL]->(goal)
MATCH (u:User {memoryUserKey: $memoryUserKey})-[:STARTED]->(s)
OPTIONAL MATCH (s)-[:SUMMARIZED_AS]->(m:MemoryEpisode)
OPTIONAL MATCH (m)-[:ABOUT]->(r:Repo)
OPTIONAL MATCH (m)-[:ABOUT_BRANCH]->(b:Branch)
OPTIONAL MATCH (goal)-[:BLOCKED_BY]->(blk:Blocker)
  WHERE blk.resolved = false
OPTIONAL MATCH (goal)-[:NEXT_ACTION]->(ns:NextStep)
  WHERE ns.completed = false
RETURN goal, score, s.sessionId, m, r, b,
       collect(DISTINCT blk) AS blockers,
       collect(DISTINCT ns) AS nextSteps
ORDER BY score DESC
LIMIT 5
```

This query does in **one network round-trip** what would otherwise require:
1. An embedding similarity search (separate vector DB)
2. Multiple S3 fetches (one per memory doc)
3. Manual joining of results

## 13.5 Recency-based resume (fallback when no transcript for embedding)

```cypher
MATCH (u:User {memoryUserKey: $memoryUserKey})-[:STARTED]->(s:Session)-[:SUMMARIZED_AS]->(m:MemoryEpisode)
OPTIONAL MATCH (m)-[:ABOUT]->(r:Repo)
OPTIONAL MATCH (m)-[:ABOUT_BRANCH]->(b:Branch)
OPTIONAL MATCH (m)-[:NOTES_BLOCKER]->(blk:Blocker)
  WHERE blk.resolved = false
OPTIONAL MATCH (m)-[:NOTES_NEXT_STEP]->(ns:NextStep)
  WHERE ns.completed = false
RETURN m, r, b, collect(DISTINCT blk) AS blockers, collect(DISTINCT ns) AS nextSteps
ORDER BY m.timestamp DESC
LIMIT 3
```

## 13.6 Phase 2: Execution-aware query

```cypher
// "What happened during the last bridge run for this repo?"
MATCH (u:User {memoryUserKey: $memoryUserKey})-[:STARTED]->(s:Session)
MATCH (s)-[:INVOKED]->(t:ToolInvocation)-[:STARTED]->(cmd:BridgeCommandRun)
MATCH (s)-[:WORKED_ON]->(r:Repo {repoName: $repoName})
OPTIONAL MATCH (cmd)-[:PRODUCED]->(a:Artifact)
RETURN t.toolName, cmd.command, cmd.exitCode, a.summary
ORDER BY cmd.startedAt DESC
LIMIT 5
```

## 13.7 Phase 2: "What's blocking this PR?"

```cypher
MATCH (pr:PullRequest {prUrl: $prUrl})<-[:HAS_PR]-(br:Branch)
OPTIONAL MATCH (goal:Goal)-[:EXECUTED_VIA]->(:ToolInvocation)-[:SPAWNED]->
  (:CursorAgentRun)-[:UPDATED]->(pr)
OPTIONAL MATCH (goal)-[:BLOCKED_BY]->(blk:Blocker)
  WHERE blk.resolved = false
RETURN pr, br, goal, collect(DISTINCT blk) AS blockers
```

---

## 14. Pseudocode for the implementation

## 14.1 ContextGraphService

```ts
class ContextGraphService {
  constructor(
    private graphStore: GraphStore,
    private embeddingService: EmbeddingService,
    private memoryService: MemoryService,
    private config: { retrieveTimeoutMs: number; maxInjectedChars: number },
  ) {}

  /**
   * Fire-and-forget graph update. Never throws.
   * All writes are non-blocking — the conductor loop never waits.
   */
  async apply(update: ContextGraphUpdate): Promise<void> {
    try {
      switch (update.type) {
        case "session.start":
          await this.handleSessionStart(update);
          break;
        case "goal.started":
          await this.handleGoalStarted(update);
          break;
        case "session.finalized":
          await this.handleSessionFinalized(update);
          break;
        // Phase 2: tool.call, tool.result, bridge.*, cursor.*, github.*
      }
    } catch (err) {
      console.error(`[ContextGraph] Failed to apply ${update.type}:`, err);
    }
  }

  private async handleSessionStart(update: ContextGraphUpdate) {
    const { memoryUserKey } = update.payload as { memoryUserKey: string };
    await this.graphStore.upsertNode({ type: "User", key: memoryUserKey, props: {} });
    await this.graphStore.upsertNode({
      type: "Session", key: update.sessionId,
      props: { startedAt: update.timestamp },
    });
    await this.graphStore.upsertEdge({
      from: ["User", memoryUserKey],
      to: ["Session", update.sessionId],
      type: "STARTED",
    });
  }

  private async handleGoalStarted(update: ContextGraphUpdate) {
    const { text } = update.payload as { text: string };
    const goalId = `${update.sessionId}-goal-${Date.now()}`;

    // Create goal node
    await this.graphStore.upsertNode({
      type: "Goal", key: goalId,
      props: { text, createdAt: update.timestamp, sessionId: update.sessionId },
    });
    await this.graphStore.upsertEdge({
      from: ["Session", update.sessionId],
      to: ["Goal", goalId],
      type: "HAS_GOAL",
    });

    // Embed the goal text asynchronously for future vector search
    try {
      const embedding = await this.embeddingService.embed(text);
      await this.graphStore.upsertEmbedding("Goal", goalId, embedding);
    } catch (err) {
      console.error("[ContextGraph] Failed to embed goal:", err);
    }
  }

  private async handleSessionFinalized(update: ContextGraphUpdate) {
    const { memoryUserKey, workingContext, summary, decisions, blockers, nextSteps } =
      update.payload as {
        memoryUserKey: string;
        workingContext?: WorkingContextSnapshot;
        summary?: string;
        decisions?: string[];
        blockers?: string[];
        nextSteps?: string[];
      };

    // Create MemoryEpisode node
    const episodeKey = `${update.sessionId}-episode`;
    await this.graphStore.upsertNode({
      type: "MemoryEpisode", key: episodeKey,
      props: { sessionId: update.sessionId, timestamp: update.timestamp, summary },
    });
    await this.graphStore.upsertEdge({
      from: ["Session", update.sessionId],
      to: ["MemoryEpisode", episodeKey],
      type: "SUMMARIZED_AS",
    });

    // Embed the episode summary for semantic retrieval
    if (summary) {
      try {
        const embedding = await this.embeddingService.embed(summary);
        await this.graphStore.upsertEmbedding("MemoryEpisode", episodeKey, embedding);
      } catch (err) {
        console.error("[ContextGraph] Failed to embed episode:", err);
      }
    }

    // Link to repo/branch if known
    if (workingContext?.repo) {
      await this.graphStore.upsertNode({
        type: "Repo", key: workingContext.repo,
        props: { repoName: workingContext.repo },
      });
      await this.graphStore.upsertEdge({
        from: ["Session", update.sessionId],
        to: ["Repo", workingContext.repo],
        type: "WORKED_ON",
      });
      await this.graphStore.upsertEdge({
        from: ["MemoryEpisode", episodeKey],
        to: ["Repo", workingContext.repo],
        type: "ABOUT",
      });
    }
    if (workingContext?.branch) {
      await this.graphStore.upsertNode({
        type: "Branch", key: `${workingContext.repo}/${workingContext.branch}`,
        props: { branchName: workingContext.branch },
      });
      await this.graphStore.upsertEdge({
        from: ["MemoryEpisode", episodeKey],
        to: ["Branch", `${workingContext.repo}/${workingContext.branch}`],
        type: "ABOUT_BRANCH",
      });
    }

    // Create and embed decision/blocker/next-step nodes
    for (const d of decisions ?? []) {
      const key = `${update.sessionId}-decision-${hashShort(d)}`;
      await this.graphStore.upsertNode({ type: "Decision", key, props: { text: d } });
      await this.graphStore.upsertEdge({
        from: ["MemoryEpisode", episodeKey], to: ["Decision", key], type: "NOTES_DECISION",
      });
      void this.embedNode("Decision", key, d);
    }
    for (const b of blockers ?? []) {
      const key = `${update.sessionId}-blocker-${hashShort(b)}`;
      await this.graphStore.upsertNode({
        type: "Blocker", key, props: { text: b, resolved: false },
      });
      await this.graphStore.upsertEdge({
        from: ["MemoryEpisode", episodeKey], to: ["Blocker", key], type: "NOTES_BLOCKER",
      });
      void this.embedNode("Blocker", key, b);
    }
    for (const ns of nextSteps ?? []) {
      const key = `${update.sessionId}-nextstep-${hashShort(ns)}`;
      await this.graphStore.upsertNode({
        type: "NextStep", key, props: { text: ns, completed: false },
      });
      await this.graphStore.upsertEdge({
        from: ["MemoryEpisode", episodeKey], to: ["NextStep", key], type: "NOTES_NEXT_STEP",
      });
      void this.embedNode("NextStep", key, ns);
    }
  }

  /** Fire-and-forget embedding for a node */
  private async embedNode(type: string, key: string, text: string): Promise<void> {
    try {
      const embedding = await this.embeddingService.embed(text);
      await this.graphStore.upsertEmbedding(type, key, embedding);
    } catch (err) {
      console.error(`[ContextGraph] Failed to embed ${type}:${key}:`, err);
    }
  }

  /**
   * Graph-enhanced resume context retrieval.
   * Uses Neptune's hybrid vector+graph query for semantic + structural retrieval.
   * Falls back to MemoryService if Neptune is unavailable.
   */
  async retrieveResumeContext(input: {
    memoryUserKey: string;
    transcript?: string;
  }): Promise<string | null> {
    const deadline = Date.now() + this.config.retrieveTimeoutMs;

    // Try hybrid graph+vector retrieval
    try {
      if (input.transcript) {
        // Embed the user's utterance for semantic search
        const queryEmbedding = await this.embeddingService.embed(input.transcript);

        if (Date.now() < deadline) {
          // Hybrid query: vector similarity on goals + graph traversal
          const neighborhood = await withTimeout(
            this.graphStore.hybridResumeQuery(
              input.memoryUserKey, queryEmbedding, 5,
            ),
            deadline - Date.now(),
          );

          if (neighborhood && neighborhood.episodes.length > 0) {
            return this.formatResumeContext(neighborhood);
          }
        }
      } else {
        // No transcript yet — use recency-based graph query
        const neighborhood = await withTimeout(
          this.graphStore.queryNeighborhood("User", input.memoryUserKey, 3),
          deadline - Date.now(),
        );
        if (neighborhood && neighborhood.nodes.length > 0) {
          return this.formatGraphContext(neighborhood);
        }
      }
    } catch (err) {
      console.error("[ContextGraph] Neptune retrieval failed, falling back:", err);
    }

    // Fallback: existing MemoryService pipeline (S3 + Bedrock KB)
    return this.memoryService.retrieveContext(input);
  }

  /**
   * Format the graph-derived resume context into a compact string
   * for injection as a system turn.
   */
  private formatResumeContext(neighborhood: ResumeNeighborhood): string {
    const lines: string[] = ["Prior context from knowledge graph:"];

    for (const ep of neighborhood.episodes) {
      const repoLine = ep.repo ? ` Repo: ${ep.repo.props.repoName}` : "";
      const branchLine = ep.branch ? ` (${ep.branch.props.branchName})` : "";
      lines.push(`• ${ep.episode.props.summary}${repoLine}${branchLine}`);

      if (ep.blockers.length > 0) {
        lines.push(`  Blockers: ${ep.blockers.map(b => b.props.text).join("; ")}`);
      }
      if (ep.nextSteps.length > 0) {
        lines.push(`  Next: ${ep.nextSteps.map(ns => ns.props.text).join("; ")}`);
      }
    }

    const result = lines.join("\n");
    return result.length > this.config.maxInjectedChars
      ? result.slice(0, this.config.maxInjectedChars) + "…"
      : result;
  }

  /**
   * Delegates to existing MemoryService for S3 storage + KB ingestion.
   * Graph nodes are created separately via apply("session.finalized").
   */
  async summarizeAndStore(
    memoryUserKey: string,
    sessionId: string,
    history: ConversationTurn[],
    workingContext?: WorkingContextSnapshot,
  ): Promise<void> {
    await this.memoryService.summarizeAndStore(
      memoryUserKey, sessionId, history, workingContext,
    );
  }
}
```

## 14.2 NeptuneAnalyticsStore

```ts
import {
  NeptuneGraphClient,
  ExecuteQueryCommand,
} from "@aws-sdk/client-neptune-graph";

class NeptuneAnalyticsStore implements GraphStore {
  private client: NeptuneGraphClient;

  constructor(
    private graphId: string,
    private endpoint: string,
    private region: string,
  ) {
    this.client = new NeptuneGraphClient({
      region,
      endpoint: `https://${endpoint}`,
    });
  }

  private async query(cypher: string, params: Record<string, unknown> = {}): Promise<any> {
    const cmd = new ExecuteQueryCommand({
      graphIdentifier: this.graphId,
      queryString: cypher,
      language: "OPEN_CYPHER",
      parameters: params,
    });
    const response = await this.client.send(cmd);
    return JSON.parse(new TextDecoder().decode(response.payload));
  }

  async upsertNode(node: GraphNodeBase): Promise<void> {
    // Build SET clause from props
    const propEntries = Object.entries(node.props);
    const setClauses = propEntries.map(([k]) => `n.${k} = $prop_${k}`).join(", ");
    const params: Record<string, unknown> = { key: node.key };
    propEntries.forEach(([k, v]) => { params[`prop_${k}`] = v; });

    const cypher = `
      MERGE (n:${node.type} {key: $key})
      ${setClauses ? `SET ${setClauses}` : ""}
      RETURN n
    `;
    await this.query(cypher, params);
  }

  async upsertEdge(edge: GraphEdge): Promise<void> {
    const cypher = `
      MATCH (a:${edge.from[0]} {key: $fromKey})
      MATCH (b:${edge.to[0]} {key: $toKey})
      MERGE (a)-[:${edge.type}]->(b)
    `;
    await this.query(cypher, { fromKey: edge.from[1], toKey: edge.to[1] });
  }

  async upsertEmbedding(type: string, key: string, embedding: number[]): Promise<void> {
    const cypher = `
      MATCH (n:${type} {key: $key})
      CALL neptune.algo.vectors.upsert(n, $embedding)
      RETURN n
    `;
    await this.query(cypher, { key, embedding });
  }

  async topKByEmbedding(
    embedding: number[],
    k: number,
    labelFilter?: string,
  ): Promise<Array<{ node: GraphNodeBase; score: number }>> {
    const whereClause = labelFilter ? `WHERE labels(node) = '${labelFilter}'` : "";
    const cypher = `
      CALL neptune.algo.vectors.topKByEmbedding($embedding)
        YIELD node, score
        ${whereClause}
      RETURN node, score
      ORDER BY score DESC
      LIMIT ${k}
    `;
    const result = await this.query(cypher, { embedding });
    return result.results.map((r: any) => ({
      node: { type: r.node.labels[0], key: r.node.properties.key, props: r.node.properties },
      score: r.score,
    }));
  }

  async hybridResumeQuery(
    userKey: string,
    queryEmbedding: number[],
    limit: number,
  ): Promise<ResumeNeighborhood> {
    const cypher = `
      CALL neptune.algo.vectors.topKByEmbedding($queryEmbedding)
        YIELD node, score
        WHERE labels(node) = 'Goal' AND score > 0.6
      WITH node AS goal, score
      MATCH (s:Session)-[:HAS_GOAL]->(goal)
      MATCH (u:User {memoryUserKey: $userKey})-[:STARTED]->(s)
      OPTIONAL MATCH (s)-[:SUMMARIZED_AS]->(m:MemoryEpisode)
      OPTIONAL MATCH (m)-[:ABOUT]->(r:Repo)
      OPTIONAL MATCH (m)-[:ABOUT_BRANCH]->(b:Branch)
      OPTIONAL MATCH (goal)-[:BLOCKED_BY]->(blk:Blocker)
        WHERE blk.resolved = false
      OPTIONAL MATCH (goal)-[:NEXT_ACTION]->(ns:NextStep)
        WHERE ns.completed = false
      RETURN goal, score, m, r, b,
             collect(DISTINCT blk) AS blockers,
             collect(DISTINCT ns) AS nextSteps
      ORDER BY score DESC
      LIMIT $limit
    `;
    const result = await this.query(cypher, { queryEmbedding, userKey, limit });
    return this.parseResumeResult(result);
  }

  async queryNeighborhood(type: string, key: string, depth: number): Promise<GraphSubgraph> {
    // Variable-length path match for N hops
    const cypher = `
      MATCH (start:${type} {key: $key})
      OPTIONAL MATCH path = (start)-[*1..${depth}]-(related)
      WITH start, collect(DISTINCT related) AS neighbors, collect(DISTINCT relationships(path)) AS rels
      RETURN start, neighbors, rels
    `;
    const result = await this.query(cypher, { key });
    return this.parseSubgraph(result);
  }
}
```

## 14.3 EmbeddingService

```ts
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

class EmbeddingService {
  constructor(
    private client: BedrockRuntimeClient,
    private modelId: string = "amazon.titan-embed-text-v2:0",
    private dimensions: number = 256,
  ) {}

  async embed(text: string): Promise<number[]> {
    const response = await this.client.send(new InvokeModelCommand({
      modelId: this.modelId,
      contentType: "application/json",
      accept: "application/json",
      body: JSON.stringify({
        inputText: text.slice(0, 50000),  // Titan V2 limit: 50K chars
        dimensions: this.dimensions,
        normalize: true,  // unit vector normalization for cosine similarity
      }),
    }));

    const result = JSON.parse(new TextDecoder().decode(response.body));
    return result.embedding;
  }

  async embedBatch(texts: string[]): Promise<number[][]> {
    // Titan V2 doesn't support native batching — parallelize
    return Promise.all(texts.map(t => this.embed(t)));
  }
}
```
```

## 14.4 Conductor integration (diff-style — what actually changes)

```ts
// In ConductorServiceDependencies:
// REPLACE: memoryService?: MemoryService
// WITH:    contextGraphService?: ContextGraphService

// In handleEvent, session.start case, AFTER existing token hydration:
if (session.memoryUserKey && this.deps.contextGraphService) {
  void this.deps.contextGraphService.apply({
    type: "session.start",
    sessionId: session.sessionId,
    payload: { memoryUserKey: session.memoryUserKey },
    timestamp: event.timestamp,
  });
}

// In runConductorLoop, memory hydration block:
// REPLACE: this.deps.memoryService.retrieveContext(...)
// WITH:    this.deps.contextGraphService.retrieveResumeContext(...)
// (The context graph service now does hybrid vector+graph retrieval,
//  falling back to the existing MemoryService S3/KB pipeline.)

// In runConductorLoop, after workingContext.lastGoal update:
void this.deps.contextGraphService?.apply({
  type: "goal.started",
  sessionId: session.sessionId,
  payload: { text: transcript },
  timestamp: new Date().toISOString(),
});

// In finalizeSession:
// Step 1: existing S3 + KB storage (unchanged)
// REPLACE: this.deps.memoryService.summarizeAndStore(...)
// WITH:    this.deps.contextGraphService.summarizeAndStore(...)

// Step 2: populate the graph with structured data from the MemoryDocument
// The MemoryService.summarizeAndStore() extracts decisions, blockers, nextSteps.
// We need those to create graph nodes. Two approaches:
//
// Option A (preferred): ContextGraphService.summarizeAndStore() captures the
//   MemoryDocument output from MemoryService and passes it to apply():
void this.deps.contextGraphService?.apply({
  type: "session.finalized",
  sessionId,
  payload: {
    memoryUserKey,
    workingContext: session.workingContext,
    // These come from the MemoryDocument created by MemoryService:
    summary: memoryDoc.summary,
    decisions: memoryDoc.decisions,
    blockers: memoryDoc.blockers,
    nextSteps: memoryDoc.nextSteps,
  },
  timestamp: new Date().toISOString(),
});
```

## 14.5 Server.ts wiring

```ts
// Construct embedding service (reuses existing Bedrock client)
const embeddingService = new EmbeddingService(
  bedrockClient,
  process.env.EMBEDDING_MODEL_ID || "amazon.titan-embed-text-v2:0",
  parseInt(process.env.EMBEDDING_DIMENSIONS || "256"),
);

// Construct Neptune Analytics store
const graphStore = new NeptuneAnalyticsStore(
  process.env.NEPTUNE_GRAPH_ID!,
  process.env.NEPTUNE_GRAPH_ENDPOINT!,
  process.env.NEPTUNE_GRAPH_REGION || "us-east-1",
);

// Construct context graph service wrapping existing memory service
const contextGraphService = new ContextGraphService(
  graphStore,
  embeddingService,
  memoryService,  // existing MemoryService still handles S3 + KB
  {
    retrieveTimeoutMs: 1500,
    maxInjectedChars: 900,
  },
);

// Pass to conductor (replaces memoryService)
const conductor = new ConductorService(provider, config, {
  ...existingDeps,
  contextGraphService,  // replaces: memoryService
});

// Wire bridge router graph callback (Phase 2)
const bridgeRouter = new BridgeToolRouter({
  ...existingDeps,
  onGraphEvent: (update) => contextGraphService.apply(update),
});
```

---

## 15. Cost, scalability, and operational tradeoffs

## 15.1 Cost estimate

| Component | Cost | Notes |
|-----------|------|-------|
| Neptune Analytics (32 m-NCU) | ~$2.50/hr (~$60/day) | Minimum provisioned memory; can scale down when not demoing |
| Titan Embed V2 | $0.00002/1K tokens | ~$0.01 for 500 embeddings; negligible |
| S3 memory docs | < $0.01/mo | Existing; minimal storage |
| Bedrock KB | Existing | Already provisioned |

**For hackathon**: Create the Neptune Analytics graph only when demoing. Delete it after. Total cost: ~$5–10 for a day of development + demo.

**For production**: Neptune Analytics supports provisioned memory scaling. Start at 32 m-NCU, scale up as graph grows.

## 15.2 Highest-value complexity to add

The best complexity-to-wow ratio is:

1. **Hybrid vector+graph resume retrieval** (Phase 1) — the single Neptune query that finds semantically similar past goals and traverses to their blockers/next-steps is the marquee demo
2. **Embedded goals and memory episodes** — "resume my work on auth" finds the right session even if the user doesn't say "auth" verbatim
3. **Execution graph for bridge + cursor** (Phase 2) — "what happened last time I ran tests?" answered from graph

The most expensive early complexity is:

- full symbol/file dependency graph over large repos
- automatic graph extraction from every log line
- graph ML or graph embeddings everywhere

Do not start there.

## 15.3 Scaling advice

If the product grows:

- operational graph should remain relatively compact (< 10K nodes per user)
- code graph should be per-repo and probably separately indexed
- long-term memory docs should stay summary-only
- graph writes must always be async / fire-and-forget
- Neptune Analytics supports up to 128 m-NCU; beyond that, consider Neptune Database Serverless
- embedding dimensions can be increased from 256→512→1024 as accuracy needs grow

---

## 16. What to avoid

1. **Do not build a generic "knowledge graph of everything."**
   - build a workflow graph for Abyss.

2. **Do not depend on LLM extraction for every edge.**
   - use structured tool/event signals first.

3. **Do not store full transcripts and full logs in the graph.**
   - store summaries, keys, references, and short artifacts only.

4. **Do not make graph retrieval block the critical path for too long.**
   - use fast path + timeout (match existing `MemoryService` timeout pattern: 1500ms budget).

5. **Do not make Bedrock KB your only retrieval source.**
   - use fallback recent-memory retrieval (existing).

6. **Do not duplicate existing `MemoryService` functionality.**
   - `ContextGraphService` wraps and extends it, never replaces.

7. **Do not over-embed.**
   - Only embed nodes that need semantic search: Goal, MemoryEpisode, Decision, Blocker, NextStep. Do not embed User, Session, Repo, Branch — those are looked up by exact key.

8. **Do not create graph nodes for every utterance or tool call in Phase 1.**
   - Start with session-boundary events only. Add mid-session events in Phase 2.

---

## 17. Recommended MVP build order

### Step 1 — Infrastructure + scaffold
- Provision Neptune Analytics graph (`aws neptune-graph create-graph ...`)
- Add IAM permissions to `abyss-ecs-task-role`
- Add env vars to `.env` and `.env.example`
- Create `server/src/contextGraph/types.ts` — node/edge/update type definitions
- Create `server/src/contextGraph/store/graphStore.ts` — interface
- Create `server/src/contextGraph/embedding/embeddingService.ts` — Titan Embed V2 wrapper
- Create `server/src/contextGraph/store/neptuneAnalyticsStore.ts` — Neptune implementation
- Test: verify Neptune connectivity and basic MERGE/MATCH queries

### Step 2 — ContextGraphService + conductor wiring (pass-through first)
- Create `server/src/contextGraph/contextGraphService.ts` wrapping `MemoryService`
- Wire into `server.ts` — replace `memoryService` with `contextGraphService` in conductor deps
- All existing behavior unchanged (pass-through to `MemoryService`)
- Test: existing memory hydration and summarization still works

### Step 3 — Graph population on session lifecycle
- Emit `session.start`, `goal.started`, `session.finalized` updates from conductor
- `ContextGraphService.apply()` creates User, Session, Goal, MemoryEpisode, Repo, Branch, Decision, Blocker, NextStep nodes in Neptune
- Embed Goal and MemoryEpisode text via Titan Embed V2
- Test: after a conversation, verify nodes and embeddings exist in Neptune

### Step 4 — Hybrid vector+graph retrieval
- Implement `hybridResumeQuery()` in Neptune store — the core hybrid openCypher query
- `retrieveResumeContext()` embeds the user's utterance, runs hybrid query, formats result
- Falls back to existing `MemoryService` pipeline on failure
- Test: start a new session, say something related to a past session, verify graph-enriched context is injected

### Step 5 — Bridge + Cursor + GitHub execution events (Phase 2)
- Wire `onGraphEvent` callback into `BridgeToolRouter`
- Add `ToolInvocation`, `BridgeCommandRun`, `CursorAgentRun` nodes with embeddings
- Embed tool invocation summaries for "what happened last?" queries
- Add `context.query` tool for explicit LLM-driven graph introspection

### Step 6 — Code-layer graph (Phase 3)
- Parse bridge filesystem and git results to create File, Patch, Test nodes
- Use graph for code-context-aware retrieval during active task planning

---

## 18. Files to add and modify

### New server modules
- `server/src/contextGraph/types.ts` — node, edge, update, and query result types
- `server/src/contextGraph/contextGraphService.ts` — main service wrapping MemoryService + graph
- `server/src/contextGraph/store/graphStore.ts` — interface with vector operations
- `server/src/contextGraph/store/neptuneAnalyticsStore.ts` — Neptune Analytics implementation (openCypher + vector)
- `server/src/contextGraph/embedding/embeddingService.ts` — Titan Text Embeddings V2 wrapper
- `server/src/contextGraph/retrieval/hybridRetriever.ts` — orchestrates embed → query → format pipeline

### New dependencies
- `@aws-sdk/client-neptune-graph` — Neptune Analytics SDK

### Existing files to modify (minimal changes)
- `server/src/core/types.ts` — add 2 fields to `SessionState` (`graphContextCache`, `lastGraphQueryTs`)
- `server/src/core/conductorService.ts` — swap `memoryService` for `contextGraphService`, add 3 `apply()` calls
- `server/src/server.ts` — construct `EmbeddingService` + `NeptuneAnalyticsStore` + `ContextGraphService`, wire to conductor
- `server/src/bridge/toolRouter.ts` — add optional `onGraphEvent` callback (Phase 2)
- `server/.env.example` — add Neptune + embedding config vars

### Files NOT to modify
- ~~`server/src/core/sessionStore.ts`~~ — no changes needed, `get()` already exists
- ~~`server/src/core/memory/memoryService.ts`~~ — no changes; `ContextGraphService` wraps it without modification

---

## 19. Bottom line

For Abyss, the right graph system is **not** a generic enterprise knowledge graph.

It is a **developer-workflow context graph** that sits on top of the current event-driven architecture and captures:

- goals
- repos / branches / PRs
- tool invocations
- bridge command runs
- cursor agent runs
- decisions / blockers / next steps
- memory episodes across sessions

The strongest architecture for this project is:

- **graph for structure and execution lineage**
- **semantic retrieval for fuzzy matching** (existing Bedrock KB)
- **session summaries for long-term memory** (existing MemoryService + S3)
- **short, graph-derived resume context injected into the conductor**

The implementation strategy is:

1. **Wrap, don't replace** — `ContextGraphService` composes with existing `MemoryService`
2. **Neptune Analytics** — real graph database with native vector search; hybrid openCypher queries combine graph traversal + semantic similarity in one call
3. **Titan Text Embeddings V2** — 256-dimension embeddings on Goal, MemoryEpisode, Decision, Blocker, NextStep nodes for semantic retrieval
4. **Fire-and-forget writes** — graph updates never block the conductor loop
5. **Graceful degradation** — if Neptune is unavailable, fall back to existing S3/KB pipeline
6. **Phase by value** — hybrid resume context first, execution graph second, code graph third

The technical differentiator is the **single-query hybrid retrieval**: one openCypher call to Neptune that finds semantically similar past goals via vector search, then traverses the graph to their repos, branches, blockers, and next steps. This is not possible with a flat vector index, an in-memory JSON graph, or separate graph + vector systems.

That is technically deep, highly specific to Abyss, and implementable in phases without breaking the current codebase.

---

## 20. Repo references used for this plan

The recommendations in this plan are grounded in the current Abyss codebase shape (verified 2026-03-16), especially:

- `server/src/core/conductorService.ts` — orchestration, tool routing, memory hydration, session finalization (2,774 lines)
- `server/src/core/sessionStore.ts` — session storage, Cursor run tracking, webhook queues (145 lines)
- `server/src/core/types.ts` — `SessionState` (already has `memoryUserKey`, `memoryHydrated`, `workingContext`), `ConversationTurn`, tool types (128 lines)
- `server/src/core/memory/memoryService.ts` — existing S3 + Bedrock KB memory system with summarization, retrieval, and timeout handling (367 lines)
- `server/src/server.ts` — dependency wiring, socket lifecycle, bridge registration, conductor instantiation, already calls `finalizeSession` on disconnect (876 lines)
- `server/src/bridge/state.ts` — bridge device/session/capability mapping, device resolution
- `server/src/bridge/toolRouter.ts` — bridge command lifecycle, Claude Code run orchestration, streaming output, cancellation
