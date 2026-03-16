You are a senior full-stack engineer working in the existing Abyss codebase. Implement BEE-45: Bedrock Knowledge Bases — Semantic Conversation Memory as a hackathon-optimized “resume context memory” system that fits the current repository architecture.

This is not a generic chat-memory feature. It is a developer workflow resume system for Abyss.

The implementation must fit the current codebase shape:
- server/src/core/conductorService.ts owns the model/tool loop and session history
- server/src/core/sessionStore.ts stores SessionState
- server/src/server.ts wires dependencies and handles websocket close
- the app already has significant bridge/cursor/tooling context, so memory should remember development workflow state, not just chat summaries

GOAL

When an iOS session ends, Abyss should store a concise structured summary of the work done.
When a future session starts, Abyss should retrieve relevant prior memory and inject it as a short system context block before the first user turn.

Example desired UX:
- User opens Abyss and says: “Let’s continue the auth work.”
- Abyss already knows:
  - repo/branch/PR they were working on
  - what was accomplished
  - blockers / next steps
- Abyss responds with continuity:
  “You were working in storefront-web on branch feature/auth-v2. Unit tests passed after the refresh-token fix, but checkout validation still needs to be rerun before merging PR #42.”

NON-NEGOTIABLE PRODUCT REQUIREMENTS

1. Memory must be optional and fully gated by env vars.
2. Memory must never block the first model call for more than a short timeout.
3. Memory must store summaries only, not full raw conversation history.
4. Memory must fit the current codebase with minimal churn:
   - inject memory as a normal "system" ConversationTurn
   - do not redesign the conversation model
5. Memory must be developer-workflow aware:
   - repo / branch / PR / tools used / decisions / blockers / next steps
6. Use AWS-native components where possible:
   - S3 for stored memory documents
   - Bedrock Knowledge Bases for semantic retrieval
   - Nova 2 Lite (Bedrock) for summarization
7. For hackathon robustness, do not rely exclusively on KB retrieval:
   - add a recent-memory fallback path so resume works even if KB ingestion is delayed

CURRENT CODEBASE FACTS YOU MUST DESIGN AROUND

- ConductorService currently handles session.start, user.audio.transcript.final, tool.result, audio.output.interrupted, agent.completed, etc.
- runConductorLoop appends user turns into SessionStore.history and then calls the model.
- SessionStore currently stores session history, pending tool calls, transcript trace, active bridge command/device, but does not yet have memory fields.
- server.ts already injects optional dependencies into ConductorService and already owns websocket close cleanup.
- There is no full user-auth system here yet, so memory should use a stable client-provided user key rather than sessionId.

KEY DESIGN REFINEMENTS (MUST FOLLOW)

A) DO NOT key memory retrieval by sessionId alone.
A new websocket session gets a new sessionId, so retrieval must use a more stable identity.

Implement a stable field:
- memoryUserKey

This should come from session.start payload if provided.
If it is absent, memory should no-op gracefully.

B) Use structured developer memory documents.
Do not just store one freeform summary string.
Store both:
- structured metadata
- a short natural-language summary

Required memory document shape:

{
  "memoryUserKey": "user-123",
  "sessionId": "abc123",
  "timestamp": "2026-03-15T20:00:00Z",
  "summary": "Worked on auth refactor in storefront-web. Unit tests were run locally on the bridge. Checkout validation is still pending.",
  "repo": "storefront-web",
  "branch": "feature/auth-v2",
  "prUrl": "https://github.com/org/repo/pull/42",
  "status": "in_progress",
  "decisions": [
    "Use JWT with 24h expiry",
    "Keep refresh-token rotation"
  ],
  "blockers": [
    "Checkout validation not rerun after latest patch"
  ],
  "nextSteps": [
    "Re-run checkout validation on preview URL",
    "Merge if browser flow passes"
  ],
  "toolsUsed": [
    "bridge.exec.run",
    "bridge.git.commit",
    "cursor.agent.spawn"
  ],
  "turnCount": 14
}

C) Use a hybrid retrieval strategy for hackathon reliability.
Do not rely only on Bedrock KB, because ingestion may lag.

On session start:
1. Retrieve the most recent memory docs for the memoryUserKey from S3-backed metadata/index (fast path)
2. Also query Bedrock KB semantically if configured and retrieval succeeds in time
3. Merge results and inject a short “Prior context” system turn
4. If KB is slow or unavailable, continue with recent-memory fallback only

