# Simplified Live Conversation — Nova Sonic Native Flow

## Problem

The current live conversation (vadAuto) implementation layers iOS-side VAD, local barge-in detection, and audio chunk gating on top of Nova Sonic's native duplex conversation system. This creates two competing interrupt paths (iOS local VAD vs. Nova Sonic server-side VAD) that race against each other, causing audio bleed where the user hears stale audio after interrupting.

Amazon's own documentation states the client should simply react to Nova Sonic's interruption signal — not implement its own detection.

## Solution

Make the iOS app a thin audio I/O client in live (vadAuto) mode. Nova Sonic handles the full conversation lifecycle natively: speech detection, response generation, interruption, transcription, and state management. iOS just streams mic audio, plays back audio chunks, stops on interrupt, and displays text.

PTT mode is completely unchanged.

## Architecture

### iOS (Thin Client in vadAuto mode)

```
RemoteAudioCapture
├── Mic → base64 chunks → WebSocket → Server → Nova Sonic
└── AVAudioPlayerNode ← play/stop

Event handlers (all driven by server events, no local logic):
├── assistant.audio.chunk → decode and play audio
├── assistant.audio.end → finish playback
├── assistant.audio.interrupted → playerNode.stop() + reset() + queue.reset()
├── convo.setState → update appState for UI
└── convo.appendMessage → add chat bubble
```

### Server (Passthrough)

```
iOS audio chunks → voiceProvider.appendAudioChunk() → Nova Sonic
Nova Sonic events → translated to app events → forwarded to iOS via WebSocket
```

### Nova Sonic (Full Conversation Engine)

- Full-duplex: receives user audio + sends assistant audio simultaneously
- Built-in VAD: detects user speech during assistant output
- Native barge-in: stops generation, emits completionEnd(INTERRUPTED/BARGE_IN)
- Native STT: transcribes user speech, emits user.audio.transcript.final
- Native TTS: generates assistant audio as PCM chunks
- Tool calling: orchestrates tool use natively
- State management: emits convo.setState (listening/thinking/speaking/idle)

### Interruption Flow (Single Path — No Race)

```
User speaks during assistant audio
    │
    ▼
Nova Sonic detects speech (built-in VAD)
    │
    ▼
Nova Sonic emits completionEnd(BARGE_IN)
    │
    ▼
Server: handleBargeIn()
├── resetAssistantTurnState (clear pending audio/text)
├── set bargedIn flag (suppresses stale events on existing stream)
├── emit assistant.audio.interrupted (with liveResponseId)
└── emit convo.setState(listening)
    (Nova Sonic stream stays open — no transport restart)
    │
    ▼
iOS receives assistant.audio.interrupted
└── playerNode.stop() + playerNode.reset() + queue.reset()
   (audio stops immediately — no race, no competing paths)
    │
    ▼
iOS receives convo.setState(listening)
└── appState = .listening (UI updates)
    │
    ▼
Nova Sonic processes user speech on new stream
├── emit user.audio.transcript.final
├── emit convo.setState(thinking)
├── generate response
├── emit convo.setState(speaking) + assistant.audio.chunk events
└── iOS plays new response
```

## Changes

### ConversationAudioPipeline.swift (vadAuto path only)

**Remove from vadAuto path:**
- VAD monitoring (`voiceActivityDetector.startMonitoring()` / `stopMonitoring()` when vadAuto)
- `handsFreeBargeInInFlight` flag usage in vadAuto
- `currentPlayingLiveResponseId` and `rejectedLiveResponseId` (the earlier fix attempt)
- The `onSpeechStarted` barge-in branch that checks `appState == .speaking`
- The `bargeIn()` else clause (vadAuto branch) — server handles interrupts now
- Any vadAuto-specific logic in `bargeIn()` that sends `audio.output.interrupted` to the server (Nova Sonic detects this itself)

**Keep unchanged:**
- `RemoteAudioCapture` class (mic streaming + audio playback via AVAudioEngine)
- `handleAssistantAudioChunk()` — just decode and play (remove gating logic, keep the core)
- `handleAssistantAudioEnd()` — finish playback
- `handleAssistantAudioInterrupted()` — stop playback (this is now the ONLY interrupt path)
- `refreshRemoteVoiceConversationState()` — starts/stops remote capture based on mode
- `startRemoteVoiceCapture()` / `stopRemoteVoiceCapture()` — mic streaming lifecycle
- `BufferedPCMPlaybackQueue` — still needed for smooth streaming playback
- ALL PTT code — completely untouched

**Simplify:**
- `handleAssistantAudioChunk()`: remove `rejectedLiveResponseId` gate, just decode base64 → appendAssistantAudio
- `configureVoicePipeline()`: the `onSpeechStarted` callback should NOT trigger barge-in in vadAuto mode (remove that branch). Keep the PTT `onSpeechEnded` callback.
- `bargeIn()`: becomes PTT-only. The vadAuto else branch is removed since interrupts come from the server via `handleAssistantAudioInterrupted()`.

