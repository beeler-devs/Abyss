# VoiceIDE Architecture — Phase 1

## Overview

VoiceIDE is a voice-first agentic development app built around **formal tool calling**. The core principle is that all state mutations, audio operations, and UI updates flow through a structured event/tool system — never through direct method calls from the UI or conductor.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                      SwiftUI Views                       │
│  ContentView ← MicButton, TranscriptView, Timeline       │
│                         │                                │
│                    User Intents                           │
│              (micTapped, micPressed, etc.)                │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│              ConversationViewModel                       │
│                                                          │
│  Translates intents → tool.call Events                   │
│  Owns: EventBus, ConversationStore, AppStateStore        │
│  Observes stores → publishes @Published state            │
└───────┬──────────────────────────┬──────────────────────┘
        │                          │
        ▼                          ▼
┌───────────────┐    ┌─────────────────────────────┐
│   Conductor   │    │         ToolRouter           │
│  (Protocol)   │    │                              │
│               │    │  Receives tool.call Events   │
│  Phase 1:     │    │  Dispatches via ToolRegistry │
│  LocalStub    │    │  Emits tool.result Events    │
│               │    │                              │
│  Phase 2:     │    └──────────┬──────────────────┘
│  WebSocket    │               │
│  Client       │               ▼
└───────┬───────┘    ┌─────────────────────────────┐
        │            │       ToolRegistry           │
        │            │                              │
        │            │  stt.start  → STTStartTool   │
        │            │  stt.stop   → STTStopTool    │
        │            │  tts.speak  → TTSSpeakTool   │
        │            │  tts.stop   → TTSStopTool    │
        │            │  convo.appendMessage          │
        │            │  convo.setState               │
        │            └──────────┬──────────────────┘
        │                       │
        │                       ▼
        │            ┌─────────────────────────────┐
        │            │      Service Layer           │
        │            │                              │
        │            │  SpeechTranscriber (Protocol) │
        │            │    └─ WhisperKitImpl          │
        │            │                              │
        │            │  TextToSpeech (Protocol)      │
        │            │    └─ ElevenLabsTTS           │
        │            └─────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────┐
│                      EventBus                            │
│                                                          │
│  Append-only log of all Events                           │
│  Observable by UI (timeline view)                        │
│  Replayable for debugging                                │
│                                                          │
│  Event types:                                            │
│    session.start                                         │
│    user.audio.transcript.partial / .final                │
│    assistant.speech.partial / .final                     │
│    assistant.ui.patch (placeholder)                      │
│    tool.call { name, arguments, call_id }                │
│    tool.result { call_id, result | error }               │
│    error { code, message }                               │
└─────────────────────────────────────────────────────────┘
```

## Why Formal Tool Calling?

1. **Auditability**: Every action is logged as an Event. The timeline view shows exactly what happened and when. No hidden side effects.

2. **Swappable conductor**: The `Conductor` protocol accepts a transcript and returns `[Event]`. Phase 1 uses `LocalConductorStub` (deterministic, no network). Phase 2 drops in `WebSocketConductorClient` that sends transcripts to a Nova-powered backend and receives events back over WebSocket — without changing any tool handlers.

3. **Testability**: Tools are pure functions (arguments → result). The ToolRouter can be tested with a mock registry. Barge-in logic can be verified by checking event ordering.

4. **Replay/Debug**: The EventBus is append-only. Events can be replayed to reproduce issues. The timeline UI makes this visible during development and demos.

5. **Phase 2 readiness**: Adding new tools (file.read, file.write, git.commit, browser.navigate, etc.) only requires implementing the `Tool` protocol and registering. The router, bus, and UI timeline work automatically.

## Data Flow: User Says "Hello"

```
1. User taps mic button
2. ViewModel emits: tool.call(convo.setState, {state: "listening"})
3. ToolRouter dispatches → AppStateStore.current = .listening
4. ViewModel emits: tool.call(stt.start, {mode: "tapToToggle"})
5. ToolRouter dispatches → WhisperKit starts recording

   ... user speaks ...

6. WhisperKit emits partials → EventBus: user.audio.transcript.partial
7. User taps mic again
8. ViewModel emits: tool.call(convo.setState, {state: "transcribing"})
9. ViewModel emits: tool.call(stt.stop, {})
10. ToolRouter dispatches → WhisperKit stops, returns "Hello"
11. EventBus: user.audio.transcript.final("Hello")

12. ViewModel sends "Hello" to Conductor
13. Conductor returns event sequence:
    a. tool.call(convo.setState, {state: "thinking"})
    b. tool.call(convo.appendMessage, {role: "user", text: "Hello"})
    c. assistant.speech.final("Hello! I'm your voice assistant...")
    d. tool.call(convo.appendMessage, {role: "assistant", text: "Hello!..."})
    e. tool.call(convo.setState, {state: "speaking"})
    f. tool.call(tts.speak, {text: "Hello!..."})
    g. tool.call(convo.setState, {state: "idle"})

14. ToolRouter processes each event in order
15. ElevenLabs streams audio, user hears response
16. State returns to idle
```

## Barge-in Flow

```
1. TTS is playing (state: speaking)
2. User taps mic
3. ViewModel detects state == .speaking
4. ViewModel emits: tool.call(tts.stop, {})
5. ToolRouter dispatches → ElevenLabs stops playback
6. ViewModel emits: tool.call(convo.setState, {state: "listening"})
7. ViewModel emits: tool.call(stt.start, {mode: "tapToToggle"})
8. User continues speaking...
```

## Phase 2 Transition Plan

### What Changes
- `LocalConductorStub` is replaced by `WebSocketConductorClient`
- New conductor connects to a WebSocket backend (e.g., running on AWS)
- Backend uses Bedrock Nova 2 Lite for reasoning, Nova embeddings for context
- Backend sends events over WebSocket (same format as LocalConductorStub returns)

### What Stays the Same
- `ToolRegistry`, `ToolRouter`, `EventBus` — unchanged
- All existing tools — unchanged
- UI — unchanged (it only observes the EventBus)
- `ConversationViewModel` — minimal changes (swap conductor init)

### New Tools for Phase 2+
- `file.read`, `file.write`, `file.list`
- `git.status`, `git.commit`, `git.push`
- `browser.navigate`, `browser.screenshot`
- `agent.spawn`, `agent.status` (for Nova Act sub-agents)
- `project.analyze`, `project.search`

All follow the same `Tool` protocol and register in `ToolRegistry`.
