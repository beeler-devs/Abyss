# Abyss Event Protocol (Phase 2)

## Transport

- Protocol: WebSocket (`ws://` or `wss://`)
- Encoding: UTF-8 JSON
- Endpoint: `/ws`
- Direction:
  - Client -> Server: session, transcript, tool results, interruption notices
  - Server -> Client: speech stream, tool calls, status/UI/error events

## Event Envelope

Every message is an envelope:

```json
{
  "id": "evt_123",
  "type": "tool.call",
  "timestamp": "2026-02-18T12:34:56.123Z",
  "sessionId": "session-abc",
  "payload": {}
}
```

Fields:

- `id`: unique event id (used by client dedupe)
- `type`: dot-separated event type
- `timestamp`: ISO8601
- `sessionId`: stable session id for the socket session
- `payload`: type-specific object

## Event Types

### session.start (client -> server)

```json
{
  "id": "evt-1",
  "type": "session.start",
  "timestamp": "2026-02-18T12:00:00.000Z",
  "sessionId": "session-1",
  "payload": { "sessionId": "session-1" }
}
```

### session.started (server -> client, optional ack)

```json
{
  "id": "evt-2",
  "type": "session.started",
  "timestamp": "2026-02-18T12:00:00.050Z",
  "sessionId": "session-1",
  "payload": { "sessionId": "session-1" }
}
```

### user.audio.transcript.final (client -> server)

```json
{
  "id": "evt-3",
  "type": "user.audio.transcript.final",
  "timestamp": "2026-02-18T12:00:04.000Z",
  "sessionId": "session-1",
  "payload": {
    "text": "hello",
    "timestamp": "2026-02-18T12:00:04.000Z",
    "sessionId": "session-1"
  }
}
```

### assistant.speech.partial (server -> client)

```json
{
  "id": "evt-4",
  "type": "assistant.speech.partial",
  "timestamp": "2026-02-18T12:00:04.200Z",
  "sessionId": "session-1",
  "payload": { "text": "Hello, " }
}
```

### assistant.speech.final (server -> client)

```json
{
  "id": "evt-5",
  "type": "assistant.speech.final",
  "timestamp": "2026-02-18T12:00:04.800Z",
  "sessionId": "session-1",
  "payload": { "text": "Hello, how can I help?" }
}
```

### tool.call (server -> client)

```json
{
  "id": "evt-6",
  "type": "tool.call",
  "timestamp": "2026-02-18T12:00:04.100Z",
  "sessionId": "session-1",
  "payload": {
    "callId": "call-123",
    "name": "convo.setState",
    "arguments": "{\"state\":\"thinking\"}"
  }
}
```

### tool.result (client -> server)

Success:

```json
{
  "id": "evt-7",
  "type": "tool.result",
  "timestamp": "2026-02-18T12:00:04.120Z",
  "sessionId": "session-1",
  "payload": {
    "callId": "call-123",
    "result": "{\"newState\":\"thinking\",\"previousState\":\"idle\"}",
    "error": null
  }
}
```

Error:

```json
{
  "id": "evt-8",
  "type": "tool.result",
  "timestamp": "2026-02-18T12:00:04.120Z",
  "sessionId": "session-1",
  "payload": {
    "callId": "call-123",
    "result": null,
    "error": "ElevenLabs API key missing"
  }
}
```

### assistant.ui.patch (server -> client)

```json
{
  "id": "evt-9",
  "type": "assistant.ui.patch",
  "timestamp": "2026-02-18T12:00:05.000Z",
  "sessionId": "session-1",
  "payload": {
    "patch": "{\"op\":\"replace\",\"path\":\"/cards/0\"}"
  }
}
```

### agent.status (server -> client)

```json
{
  "id": "evt-10",
  "type": "agent.status",
  "timestamp": "2026-02-18T12:00:05.500Z",
  "sessionId": "session-1",
  "payload": {
    "status": "thinking",
    "detail": "Running tool sequence"
  }
}
```

### audio.output.interrupted (client -> server, optional)

```json
{
  "id": "evt-11",
  "type": "audio.output.interrupted",
  "timestamp": "2026-02-18T12:00:06.000Z",
  "sessionId": "session-1",
  "payload": {
    "reason": "barge_in"
  }
}
```

### error (either direction)

```json
{
  "id": "evt-12",
  "type": "error",
  "timestamp": "2026-02-18T12:00:06.050Z",
  "sessionId": "session-1",
  "payload": {
    "code": "model_provider_failed",
    "message": "Anthropic HTTP 429"
  }
}
```

## Required Phase 2 Sequence

On `user.audio.transcript.final`, the backend emits:

1. `tool.call` `convo.setState` `{state:"thinking"}`
2. `tool.call` `convo.appendMessage` for user transcript
3. `assistant.speech.partial` chunks
4. `assistant.speech.final`
5. `tool.call` `convo.appendMessage` for assistant
6. `tool.call` `convo.setState` `{state:"speaking"}`
7. `tool.call` `tts.speak`
8. `tool.call` `convo.setState` `{state:"idle"}`

## Reconnect + Dedupe

Client behavior:

- reconnect with exponential backoff
- keep same `sessionId` for reconnect attempts
- dedupe inbound events by `event.id`
- ignore duplicate ids across reconnects

Server behavior:

- accept repeated `session.start`
- do not require strict ACK handshake to continue
- may resend events after reconnect; client id dedupe makes this safe

## Compatibility Notes

- Unknown `type` values should be ignored safely.
- `payload` remains object-based for forward compatibility.
- `arguments` and `result` stay JSON-encoded strings to align with the iOS tool router contract.
