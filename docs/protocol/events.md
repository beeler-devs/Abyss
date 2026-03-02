# Abyss Event Protocol (Bridge v0)

All WebSocket events use the same envelope:

```json
{
  "id": "evt_123",
  "type": "tool.call",
  "timestamp": "2026-03-01T12:00:00.000Z",
  "sessionId": "session-abc",
  "protocolVersion": 1,
  "payload": {}
}
```

Required envelope fields:
- `id`: unique event id
- `type`: event type
- `timestamp`: ISO8601 UTC string
- `sessionId`: iOS session id for conductor events; bridge device session id for bridge registration traffic
- `protocolVersion`: integer protocol version (`1`)
- `payload`: event payload object

## Bridge Events

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
  "capabilities": { "execRun": true, "readFile": true },
  "protocolVersion": 1
}
```

### `bridge.paired` (server -> iOS)

```json
{ "deviceId": "uuid", "deviceName": "Ben's MacBook", "status": "online" }
```

### `bridge.status` (server -> iOS)

```json
{ "deviceId": "uuid", "status": "online", "lastSeen": "2026-03-01T12:00:00.000Z" }
```

### `bridge.device.selection.required` (server -> iOS)

Emitted when a bridge tool call omitted `deviceId` but multiple online bridge devices are paired to the session.

Payload:

```json
{
  "devices": [
    { "deviceId": "uuid-1", "deviceName": "Work Mac", "status": "online", "lastSeen": "..." },
    { "deviceId": "uuid-2", "deviceName": "Home Mac", "status": "online", "lastSeen": "..." }
  ]
}
```

## Tool Flow Events

Bridge tools still use standard formal tool events:
- `tool.call`
- `tool.result`

The server forwards `tool.call` to the bridge connection and relays normalized `tool.result` back to iOS timeline and conductor state.
