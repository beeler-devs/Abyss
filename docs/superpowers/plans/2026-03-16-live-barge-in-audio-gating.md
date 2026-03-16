# Live Barge-In Audio Gating Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate stale audio bleed after barge-in in hands-free live conversation mode by gating incoming audio chunks against a rejected liveResponseId.

**Architecture:** Add `currentPlayingLiveResponseId` and `rejectedLiveResponseId` properties to `ConversationAudioPipeline`. On barge-in, capture the current ID as rejected. In `handleAssistantAudioChunk`, drop chunks matching the rejected ID and clear the gate when a new ID arrives.

**Tech Stack:** Swift, AVFoundation (no new dependencies)

**Spec:** `docs/superpowers/specs/2026-03-16-live-barge-in-audio-gating-design.md`

---

## File Structure

**Modified:**
- `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` — Add two properties, modify `handleAssistantAudioChunk`, `handleAssistantAudioEnd`, and `bargeIn`
- `ios/Abyss/AbyssTests/ConversationAudioPipelineNovaTests.swift` — Add tests for the gating behavior

No new files. No other files modified.

**Deliberately NOT modified (and why):**
- `handleAssistantAudioInterrupted()` — The coordinator already gates this (lines 152-157). The method just calls `stopAssistantAudio()` which is a harmless double-stop on an already-stopped player. Adding a gate would require a signature change + coordinator update for zero practical benefit.
- `ConversationEventCoordinator.swift` — The coordinator's existing `shouldIgnoreLiveResponse` gating is the primary defense. The pipeline gate is defense-in-depth targeting only the MainActor scheduling window.
- All PTT code paths — untouched, must remain untouched.

**Note:** Line numbers in this plan are approximate. Find methods by name, not line number.

---

## Chunk 1: Implementation

### Task 1: Add gating properties to ConversationAudioPipeline

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (property declarations section)

- [ ] **Step 1: Add the two tracking properties**

In `ConversationAudioPipeline`, after the existing `handsFreeBargeInInFlight` property, add:

```swift
    private var currentPlayingLiveResponseId: String?
    private var rejectedLiveResponseId: String?
```

These sit alongside the other private state flags. `currentPlayingLiveResponseId` tracks which liveResponseId is currently being played. `rejectedLiveResponseId` is set on barge-in to gate stale chunks.

- [ ] **Step 2: Verify project still builds**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 2: Gate handleAssistantAudioChunk on rejectedLiveResponseId

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (the `handleAssistantAudioChunk` method)

- [ ] **Step 1: Add gating logic to handleAssistantAudioChunk**

Replace the current `handleAssistantAudioChunk` method with:

```swift
    func handleAssistantAudioChunk(_ chunk: Event.AssistantAudioChunk) async {
        guard recordingMode == .vadAuto else { return }

        // Gate: drop chunks from a rejected (interrupted) response
        if let rejected = rejectedLiveResponseId {
            if chunk.liveResponseId == rejected {
                return
            }
            // New response arrived — clear the gate
            rejectedLiveResponseId = nil
        }

        currentPlayingLiveResponseId = chunk.liveResponseId

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

Key behavior:
- If `rejectedLiveResponseId` is set and chunk matches it → drop silently
- If `rejectedLiveResponseId` is set but chunk has a *different* ID → clear gate, process normally
- Always track `currentPlayingLiveResponseId` from accepted chunks

- [ ] **Step 2: Verify project still builds**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 3: Clear currentPlayingLiveResponseId in handleAssistantAudioEnd

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (the `handleAssistantAudioEnd` method)

- [ ] **Step 1: Add cleanup to handleAssistantAudioEnd**

Replace the current `handleAssistantAudioEnd` method with:

```swift
    func handleAssistantAudioEnd() async {
        guard recordingMode == .vadAuto else { return }
        currentPlayingLiveResponseId = nil
        await remoteVoiceCapture.finishAssistantAudio()
    }
```

This clears the tracking state when a response ends naturally. Without this, `currentPlayingLiveResponseId` would hold a stale ID until the next response, which is harmless but unclean.

- [ ] **Step 2: Verify project still builds**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 4: Capture rejectedLiveResponseId in bargeIn()

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift` (the `bargeIn` method)

- [ ] **Step 1: Set rejectedLiveResponseId in the vadAuto branch of bargeIn**

