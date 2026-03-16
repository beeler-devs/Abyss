# True Live Conversation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore true full-duplex live conversation in hands-free mode so the user can interrupt naturally while the assistant is speaking, without falling back to muting/stopping the mic during assistant playback.

**Architecture direction:** Keep the Nova Sonic audio input stream open continuously while the chat is active and unmuted. Handle interruptions the way Gemini/OpenAI/Nova-style realtime systems do: continuous input + explicit interruption semantics. Solve self-echo at the audio stack and false-barge-in layers, not by serializing turns.

**Tech stack:** Swift, AVFoundation, TypeScript, AWS Bedrock Nova Sonic, XCTest, Node test runner

---

## Historical Findings

**Last working full-duplex-style implementation**

- `03e558d66834e08b51d093fcbc511d4d57e1d8ba` (`Fix Nova Sonic, working`, March 15, 2026) is the last commit on the current ancestry where hands-free live conversation kept the remote mic path open while the assistant was speaking.
- In that state, `ConversationAudioPipeline` did **not** stop remote capture on `.speaking`, and `handleAssistantAudioChunk()` did **not** stop the remote stream when assistant playback began.
- That behavior was the true live-conversation version: user audio kept flowing to Nova Sonic, so natural interrupts were possible.

**Commits that made the system half-duplex**

- `b3b06f88f5a387a9a001184247c372ae94efa67e` (`Fix live conversation startup issue`, March 15, 2026) introduced the key half-duplex guards:
  - `shouldStreamRemoteVoiceCapture` now requires `appState != .speaking`
  - `applyRemoteState(.speaking)` calls `stopRemoteVoiceCapture()`
  - `handleAssistantAudioChunk()` also stops remote capture if it is still open
- `b3acd329fc9d1f2d0fdc66f7f1064a59db530453` (`Fix mic opening during long assistant audio playback in vadAuto mode`, March 15, 2026) added `waitForPlaybackToFinish()` before processing `idle`, which further cemented the serialized-turn behavior.

**Nova Sonic behavior that is still useful**

- `428b70b5c0258454bff9e0312bc370b565223e10` got Nova voice working.
- `bc816de5504f260a3adb29d8ea442c1648b5a1d3` improved session reuse, trailing silence, and first-audio speaking-state transitions.
- The current provider already handles server-side interruption semantics (`INTERRUPTED`, `BARGE_IN`) and live-response IDs well enough to build on.

**Current blockers in code**

- `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift`
  - Lines around `190-224`, `242-248`, and `520-525` explicitly shut down capture when the assistant speaks.
- `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss/AbyssTests/ConversationAudioPipelineNovaTests.swift`
  - Current tests codify half-duplex behavior by asserting that `.speaking` stops the remote stream.
- `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss/Abyss/ViewModels/ConversationEventCoordinator.swift`
  - Current hands-free interruption flow invalidates the active live response immediately on `assistant.audio.interrupted`, which is too aggressive if the interruption was false/self-echo.

---

## External Findings

- Google Gemini Live supports automatic activity detection with interruption-aware turn coverage. The Live API explicitly supports `START_OF_ACTIVITY_INTERRUPTS` and also allows disabling interruption with `NO_INTERRUPTION`.
- OpenAI Realtime exposes server VAD with `interrupt_response` and documents interruption/truncation handling rather than muting input during output.
- AWS Nova Sonic emits interruption stop reasons (`INTERRUPTED`, `BARGE_IN`) at the provider layer, so the model already supports barge-in as a first-class concept.
- Apple’s voice chat / voice-processing stack is designed for two-way conversation and includes acoustic echo cancellation, noise suppression, and automatic gain control. Our code currently sets `AVAudioSession` to `.voiceChat`, but it does not explicitly enable the stronger voice-processing path on the engine nodes / voice-processing I/O path.
- LiveKit’s voice-agent docs call out false interruptions as a real issue and recommend tuning turn detection instead of disabling duplex behavior entirely.

**Conclusion:** Our current design is compensating for missing echo suppression by muting the mic in software. Gemini-style live conversation uses continuous audio plus interruption handling; the missing piece for Abyss is reliable echo control and a false-barge-in fallback.

