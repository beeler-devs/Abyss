# Simplified Live Conversation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove iOS-side VAD barge-in from vadAuto mode so live conversation relies entirely on Nova Sonic's native server-side interruption detection — eliminating the audio bleed bug.

**Architecture:** Strip the vadAuto path in `ConversationAudioPipeline` down to a thin audio I/O client. Remove local VAD monitoring, local barge-in, and chunk gating. `handleAssistantAudioInterrupted()` (driven by server events) becomes the only interrupt path. PTT is completely untouched.

**Tech Stack:** Swift, AVFoundation (no new dependencies)

**Spec:** `docs/superpowers/specs/2026-03-16-simplified-live-conversation-design.md`

---

## File Structure

**Modified:**
- `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` — Remove vadAuto barge-in logic, simplify handlers
- `ios/Abyss/AbyssTests/ConversationAudioPipelineNovaTests.swift` — Delete obsolete tests, add new ones

No new files. No server changes. No other files modified.

**DO NOT TOUCH:**
- All PTT code paths (micPressed, micReleased, startListeningPTT, stopListeningAndProcess, etc.)
- `RemoteAudioCapture` class internals
- `BufferedPCMPlaybackQueue` class internals
- `ConversationEventCoordinator.swift`
- Any server-side code
- `ElevenLabsTTS` / `StreamingPCMPlayer`

**Note:** Line numbers are approximate. Find methods/properties by name, not line number.

---

## Chunk 1: Remove vadAuto barge-in logic

### Task 1: Remove gating properties

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (property declarations)

- [ ] **Step 1: Remove `handsFreeBargeInInFlight`, `currentPlayingLiveResponseId`, and `rejectedLiveResponseId`**

Find and delete these three lines from the property declarations section:

```swift
    private var handsFreeBargeInInFlight = false
    private var currentPlayingLiveResponseId: String?
    private var rejectedLiveResponseId: String?
```

- [ ] **Step 2: Verify project builds**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,id=1156F3F5-3011-4987-A050-A0E4E988679E' build 2>&1 | tail -3`
Expected: Build will FAIL (references to removed properties). That's expected — we'll fix them in subsequent tasks.

---

### Task 2: Simplify `configureVoicePipeline()` — remove vadAuto barge-in from onSpeechStarted

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (the `configureVoicePipeline` method)

- [ ] **Step 1: Replace the `onSpeechStarted` callback**

Find the current `onSpeechStarted` callback in `configureVoicePipeline()`. Replace the entire callback with a version that removes the vadAuto barge-in branch. The callback currently has two branches: (1) vadAuto barge-in when `appState == .speaking`, and (2) set state to listening. Remove branch (1) entirely:

```swift
        voiceActivityDetector.onSpeechStarted = { [weak self] in
            guard let self else { return }
            guard self.canRunLiveConversation else { return }
            // vadAuto: no local barge-in. Nova Sonic handles interruption natively.
            // PTT: onSpeechStarted is not used (PTT uses onSpeechEnded + micPressed).
            if self.appState == .idle || self.appState == .transcribing {
                self.setState(.listening)
            }
        }
```

Do NOT modify the `onSpeechEnded` callback or the `whisperTranscriber.onAudioLevel` wiring below it — those are PTT-only.

---

### Task 3: Make `bargeIn()` PTT-only

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (the `bargeIn` method)

- [ ] **Step 1: Replace `bargeIn()` with a PTT-only version**

Find the `bargeIn(reason:)` method. Replace it entirely with:

```swift
    private func bargeIn(reason: String) async {
        guard recordingMode == .pushToTalk else { return }

        voiceActivityDetector.stopMonitoring()

        let stopEvent = Event.toolCall(
            name: TTSStopTool.name,
            arguments: encode(TTSStopTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(stopEvent)
        if case .toolCall(let toolCall) = stopEvent.kind {
            await toolRouter.dispatch(toolCall)
        }

        let interruptedEvent = Event.audioOutputInterrupted(reason, sessionId: sessionId)
        eventBus.emit(interruptedEvent)
        Task {
            await sendConductorEvent(interruptedEvent, false)
        }

        await refreshLiveConversationState()
    }
```

