# Bridge v1 MVP

Bridge v1 makes Abyss Bridge usable as a real-time voice IDE bridge:

- Real-time command streaming (`bridge.exec.start` + `bridge.exec.output` / `bridge.exec.finished`)
- Command cancellation (`bridge.exec.cancel`)
- Safe workspace-scoped file tools (`bridge.fs.search`, `bridge.fs.readRange`, `bridge.fs.applyPatch`)
- Git workflow tools (`bridge.git.status`, `bridge.git.diff`, `bridge.git.stage`, `bridge.git.commit`, `bridge.git.push`)
- Workspace allowlist + denylist enforcement in BridgeCore
- Backward compatibility with Bridge v0 tools (`bridge.exec.run`, `bridge.fs.readFile`)

## What Changed

## Protocol and tooling

- Added/updated schemas in:
  - `shared/protocol/schemas/bridge-tools.schema.json`
  - `shared/protocol/schemas/bridge-events.schema.json`
- Added typed protocol models in:
  - `shared/libs/swift-protocol/Sources/SwiftProtocol/EventEnvelope.swift`
  - `shared/libs/ts-protocol/src/index.ts`

## BridgeCore (mac)

- Added `CommandManager`:
  - start/status/cancel lifecycle
  - near real-time stdout/stderr streaming callbacks
  - timeout enforcement (max 900s)
  - cancellation: SIGINT then SIGKILL fallback
  - rolling output tails (default 200KB per stream)
- Expanded `WorkspacePolicy`:
  - multiple allowlisted roots
  - strict path normalization inside roots
  - denylist patterns (e.g. `.env`, `*.pem`, `id_rsa`, `node_modules/**`)
- Added new tool handlers:
  - `bridge.exec.*` (start/cancel/status/output.subscribe + v0 run)
  - `bridge.fs.search`, `bridge.fs.readRange`, `bridge.fs.applyPatch`
  - `bridge.git.status`, `bridge.git.diff`, `bridge.git.stage`, `bridge.git.commit`, `bridge.git.push`

## Server

- Bridge router now forwards bridge-origin streaming events:
  - `bridge.exec.output`
  - `bridge.exec.finished`
- `bridge.exec.run` compatibility path implemented via start + finished correlation.
- Added active command run-control support in bridge router:
  - tracks per-session active command
  - exposes cancellation for audio interruption flow
- `audio.output.interrupted` now triggers bridge cancel attempt for active command.

## macOS app (`mac/AbyssBridge`)

- Multi-workspace management:
  - add/remove workspaces
  - persist with security-scoped bookmarks
  - select active workspace
- Permissions UI:
  - allow command execution
  - allow writes/applyPatch/git stage+commit
  - allow git push
  - require git push confirmation
- Live status improvements:
  - paired + online/offline
  - active command details and live tail
  - cancel active command button

## iOS

- Added event support for:
  - `bridge.exec.output`
  - `bridge.exec.finished`
- Timeline rendering includes streaming and finished bridge exec events.

## Requirements

- macOS 13+
- Node.js 20+
- Xcode / Swift 5.9+
- `git` available in `PATH`
- `rg` (ripgrep) recommended for `bridge.fs.search`
  - fallback scanner is used when `rg` is unavailable

## Environment and Local Config

No secrets are committed. Configure locally:

- Root `.env.example` (project-level guidance)
- `server/.env.example` (runtime server settings)

Minimum server setup:

- `ANTHROPIC_API_KEY` (if using Anthropic provider)
- Optional bridge settings:
  - `BRIDGE_PAIRING_TTL_MS`

## Setup

## 1) Server

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm install
cp .env.example .env
npm run dev
```

## 2) macOS bridge

```bash
cd /Users/bentontameling/Dev/VoiceBot2/mac/AbyssBridge
swift run
```

In app:

1. Add one or more workspace roots.
2. Generate/copy pairing code.
3. Set permissions for your environment.
4. Keep `Allow command execution` enabled for exec tools.

## 3) iOS app

- Connect iOS app to the same backend.
- Pair using the generated Bridge code.

## Usage Notes

- Streaming command output is delivered as events; assistant speech should summarize status, not read full logs.
- `bridge.fs.applyPatch` uses `git apply` and refuses paths outside allowed workspaces or denied patterns.
- `bridge.git.push` is guarded by app permission and optional confirmation modal.

## Smoke Checklist (v1)

1. Pair iOS and Mac bridge.
2. Voice: `Run npm test`
   - verify `bridge.exec.output` events stream
   - verify `bridge.exec.finished` and final tool result
3. Voice: `Stop`
   - verify `audio.output.interrupted` leads to cancel attempt
   - running command transitions to cancelled/timed_out/failed appropriately
4. Voice: `Search for refreshToken`
   - verify `bridge.fs.search` matches returned
5. Voice: `Open src/auth.ts around line 80`
   - verify `bridge.fs.readRange`
6. Voice: `Apply this patch`
   - verify `bridge.fs.applyPatch` success/failure reason
7. Voice: `Git status`
   - verify branch + changed/staged files
8. Voice: `Stage and commit with message Fix failing test`
   - verify `bridge.git.stage` then `bridge.git.commit`

## Compatibility

Bridge v0 behavior is preserved:

- `bridge.exec.run`
- `bridge.fs.readFile`

`bridge.exec.run` is now backed by v1 command lifecycle on the server side and still returns v0-shaped result payload.
