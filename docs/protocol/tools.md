# Tool Catalog (Bridge v0)

Bridge v0 adds two server-routed tools.

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

## Routing Rules

- If `deviceId` omitted and exactly one online bridge is paired, server routes there.
- If omitted and multiple bridges are online, server emits `bridge.device.selection.required`.
- If no online bridge is paired, tool result returns `bridge_not_paired`.
