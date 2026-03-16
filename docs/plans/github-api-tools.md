# BEE-46: GitHub API Tools for Voice-Driven PR and Issue Workflows

## Mandatory Setup

This feature should be built in a dedicated git worktree, not in the main checkout.

Recommended command:

```bash
git worktree add ../VoiceBot2-github-api-tools -b codex/github-api-tools
```

Reason:
- This change touches the conductor, provider guidance, and server wiring in the same slice.
- The server test suite is broad, and isolating the work avoids mixing this feature with unrelated local changes.
- The repo already has multiple moving parts (`server`, `ios`, `mac`); a worktree keeps the feature branch clean and reviewable.

## What Already Exists

- GitHub OAuth exchange already exists in [`server/src/server.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/server.ts).
- The iOS app already sends `payload.githubToken` on `session.start`.
- `SessionState.githubToken` already exists in [`server/src/core/types.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/core/types.ts).
- [`ConductorService`](/Users/bentontameling/Dev/VoiceBot2/server/src/core/conductorService.ts) already has the exact server-side integration shape we should follow for Gmail and bridge tools.

This means the GitHub work is a server-side tool integration, not a protocol or auth redesign.

## Scope

Implement server-side GitHub REST tools that let the model inspect and act on pull requests, workflow runs, issues, and repositories using the existing session token.

In scope:
- New `GitHubClient` integration class.
- New `github.*` tool definitions in the conductor.
- Server-side tool dispatch for those tools.
- Dependency wiring from [`server/src/server.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/server.ts).
- Provider instruction updates so both model backends use the tools correctly.
- Tests for client behavior, tool availability, and dispatch.

Out of scope:
- iOS auth UX changes.
- Bridge changes.
- Shared protocol/schema changes.
- A new `github.authenticate` client tool. There is no existing iOS tool for that flow, so this plan keeps auth unchanged and only exposes GitHub tools when a session already has a token.

## Files To Change

- Create [`server/src/integrations/githubClient.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/integrations/githubClient.ts)
- Modify [`server/src/core/conductorService.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/core/conductorService.ts)
- Modify [`server/src/server.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/server.ts)
- Modify [`server/src/providers/bedrockNovaProvider.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/providers/bedrockNovaProvider.ts)
- Modify [`server/src/providers/anthropicProvider.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/providers/anthropicProvider.ts)
- Add tests in [`server/tests/conductorService.test.ts`](/Users/bentontameling/Dev/VoiceBot2/server/tests/conductorService.test.ts)
- Add [`server/tests/githubClient.test.ts`](/Users/bentontameling/Dev/VoiceBot2/server/tests/githubClient.test.ts)

No changes should be needed in [`server/src/core/types.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/core/types.ts) beyond using the existing `githubToken`.

## Implementation Plan

### Phase 1: Establish the server integration shape

Follow the same pattern already used for Gmail:
- `ConductorServiceDependencies` gets an optional `githubClient`.
- `ConductorService` stores it on the instance.
- `availableTools()` appends `github.*` tools only when a session has `githubToken` and `githubClient` is present.
- `shouldExecuteServerTool()` treats `github.*` as server-side tools.
- `executeServerTool()` dispatches each `github.*` tool and returns `stableJSONStringify(...)` payloads.

Important correction to the old plan:
- [`server/src/server.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/server.ts) must construct and inject `GitHubClient`, just like it already does for `GmailClient`. Without that wiring, the conductor cannot expose or execute the new tools.

### Phase 2: Add `GitHubClient`

