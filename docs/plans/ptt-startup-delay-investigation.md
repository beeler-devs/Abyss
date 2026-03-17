# PTT First-Word Drop — Investigation & Fix Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Diagnose and fix the PTT recording startup delay that drops the first 1-2 words after button press.

**Architecture:** Add timestamped diagnostic logging across the entire PTT path to measure where latency actually lives, then fix the confirmed bottleneck(s). Previous attempt to reorder dispatches in `startListeningPTT()` did not fix the issue — the root cause is likely deeper than dispatch ordering.

**Tech Stack:** Swift, AVAudioSession, AVAudioEngine, WhisperKit

---

## Hypotheses (Ranked by Likelihood)

Based on code exploration, there are several potential causes. This plan investigates each before implementing fixes.

### H1: AVAudioSession reactivation after TTS deactivates it
`ElevenLabsTTS.stop()` at `ElevenLabsTTS.swift:78` unconditionally calls `AVAudioSession.setActive(false)`. This kills the warm audio engine that `preloadTranscriber()` prepared. When `WhisperKitSpeechTranscriber.start()` runs, it hits the `!engine.isRunning` branch (`WhisperKitSpeechTranscriber.swift:165`) and must call `setActive(true)` + `engine.start()` — a 100-400ms dead zone where the mic isn't capturing.

This applies even in non-barge-in cases: if TTS finished playing moments before the user presses PTT, the session is already deactivated.

### H2: Barge-in serializes TTS stop before mic open
In `micPressed()` (`ConversationAudioPipeline.swift:161`), when `appState == .speaking`, the full `bargeIn()` is awaited before `startListeningPTT()`. `bargeIn()` dispatches `tts.stop` and awaits it, which includes the `setActive(false)` call. Then `startListeningPTT()` must re-activate the session. The deactivation + reactivation is serial — easily 200-500ms.

### H3: `preloadTranscriber()` not complete by first button press
`preloadTranscriber()` fires a detached `Task` (`ConversationAudioPipeline.swift:88-92`). There's no completion signal. If the user presses PTT before `warmUp()` finishes (which includes `setActive(true)` + `engine.start()` + potentially WhisperKit model loading), the cold-start path runs inline in `start()`, adding 70-400ms.

### H4: WhisperKit partial transcription delay (not a mic issue)
The mic might actually be capturing audio on time, but WhisperKit's live partial transcription (`scheduleLivePartialTranscription()`) might have a startup delay before yielding the first meaningful partial. The audio buffers accumulate but the first transcription pass takes time, making it *appear* that words were dropped when they were actually captured but not transcribed fast enough.

### H5: Audio buffer discard on tap install
When `inputNode.installTap()` is called, any audio that arrived before the tap was installed is lost. If there's latency between `engine.start()` returning and the tap being installed (lines 169 → 213 in `WhisperKitSpeechTranscriber.swift`), those frames are gone.

---

## Task 1: Add Diagnostic Timing Instrumentation

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift`
- Modify: `ios/Abyss/Abyss/Services/WhisperKitSpeechTranscriber.swift`
- Modify: `ios/Abyss/Abyss/Services/ElevenLabsTTS.swift`

Add `CFAbsoluteTimeGetCurrent()` timestamps at key points in the PTT flow so we can see exactly where time is spent. Use `AppLogger.audio.warning` (not debug) so they show up in Console.app without filter changes.

- [ ] **Step 1: Instrument `micPressed()` in ConversationAudioPipeline.swift**

Add a stored property and timestamp the button press, Task start, barge-in boundaries, and `startListeningPTT()` call:

```swift
// Add property to ConversationAudioPipeline class:
private var pttPressTimestamp: CFAbsoluteTime = 0

// In micPressed(), before guards:
pttPressTimestamp = CFAbsoluteTimeGetCurrent()
AppLogger.audio.warning("[PTT-TIMING] micPressed at T=0")

// Inside the Task, before bargeIn:
AppLogger.audio.warning("[PTT-TIMING] Task body start: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - self.pttPressTimestamp) * 1000))ms")

// After bargeIn returns (if it ran):
AppLogger.audio.warning("[PTT-TIMING] bargeIn complete: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - self.pttPressTimestamp) * 1000))ms")

