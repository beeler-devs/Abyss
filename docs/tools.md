# Abyss Tool Catalog

## Overview

Tools are the formal interface between the conductor (brain) and the runtime (iOS app). The conductor ONLY interacts with the system through tool calls. Every tool has typed arguments, typed results, and defined side effects.

## Tool Protocol

```swift
protocol Tool {
    static var name: String { get }
    associatedtype Arguments: Codable
    associatedtype Result: Codable
    func execute(_ arguments: Arguments) async throws -> Result
}
```

---

## Audio Tools

### stt.start

**Purpose**: Start speech-to-text recording using the on-device transcriber.

**Arguments**:
```json
{
  "mode": "tapToToggle"  // "tapToToggle" | "pressAndHold"
}
```

**Result**:
```json
{
  "started": true
}
```

**Side Effects**: WRITE — Activates microphone, begins audio capture, starts emitting `user.audio.transcript.partial` events.

**Idempotency**: Not idempotent. Calling while already listening will throw an error.

**Errors**:
- Microphone permission denied
- Audio session setup failure
- WhisperKit model loading failure

---

### stt.stop

**Purpose**: Stop speech-to-text recording and return the final transcript.

**Arguments**:
```json
{}
```

**Result**:
```json
{
  "finalTranscript": "Hello world"
}
```

**Side Effects**: WRITE — Stops microphone, runs final transcription pass, deactivates audio session.

**Idempotency**: Idempotent if not listening (returns empty transcript).

**Errors**:
- Transcription failure (returns best partial)

---

### tts.speak

**Purpose**: Speak text using ElevenLabs streaming TTS.

**Arguments**:
```json
{
  "text": "Hello! How can I help you?"
}
```

**Result**:
```json
{
  "spoken": true
}
```

**Side Effects**: WRITE — Streams audio from ElevenLabs, activates speaker, plays audio. Blocks until playback completes (or is stopped).

**Idempotency**: Not idempotent. Each call triggers new speech.

**Errors**:
- `missingAPIKey` — ElevenLabs API key not configured
- `httpError(code)` — ElevenLabs API returned an error
- `invalidResponse` — Non-HTTP response
- `playbackFailed` — Audio player error

---

### tts.stop

**Purpose**: Stop any currently playing TTS audio. Primary use: barge-in.

**Arguments**:
```json
{}
```

**Result**:
```json
{
  "stopped": true   // true if was speaking, false if already idle
}
```

**Side Effects**: WRITE — Stops audio playback, deactivates audio session.

**Idempotency**: Idempotent. Safe to call when not speaking.

**Errors**: None expected.

---

## Conversation Tools

### convo.appendMessage

**Purpose**: Append a message to the conversation transcript visible in the UI.

**Arguments**:
```json
{
  "role": "user",        // "user" | "assistant" | "system"
  "text": "Hello world",
  "isPartial": false     // optional, defaults to false
}
```

**Result**:
```json
{
  "messageId": "550e8400-e29b-41d4-a716-446655440000"
}
```

**Side Effects**: WRITE — Mutates the conversation message list. If `isPartial: true` and the last message is also a partial from the same role, replaces it (for streaming updates).

**Idempotency**: Not idempotent (appends each time).

**Errors**:
- Invalid role string

---

### convo.setState

**Purpose**: Set the top-level app state (displayed in UI state indicator).

**Arguments**:
```json
{
  "state": "listening"  // "idle" | "listening" | "transcribing" | "thinking" | "speaking" | "error"
}
```

**Result**:
```json
{
  "previousState": "idle",
  "newState": "listening"
}
```

**Side Effects**: WRITE — Changes the app's visual state indicator and enables/disables UI interactions accordingly.

**Idempotency**: Idempotent (setting same state twice is a no-op in effect).

**Errors**:
- Invalid state string

---

## Cursor Cloud Agent Tools

These tools are implemented and backed by the Cursor Cloud Agents API:

| Name | Purpose | Category |
|------|---------|----------|
| `agent.spawn` | Launch a cloud agent for a repository/PR | EXECUTE |
| `agent.status` | Retrieve a cloud agent's current status | READ |
| `agent.cancel` | Stop a running cloud agent | EXECUTE |
| `agent.followup` | Add follow-up instructions to an existing agent | EXECUTE |
| `agent.list` | List cloud agents for the authenticated user | READ |

Requirements:
- Cursor API key configured in `Settings -> Cursor Cloud Agents -> API Key` or `CURSOR_API_KEY`.
- Authentication uses Basic auth with your Cursor API key.

---

## Phase 2+ Tools (Planned)

These tools are NOT implemented in Phase 1 but the architecture is designed to support them by simply implementing the `Tool` protocol and calling `registry.register()`.

### File Tools
| Name | Purpose | Category |
|------|---------|----------|
| `file.read` | Read file contents | READ |
| `file.write` | Write/create file | WRITE |
| `file.list` | List directory contents | READ |
| `file.search` | Search file contents | READ |

### Git Tools
| Name | Purpose | Category |
|------|---------|----------|
| `git.status` | Get repo status | READ |
| `git.diff` | Get diff | READ |
| `git.commit` | Create commit | WRITE |
| `git.push` | Push to remote | EXECUTE |

### Browser Tools
| Name | Purpose | Category |
|------|---------|----------|
| `browser.navigate` | Open URL | EXECUTE |
| `browser.screenshot` | Capture page | READ |
| `browser.click` | Click element | EXECUTE |

### Project Tools
| Name | Purpose | Category |
|------|---------|----------|
| `project.analyze` | Analyze codebase structure | READ |
| `project.search` | Semantic code search (Nova embeddings) | READ |
| `project.build` | Run build | EXECUTE |
| `project.test` | Run tests | EXECUTE |
