# Cloud Agent Prompt: Fix PTT Recording Startup Delay (BEE-60)

---

You are fixing a bug in the **Abyss** iOS app. Read `CLAUDE.md` at the repo root before starting.

## The Bug

In push-to-talk mode, the first 1–2 words spoken immediately after pressing the mic button are dropped. The microphone doesn't open until after some async bookkeeping completes, creating a gap between button press and actual audio capture.

## The File

All changes are in one file:

```
ios/Abyss/Abyss/ViewModels/ConversationAudioPipeline.swift
```

Do not touch any other file.

---

## Root Cause

Read `startListeningPTT()` carefully. The current sequence is:

1. `setState(.listening)` — UI update (immediate, correct)
2. **`await toolRouter.dispatch(convo.setState tool call)`** — waits for a UI bookkeeping call to complete
3. Only after step 2 completes: **`await toolRouter.dispatch(STTStartTool)`** — this is what actually opens the microphone

Step 2 is blocking the microphone from opening. The `convo.setState` dispatch is purely a UI/state sync call and does not need to complete before the microphone opens. The user presses the button, speaks immediately, but the mic isn't open until step 2 finishes.

There is a secondary issue: `preloadTranscriber()` guards on both `recordingMode == .pushToTalk` AND `isChatActive`. If `setChatActive(true)` is called after `updateRecordingMode(.pushToTalk)`, the pre-warm never runs. So the audio engine may not be warm on first button press.

---

## The Fix

### Fix 1 — Start the microphone before the bookkeeping await

In `startListeningPTT()`, reorder so `STTStartTool` is dispatched **before** awaiting `convo.setState`. The microphone should open as the very first async operation.

The new sequence should be:
1. `setState(.listening)` — UI update (keep as-is)
2. Emit `convo.setState` event on the event bus (keep emitting, just don't await the dispatch yet)
3. **Immediately dispatch `STTStartTool`** — opens the microphone with no prior awaits blocking it
4. After STT is started, dispatch `convo.setState` (or run it concurrently)

The simplest correct implementation is to use `async let` to run both dispatches concurrently, with `STTStartTool` having no dependency on `convo.setState`:

```swift
private func startListeningPTT() async {
    guard recordingMode == .pushToTalk else { return }
    guard !isStoppingRecording else { return }

    partialTranscript = ""
    setState(.listening)

    // Emit both events on the bus immediately
    let setStateEvent = Event.toolCall(
        name: ConvoSetStateTool.name,
        arguments: encode(ConvoSetStateTool.Arguments(state: AppState.listening.rawValue)),
        sessionId: sessionId
    )
    eventBus.emit(setStateEvent)

    guard !transcriber.isListening else { return }

    let sttEvent = Event.toolCall(
        name: STTStartTool.name,
        arguments: encode(STTStartTool.Arguments()),
        sessionId: sessionId
    )
    eventBus.emit(sttEvent)

    // Run both dispatches concurrently — STT opens the mic, setState is bookkeeping
    // The microphone no longer waits for convo.setState to complete first.
    async let sttDispatch: Event = {
        if case .toolCall(let toolCall) = sttEvent.kind {
            return await toolRouter.dispatch(toolCall)
        }
        return sttEvent
    }()
    async let setStateDispatch: Void = {
        if case .toolCall(let toolCall) = setStateEvent.kind {
            _ = await toolRouter.dispatch(toolCall)
        }
    }()

    let (sttResult, _) = await (sttDispatch, setStateDispatch)

    if case .toolResult(let toolResult) = sttResult.kind, toolResult.isError {
        AppLogger.audio.error("[PTT] startListeningPTT — STT start FAILED: \(toolResult.error ?? "unknown", privacy: .public)")
        await handleError(toolResult.error ?? "STT start failed")
    } else {
        AppLogger.audio.debug("[PTT] startListeningPTT — STT started OK, transcriber.isListening=\(self.transcriber.isListening)")
    }
}
```

**Important:** If `async let` with the closure pattern above causes Swift concurrency warnings in the existing `@MainActor` context, use a simpler approach: just swap the order so the `STTStartTool` dispatch happens before the `convo.setState` dispatch, both still awaited sequentially. This alone removes the blocking gap since the mic opens without waiting for anything first:

```swift
// Simple sequential fix — stt.start fires FIRST, convo.setState fires after
// ... (setState .listening, emit both events) ...

// 1. Open the microphone immediately
if case .toolCall(let toolCall) = sttEvent.kind {
    let result = await toolRouter.dispatch(toolCall)
    if case .toolResult(let toolResult) = result.kind, toolResult.isError {
        await handleError(toolResult.error ?? "STT start failed")
        return
    }
}

// 2. Then do the bookkeeping (no longer blocking the mic open)
if case .toolCall(let toolCall) = setStateEvent.kind {
    await toolRouter.dispatch(toolCall)
}
```

Choose whichever approach compiles cleanly without concurrency warnings. The critical invariant is: **no await completes before `STTStartTool` is dispatched**.

---

### Fix 2 — Pre-warm when chat becomes active in PTT mode

In `setChatActive(_:)`, after setting `isChatActive = true`, call `preloadTranscriber()` if the current mode is `.pushToTalk`. This ensures the audio engine is warm before the first button press:

```swift
func setChatActive(_ isActive: Bool) {
    guard isChatActive != isActive else { return }
    isChatActive = isActive
    if isActive && recordingMode == .pushToTalk {
        preloadTranscriber()   // ADD THIS LINE
    }
    Task { await refreshLiveConversationState() }
}
```

This handles the case where `updateRecordingMode(.pushToTalk)` was called before `setChatActive(true)`, which would have caused `preloadTranscriber()` to no-op due to the `isChatActive` guard.

---

## Preserve All Existing Behavior

- All debug log statements using `AppLogger.audio.debug` must be kept exactly as-is
- `pendingPTTRelease` logic in `micPressed()` must not change
- `micReleased()` must not change
- `bargeIn` before `startListeningPTT` when `appState == .speaking` must not change
- `isStartingRecording` / `isStoppingRecording` guards must not change
- The `guard !transcriber.isListening else { return }` check before dispatching `STTStartTool` must be kept — if the transcriber is already listening, skip the start dispatch

---

## Verification

Build and run on an iOS simulator or device:

```bash
cd ios/Abyss
xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build
```

The build must succeed with no new warnings or errors.

Manual test:
1. Switch to Push to Talk mode
2. Press the mic button and immediately say a full sentence starting with the first word
3. Verify all words appear in the transcript — no leading words dropped
4. Verify releasing the button still correctly stops recording and sends the transcript
5. Verify barge-in (pressing while assistant is speaking) still works correctly
