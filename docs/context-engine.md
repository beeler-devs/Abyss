# Stage 3 Context Engine

## Goal

Build compact, high-signal context bundles for patch generation with deterministic budget controls.

## Retrieval pipeline

1. Direct file retrieval from stack paths (`failureSignals.stackPaths`) with highest priority.
2. Lexical path matching from `suggestedQueries`.
3. Embedding retrieval from indexed chunks (`embeddings.query`).
4. Config enrichment (`package.json`, test configs, tsconfig/playwright/jest/vitest files).
5. Current PR diff inclusion when available.

## Chunking + index strategy

- Excludes: `node_modules`, `dist`, `build`, `.next`, `coverage`.
- Text file focus: source + config + docs extensions.
- Chunk shape: ~80 lines with overlap for local semantic coherence.
- Embeddings provider interface allows swapping hash embeddings for Nova/OpenAI later.

## Budget model

`ContextBudget`:

- `maxChars`: hard cap across full files + snippets.
- `topFullFiles`: exact full-file payload count.
- `topSnippets`: snippet payload count.

Selection order is deterministic and short-circuits on budget saturation.

## Bundle schema

```json
{
  "goal": "Fix failing CI test and preserve behavior.",
  "failureSummary": "Failure signature test:abcd...",
  "logsExcerpt": "...",
  "fullFiles": [{ "path": "src/foo.ts", "content": "..." }],
  "snippets": [{ "path": "src/bar.ts", "startLine": 10, "endLine": 42, "text": "..." }],
  "configs": [{ "path": "package.json", "content": "..." }],
  "currentPrDiff": [{ "path": "src/foo.ts", "patch": "@@ ..." }],
  "constraints": {
    "allowedPaths": ["src/"],
    "noReformat": true,
    "maxDiffLines": 250,
    "mustFixSignature": "test:abcd"
  }
}
```

## Safety hooks

- Path allowlists can be passed from diagnosis signals.
- Patch validator enforces `maxDiffLines`, `noReformat`, and lockfile rules.
- Closed-loop algorithm halts on budget exhaustion and surfaces blocker artifacts.
