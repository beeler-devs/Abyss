# PTT Race Condition Fix

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the push-to-talk race condition where `isStartingRecording` is set inside an async Task, causing `micReleased()` to miss the release and making PTT behave like a toggle.

**Architecture:** Move the `isStartingRecording` flag from the async `startListeningPTT()` method to be set synchronously in `micPressed()`, and cleared at the end of the async work. Add a secondary guard in `startListeningPTT()` since it's also called from other paths. Add a regression test that reproduces the exact race condition.

**Tech Stack:** Swift, XCTest

---

## Root Cause Analysis

**The bug:** `micPressed()` (line 111) spawns a `Task` that calls `startListeningPTT()`. The `isStartingRecording = true` assignment happens inside `startListeningPTT()` (line 258), which runs asynchronously. Meanwhile `micReleased()` (line 123) checks `transcriber.isListening || isStartingRecording` — both are still `false` because the Task hasn't started executing yet. The release is silently dropped.

**The sequence:**
1. Finger down → `micPressed()` → spawns Task (not yet executed)
2. Finger up → `micReleased()` → `isStartingRecording` is false, `transcriber.isListening` is false → guard returns early, **release lost**
3. Task executes → `startListeningPTT()` → sets `isStartingRecording = true`, starts transcriber, sets `isStartingRecording = false`
4. Recording is now running with no way to stop it except another tap cycle

