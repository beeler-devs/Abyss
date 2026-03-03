# Tool Catalog (Bridge v1)

Bridge tools are server-routed to paired macOS bridge devices and still use formal `tool.call -> tool.result` envelopes.

## Execution

### `bridge.exec.run` (compat)

Arguments:

```json
{
  "deviceId": "string (optional)",
  "command": "string",
  "cwd": "string (optional, relative to workspace root)",
  "timeoutSec": 60
}
```

Result:

```json
{
  "exitCode": 0,
  "stdout": "...",
  "stderr": "..."
}
```

### `bridge.exec.start`

```json
{
  "deviceId": "string (optional)",
  "command": "string",
  "cwd": "string (optional)",
  "env": { "KEY": "VALUE" },
  "timeoutSec": 60
}
```

Result:

```json
{ "commandId": "cmd-uuid", "startedAt": "2026-03-02T12:00:00.000Z" }
```

### `bridge.exec.cancel`

```json
{ "deviceId": "string (optional)", "commandId": "cmd-uuid" }
```

Result:

```json
{ "cancelled": true }
```

### `bridge.exec.status`

```json
{ "deviceId": "string (optional)", "commandId": "cmd-uuid" }
```

Result:

```json
{ "state": "running|finished|failed|cancelled|timed_out", "exitCode": 0 }
```

### `bridge.exec.output.subscribe`

```json
{ "deviceId": "string (optional)", "commandId": "cmd-uuid" }
```

Result:

```json
{ "subscribed": true }
```

## Filesystem

### `bridge.fs.readFile`

```json
{ "deviceId": "string (optional)", "path": "relative/path.txt" }
```

Result:

```json
{ "content": "..." }
```

### `bridge.fs.search`

```json
{
  "deviceId": "string (optional)",
  "query": "refreshToken",
  "root": "src",
  "globs": ["*.ts"],
  "maxResults": 50
}
```

Result:

```json
{
  "matches": [
    { "path": "src/auth.ts", "line": 80, "snippet": "..." }
  ]
}
```

### `bridge.fs.readRange`

```json
{ "deviceId": "string (optional)", "path": "src/auth.ts", "startLine": 60, "endLine": 100 }
```

Result:

```json
{ "content": "..." }
```

### `bridge.fs.applyPatch`

```json
{
  "deviceId": "string (optional)",
  "unifiedDiff": "diff --git ...",
  "constraints": {
    "allowedPaths": ["src/auth.ts"],
    "noReformat": true,
    "maxDiffLines": 400
  }
}
```

Result:

```json
{ "applied": true, "filesChanged": ["src/auth.ts"] }
```

## Git

### `bridge.git.status`

Arguments:

```json
{ "deviceId": "string (optional)" }
```

Result:

```json
{ "branch": "feature/xyz", "changedFiles": ["a.ts"], "stagedFiles": ["a.ts"] }
```

### `bridge.git.diff`

```json
{ "deviceId": "string (optional)", "staged": false }
```

Result:

```json
{ "diff": "...", "truncated": false, "tail": "..." }
```

### `bridge.git.stage`

```json
{ "deviceId": "string (optional)", "paths": ["src/auth.ts"] }
```

Result:

```json
{ "staged": ["src/auth.ts"] }
```

### `bridge.git.commit`

```json
{ "deviceId": "string (optional)", "message": "Fix failing test" }
```

Result:

```json
{ "commitSha": "abc123..." }
```

### `bridge.git.push`

```json
{ "deviceId": "string (optional)", "remote": "origin", "branch": "feature/xyz" }
```

Result:

```json
{ "pushed": true }
```

## Routing Rules

- If `deviceId` is omitted and exactly one online bridge is paired, server routes there.
- If omitted and multiple bridges are online, server emits `bridge.device.selection.required`.
- If no online bridge is paired, result error is `bridge_not_paired`.