D) Keep prompt injection small.
Inject at most:
- 1 to 3 memory items
- about 600 to 1000 chars total
- concise “Prior context” bullets, not a giant dump

E) Only summarize meaningful sessions.
Do not summarize if:
- fewer than 3 turns AND
- no tools, decisions, repo context, blockers, or next steps

IMPLEMENTATION PLAN

PART 1 — Extend core types

Update:
- server/src/core/types.ts

Add to SessionState:
- memoryUserKey?: string
- memoryHydrated?: boolean
- workingContext?: {
    repo?: string;
    branch?: string;
    prUrl?: string;
    lastGoal?: string;
    activeExecutor?: "bridge" | "cursor" | "server";
  }

Do not break existing fields.

PART 2 — Extend SessionStore minimally

Update:
- server/src/core/sessionStore.ts

Add:
- get(sessionId: string): SessionState | undefined

Keep:
- getOrCreate()
- appendTurn()
- existing bridge/cursor helpers

Do not redesign SessionStore.

PART 3 — Add MemoryService

Create:
- server/src/core/memory/memoryService.ts

Implement the following types and class:

export interface MemoryServiceConfig {
  enabled: boolean;
  bucketName: string;
  knowledgeBaseId?: string;
  region: string;
  modelIdOrArn: string;
  maxRetrieveMs?: number;
  maxInjectedChars?: number;
}

export interface MemoryRetrieveInput {
  memoryUserKey: string;
  firstMessage?: string;
  repoHint?: string;
  branchHint?: string;
}

export interface WorkingContextSnapshot {
  repo?: string;
  branch?: string;
  prUrl?: string;
  lastGoal?: string;
  activeExecutor?: string;
}

export class MemoryService {
  constructor(config: MemoryServiceConfig) {}

  async summarizeAndStore(params: {
    memoryUserKey: string;
    sessionId: string;
    history: ConversationTurn[];
    workingContext?: WorkingContextSnapshot;
  }): Promise<void> {}

  async retrieveContext(input: MemoryRetrieveInput): Promise<string | null> {}
}

MemoryService behavior:

If disabled or not configured:
- behave as a no-op

summarizeAndStore:
1. Filter history to user and assistant turns only
2. Extract structured workflow context from workingContext
3. If not meaningful, skip
4. Use Bedrock Nova 2 Lite to generate:
   - short summary
   - decisions
   - blockers
   - nextSteps
   - toolsUsed (heuristic extraction is acceptable)
   - status
5. Write one JSON memory doc to S3
6. Path:
   memories/{memoryUserKey}/{timestamp}-{sessionId}.json
7. Trigger Bedrock KB ingestion if KB ID is configured
8. Log errors and swallow them

retrieveContext:
1. Run under a hard timeout (default 1500 to 2000 ms)
2. Load recent memory docs for memoryUserKey (latest few)
3. Optionally query KB using a semantic query composed from:
   - firstMessage
   - repoHint
   - branchHint
4. Merge and dedupe memories
5. Return a short formatted string like:

   Prior context:
   - You were working in storefront-web on branch feature/auth-v2.
   - Unit tests passed after the refresh-token fix.
   - Checkout validation still needs to be rerun before merging PR #42.

6. If nothing useful is found, return null

Important:
- Bedrock KB is an enhancement, not the only retrieval path
- implement recent-memory fallback even if KB is disabled

PART 4 — Add lightweight memory index helper

For recent-memory fallback, implement a fast path that does not depend on semantic retrieval.

Preferred option:
- list latest S3 objects under memories/{memoryUserKey}/ and fetch the top few JSON docs

Optional fallback:
- maintain a tiny in-memory cache plus S3 fallback

Keep it simple and reliable.

PART 5 — ConductorService integration

Update:
- server/src/core/conductorService.ts

Add to ConductorServiceDependencies:
- memoryService?: MemoryService

Handle session.start:
- if payload.memoryUserKey is a string, store it in session
- do not require it

Handle first user.audio.transcript.final:
Before the first call to runConductorLoop, if:
- session.memoryHydrated is not true
- session.memoryUserKey exists
- memoryService exists

Then:
1. call memoryService.retrieveContext(...)
2. if non-null, append one "system" turn to session history
3. set session.memoryHydrated = true
4. optionally emit:
   - session.memory.loaded with a small preview string for UI/debugging

Important:
- do this only once per session
- do not block for more than the configured timeout