// Before startListeningPTT():
AppLogger.audio.warning("[PTT-TIMING] calling startListeningPTT: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - self.pttPressTimestamp) * 1000))ms")
```

- [ ] **Step 2: Instrument `startListeningPTT()` in ConversationAudioPipeline.swift**

Timestamp before/after each dispatch:

```swift
// Before convo.setState dispatch:
AppLogger.audio.warning("[PTT-TIMING] before setState dispatch: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - pttPressTimestamp) * 1000))ms")

// After convo.setState dispatch:
AppLogger.audio.warning("[PTT-TIMING] after setState dispatch: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - pttPressTimestamp) * 1000))ms")

// Before stt.start dispatch:
AppLogger.audio.warning("[PTT-TIMING] before stt.start dispatch: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - pttPressTimestamp) * 1000))ms")

// After stt.start dispatch:
AppLogger.audio.warning("[PTT-TIMING] after stt.start dispatch: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - pttPressTimestamp) * 1000))ms")
```

- [ ] **Step 3: Instrument `WhisperKitSpeechTranscriber.start()`**

Timestamp the key phases inside `start()`:

```swift
// At entry to start():
let startTime = CFAbsoluteTimeGetCurrent()
AppLogger.audio.warning("[PTT-TIMING] transcriber.start() entered")

// Before warmUp() fallback (line 155):
AppLogger.audio.warning("[PTT-TIMING] transcriber needs warmUp (cold start!)")

// After warmUp() fallback:
AppLogger.audio.warning("[PTT-TIMING] warmUp complete: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")

// At engine.isRunning check (line 165):
AppLogger.audio.warning("[PTT-TIMING] engine.isRunning=\(engine.isRunning)")

// If engine restart needed:
AppLogger.audio.warning("[PTT-TIMING] engine not running, restarting session...")

// After engine restart:
AppLogger.audio.warning("[PTT-TIMING] engine restarted: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")

// Before installTap:
AppLogger.audio.warning("[PTT-TIMING] installing tap: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")

// After installTap:
AppLogger.audio.warning("[PTT-TIMING] tap installed: +\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")
```

- [ ] **Step 4: Instrument the first audio buffer callback**

Inside the `installTap` closure, log the very first buffer:

```swift
// Add a flag in the lock-protected state:
var firstBufferLogged = false  // reset in start() alongside audioBuffers = []

// In the installTap closure, after the guard:
if !self.lock.withLock({ self.firstBufferLogged }) {
    self.lock.withLock { self.firstBufferLogged = true }
    AppLogger.audio.warning("[PTT-TIMING] FIRST audio buffer received: \(buffer.frameLength) frames")
}
```

- [ ] **Step 5: Instrument `ElevenLabsTTS.stop()`**

Log the session deactivation:

```swift
// Before setActive(false):
AppLogger.audio.warning("[PTT-TIMING] TTS.stop() deactivating audio session")