---

## Proposed Design

### 1. Restore continuous upstream capture in hands-free mode

- [ ] Remove the half-duplex gates in `ConversationAudioPipeline` for `vadAuto` mode.
- [ ] `applyRemoteState(.speaking)` should no longer stop `remoteVoiceCapture`.
- [ ] `handleAssistantAudioChunk()` should no longer call `stopRemoteVoiceCapture()`.
- [ ] `shouldStreamRemoteVoiceCapture` should depend on chat activity / mute / fatal error state, not assistant speaking state.
- [ ] Keep `appState` for UI only; do not let it control whether the mic is open during hands-free mode.

**Why:** This returns us to true live conversation and matches Gemini/OpenAI/Nova realtime interaction semantics.

### 2. Upgrade the iOS audio path to real echo-canceling voice processing

- [ ] Keep `AVAudioSession` in `.playAndRecord` with `.voiceChat` or `.videoChat`.
- [ ] Explicitly enable voice processing on the capture/playback path instead of relying only on the session mode.
- [ ] Evaluate the best implementation path:
  - `AVAudioInputNode.setVoiceProcessingEnabled(true)` / matching output-side support if compatible with our engine setup
  - or a dedicated Voice Processing I/O audio unit if the engine API is insufficient
- [ ] Ensure assistant playback and microphone capture live in the same voice-processing session so the system AEC has the playback reference.
- [ ] Prefer built-in receiver / wired / Bluetooth routes when available, and treat open-speaker as the highest-risk route for echo.
- [ ] Add structured logging for route, voice-processing state, output level, input level, and interruption events.

**Why:** This is the primary mitigation used by realtime voice systems. Without actual AEC, full-duplex will keep self-triggering.

### 3. Add a false-barge-in safety layer above AEC

- [ ] Keep a short rolling buffer of the assistant text/audio currently being played.
- [ ] When Nova Sonic returns a user transcript during assistant playback or immediately after playback, classify it before treating it as a genuine interruption.
- [ ] Start with a conservative echo heuristic:
  - normalize transcript text
  - compare it against the recent assistant utterance
  - if overlap is very high and there are no clearly new user tokens, mark it as likely echo
- [ ] Do not immediately clear the active assistant draft on `assistant.audio.interrupted`; wait for confirmed user speech or a short timeout window.
- [ ] If interruption was likely echo and no real user utterance follows, recover gracefully:
  - keep the assistant draft visible
  - reopen / continue the conversation stream
  - avoid generating a spurious user message bubble

**Why:** AEC reduces the problem, but false interruptions still happen in real systems. This is the second safety net.

### 4. Make provider interruption handling recoverable

- [ ] Update `BedrockNovaSonicVoiceProvider` so `INTERRUPTED` / `BARGE_IN` does not immediately become a destructive end-state for the assistant reply.
- [ ] Preserve enough live-response state to distinguish:
  - genuine user interrupt
  - false interrupt caused by leaked assistant playback
- [ ] If no valid user transcript arrives after an interruption timeout, resume listening and allow the assistant turn to continue or be regenerated from the existing conversation state.
- [ ] Keep existing `liveResponseId` semantics so the iOS UI can reconcile partial/final assistant bubbles cleanly.

**Why:** Right now a false barge-in can permanently kill the assistant turn. Full-duplex needs a recovery path.

### 5. Tune end-of-speech behavior for duplex mode

- [ ] Revisit the trailing-silence behavior in both iOS and the provider so we do not accidentally create synthetic end-of-turn edges during assistant playback.
- [ ] Confirm that barge-in comes from genuine user speech onset, not from output drain timing.
- [ ] Keep `waitForPlaybackToFinish()` only if it is still needed for UI synchronization; it should not be part of the mic-open/closed decision in duplex mode.

**Why:** In the current system, playback-drain timing is tightly coupled to reopening the mic. That coupling has to go away.

---

## Implementation Chunks

### Chunk 1: Re-enable duplex behavior

- [ ] Change `ConversationAudioPipeline` to keep `remoteVoiceCapture` open during `.speaking`.
- [ ] Replace the existing Nova tests that assert "speaking stops remote stream".
- [ ] Add a new regression test: while assistant audio is arriving, the remote stream stays open and `audio.output.interrupted` can still be emitted by a real user barge-in.

