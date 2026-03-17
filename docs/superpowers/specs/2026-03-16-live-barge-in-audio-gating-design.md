# Live Conversation Barge-In Audio Gating

## Problem

In hands-free (VAD auto) live conversation mode, when the user interrupts the assistant's speech, they hear the last sentence of the old response before the new response starts.

### Root Cause

A race condition between iOS-side local barge-in and server-side interrupt processing:

1. VAD detects user speech → `bargeIn("local_speech_start")` → `playerNode.stop()` (audio stops immediately)
2. Server is still streaming audio chunks from the old Nova Sonic response over WebSocket
3. Late-arriving chunks hit `appendAssistantAudio()` → `scheduleAssistantPlayback()` → `playerNode.play()` restarts with OLD audio
4. Server finally processes the interrupt, sends `assistant.audio.interrupted`, but playback already resumed with stale data

The `liveResponseId` filtering in `ConversationEventCoordinator` does gate audio chunks (lines 132-138), but there is a timing window: `bargeIn()` runs in a separate `Task` on `@MainActor`, and between `playerNode.stop()` and the coordinator inserting the ID into `invalidatedLiveResponseIds` (via event bus → Combine sink), another inbound event iteration can slip through and re-enqueue stale audio.

## Solution: Client-Side Generation Gating

Add a `rejectedLiveResponseId` property to `ConversationAudioPipeline`. On barge-in, record the current liveResponseId as rejected. All incoming audio chunks matching the rejected ID are silently dropped. The gate clears when a chunk with a new liveResponseId arrives.

### Changes

**Single file modified: `ConversationAudioPipeline.swift`**

1. Add `private var rejectedLiveResponseId: String?` property
2. In `bargeIn()`: before calling `stopRemoteAssistantAudio()`, capture the current liveResponseId into `rejectedLiveResponseId`
3. In `handleAssistantAudioChunk()`: if the chunk's `liveResponseId` matches `rejectedLiveResponseId`, return early (drop). If it's a new ID, clear `rejectedLiveResponseId` and process normally.
4. In `handleAssistantAudioEnd()`: also gate — if the audioEnd's liveResponseId matches rejected, drop it
5. In `handleAssistantAudioInterrupted()`: also gate — already handled by coordinator but belt-and-suspenders

### Data Flow After Fix

```
t0: VAD fires → bargeIn()
    → rejectedLiveResponseId = currentLiveResponseId
    → playerNode.stop(), queue.reset()
t1: Late chunk arrives with OLD liveResponseId
    → handleAssistantAudioChunk: matches rejectedLiveResponseId → DROP
t2: More late chunks → all dropped
t3: Server processes interrupt, opens new Nova Sonic stream
t4: New chunk arrives with NEW liveResponseId
    → rejectedLiveResponseId cleared → audio plays normally
```

### Passing the liveResponseId to the Pipeline

`handleAssistantAudioChunk` currently receives `Event.AssistantAudioChunk` which already contains `liveResponseId: String?`. The coordinator passes the full chunk payload through. No new plumbing needed.

For `bargeIn()` to know the *current* liveResponseId being played, the pipeline needs to track it. Add `private var currentPlayingLiveResponseId: String?` — set it whenever a chunk is accepted for playback, clear it on stop.

**Defense-in-depth note:** The coordinator already filters at lines 132-138 of `ConversationEventCoordinator.swift`. This pipeline-level gate specifically targets the MainActor scheduling window between `playerNode.stop()` and the coordinator's `invalidatedLiveResponseIds.insert()`. The `currentPlayingLiveResponseId` is set only from chunks accepted by the pipeline, not synced with the coordinator's `activeLiveResponseId` — the two layers operate independently.

### Edge Cases

- **No liveResponseId on chunk**: Only possible outside live conversation mode. `handleAssistantAudioChunk` already guards `recordingMode == .vadAuto`. In live mode, Nova Sonic always provides liveResponseId.
- **Multiple rapid barge-ins**: Each barge-in overwrites `rejectedLiveResponseId`. Only the most recent matters since older responses are already stopped.
- **Server sends `assistant.audio.interrupted` after local stop**: `handleAssistantAudioInterrupted()` calls `stopAssistantAudio()` again — harmless double-stop.
- **Barge-in during silence (no active liveResponseId)**: `rejectedLiveResponseId` would be nil, gating is a no-op. Correct behavior.

### Scope Boundaries

This change does NOT touch:
- Push-to-talk code paths (all gated behind `recordingMode == .vadAuto`)
- Server-side code
- `BufferedPCMPlaybackQueue` internals
- `RemoteAudioCapture` internals
- `ElevenLabsTTS` / `StreamingPCMPlayer`
- Event protocol or event types
- `ConversationEventCoordinator`