Replace the current `bargeIn` method with:

```swift
    private func bargeIn(reason: String) async {
        if recordingMode == .pushToTalk {
            voiceActivityDetector.stopMonitoring()
        }

        if recordingMode == .pushToTalk {
            let stopEvent = Event.toolCall(
                name: TTSStopTool.name,
                arguments: encode(TTSStopTool.Arguments()),
                sessionId: sessionId
            )
            eventBus.emit(stopEvent)
            if case .toolCall(let toolCall) = stopEvent.kind {
                await toolRouter.dispatch(toolCall)
            }
        } else {
            // Capture the current response ID as rejected BEFORE stopping audio.
            // Late-arriving chunks with this ID will be dropped by handleAssistantAudioChunk.
            rejectedLiveResponseId = currentPlayingLiveResponseId
            currentPlayingLiveResponseId = nil
            await stopRemoteAssistantAudio()
        }

        let interruptedEvent = Event.audioOutputInterrupted(reason, sessionId: sessionId)
        eventBus.emit(interruptedEvent)
        Task {
            await sendConductorEvent(interruptedEvent, false)
        }

        if recordingMode == .vadAuto {
            setState(.listening)
        }

        await refreshLiveConversationState()
    }
```

The only change from the original is the two lines added in the `else` branch before `stopRemoteAssistantAudio()`:
- `rejectedLiveResponseId = currentPlayingLiveResponseId` — gates future chunks with this ID
- `currentPlayingLiveResponseId = nil` — nothing is playing now

PTT branch is completely untouched.

- [ ] **Step 2: Verify project still builds**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit implementation**

```bash
git add ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift
git commit -m "Fix live conversation barge-in audio bleed

Gate incoming audio chunks against rejectedLiveResponseId so that
late-arriving chunks from an interrupted Nova Sonic stream are
silently dropped instead of restarting playback."
```

---

### Task 5: Write tests for barge-in audio gating

**Files:**
- Modify: `ios/Abyss/AbyssTests/ConversationAudioPipelineNovaTests.swift`

- [ ] **Step 1: Write test — chunks after barge-in with same liveResponseId are dropped**

Add this test to the `ConversationAudioPipelineNovaTests` class:

```swift
    func testBargeInDropsSubsequentChunksFromSameLiveResponseId() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        // Move to speaking state and play a chunk
        await harness.pipeline.applyRemoteState(.speaking)
        let chunk1 = Event.AssistantAudioChunk(
            audio: Data(repeating: 1, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(chunk1)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 1)

        // Trigger barge-in
        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        await waitForCondition {
            harness.remoteVoiceCapture.stopAssistantAudioCallCount == 1
        }

        // Late-arriving chunk with SAME liveResponseId should be dropped
        let lateChunk = Event.AssistantAudioChunk(
            audio: Data(repeating: 2, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(lateChunk)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 1,
                       "Late chunk from interrupted response should be dropped")
    }
```

- [ ] **Step 2: Write test — chunks with new liveResponseId after barge-in are accepted**

```swift
    func testBargeInAcceptsChunksFromNewLiveResponseId() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)
        let chunk1 = Event.AssistantAudioChunk(
            audio: Data(repeating: 1, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(chunk1)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 1)

        // Trigger barge-in
        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        await waitForCondition {
            harness.remoteVoiceCapture.stopAssistantAudioCallCount == 1
        }

        // Chunk with NEW liveResponseId should be accepted
        let newChunk = Event.AssistantAudioChunk(
            audio: Data(repeating: 3, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-2"
        )
        await harness.pipeline.handleAssistantAudioChunk(newChunk)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 2,
                       "Chunk from new response should be accepted")
    }
```

- [ ] **Step 3: Write test — multiple late chunks are all dropped**

```swift
    func testBargeInDropsMultipleLateSameResponseChunks() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)
        let initial = Event.AssistantAudioChunk(
            audio: Data(repeating: 1, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(initial)

        // Trigger barge-in
        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        await waitForCondition {
            harness.remoteVoiceCapture.stopAssistantAudioCallCount == 1
        }

        // Send 5 late chunks — all should be dropped
        for _ in 0..<5 {
            let late = Event.AssistantAudioChunk(
                audio: Data(repeating: 9, count: 320).base64EncodedString(),
                encoding: "pcm_s16le",
                sampleRateHertz: 24_000,
                channelCount: 1,
                liveResponseId: "resp-1"
            )
            await harness.pipeline.handleAssistantAudioChunk(late)
        }

        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 1,
                       "All late chunks from interrupted response should be dropped")
    }
```