This removes:
- The vadAuto else branch (rejectedLiveResponseId, stopRemoteAssistantAudio)
- The vadAuto-specific setState(.listening) and comment
- The `if recordingMode == .pushToTalk` conditional structure (now it's always PTT via the guard)

---

### Task 4: Simplify `handleAssistantAudioChunk()` — remove gating

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (the `handleAssistantAudioChunk` method)

- [ ] **Step 1: Replace `handleAssistantAudioChunk` with simplified version**

Find the `handleAssistantAudioChunk` method. Replace it with:

```swift
    func handleAssistantAudioChunk(_ chunk: Event.AssistantAudioChunk) async {
        guard recordingMode == .vadAuto else { return }
        guard let data = Data(base64Encoded: chunk.audio), !data.isEmpty else { return }
        do {
            try await remoteVoiceCapture.appendAssistantAudio(
                data,
                sampleRate: Double(chunk.sampleRateHertz)
            )
        } catch {
            await handleError(error.localizedDescription)
        }
    }
```

This removes:
- The `rejectedLiveResponseId` gate
- The `currentPlayingLiveResponseId` tracking
- All `[BARGE-IN]` debug logging related to gating

---

### Task 5: Simplify `handleAssistantAudioEnd()` — remove tracking

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (the `handleAssistantAudioEnd` method)

- [ ] **Step 1: Remove `currentPlayingLiveResponseId = nil` from handleAssistantAudioEnd**

Replace the method with:

```swift
    func handleAssistantAudioEnd() async {
        guard recordingMode == .vadAuto else { return }
        await remoteVoiceCapture.finishAssistantAudio()
    }
```

---

### Task 6: Simplify `handleAssistantAudioInterrupted()` — clean up logging

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (the `handleAssistantAudioInterrupted` method)

- [ ] **Step 1: Keep method simple — this is now the ONLY interrupt path**

Replace with:

```swift
    func handleAssistantAudioInterrupted() async {
        guard recordingMode == .vadAuto else { return }
        await stopRemoteAssistantAudio()
    }
```

---

### Task 7: Remove VAD monitoring from `startRemoteVoiceCapture()` and simplify `applyRemoteState()`

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift`

- [ ] **Step 1: Remove `voiceActivityDetector.startMonitoring()` from `startRemoteVoiceCapture()`**

Find `startRemoteVoiceCapture()`. Remove the line:
```swift
            voiceActivityDetector.startMonitoring()
```

Also remove the `onInputLevel` callback that feeds the VAD. In the `remoteVoiceCapture.start(...)` call, change:
```swift
                onInputLevel: { [weak self] level in
                    self?.voiceActivityDetector.processAudioLevel(level)
                }
```
to:
```swift
                onInputLevel: { _ in }
```

And in the catch block, remove:
```swift
            voiceActivityDetector.stopMonitoring()
```

- [ ] **Step 2: Simplify `applyRemoteState()` — remove vadAuto VAD exemption**

In `applyRemoteState()`, find the `.thinking, .speaking` case. Replace:

```swift
        case .thinking, .speaking:
            // vadAuto: keep VAD monitoring so it can trigger bargeIn() when
            // the user speaks during assistant playback. Nova Sonic native
            // barge-in is unreliable when echo cancellation doesn't fully
            // suppress the assistant audio, so the iOS VAD is the primary
            // barge-in trigger.
            if recordingMode != .vadAuto {
                voiceActivityDetector.stopMonitoring()
            }
```

with:

```swift
        case .thinking, .speaking:
            voiceActivityDetector.stopMonitoring()
```

- [ ] **Step 3: Verify project builds**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,id=1156F3F5-3011-4987-A050-A0E4E988679E' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit all implementation changes**

```bash
git add ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift
git commit -m "Simplify live conversation to Nova Sonic native flow

Remove iOS-side VAD barge-in, chunk gating, and local interrupt
detection from vadAuto mode. Live conversation now relies entirely
on Nova Sonic's server-side interruption handling per Amazon's
documented client implementation guidance.

iOS becomes a thin audio I/O client in live mode: stream mic audio,
play assistant audio chunks, stop playback on server interrupt signal.
PTT mode is completely unchanged."
```

---

## Chunk 2: Update tests

### Task 8: Delete obsolete tests and add new ones

**Files:**
- Modify: `ios/Abyss/AbyssTests/ConversationAudioPipelineNovaTests.swift`

- [ ] **Step 1: Delete the 8 obsolete tests**

Delete these test methods from `ConversationAudioPipelineNovaTests`:

1. `testHandsFreeSpeechOnsetDuringSpeakingInterruptsAssistantImmediately` — tests local VAD barge-in (removed)
2. `testHandsFreeSpeechOnsetWhileListeningDoesNotInterruptAssistant` — tests VAD during listening (removed)
3. `testHandsFreeSpeechOnsetTriggersSingleBargeInPerUtterance` — tests `handsFreeBargeInInFlight` (removed)
4. `testBargeInDropsSubsequentChunksFromSameLiveResponseId` — tests `rejectedLiveResponseId` (removed)
5. `testBargeInAcceptsChunksFromNewLiveResponseId` — tests gating (removed)
6. `testBargeInDropsMultipleLateSameResponseChunks` — tests gating (removed)
7. `testBargeInWithNoActiveResponseIsHarmless` — tests gating (removed)
8. `testRapidDoubleBargeInGatesCorrectly` — tests gating (removed)

Keep all other tests (VAD auto starts, speaking keeps stream open, playback lifecycle, listening restart, buffered playback queue tests).

- [ ] **Step 2: Add test — server-driven interrupt stops playback**

Add this test:

```swift
    func testServerDrivenInterruptStopsPlayback() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        // Play some audio
        await harness.pipeline.applyRemoteState(.speaking)
        let chunk = Event.AssistantAudioChunk(
            audio: Data(repeating: 1, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(chunk)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 1)

        // Server sends interrupt (Nova Sonic detected barge-in)
        await harness.pipeline.handleAssistantAudioInterrupted()
        XCTAssertEqual(harness.remoteVoiceCapture.stopAssistantAudioCallCount, 1)

        // Stream stays open (mic keeps streaming)
        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
    }
```

- [ ] **Step 3: Add test — audio chunks play without gating**

```swift
    func testAudioChunksPlayWithoutGating() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)

        // Send multiple chunks with different liveResponseIds — all should play
        for i in 0..<3 {
            let chunk = Event.AssistantAudioChunk(
                audio: Data(repeating: UInt8(i), count: 320).base64EncodedString(),
                encoding: "pcm_s16le",
                sampleRateHertz: 24_000,
                channelCount: 1,
                liveResponseId: "resp-\(i)"
            )
            await harness.pipeline.handleAssistantAudioChunk(chunk)
        }

        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 3,
                       "All chunks should play — no client-side gating")
    }
