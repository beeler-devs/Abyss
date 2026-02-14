# VoiceIDE Event Protocol

## Overview

All communication between the conductor (brain), runtime (iOS app), and UI flows through structured events. This document defines the protocol for WebSocket-based communication between client and server (Phase 2).

## Transport

- **Protocol**: WebSocket (wss://)
- **Encoding**: JSON (UTF-8)
- **Direction**: Bidirectional
  - Client → Server: user events (transcript, tool results, session management)
  - Server → Client: conductor events (tool calls, speech partials/finals, errors)

## Connection

Connect to the WebSocket API with a sessionId query parameter:
```
wss://API-ID.execute-api.REGION.amazonaws.com/prod?sessionId=UUID
```

The sessionId must be a valid UUID v4. The server maps the connectionId to the sessionId in DynamoDB.

## Event Envelope

Every message on the wire is an Event:

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-01-15T10:30:00.000Z",
  "kind": { ... }
}
```

## Event Types

### session.start

Emitted when a new session begins.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "sessionStart": {
      "sessionId": "abc123"
    }
  }
}
```

### user.audio.transcript.partial

Streaming partial transcript from STT.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "userAudioTranscriptPartial": {
      "text": "Hello wor"
    }
  }
}
```

### user.audio.transcript.final

Final transcript after STT completes.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "userAudioTranscriptFinal": {
      "text": "Hello world"
    }
  }
}
```

### assistant.speech.partial

Streaming partial speech text from the conductor.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "assistantSpeechPartial": {
      "text": "I can help you"
    }
  }
}
```

### assistant.speech.final

Final speech text from the conductor.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "assistantSpeechFinal": {
      "text": "I can help you with that. Let me check the code."
    }
  }
}
```

### assistant.ui.patch

UI update from the conductor (Phase 2+). Placeholder in Phase 1.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "assistantUIPatch": {
      "patch": "{\"op\":\"add\",\"path\":\"/cards/0\",\"value\":{\"type\":\"diff\",\"file\":\"main.swift\"}}"
    }
  }
}
```

### tool.call

Conductor requests the runtime to execute a tool.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "toolCall": {
      "callId": "call-abc123",
      "name": "tts.speak",
      "arguments": "{\"text\":\"Hello there!\"}"
    }
  }
}
```

### tool.result

Runtime reports the result of a tool execution.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "toolResult": {
      "callId": "call-abc123",
      "result": "{\"spoken\":true}",
      "error": null
    }
  }
}
```

Error case:

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "toolResult": {
      "callId": "call-abc123",
      "result": null,
      "error": "ElevenLabs API key is not configured."
    }
  }
}
```

### error

System-level error event.

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "kind": {
    "error": {
      "code": "tts_failed",
      "message": "ElevenLabs returned HTTP 401"
    }
  }
}
```

## WebSocket Protocol Flow (Phase 2)

```
Client                          Server
  |                               |
  |-- session.start ------------->|
  |                               |
  |-- user.audio.transcript.final|
  |   { text: "Hello" }  ------->|
  |                               |
  |<-- tool.call: convo.setState  |
  |    { state: "thinking" }      |
  |                               |
  |-- tool.result: ok ----------->|
  |                               |
  |<-- assistant.speech.final     |
  |    { text: "Hi there!" }      |
  |                               |
  |<-- tool.call: tts.speak       |
  |    { text: "Hi there!" }      |
  |                               |
  |-- tool.result: ok ----------->|
  |                               |
  |<-- tool.call: convo.setState  |
  |    { state: "idle" }          |
  |                               |
  |-- tool.result: ok ----------->|
```

## Client → Server Events

| Event Kind | When Sent | Purpose |
|-----------|-----------|---------|
| `sessionStart` | On connect | Initialize session |
| `userAudioTranscriptFinal` | After STT completes | Trigger Bedrock response |
| `toolResult` | After tool execution | Return result to Bedrock |
| `error` (code: `audio.output.interrupted`) | On barge-in | Inform server of interruption |

## Server → Client Events

| Event Kind | When Sent | Purpose |
|-----------|-----------|---------|
| `assistantSpeechPartial` | During Bedrock streaming | Update transcript UI |
| `assistantSpeechFinal` | After Bedrock text complete | Finalize transcript |
| `toolCall` | When model requests tool | Execute on client |
| `error` | On server error | Surface to user |

## Tool Call Loop (Phase 2)

The Bedrock model uses a single wrapper tool `tool_call` to request client-side actions:

```
Model emits: toolUse "tool_call" { name: "tts.speak", arguments: {...}, call_id: "xxx" }
  → Backend extracts inner tool name/args
  → Backend sends: toolCall { callId: "xxx", name: "tts.speak", arguments: "{...}" }
  → Client executes tts.speak via ToolRouter
  → Client sends: toolResult { callId: "xxx", result: "{\"spoken\":true}", error: null }
  → Backend wraps as Bedrock toolResult and resumes stream
  → Model continues...
```

## Reconnection Strategy

1. iOS `WebSocketConductorClient` uses exponential backoff (1s, 2s, 4s, 8s, 16s)
2. Max 5 reconnection attempts
3. On reconnect, a new `session.start` is sent with the same sessionId
4. Session state (conversation) persists in DynamoDB across reconnections
5. If reconnection fails, iOS falls back to LocalConductorStub

## Error Codes

| Code | Source | Description |
|------|--------|-------------|
| `invalid_json` | Server | Message body is not valid JSON |
| `invalid_event` | Server | Event shape validation failed |
| `no_session` | Server | Connection has no session mapping |
| `empty_transcript` | Server | Transcript text is empty |
| `no_pending_tool_call` | Server | tool.result received with no pending call |
| `invalid_tool_call` | Server | Model emitted malformed tool_call |
| `bedrock_error` | Server | Bedrock API error |
| `conductor_error` | Server | Conductor orchestration error |
| `handler_error` | Server | Unhandled Lambda error |
| `ws_error` | Client | WebSocket transport error |
| `ws_connect_failed` | Client | Initial connection failed |
| `ws_send_failed` | Client | Failed to send event |
| `decode_error` | Client | Failed to decode server event |
| `reconnect_failed` | Client | Max reconnection attempts exceeded |
| `audio.output.interrupted` | Client | User barged in during TTS |

## Versioning

Clients must ignore unknown event kinds gracefully. No explicit protocol version field is required for Phase 2 — the event kind discriminator provides forward compatibility.