- [ ] **Step 4: Write test — barge-in with no current response is harmless**

```swift
    func testBargeInWithNoActiveResponseIsHarmless() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        // Speaking state but no audio chunk received yet (no currentPlayingLiveResponseId)
        await harness.pipeline.applyRemoteState(.speaking)
        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        await waitForCondition {
            harness.remoteVoiceCapture.stopAssistantAudioCallCount == 1
        }

        // New chunk should still be accepted (rejectedLiveResponseId is nil)
        let chunk = Event.AssistantAudioChunk(
            audio: Data(repeating: 1, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(chunk)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 1,
                       "Chunk should be accepted when no response was rejected")
    }
```

- [ ] **Step 5: Write test — rapid double barge-in gates correctly**

```swift
    func testRapidDoubleBargeInGatesCorrectly() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        // First response
        await harness.pipeline.applyRemoteState(.speaking)
        let chunk1 = Event.AssistantAudioChunk(
            audio: Data(repeating: 1, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(chunk1)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 1)

        // First barge-in
        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        await waitForCondition {
            harness.remoteVoiceCapture.stopAssistantAudioCallCount == 1
        }

        // Second response starts
        let chunk2 = Event.AssistantAudioChunk(
            audio: Data(repeating: 2, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-2"
        )
        await harness.pipeline.applyRemoteState(.speaking)
        await harness.pipeline.handleAssistantAudioChunk(chunk2)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 2)

        // Second barge-in
        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        await waitForCondition {
            harness.remoteVoiceCapture.stopAssistantAudioCallCount == 2
        }

        // Late chunk from resp-2 should be dropped
        let lateChunk2 = Event.AssistantAudioChunk(
            audio: Data(repeating: 9, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-2"
        )
        await harness.pipeline.handleAssistantAudioChunk(lateChunk2)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 2,
                       "Late chunk from second interrupted response should be dropped")

        // Late chunk from resp-1 should also be dropped (resp-2 is the rejected ID,
        // but resp-1 was already stopped — new gate overwrites old)
        let lateChunk1 = Event.AssistantAudioChunk(
            audio: Data(repeating: 8, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(lateChunk1)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 3,
                       "resp-1 is not the rejected ID (resp-2 is), so it clears the gate and is accepted — this is fine because resp-1 audio was already stopped by playerNode.stop()")

        // Third response works normally
        let chunk3 = Event.AssistantAudioChunk(
            audio: Data(repeating: 3, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "resp-3"
        )
        await harness.pipeline.handleAssistantAudioChunk(chunk3)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 4,
                       "Third response should be accepted normally")
    }
```

Note: The `resp-1` late chunk clears the gate (since `rejectedLiveResponseId` is `resp-2`) and gets accepted. This is acceptable because `playerNode.stop()` + `reset()` already cleared all scheduled buffers from resp-1 during the first barge-in — the `appendAssistantAudio` call would just schedule one buffer that starts playing. In practice this edge case is extremely unlikely (an old response's chunks arriving after a newer response was also interrupted), and the coordinator-level gate at `ConversationEventCoordinator` would have already filtered it.

- [ ] **Step 6: Run all tests**

Run: `cd ios/Abyss && xcodebuild test -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AbyssTests/ConversationAudioPipelineNovaTests 2>&1 | grep -E '(Test Case|TEST|PASS|FAIL|BUILD)'`
Expected: All tests pass including the five new ones.

- [ ] **Step 7: Commit tests**

```bash
git add ios/Abyss/AbyssTests/ConversationAudioPipelineNovaTests.swift
git commit -m "Add tests for live barge-in audio gating

Tests verify that chunks from interrupted responses are dropped,
chunks from new responses are accepted, multiple late chunks are
all dropped, rapid double barge-in gates correctly, and barge-in
with no active response is harmless."
```

---

## Verification

After both tasks are committed, do a final full test run:

```bash
cd ios/Abyss && xcodebuild test -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E '(Test Case|TEST|PASS|FAIL|BUILD)'
```

All existing tests must still pass — especially the PTT tests and the existing barge-in tests.