// After setActive(false):
AppLogger.audio.warning("[PTT-TIMING] TTS.stop() session deactivated")
```

- [ ] **Step 6: Instrument first WhisperKit transcription result**

In `scheduleLivePartialTranscription()` or the transcription callback, log when the first non-empty partial is produced:

```swift
// When the first meaningful partial text appears (not "Listening…"):
AppLogger.audio.warning("[PTT-TIMING] first transcription partial: '\(text)'")
```

- [ ] **Step 7: Build and verify instrumentation compiles**

Run:
```bash
cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,id=1156F3F5-3011-4987-A050-A0E4E988679E' build
```

- [ ] **Step 8: Commit instrumentation**

```bash
git add ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift ios/Abyss/Abyss/Services/WhisperKitSpeechTranscriber.swift ios/Abyss/Abyss/Services/ElevenLabsTTS.swift
git commit -m "Add PTT timing diagnostics to identify startup delay root cause"
```

---

## Task 2: Manual Testing — Collect Timing Data

Run the app on a device (or simulator) and perform these test scenarios, collecting the `[PTT-TIMING]` logs from Console.app for each.

- [ ] **Step 1: Test Scenario A — Cold start PTT**
1. Kill and relaunch the app
2. Switch to Push to Talk mode
3. Wait 5 seconds for preload to complete
4. Press mic and immediately say "one two three four five"
5. Copy all `[PTT-TIMING]` logs

**What to look for:** Time from `micPressed` to `tap installed`. If > 50ms, identify which sub-step is slow.

- [ ] **Step 2: Test Scenario B — PTT immediately after TTS finishes**
1. Ask the assistant something that produces a spoken response
2. Wait for TTS to finish naturally (don't interrupt)
3. Within 1-2 seconds of TTS finishing, press mic and say "one two three four five"
4. Copy all `[PTT-TIMING]` logs

**What to look for:** Whether `engine.isRunning` is false after TTS stopped, and the cost of reactivation.

- [ ] **Step 3: Test Scenario C — PTT barge-in (press while assistant speaks)**
1. Ask the assistant something that produces a long response
2. While TTS is playing, press mic and immediately say "one two three four five"
3. Copy all `[PTT-TIMING]` logs

**What to look for:** Total time from `micPressed` through `bargeIn complete` to `tap installed`. The barge-in path serializes TTS stop before mic start.

- [ ] **Step 4: Test Scenario D — Rapid successive PTT presses**
1. Press and release PTT, speak briefly
2. Wait for the response to start
3. Press PTT again immediately
4. Copy all `[PTT-TIMING]` logs

**What to look for:** Whether the engine stays warm between quick successive presses.

- [ ] **Step 5: Analyze results and identify the dominant bottleneck**

Compare timing data across scenarios. Determine:
- Which hypothesis (H1-H5) is confirmed?
- What is the measured latency at each stage?
- Is the problem consistent or variable?

Document findings in the commit message of the fix.

---

## Task 3: Fix Based on Findings

The specific fix depends on what the timing data reveals. Below are pre-written fixes for each hypothesis. **Implement only the fix(es) that the timing data confirms.**

### If H1 confirmed: TTS deactivates the audio session

**Files:**
- Modify: `ios/Abyss/Abyss/Services/ElevenLabsTTS.swift:78`

- [ ] **Step 1: Stop TTS from deactivating the shared audio session**

The `setActive(false)` call in `ElevenLabsTTS.stop()` kills the recording engine. Remove it or make it conditional on whether PTT mode is active. The simplest fix: remove `setActive(false)` entirely — iOS will manage the session lifecycle, and the recording session category set by `warmUp()` will persist.

```swift
// ElevenLabsTTS.swift:65-79
func stop() async {
    lock.withLock { _isSpeaking = false }
    speakingSubject.send(false)

    await MainActor.run {
        if StreamingPCMPlayer.shared.hasActivePlaybackSession {
            StreamingPCMPlayer.shared.stop()
        }
        if fallbackSynth.isSpeaking || fallbackSynth.isPaused {
            fallbackSynth.stopSpeaking(at: .immediate)
        }
    }
    // REMOVED: AVAudioSession.setActive(false) — this was killing the warm
    // recording engine, forcing a 100-400ms reactivation on next PTT press.
    // iOS manages session lifecycle; the session stays active until the app
    // backgrounds or another session takes priority.
}
```

- [ ] **Step 2: Build and test**

```bash
cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,id=1156F3F5-3011-4987-A050-A0E4E988679E' build
```

Repeat test scenarios B and C. Verify `engine.isRunning` stays true and the gap is eliminated.

- [ ] **Step 3: Commit**

```bash
git add ios/Abyss/Abyss/Services/ElevenLabsTTS.swift
git commit -m "Stop TTS from deactivating audio session — fixes PTT engine restart delay"
```

### If H2 confirmed: Barge-in serialization

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift`

- [ ] **Step 1: Overlap TTS stop with mic start during barge-in**

In `micPressed()`, instead of `await bargeIn()` then `await startListeningPTT()`, fire TTS stop and STT start concurrently. The mic doesn't need TTS to be fully stopped before it can open — AVAudioSession supports simultaneous playback and record categories.

```swift
// In micPressed() Task body, replace:
//   if appState == .speaking { await bargeIn(reason: "ptt_barge_in") }
//   await startListeningPTT()
// With:
if appState == .speaking {
    // Fire barge-in and mic start concurrently — mic opens without
    // waiting for TTS teardown to complete
    async let _ = bargeIn(reason: "ptt_barge_in")
    await startListeningPTT()
} else {
    await startListeningPTT()
}
```