### ConversationEventCoordinator.swift

**Keep as-is.** The coordinator already handles all the relevant server events:
- `assistant.audio.chunk` → routes to pipeline (line 132-141)
- `assistant.audio.end` → routes to pipeline (line 143-150)
- `assistant.audio.interrupted` → routes to pipeline (line 152-162)
- `convo.setState` / `convo.appendMessage` tool calls → dispatched normally
- `liveResponseId` filtering → still useful as defense-in-depth for edge cases

### Server-side

**No changes needed.** The server already:
- Routes iOS audio stream events to Nova Sonic voice provider
- Translates Nova Sonic output events to app events
- Handles `restartSessionAfterInterruption()` on BARGE_IN/INTERRUPTED
- Emits `assistant.audio.interrupted`, state changes, and messages

### iOS-side tools in live mode

**Tools that become unused in vadAuto (but kept for PTT):**
- `tts.speak` / `tts.stop` — Nova Sonic handles TTS natively
- `stt.start` / `stt.stop` — Nova Sonic handles STT natively

These tools still exist in the registry for PTT mode. In vadAuto mode, the server's Nova Sonic voice provider never emits these tool calls (it emits audio chunks and text events directly), so they naturally don't execute.

## What This Eliminates

- Two competing barge-in paths racing (iOS VAD vs Nova Sonic VAD)
- `rejectedLiveResponseId` / `currentPlayingLiveResponseId` gating logic
- MainActor Task scheduling races between VAD callbacks and WebSocket event processing
- The `handsFreeBargeInInFlight` guard and its associated race window
- iOS-side VAD monitoring during live conversation (less battery, less complexity)
- The entire class of bugs where audio chunks slip between stop and gate

## Why This Works

Per Amazon's documentation: *"While Amazon Nova 2 Sonic handles barge-in on the server side, you need to implement client-side logic for a complete experience by detecting the interruption signal, stopping current playback, clearing the audio queue of any buffered audio from the interrupted response, and starting to play newly received audio."*

The client's only job is:
1. Detect `assistant.audio.interrupted` event
2. Stop playback + clear queue
3. Play new audio when it arrives

No local VAD. No local barge-in detection. No competing interrupt paths.

## Edge Cases

- **Network latency on interrupt event**: Nova Sonic stops generating immediately, so no new chunks are sent. Already-buffered chunks on the client are cleared by `playerNode.stop()` + `queue.reset()`. Worst case: a few hundred ms of stale audio while the interrupt event is in transit.
- **False barge-in (cough, background noise)**: Nova Sonic's built-in VAD handles this. The coordinator's existing `pendingInterruptCandidate` / echo detection logic remains as defense-in-depth.
- **Tool calls during conversation**: Nova Sonic handles tool orchestration natively. The server executes tools and sends results back. iOS displays results via `convo.appendMessage`.
- **PTT mode**: Completely unchanged. Different code path, different tools, different audio mechanism.

## Scope Boundaries

**This change does NOT touch:**
- Push-to-talk code paths
- `ElevenLabsTTS` / `StreamingPCMPlayer`
- `WhisperKitSpeechTranscriber`
- Server-side code
- `RemoteAudioCapture` internals (mic capture, audio engine, resampling)
- `BufferedPCMPlaybackQueue` internals
- Event protocol or event types
- The coordinator's liveResponseId tracking (kept as defense-in-depth)

## Tests That Need Updating

**`ConversationAudioPipelineNovaTests.swift`** — 8 tests to delete or rewrite:
- `testHandsFreeSpeechOnsetDuringSpeakingInterruptsAssistantImmediately` — tests local VAD barge-in (removed)
- `testHandsFreeSpeechOnsetWhileListeningDoesNotInterruptAssistant` — tests VAD behavior (removed)
- `testHandsFreeSpeechOnsetTriggersSingleBargeInPerUtterance` — tests `handsFreeBargeInInFlight` (removed)
- 5 `testBargeIn*` tests — test `rejectedLiveResponseId` gating (removed)

**New tests to add:**
- Test that `handleAssistantAudioInterrupted()` stops playback (server-driven interrupt)
- Test that audio chunks play normally without gating
- Test that `handleAssistantAudioEnd()` finishes playback cleanly

**`ConversationEventCoordinatorInterruptTests.swift`** — 2 tests reference local `audioOutputInterrupted` events that won't be emitted in vadAuto mode. Keep as coordinator regression tests.

## Dead Code Cleanup (Optional)

After this change, the coordinator's `handleLocalEvent` / `handleLocalAudioOutputInterrupted` / `observeLocalEvents` path becomes dead code for vadAuto (it guards on `isHandsFreeLiveConversationMode` but no `audioOutputInterrupted` events are emitted in that mode). Harmless to leave, but could be cleaned up later.