**The fix:** Set `isStartingRecording = true` synchronously in `micPressed()` before spawning the Task. Remove the redundant set in `startListeningPTT()` but keep the guard (it's called from other code paths). Clear the flag via defer in the Task block itself so it's always cleaned up.

---

## Chunk 1: Fix and Test

### Task 1: Fix the race condition in `micPressed()`

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift:111-121`

- [ ] **Step 1: Write the failing test**

Add to a new test file `ios/Abyss/AbyssTests/PTTRaceConditionTests.swift`:

```swift
import XCTest
@testable import Abyss

@MainActor
final class PTTRaceConditionTests: XCTestCase {

    /// Reproduces the bug where a quick tap (press + immediate release)
    /// fails to stop recording because `isStartingRecording` wasn't set
    /// synchronously in `micPressed()`.
    func testQuickTapReleaseSendsTranscript() async {
        let transcriber = MockSpeechTranscriber()
        let eventBus = EventBus()
        let registry = ToolRegistry()
        let toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
        var sentEvents: [Event] = []

        let pipeline = ConversationAudioPipeline(
            transcriber: transcriber,
            tts: MockTextToSpeech(),
            transcriptFormatter: FastTranscriptFormatter(),
            eventBus: eventBus,
            toolRouter: toolRouter,
            appStateStore: AppStateStore(),
            sessionId: "session-ptt-race",
            sendConductorEvent: { event, _ in
                sentEvents.append(event)
            },
            handleError: { _ in }
        )

        pipeline.updateRecordingMode(.pushToTalk)
        pipeline.setChatActive(true)

        // Simulate quick tap: press and immediately release
        // before the Task in micPressed() can execute
        pipeline.micPressed()
        pipeline.micReleased()

        // Give async work time to complete
        try? await Task.sleep(nanoseconds: 500_000_000)

        // The transcriber should have been started AND stopped
        XCTAssertEqual(transcriber.startCallCount, 1, "Transcriber should have started once")
        XCTAssertEqual(transcriber.stopCallCount, 1, "Transcriber should have stopped once (release was not lost)")

        // A final transcript event should have been sent to the conductor
        let transcriptEvents = sentEvents.filter {
            if case .transcriptFinal = $0.kind { return true }
            return false
        }
        XCTAssertEqual(transcriptEvents.count, 1, "Should have sent exactly one transcript")
    }

    /// Verifies that normal hold-and-release PTT still works.
    func testHoldAndReleaseSendsTranscript() async {
        let transcriber = MockSpeechTranscriber()
        let eventBus = EventBus()
        let registry = ToolRegistry()
        let toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
        var sentEvents: [Event] = []

        let pipeline = ConversationAudioPipeline(
            transcriber: transcriber,
            tts: MockTextToSpeech(),
            transcriptFormatter: FastTranscriptFormatter(),
            eventBus: eventBus,
            toolRouter: toolRouter,
            appStateStore: AppStateStore(),
            sessionId: "session-ptt-hold",
            sendConductorEvent: { event, _ in
                sentEvents.append(event)
            },
            handleError: { _ in }
        )

        pipeline.updateRecordingMode(.pushToTalk)
        pipeline.setChatActive(true)

        pipeline.micPressed()

        // Wait for recording to actually start
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(transcriber.isListening, "Transcriber should be listening after hold")

        pipeline.micReleased()

        // Wait for processing
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(transcriber.stopCallCount, 1)

        let transcriptEvents = sentEvents.filter {
            if case .transcriptFinal = $0.kind { return true }
            return false
        }
        XCTAssertEqual(transcriptEvents.count, 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/Abyss && xcodebuild test -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AbyssTests/PTTRaceConditionTests/testQuickTapReleaseSendsTranscript 2>&1 | tail -20`

Expected: `testQuickTapReleaseSendsTranscript` FAILS because `transcriber.stopCallCount` is 0 (release was lost).

Note: If the `ConversationAudioPipeline` init signature doesn't match (e.g. missing `remoteVoiceCapture` parameter), adjust the test to match the current init. The Nova tests may be out of date.

- [ ] **Step 3: Apply the fix**

In `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift`, change `micPressed()` to set `isStartingRecording` synchronously:

**Before (lines 111-121):**
```swift
func micPressed() {
    guard recordingMode == .pushToTalk else { return }
    guard isChatActive else { return }
    guard !transcriber.isListening, !isStartingRecording else { return }
    Task {
        if appState == .speaking {
            await bargeIn(reason: "ptt_barge_in")
        }
        await startListeningPTT()
    }
}
```

**After:**
```swift
func micPressed() {
    guard recordingMode == .pushToTalk else { return }
    guard isChatActive else { return }
    guard !transcriber.isListening, !isStartingRecording else { return }
    isStartingRecording = true
    Task {
        defer { isStartingRecording = false }
        if appState == .speaking {
            await bargeIn(reason: "ptt_barge_in")
        }
        await startListeningPTT()
    }
}
```

And update `startListeningPTT()` to remove the now-redundant flag management:

**Before (lines 254-259):**
```swift
private func startListeningPTT() async {
    guard recordingMode == .pushToTalk else { return }
    guard !isStoppingRecording else { return }
    guard !isStartingRecording else { return }
    isStartingRecording = true
    defer { isStartingRecording = false }
```

**After:**
```swift
private func startListeningPTT() async {
    guard recordingMode == .pushToTalk else { return }
    guard !isStoppingRecording else { return }
```

The `guard !isStartingRecording` is removed because it would now always be true when called from `micPressed()` (we just set it). The `isStartingRecording = true` and `defer` are removed because ownership of that flag is now in `micPressed()`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios/Abyss && xcodebuild test -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AbyssTests/PTTRaceConditionTests 2>&1 | tail -20`

Expected: Both `testQuickTapReleaseSendsTranscript` and `testHoldAndReleaseSendsTranscript` PASS.

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `cd ios/Abyss && xcodebuild test -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30`

Expected: All tests pass. If Nova tests fail due to stale init signatures, that's a pre-existing issue — not caused by this change.

- [ ] **Step 6: Commit**

```bash
git add ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift ios/Abyss/AbyssTests/PTTRaceConditionTests.swift
git commit -m "fix: PTT race condition — set isStartingRecording synchronously in micPressed()

micReleased() was silently dropped on quick taps because isStartingRecording
was set inside an async Task, not before spawning it. This made PTT behave
like a toggle instead of hold-to-talk."
```
