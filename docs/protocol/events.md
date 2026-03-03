# Abyss Event Protocol (Bridge v1)

All WebSocket events use this envelope:

```json
{
  "id": "evt_123",
  "type": "tool.call",
  "timestamp": "2026-03-02T12:00:00.000Z",
  "sessionId": "session-abc",
  "protocolVersion": 1,
  "payload": {}
}
```

Required envelope fields:

- `id`: unique event id
- `type`: event type
- `timestamp`: ISO8601 UTC string
- `sessionId`: iOS session id for conductor traffic; bridge device id for bridge-originated exec stream traffic
- `protocolVersion`: integer protocol version (`1`)
- `payload`: event payload object

## Bridge pairing and presence

### `bridge.pair.request` (iOS -> server)

```json
{ "pairingCode": "ABC123", "deviceName": "Ben's MacBook" }
```

### `bridge.register` (bridge -> server)

```json
{
  "pairingCode": "ABC123",
  "deviceId": "uuid",
  "deviceName": "Ben's MacBook",
  "workspaceRoot": "/Users/ben/project",
  "workspaceRoots": ["/Users/ben/project", "/Users/ben/second-repo"],
  "capabilities": {
    "execRun": true,
    "readFile": true,
    "execStart": true,
    "execCancel": true,
    "execStatus": true,
    "execOutputEvents": true,
    "fsSearch": true,
    "fsReadRange": true,
    "fsApplyPatch": true,
    "gitStatus": true,
    "gitDiff": true,
    "gitStage": true,
    "gitCommit": true,
    "gitPush": true
  },
  "protocolVersion": 1
}
```

### `bridge.paired` (server -> iOS)

```json
{ "deviceId": "uuid", "deviceName": "Ben's MacBook", "status": "online" }
```

### `bridge.status` (server -> iOS)

```json
{ "deviceId": "uuid", "status": "online", "lastSeen": "2026-03-02T12:00:00.000Z" }
```

### `bridge.device.selection.required` (server -> iOS)

```json
{
  "devices": [
    { "deviceId": "uuid-1", "deviceName": "Work Mac", "status": "online", "lastSeen": "..." },
    { "deviceId": "uuid-2", "deviceName": "Home Mac", "status": "online", "lastSeen": "..." }
  ]
}
```

## Bridge exec streaming events

### `bridge.exec.output` (bridge -> server -> iOS)

```json
{
  "deviceId": "uuid",
  "commandId": "cmd-uuid",
  "stream": "stdout",
  "chunk": "line text...",
  "isFinal": false
}
```

### `bridge.exec.finished` (bridge -> server -> iOS)

```json
{
  "deviceId": "uuid",
  "commandId": "cmd-uuid",
  "exitCode": 0,
  "stdoutTail": "...",
  "stderrTail": "..."
}
```

## Tool flow events

Bridge tools still use standard formal tool events:

- `tool.call`
- `tool.result`

For backward compatibility:

- `bridge.exec.run` remains available and is implemented using Bridge v1 command lifecycle on the server side.
