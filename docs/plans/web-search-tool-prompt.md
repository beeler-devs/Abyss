# Cloud Agent Prompt: Implement Web Search Tool (BEE-61)

---

You are a senior engineer working in the **Abyss** codebase — a voice-first AI conductor architecture. Your task is to implement a `web.search` server-side tool that allows the LLM to search the web during voice conversations.

Read `CLAUDE.md` at the repo root before starting. It contains architecture context and development commands.

---

## What Already Exists (Do Not Change)

- `server/src/core/conductorService.ts` — owns all tool definitions and server-side tool dispatch. Follow the existing Gmail integration as your exact model.
- `server/src/integrations/gmailClient.ts` — the pattern you must follow: a class with typed methods, each taking `session: SessionState` as first arg.
- `server/src/server.ts` — constructs integrations and injects them into `ConductorService` via `ConductorServiceDependencies`.
- `server/src/core/types.ts` — `SessionState` and all shared types. **Do not add fields to `SessionState`** — web search needs no session-level state.
- `.env.example` — already has entries for all optional integrations. You will add two new ones.

---

## What You Must Build

### 1. `server/src/integrations/searchClient.ts` (NEW)

A focused HTTP client for the Brave Search API. Model it after `gmailClient.ts` structurally.

**Class shape:**

```typescript
export interface SearchClientConfig {
  apiKey: string;
  timeoutMs?: number;
}

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

export interface SearchResponse {
  query: string;
  results: SearchResult[];
}

export class SearchClient {
  constructor(config: SearchClientConfig) {}

  isConfigured(): boolean   // returns true if apiKey is non-empty

  async search(query: string, maxResults?: number): Promise<SearchResponse>
}
```

**Implementation details:**
- Base URL: `https://api.search.brave.com/res/v1/web/search`
- Auth header: `X-Subscription-Token: ${apiKey}`
- Accept header: `Accept: application/json`
- Query params: `q={query}&count={maxResults}&text_decorations=false&search_lang=en`
- Default `maxResults`: 5, max 10
- Default timeout: 10s
- Parse `web.results` array from the Brave response — each item has `title`, `url`, `description` (map to `snippet`)
- Truncate each snippet to 300 chars to keep model context bounded
- Error format: `search_http_<status>:<body-snippet>` (same pattern as gmailClient)
- If `web.results` is absent or empty in the response, return `{ query, results: [] }`

---

### 2. Tool definition in `server/src/core/conductorService.ts` (MODIFY)

Add a new `SERVER_SEARCH_TOOLS` constant following the exact same pattern as `SERVER_CURSOR_TOOLS` and the Gmail tool block.

**Tool definition:**

```typescript
const SERVER_SEARCH_TOOLS: ToolDefinition[] = [
  {
    name: "web.search",
    description:
      "Search the web for current information. Use when the user asks about something that may have changed since your training data — package versions, documentation, error messages, news, API changes, prices, or any real-time fact. Always summarize results conversationally rather than reading URLs aloud. If results are not useful, say so rather than guessing.",
    input_schema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "The search query. Be specific — include version numbers, library names, or error text when relevant.",
        },
        maxResults: {
          type: "number",
          description: "Number of results to fetch (default 5, max 10). Use 3 for quick lookups, 8-10 for research tasks.",
        },
      },
      required: ["query"],
    },
  },
];
```

**Availability guard** — append tools only when search is configured. Add after the Gmail availability block in `listAvailableTools()`:

```typescript
if (this.deps.searchClient?.isConfigured()) {
  tools.push(...SERVER_SEARCH_TOOLS);
}
```

**Dispatch block** — in the server-side tool execution section (where `shouldExecuteServerTool` routes to `executeServerTool`), add a case for `web.search`:

```typescript
if (toolName === "web.search") {
  const query = asString(input.query ?? "");
  const maxResults = typeof input.maxResults === "number" ? input.maxResults : undefined;
  if (!query) {
    return JSON.stringify({ error: "search_missing_query" });
  }
  const response = await this.deps.searchClient!.search(query, maxResults);
  return stableJSONStringify(response);
}
```

**`shouldExecuteServerTool`** — add `web.search` to the list of server-executed tools alongside the existing Gmail and Cursor tools.

---

### 3. `server/src/server.ts` (MODIFY)

**Add env var reads** near the other integration config vars:

```typescript
const SEARCH_API_KEY = process.env.SEARCH_API_KEY ?? "";
```

**Construct and inject** alongside `gmailClient`:

```typescript
import { SearchClient } from "./integrations/searchClient.js";

const searchClient = new SearchClient({ apiKey: SEARCH_API_KEY });
```

Pass into `ConductorService`:

```typescript
const conductor = new ConductorService(provider, config, {
  // ... existing deps ...
  searchClient,
});
```

**Add to `ConductorServiceDependencies`** in `conductorService.ts`:

```typescript
export interface ConductorServiceDependencies {
  // ... existing fields ...
  searchClient?: SearchClient;
}
```

---

### 4. `.env.example` (MODIFY)

Add after the Canvas comment:

```
# Web search (Brave Search API — https://brave.com/search/api/)
# Get a free API key at https://api.search.brave.com/
SEARCH_API_KEY=
```

---

### 5. Tests

**`server/tests/searchClient.test.ts`** (NEW)

Follow the same structure as `server/tests/githubClient.test.ts`. Use Node's built-in test runner (`import test from "node:test"`).

Tests to write:

1. `isConfigured()` returns false when apiKey is empty, true when set
2. `search()` sends the correct URL, query params, and `X-Subscription-Token` header — mock `fetch` globally
3. Non-2xx response throws with `search_http_<status>` prefix
4. Response with `web.results` array is normalized to `SearchResponse` shape with snippets truncated to 300 chars
5. Response with no `web.results` returns `{ query, results: [] }` without throwing
6. `maxResults` param is clamped to 10

**`server/tests/conductorService.test.ts`** (MODIFY)

Add two tests following the existing `ToolCaptureProvider` + `SequenceProvider` patterns already in that file:

1. `web.search` tool does NOT appear in available tools when `searchClient` is not injected
2. `web.search` tool DOES appear when a configured `SearchClient` is injected
3. A `web.search` tool call is dispatched server-side and returns the search result JSON

---

## Verification

After implementing, run from the `server/` directory:

```bash
npm test       # all tests must pass
npm run build  # TypeScript must compile cleanly
```

Do not leave any `console.log` calls. Use the existing `logger` from `server/src/core/logger.ts` for any debug output.

---

## What NOT to Change

- `server/src/core/types.ts` — no changes needed
- `server/src/voice/` — no changes
- `server/src/bridge/` — no changes
- `ios/` — no changes
- `mac/` — no changes
- Any existing tool definitions — do not modify them

---

## Delivery Checklist

- [ ] `server/src/integrations/searchClient.ts` created
- [ ] `server/src/core/conductorService.ts` updated: `SearchClient` dep, `SERVER_SEARCH_TOOLS`, availability guard, dispatch case, `shouldExecuteServerTool`
- [ ] `server/src/server.ts` updated: env var read, `SearchClient` construction, injection
- [ ] `.env.example` updated with `SEARCH_API_KEY`
- [ ] `server/tests/searchClient.test.ts` created
- [ ] `server/tests/conductorService.test.ts` updated with search tool tests
- [ ] `npm test` passes
- [ ] `npm run build` passes
