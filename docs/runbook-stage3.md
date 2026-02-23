# Stage 3 Runbook

## Quick checks

1. `npm run build` in `/Users/bentontameling/Dev/VoiceBot2/server`.
2. `npm test` in `/Users/bentontameling/Dev/VoiceBot2/server`.
3. Verify iOS backend URL and GitHub auth in Settings.

## Required config

- Server `.env`: Anthropic + GitHub OAuth vars.
- iOS `Secrets.plist`: `BACKEND_WS_URL`, optional `CURSOR_API_KEY`, `ELEVENLABS_API_KEY`.
- iOS Settings: optional `Preferred Repo (owner/repo)`.

## Debugging by stage

### 1) Repo selection / run tests

- Check inbound `session.start` carries `githubToken` and optional `selectedRepo`.
- Confirm model calls `stage3.runTests` or `github.repo.*` + `ci.checks.list`.
- If checks missing: inspect PR branch/ref resolution and `github.checks.list` output.

### 2) Fix loop

- Confirm `diagnose.ciFailure` returns non-empty signature.
- Inspect `context.buildBundle` payload size and selected files.
- If patch generation fails: verify `ANTHROPIC_API_KEY` and context budgets.
- If patch rejected: inspect `patch.validate` violations.

### 3) Preview + web validation

- `preview.findUrl` searches check URLs then PR comments.
- If no URL found, artifact emits `preview_url_not_found`.
- Stub WebQA validates HTTP fetch + title/assertions.

### 4) Merge gate

- `policy.checkMerge` blocker list is authoritative.
- Never merge if blockers exist unless explicit override policy is introduced.

## Event timeline cues

- `agent.status` with `server_tool` details indicates backend tool execution progress.
- `assistant.ui.patch` with `stage=stage3` contains PR/CI/patch/webqa artifacts.
- `tool.call` events should remain client-executed only.

## Common failure signatures

- `missing_github_token`: session started without OAuth token.
- `repo_not_selected`: no repo in args or session state.
- `patch_generate_failed:*`: provider call or prompt output issue.
- `patch_validation_failed:*`: safety constraints blocked diff.
- `preview_url_not_found`: deployment URL unavailable in checks/comments.

## Safe recovery

1. Ask user to confirm repo and rerun `stage3.runTests`.
2. Increase budget (`maxIterations` or `maxCiWaitMs`) only with user confirmation.
3. If still blocked, post PR comment with diagnosis and stop automatic loop.
