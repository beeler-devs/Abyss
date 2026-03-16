# Memory Document Schema

## S3 Key Format

```
memories/{memoryUserKey}/{ISO-timestamp}-{sessionId}.json
```

Example:
```
memories/user_abc123/2026-03-15T20-00-00-000Z-sess_xyz789.json
```

The `{ISO-timestamp}` has colons and dots replaced with hyphens to be S3-safe. S3 `ListObjectsV2` with this prefix returns all sessions for a given user, sorted by `LastModified`.

---

## Document Fields

```typescript
interface MemoryDocument {
  memoryUserKey: string;      // Stable user identifier across sessions
  sessionId: string;          // Session that generated this memory
  timestamp: string;          // ISO 8601 (e.g. "2026-03-15T20:00:00.000Z")
  summary: string;            // LLM-generated paragraph summary

  // Working context (optional — populated from session state)
  repo?: string;              // GitHub repo in "owner/repo" format
  branch?: string;            // Git branch name
  prUrl?: string;             // Pull request URL if created
  lastGoal?: string;          // Last user utterance / active task description
  activeExecutor?: string;    // Active Cursor agent ID or bridge executor name

  // Structured extractions (optional — populated by summarization LLM)
  decisions?: string[];       // Key decisions made during the session
  blockers?: string[];        // Blockers encountered
  nextSteps?: string[];       // Next steps planned
}
```

---

## Example Document

```json
{
  "memoryUserKey": "user_abc123",
  "sessionId": "sess_xyz789",
  "timestamp": "2026-03-15T20:00:00.000Z",
  "summary": "User worked on JWT auth refactor in the abyss-server repo. Decided to use 24-hour token expiry with refresh tokens stored in Redis. Branch feature/auth-v2 was created. Hit a blocker with the AWS Secrets Manager SDK version mismatch.",
  "repo": "bentontameling/abyss-server",
  "branch": "feature/auth-v2",
  "prUrl": null,
  "lastGoal": "fix the secrets manager SDK import error",
  "activeExecutor": null,
  "decisions": [
    "Use 24-hour JWT expiry with refresh tokens",
    "Store refresh tokens in Redis, not DynamoDB"
  ],
  "blockers": [
    "AWS Secrets Manager SDK version mismatch with Node 22"
  ],
  "nextSteps": [
    "Pin @aws-sdk/client-secrets-manager to v3.x",
    "Write integration test for token refresh flow",
    "Open PR once tests pass"
  ]
}
```

---

## Notes

- Fields with `null` values are omitted when writing to S3 (`undefined` fields are stripped by `JSON.stringify`).
- `summary` is always present; all other fields except `memoryUserKey`, `sessionId`, and `timestamp` are optional.
- Documents are never updated — each session produces a new file. Old files accumulate and the most recent `MEMORY_RECENT_COUNT` are used for retrieval.
- The summarization LLM generates `summary`, `decisions`, `blockers`, and `nextSteps`. The remaining fields are populated directly from `WorkingContextSnapshot` tracked by `ConductorService`.
