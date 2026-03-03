# Tool Catalog (Bridge v0)

Bridge v0 adds three server-routed tools.

## `bridge.exec.run`

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

Rules:
- `timeoutSec` capped to `600`
- output is truncated by bridge policy
- `cwd` must stay inside workspace root
- `timeoutSec` must be an integer number of seconds

## `bridge.fs.readFile`

Arguments:

```json
{
  "deviceId": "string (optional)",
  "path": "relative/path.txt"
}
```

Result:

```json
{ "content": "..." }
```

Rules:
- path must resolve under workspace root allowlist
- file content is truncated by bridge policy

## `bridge.claude.run`

Arguments:

```json
{
  "deviceId": "string (optional)",
  "prompt": "string",
  "cwd": "string (optional, relative to workspace root)",
  "timeoutSec": 120,
  "allowedTools": "Bash,Read,Edit"
}
```

Result:

```json
{
  "result": "...",
  "sessionId": "string (optional)"
}
```

Rules:
- `prompt` is required
- `timeoutSec` defaults to `120`, capped to `600`
- `timeoutSec` must be an integer number of seconds
- `allowedTools` defaults to `Bash,Read,Edit`
- output is truncated by bridge policy
- `cwd` must stay inside workspace root
- requires Claude Code CLI installed and authenticated on the Mac
- selected bridge must advertise `claudeRun: true` capability

## Routing Rules

- If `deviceId` omitted and exactly one online bridge is paired, server routes there.
- If omitted and multiple bridges are online, server emits `bridge.device.selection.required`.
- If no online bridge is paired, tool result returns `bridge_not_paired`.