Create a focused REST client in [`server/src/integrations/githubClient.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/integrations/githubClient.ts).

Design requirements:
- Base URL: `https://api.github.com`
- Auth: `Authorization: Bearer ${session.githubToken}`
- Headers: `Accept: application/vnd.github+json`
- Timeout: 15s by default
- Error format: `github_http_<status>:<body-snippet>`
- Authentication check: `!!session.githubToken`

Methods to implement:
- `listRepos`
- `listPRs`
- `getPR`
- `getReviews`
- `getActionsStatus`
- `listIssues`
- `createPR`
- `mergePR`
- `createIssue`

Normalization rules:
- Return repo names as `owner/repo`.
- Normalize PR state so merged PRs surface as `"merged"` rather than only `"closed"`.
- Truncate long review/comment bodies to keep model context bounded.
- For workflow status, collapse the latest runs into a small summary with an overall state plus recent runs.

Implementation note:
- Use a small internal request helper and keep all GitHub response shaping in the client. `ConductorService` should remain thin and only validate args plus serialize results.

### Phase 3: Add tool definitions

Add a `SERVER_GITHUB_TOOLS` constant in [`server/src/core/conductorService.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/core/conductorService.ts).

Initial tool set:
- `github.repos.list`
- `github.pr.list`
- `github.pr.get`
- `github.pr.reviews`
- `github.actions.status`
- `github.issues.list`
- `github.pr.create`
- `github.pr.merge`
- `github.issues.create`

Tool description requirements:
- Be explicit about when to use each tool.
- Tell the model not to guess `owner/repo` if it is unknown.
- Mark write tools as confirmation-gated.

Safety rule:
- `github.pr.create`, `github.pr.merge`, and `github.issues.create` should mirror the Gmail safety posture. Their descriptions should explicitly require the assistant to present the intended action and get user confirmation before calling the tool.

### Phase 4: Update provider guidance

Both model backends need the same behavior guidance:
- [`server/src/providers/bedrockNovaProvider.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/providers/bedrockNovaProvider.ts)
- [`server/src/providers/anthropicProvider.ts`](/Users/bentontameling/Dev/VoiceBot2/server/src/providers/anthropicProvider.ts)

Add short system instructions covering:
- Use `github.*` tools when the user asks about PRs, issues, CI, or repos and those tools are available.
- Do not guess repository names; use `github.repos.list` first if needed.
- Before `github.pr.create`, `github.pr.merge`, or `github.issues.create`, require explicit user confirmation.

This keeps behavior aligned across Bedrock and Anthropic instead of relying only on tool descriptions.

### Phase 5: Testing

Add targeted tests instead of relying on manual GitHub calls.

`server/tests/githubClient.test.ts`
- Auth check fails without token.
- Request helper sends the expected GitHub headers.
- Non-2xx responses become `github_http_*` errors.
- PR, review, issue, and workflow payloads are normalized into the intended shapes.

`server/tests/conductorService.test.ts`
- GitHub tools are absent when there is no session token.
- GitHub tools appear after `session.start` with `githubToken`.
- A representative GitHub tool call is executed server-side through `githubClient`.
- Write tools reject missing required arguments cleanly.

If provider instructions are changed materially, add or extend provider tests to assert the new guidance is present.

### Phase 6: Verification

Run the normal server checks from the feature worktree:

```bash
cd server
npm test
npm run build
```

If any new tests are added for only this feature, they should still pass under the existing `npm test` entrypoint rather than requiring a one-off script.

## Suggested Delivery Order

1. Create the worktree and confirm the server test baseline there.
2. Implement `GitHubClient` with unit tests first.
3. Wire `githubClient` into `server.ts` and `ConductorService`.
4. Add read-only tools and conductor tests.
5. Add confirmation-gated write tools.
6. Update provider prompts.
7. Run `npm test` and `npm run build`.

## Acceptance Criteria

- A session with `githubToken` exposes GitHub tools; a session without it does not.
- The conductor executes `github.*` tools on the server, not through iOS or Bridge.
- GitHub responses are normalized into compact JSON the model can reason over.
- Write actions require explicit confirmation in both tool descriptions and provider guidance.
- The implementation is isolated in a dedicated git worktree for development and review.
- Server tests and build pass from the worktree.