### Chunk 2: Enable real voice processing on iOS

- [ ] Prototype the strongest Apple-supported AEC path that still works with our PCM streaming setup.
- [ ] Validate it on device, not just simulator.
- [ ] Record before/after logs for speakerphone, wired headphones, AirPods, and receiver mode.

### Chunk 3: Add false-echo classification

- [ ] Add assistant-playback context to the transcript handling path.
- [ ] Drop likely echo transcripts before they become user bubbles.
- [ ] Delay live-response invalidation until user speech is confirmed.

### Chunk 4: Provider recovery

- [ ] Preserve interrupted assistant state long enough to distinguish real from false barge-ins.
- [ ] If interruption is false, recover the stream without visually nuking the assistant turn.
- [ ] Add provider tests for:
  - genuine user interrupt
  - self-echo interrupt with no real user transcript
  - resume after false interrupt

### Chunk 5: Manual validation

- [ ] Test on physical iPhone with speaker at low / medium / high volume.
- [ ] Test with device near mouth and at arm’s length.
- [ ] Test with Bluetooth and wired audio.
- [ ] Validate that user can interrupt mid-sentence naturally.
- [ ] Validate that the assistant does not transcribe its own last sentence as a user message.

---

## Test Plan

- [ ] Update `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss/AbyssTests/ConversationAudioPipelineNovaTests.swift`
  - replace half-duplex assertions with duplex assertions
- [ ] Add iOS tests for:
  - assistant speaking does not stop remote capture
  - user barge-in while assistant is speaking emits interrupt and keeps conversation alive
  - suspected echo does not create a user bubble
- [ ] Add server tests for:
  - false `BARGE_IN` without a valid user transcript
  - interruption recovery preserving `liveResponseId`
  - no duplicate assistant finalization after false interrupts
- [ ] Run:
  - `cd server && npm test`
  - iOS simulator tests for updated pipeline/event-coordinator coverage
  - physical-device manual audio validation

---

## Open Questions

- [ ] Which Apple API combination gives us the strongest usable AEC with our custom PCM streaming path?
- [ ] Can Nova Sonic continue an interrupted assistant turn cleanly, or do we need to regenerate from conversation state after a false interruption?
- [ ] How aggressive can the echo-text heuristic be before it starts suppressing legitimate user repetition or paraphrase?
- [ ] Do we want a user-facing fallback such as "Prefer headphones for best live conversation quality" on routes where AEC is weakest?

---

## Success Criteria

- [ ] In hands-free mode, the user can interrupt the assistant naturally without tapping mute or stop.
- [ ] The microphone remains open during assistant playback in duplex mode.
- [ ] The assistant does not reliably hear and transcribe its own speech on speakerphone.
- [ ] False barge-ins no longer clear assistant drafts or create duplicate user/assistant bubbles.
- [ ] Duplex behavior is covered by automated tests instead of only manual validation.

---

## Source Notes

- Google Live API guide: [https://ai.google.dev/gemini-api/docs/live-guide](https://ai.google.dev/gemini-api/docs/live-guide)
- Google Live API reference: [https://ai.google.dev/api/live](https://ai.google.dev/api/live)
- OpenAI Realtime conversations guide: [https://platform.openai.com/docs/guides/realtime-conversations](https://platform.openai.com/docs/guides/realtime-conversations)
- OpenAI Realtime API reference: [https://platform.openai.com/docs/api-reference/realtime-server-events](https://platform.openai.com/docs/api-reference/realtime-server-events)
- AWS Nova Sonic user guide: [https://docs.aws.amazon.com/nova/latest/userguide/what-is-nova.html](https://docs.aws.amazon.com/nova/latest/userguide/what-is-nova.html)
- Apple AVAudioSession voice chat mode: [https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat)
- Apple WWDC voice-processing overview: [https://developer.apple.com/videos/play/wwdc2019/510/](https://developer.apple.com/videos/play/wwdc2019/510/)
- LiveKit turn-detection / interruptions: [https://docs.livekit.io/agents/build/turns/](https://docs.livekit.io/agents/build/turns/)