Add a new public method:

async finalizeSession(sessionId: string): Promise<void>

Implementation:
- use this.sessions.get(sessionId), not getOrCreate
- if no session, return
- if no memoryUserKey, return
- if no memoryService, return
- gather history and workingContext
- call memoryService.summarizeAndStore(...)
- swallow and log errors

PART 6 — Working-context tracking inside ConductorService

This is required so memory is useful.

Add lightweight updates to session.workingContext in places where data already exists:
- In runConductorLoop, set workingContext.lastGoal = transcript for normal user turns
- When bridge tools are used:
  - bridge.git.status result can populate branch
  - bridge.git.push can preserve branch/executor
  - any bridge tool use can set activeExecutor = "bridge"
- When cursor tools are used:
  - cursor.agent.spawn and webhook routing should update:
    - activeExecutor = "cursor"
    - prUrl
    - branch
- If repo URLs or repo names are available in spawn args, capture repo
- Keep this heuristic and lightweight; do not overcomplicate

PART 7 — server.ts wiring

Update:
- server/src/server.ts

Add env vars:
- MEMORY_ENABLED=false
- MEMORY_BUCKET_NAME=abyss-memory
- MEMORY_KB_ID=
- MEMORY_MODEL_ID=us.amazon.nova-2-lite-v1:0
- MEMORY_MAX_RETRIEVE_MS=1500
- MEMORY_MAX_INJECTED_CHARS=900

Construct memoryService if enabled and pass it into ConductorService.

On iOS websocket close:
after existing cleanup, call:
- void conductor.finalizeSession(context.sessionId)

Do not await it.

PART 8 — AWS implementation details

Use:
- S3 for memory docs
- Bedrock Runtime / Converse or InvokeModel for summarization
- Bedrock Knowledge Bases Retrieve or RetrieveAndGenerate and StartIngestionJob for semantic memory
- Titan embeddings are handled by KB setup, not by app code

Memory S3 path:
- memories/{memoryUserKey}/{timestamp}-{sessionId}.json

IAM needs:
- S3 Put/Get/List on the memory bucket
- Bedrock Retrieve / RetrieveAndGenerate / StartIngestionJob
- Bedrock model invoke for Nova summarization

PART 9 — Documentation

Add:
- docs/memory/overview.md
- docs/memory/aws-setup.md
- docs/memory/schema.md

Update:
- .env.example
- README or server setup docs to mention optional memory

Document:
- why memory uses memoryUserKey, not sessionId
- why there is a recent-memory fallback in addition to KB
- that full transcripts are not stored

TESTING REQUIREMENTS

Unit tests:
1. MemoryService.summarizeAndStore
   - skips meaningless sessions
   - writes structured JSON doc
   - triggers ingestion when configured
2. MemoryService.retrieveContext
   - returns null when disabled
   - returns recent-memory fallback when KB is unavailable
   - obeys timeout
   - truncates injected context
3. ConductorService
   - on first user turn, injects memory as a system turn when available
   - does not inject twice in the same session
4. finalizeSession
   - no-ops safely when session is missing, short, or disabled
   - calls summarize when meaningful

Integration tests:
- mock recent memory plus mocked KB retrieval and verify that the system turn is inserted before first user turn
- simulate socket close and verify finalizeSession is triggered fire-and-forget

IMPORTANT IMPLEMENTATION CONSTRAINTS

- Do not redesign the model/provider abstraction for the main conductor
- Do not store raw tool output or full transcripts in S3
- Do not make KB retrieval mandatory
- Do not make memory depend on bridge, cursor, or gmail internals
- Do not break existing Stage 2, bridge, cursor, or gmail flows

ACCEPTANCE CRITERIA

1. With MEMORY_ENABLED=false, behavior is unchanged.
2. With MEMORY_ENABLED=true, ending a meaningful session writes a structured memory document to S3.
3. Starting a new session with the same memoryUserKey can inject relevant prior context before the first model turn.
4. If KB retrieval is slow or not yet ingested, recent-memory fallback still provides useful resume context.
5. Memory injection is short, helpful, and developer-workflow-specific.

OUTPUT REQUIREMENTS

When done:
1. show the updated file tree
2. provide full contents of all new and modified files
3. include .env.example updates
4. include any AWS setup notes required to run the feature
5. ensure the feature is safe-by-default and disabled unless configured

START NOW: implement this refined memory system so it fits the current Abyss codebase exactly.