Note: If `async let` causes `@MainActor` concurrency warnings, use a detached Task for barge-in instead:

```swift
if appState == .speaking {
    Task { await bargeIn(reason: "ptt_barge_in") }
    await startListeningPTT()
} else {
    await startListeningPTT()
}
```

**Important:** This only works if H1 is also fixed (TTS stop no longer deactivates the session). If TTS stop still calls `setActive(false)`, running it concurrently with mic start creates a race condition where the session could be deactivated mid-recording.

- [ ] **Step 2: Build and test**
- [ ] **Step 3: Commit**

### If H3 confirmed: Preload not complete

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift`

- [ ] **Step 1: Track preload completion and block PTT start until warm**

Store the preload Task and await it in `startListeningPTT()` if it hasn't completed:

```swift
// Add property:
private var preloadTask: Task<Void, Never>?

// In preloadTranscriber():
func preloadTranscriber() {
    guard recordingMode == .pushToTalk, isChatActive else { return }
    let transcriber = self.transcriber
    preloadTask = Task {
        await transcriber.preload()
        try? await transcriber.warmUp()
    }
}

// At the top of startListeningPTT(), after guards:
if let preloadTask {
    await preloadTask.value  // ensure warm before proceeding
}
```

This ensures the engine is warm before `start()` is called, avoiding the cold-start path.

- [ ] **Step 2: Build and test**
- [ ] **Step 3: Commit**

### If H4 confirmed: WhisperKit transcription delay (not mic delay)

**Files:**
- Modify: `ios/Abyss/Abyss/Services/WhisperKitSpeechTranscriber.swift`

- [ ] **Step 1: Investigate WhisperKit first-transcription latency**

If the timing data shows the mic opens quickly (tap installed < 50ms) but the first transcription partial takes > 500ms, the issue is WhisperKit startup, not mic capture. In this case the audio IS being captured but not transcribed fast enough.

Potential fixes:
- Reduce `minPartialBufferDuration` to trigger transcription sooner
- Pre-warm the CoreML model with a dummy transcription during `preload()`
- Consider buffering early audio and prepending it to the first transcription window

This hypothesis requires more investigation — document findings and iterate.

- [ ] **Step 2: Build and test**
- [ ] **Step 3: Commit**

### If H5 confirmed: Gap between engine.start() and installTap()

**Files:**
- Modify: `ios/Abyss/Abyss/Services/WhisperKitSpeechTranscriber.swift`

- [ ] **Step 1: Move tap installation before engine start**

If there's measurable latency between `engine.start()` returning and `installTap()` being called, install the tap before starting the engine so the tap is ready when the first buffer arrives:

```swift
// In start(), move installTap BEFORE engine.start():
inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { ... }
// Then if engine needs restart:
if !engine.isRunning {
    try session.setActive(true)
    try engine.start()
}
```

Note: `installTap` can be called on a stopped engine — it registers the callback, and buffers start flowing once the engine starts.

- [ ] **Step 2: Build and test**
- [ ] **Step 3: Commit**

---

## Task 4: Remove Diagnostic Instrumentation

- [ ] **Step 1: Remove all `[PTT-TIMING]` log lines and the `pttPressTimestamp` property**

Remove from:
- `ConversationAudioPipeline.swift` — `pttPressTimestamp` property and all timing logs
- `WhisperKitSpeechTranscriber.swift` — `firstBufferLogged` flag and timing logs
- `ElevenLabsTTS.swift` — timing logs

- [ ] **Step 2: Build**

```bash
cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,id=1156F3F5-3011-4987-A050-A0E4E988679E' build
```

- [ ] **Step 3: Commit**

```bash
git commit -m "Remove PTT timing diagnostics"
```

---

## Task 5: Final Verification

- [ ] **Step 1: Run all test scenarios from Task 2 again without diagnostics**
- [ ] **Step 2: Verify first words are captured in all scenarios**
- [ ] **Step 3: Verify barge-in still works (press while assistant speaks)**
- [ ] **Step 4: Verify mic release during startup (`pendingPTTRelease`) still works**
- [ ] **Step 5: Verify VAD auto mode is unaffected**
- [ ] **Step 6: Final commit with fix description**