```

- [ ] **Step 4: Add test — VAD is disconnected from remote capture in vadAuto mode**

This test verifies that the VAD is not wired to the remote capture's input levels in vadAuto mode. After the simplification, `onInputLevel` is a no-op, so audio levels never reach the VAD, and no local barge-in can fire.

```swift
    func testVADDisconnectedFromRemoteCaptureInVadAutoMode() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)

        // Emit audio level — VAD is disconnected so nothing should happen
        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // No local interrupt should have fired (VAD not connected)
        XCTAssertEqual(harness.remoteVoiceCapture.stopAssistantAudioCallCount, 0,
                       "No local barge-in — VAD is disconnected in vadAuto mode")
        XCTAssertEqual(audioOutputInterruptedCount(in: harness.sentEvents.events), 0,
                       "No local interrupt event should be sent")
    }
```

- [ ] **Step 5: Add test — handleAssistantAudioEnd finishes playback cleanly**

```swift
    func testHandleAssistantAudioEndFinishesPlayback() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)
        let chunk = Event.AssistantAudioChunk(
            audio: Data(repeating: 1, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(chunk)
        await harness.pipeline.handleAssistantAudioEnd()

        XCTAssertEqual(harness.remoteVoiceCapture.finishAssistantAudioCallCount, 1)
        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming,
                      "Stream should stay open after playback ends")
    }
```

- [ ] **Step 6: Verify tests build and run**

Run: `cd ios/Abyss && xcodebuild test -scheme Abyss -destination 'platform=iOS Simulator,id=1156F3F5-3011-4987-A050-A0E4E988679E' -only-testing:AbyssTests/ConversationAudioPipelineNovaTests 2>&1 | grep -E '(Test Case|Executed|PASS|FAIL|BUILD)'`
Expected: All tests pass.

- [ ] **Step 7: Commit tests**

```bash
git add ios/Abyss/AbyssTests/ConversationAudioPipelineNovaTests.swift
git commit -m "Update tests for simplified live conversation flow

Delete 8 tests for removed VAD barge-in and chunk gating logic.
Add 4 new tests verifying: server-driven interrupt stops playback,
audio chunks play without gating, VAD speech does not trigger local
barge-in, and handleAssistantAudioEnd finishes cleanly."
```

---

## Verification

After both chunks are committed, do a full build:

```bash
cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,id=1156F3F5-3011-4987-A050-A0E4E988679E' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

Then test live conversation on device:
1. Open app in Live mode
2. Ask a long question (e.g., "list all my repositories")
3. While assistant is speaking, interrupt with a new question
4. Verify: old audio stops immediately, new response plays
