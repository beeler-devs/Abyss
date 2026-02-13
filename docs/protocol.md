# VoiceIDE Event Protocol

## Overview

All communication between the conductor (brain), runtime (iOS app), and UI flows through structured events. This document defines the protocol for the future WebSocket-based communication between client and server.

## Transport (Phase 2)

- **Protocol**: WebSocket (wss://)
- **Encoding**: JSON (UTF-8)
- **Direction**: Bidirectional
  - Client → Server: user events (transcript, audio state)
  - Server → Client: conductor events (tool calls, speech, UI patches)

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

## Reconnection Strategy (Phase 2)

1. On disconnect, buffer outgoing events locally
2. On reconnect, send `session.reconnect` with last known event ID
3. Server replays missed events from its log
4. Client deduplicates by event ID

## Versioning

Events include no explicit version field in Phase 1. Phase 2 will add:

```json
{
  "protocolVersion": "2.0",
  "id": "...",
  ...
}
```

Clients must ignore unknown event kinds gracefully.
