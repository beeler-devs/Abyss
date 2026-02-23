# Stage 3 Tool Server Catalog

## Tool execution targets

- `client`: emitted as `tool.call` to iOS, resolved via `tool.result`.
- `server`: executed in backend ToolRegistry and fed back into the conductor loop.

## GitHub tools

- `github.repo.list {limit?}`
- `github.repo.getDefaultBranch {repo}`
- `github.file.get {repo, ref, path}`
- `github.tree.list {repo, ref, path?}`
- `github.search.code {repo, query, ref?}`
- `github.branch.create {repo, baseRef, newBranch, idempotencyKey?}`
- `github.pr.openOrUpdate {repo, base, head, title, body, draft?, idempotencyKey?}`
- `github.pr.diff {repo, prNumber}`
- `github.pr.comment {repo, prNumber, body, idempotencyKey?}`
- `github.pr.merge {repo, prNumber, method}`
- `github.checks.list {repo, refOrPr?, prNumber?}`
- `github.applyPatchToBranch {repo, branch, unifiedDiff, commitMessage?, idempotencyKey?}`

## CI tools

- `ci.checks.list {repo, prNumber}`
- `ci.checks.logs {repo, checkRunId}`
- `ci.checks.rerun {repo, checkRunId}`
- `ci.workflow.dispatch {repo, workflow, ref, inputs?}`
- `ci.workflow.status {repo, runId}`

## Diagnosis + context tools

- `diagnose.ciFailure {logsExcerpt}`
- `embeddings.indexRepo {repo, ref}`
- `embeddings.updateChangedFiles {repo, ref, changedPaths}`
- `embeddings.query {repo, ref, query, topK?}`
- `context.buildBundle {repo, ref, goal, failureSignals, constraints, budget}`

## Patch tools

- `patch.generateDiff {provider?, model?, contextBundle, constraints}`
- `patch.validate {unifiedDiff, constraints}`

## Preview/Web QA tools

- `preview.findUrl {repo, prNumber}`
- `webqa.run {url, flowSpec, assertions, budget?}`
- `webqa.status {runId}`
- `webqa.artifacts {runId}`

## Policy + merge tools

- `policy.checkMerge {repo, prNumber, requireWebQA?, requireChecksGreen?, webqaPass?}`
- `github.pr.merge {repo, prNumber, method}`

## Runner tools (interface ready, stub provider)

- `runner.start {repo, ref}`
- `runner.exec {runId, command, timeoutSec?}`
- `runner.applyPatch {runId, unifiedDiff}`
- `runner.commitAndPush {runId, message}`
- `runner.stop {runId}`

## High-level orchestration helpers

- `stage3.runTests {repo?, baseRef?}`
- `stage3.fixFailingTest {repo?, prNumber?, maxIterations?, maxCiWaitMs?}`

## Artifact events

Server tools publish timeline artifacts via `assistant.ui.patch` JSON payloads:

```json
{
  "stage": "stage3",
  "title": "CI Summary",
  "body": "Failing check: unit-tests (failure).",
  "data": { "prUrl": "https://github.com/.../pull/123" }
}
```
