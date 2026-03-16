# Live Conversation Message Finalization Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make assistant messages in live conversation mode finalize from grey (`isPartial: true`) to white (`isPartial: false`) at the correct times.

**Architecture:** Server-only changes in `bedrockNovaSonicVoiceProvider.ts`. Three finalization triggers: (1) normal end of turn, (2) user interrupts, (3) user speaks next. The iOS side already handles `isPartial: false` correctly — messages turn white, `completeLiveResponse()` marks the liveResponseId as done. No iOS changes needed.

**Tech Stack:** Node.js/TypeScript server, Nova Sonic bidirectional streaming

**Key constraint:** Do NOT change the interrupt or live conversation flow. Same audio behavior, same state transitions, same VAD/echo detection. This is purely a visual change to finalize messages.

---

## Background: How Nova Sonic Text Events Work

Nova Sonic sends two parallel text streams per assistant response:

1. **SPECULATIVE** (`generationStage: "SPECULATIVE"`) — preview text, arrives BEFORE audio
2. **FINAL** (`generationStage: "FINAL"`) — confirmed text, arrives AFTER audio plays

Each has its own `contentStart → textOutput → contentEnd` lifecycle. The server tracks them in:
- `accumulatedSpeculativeText` — grows as SPECULATIVE contentEnds arrive
- `accumulatedAssistantText` — grows as FINAL contentEnds arrive

A response ends with either:
- `completionEnd(stopReason: "END_TURN")` — normal completion
- `completionEnd(stopReason: "INTERRUPTED" | "BARGE_IN")` — user interrupted
- Audio contentEnd + 500ms fallback timer (if completionEnd doesn't arrive promptly)

## Current State: Why Messages Stay Grey

### How finalization works today
`finalizeAccumulatedAssistantText()` (line ~462) emits `convo.appendMessage(isPartial: false)` with the `liveResponseId`. On iOS, this replaces the grey partial message with a white finalized one.

### Three bugs preventing finalization

**Bug 1: `hasOpenAssistantTurn()` doesn't check speculative text**
```typescript
// Current (line ~456):
return session.accumulatedAssistantText.trim().length > 0
    || session.sawAssistantAudio
    || session.liveResponseId !== null;
```
If only speculative text has arrived (FINAL hasn't caught up) and `liveResponseId` was somehow cleared, this returns `false` and `finalizeAccumulatedAssistantText` is never called.

**Bug 2: `scheduleAssistantTurnFinalize()` doesn't check speculative text**
```typescript
// Current (line ~528):
if (!session.accumulatedAssistantText.trim()) {
    return;  // ← never schedules timer if only speculative text exists
}
```
The audio-end fallback timer is never scheduled when only speculative text exists.

**Bug 3: `handleBargeIn()` clears text without finalizing**
```typescript
// Current behavior:
resetAssistantTurnState(session);  // ← clears ALL text, liveResponseId
session.bargedIn = true;
// Emits assistant.audio.interrupted → iOS DELETES the message
```
On interrupt, the grey message is deleted entirely rather than finalized.

### How iOS handles these events
- `convo.appendMessage(isPartial: false)` → `completeLiveResponse()` → message turns white, liveResponseId added to `invalidatedLiveResponseIds`
- `assistant.audio.interrupted` → `invalidateActiveLiveResponse()` → calls `removePartialMessage()` which only removes messages where `isPartial == true`

**Key insight for interrupts:** If we emit `isPartial: false` BEFORE the interrupted event, the message becomes finalized. When `removePartialMessage()` runs, it finds no partial message (it's already finalized) → no-op. The white message stays.

---

## File to Modify

- Modify: `server/src/voice/bedrockNovaSonicVoiceProvider.ts`
- Test: `server/tests/bedrockNovaSonicVoiceProvider.test.ts`

---

## Chunk 1: Fix Normal End-of-Turn Finalization

### Task 1: Fix `hasOpenAssistantTurn` to check speculative text

**Files:**
- Modify: `server/src/voice/bedrockNovaSonicVoiceProvider.ts:456-460`
- Test: `server/tests/bedrockNovaSonicVoiceProvider.test.ts`

- [ ] **Step 1: Write the failing test**

Test that an open turn is detected when only speculative text exists (no FINAL yet).

```typescript
test("completionEnd END_TURN finalizes speculative-only response", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Only SPECULATIVE text — no FINAL arrives before completionEnd
  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-only-1",
      completionId: "comp-spec-only",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-only-1", content: "Hello there." } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-only-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // completionEnd END_TURN arrives (FINAL never came)
  harness.client.emitEvent({
    completionEnd: {
      completionId: "comp-spec-only",
      stopReason: "END_TURN",
    },
  });

  await waitForTicks();

  // Should have finalized with speculative text
  const appends = findToolCalls(harness.emitted, "convo.appendMessage");
  const lastAppend = appends[appends.length - 1];
  assertAssistantAppend(lastAppend, { text: "Hello there.", isPartial: false });
  assert.ok(findStateTransitions(harness.emitted, "idle").length >= 1);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx tsx --test tests/bedrockNovaSonicVoiceProvider.test.ts`
Expected: FAIL — `hasOpenAssistantTurn` returns false when only speculative text exists and the completionEnd path doesn't finalize.

- [ ] **Step 3: Fix `hasOpenAssistantTurn`**

In `bedrockNovaSonicVoiceProvider.ts`, update `hasOpenAssistantTurn` (~line 456):

```typescript
private hasOpenAssistantTurn(session: SonicSession): boolean {
    return session.accumulatedAssistantText.trim().length > 0
      || session.accumulatedSpeculativeText.trim().length > 0
      || session.sawAssistantAudio
      || session.liveResponseId !== null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx tsx --test tests/bedrockNovaSonicVoiceProvider.test.ts`
Expected: ALL tests PASS

- [ ] **Step 5: Commit**

```bash
git add server/src/voice/bedrockNovaSonicVoiceProvider.ts server/tests/bedrockNovaSonicVoiceProvider.test.ts
git commit -m "Fix hasOpenAssistantTurn to check speculative text for finalization"
```

### Task 2: Fix `scheduleAssistantTurnFinalize` to check speculative text

**Files:**
- Modify: `server/src/voice/bedrockNovaSonicVoiceProvider.ts:~528`
- Test: `server/tests/bedrockNovaSonicVoiceProvider.test.ts`

- [ ] **Step 1: Write the failing test**

Test that the audio-end fallback timer fires when only speculative text exists.

```typescript
test("audio-end fallback finalizes when only speculative text exists", async (t) => {
  const harness = createHarness({ assistantTurnFinalizeDelayMs: 50 });
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // SPECULATIVE text only
  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-fallback-1",
      completionId: "comp-fallback",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-fallback-1", content: "Fallback test." } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-fallback-1", type: "TEXT", stopReason: "END_TURN" } });

  // Audio start + end (triggers fallback timer)
  harness.client.emitEvent({
    contentStart: {
      contentId: "audio-fallback-1",
      completionId: "comp-fallback",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({ audioOutput: { contentId: "audio-fallback-1", content: "AQID" } });
  harness.client.emitEvent({ contentEnd: { contentId: "audio-fallback-1", type: "AUDIO" } });

  // Wait for fallback timer (50ms + buffer)
  await waitFor(() => {
    const appends = findToolCalls(harness.emitted, "convo.appendMessage");
    return appends.some((e) => JSON.parse(String(e.payload.arguments)).isPartial === false);
  });

  const appends = findToolCalls(harness.emitted, "convo.appendMessage");
  const finalAppend = appends.filter((e) => JSON.parse(String(e.payload.arguments)).isPartial === false);
  assert.equal(finalAppend.length, 1);
  assertAssistantAppend(finalAppend[0], { text: "Fallback test.", isPartial: false });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx tsx --test tests/bedrockNovaSonicVoiceProvider.test.ts`
Expected: FAIL — fallback timer never fires because `scheduleAssistantTurnFinalize` bails on empty `accumulatedAssistantText`.

- [ ] **Step 3: Fix `scheduleAssistantTurnFinalize`**

In `bedrockNovaSonicVoiceProvider.ts`, update the text check (~line 528):

```typescript
// Before:
if (!session.accumulatedAssistantText.trim()) {
    return;
}

// After:
if (!session.accumulatedAssistantText.trim() && !session.accumulatedSpeculativeText.trim()) {
    return;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx tsx --test tests/bedrockNovaSonicVoiceProvider.test.ts`
Expected: ALL tests PASS

- [ ] **Step 5: Commit**

```bash
git add server/src/voice/bedrockNovaSonicVoiceProvider.ts server/tests/bedrockNovaSonicVoiceProvider.test.ts
git commit -m "Fix audio-end fallback timer to check speculative text"
```

---

## Chunk 2: Finalize on User Interrupt (Barge-In)

### Task 3: Finalize text before clearing state on barge-in

**Files:**
- Modify: `server/src/voice/bedrockNovaSonicVoiceProvider.ts:~910` (`handleBargeIn`)
- Test: `server/tests/bedrockNovaSonicVoiceProvider.test.ts`

**How this works with iOS (no iOS changes needed):**
1. Server emits `convo.appendMessage(isPartial: false, liveResponseId: X)` — message turns white
2. iOS calls `completeLiveResponse(X)` — adds X to `invalidatedLiveResponseIds`
3. Server emits `assistant.audio.interrupted(liveResponseId: X)`
4. iOS checks `shouldIgnoreLiveResponse(X)` → true → event skipped
5. Server emits `convo.setState("listening")` — still works, unrelated to liveResponseId
6. Audio stops naturally: server sets `bargedIn = true` → no more audio chunks sent → iOS player drains

**Note on audio drain:** Without `handleAssistantAudioInterrupted()` being called on iOS, any already-buffered audio chunks will play out (typically < 200ms). This is acceptable — the server stops sending new chunks immediately. If testing reveals this is noticeable, a follow-up could emit the interrupted event without a liveResponseId so iOS doesn't skip it, but that's a separate concern.

- [ ] **Step 1: Write the failing test**

```typescript
test("barge-in finalizes assistant text before clearing state", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Assistant speaks
  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-bargein-1",
      completionId: "comp-bargein",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-bargein-1", content: "I was saying something." } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-bargein-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // Capture the liveResponseId from the speculative append
  const specAppends = findToolCalls(harness.emitted, "convo.appendMessage");
  const specLiveId = JSON.parse(String(specAppends[specAppends.length - 1].payload.arguments)).liveResponseId;

  // User barges in
  harness.client.emitEvent({
    completionEnd: {
      completionId: "comp-bargein",
      stopReason: "BARGE_IN",
    },
  });

  await waitForTicks();

  // Should have finalized the text BEFORE the interrupted event
  const allAppends = findToolCalls(harness.emitted, "convo.appendMessage");
  const finalizedAppends = allAppends.filter((e) => {
    const args = JSON.parse(String(e.payload.arguments));
    return args.isPartial === false && args.role === "assistant";
  });
  assert.equal(finalizedAppends.length, 1, "should have exactly one finalized assistant message");
  assertAssistantAppend(finalizedAppends[0], { text: "I was saying something.", isPartial: false });

  // Interrupted event should still be emitted (with same liveResponseId)
  const interrupted = harness.emitted.filter((e) => e.type === "assistant.audio.interrupted");
  assert.equal(interrupted.length, 1);
  assert.equal(interrupted[0].payload.liveResponseId, specLiveId);

  // Finalization should come BEFORE the interrupted event
  const finalizeIdx = harness.emitted.indexOf(finalizedAppends[0]);
  const interruptIdx = harness.emitted.indexOf(interrupted[0]);
  assert.ok(finalizeIdx < interruptIdx, "finalization must precede interrupted event");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx tsx --test tests/bedrockNovaSonicVoiceProvider.test.ts`
Expected: FAIL — currently `handleBargeIn` clears state without finalizing.

- [ ] **Step 3: Implement finalization in `handleBargeIn`**

In `bedrockNovaSonicVoiceProvider.ts`, modify `handleBargeIn` (~line 910):

```typescript
private handleBargeIn(session: SonicSession, reason: string): void {
    if (session.closed || session.bargedIn) return;

    // Finalize any accumulated text as a completed message BEFORE clearing state.
    // This turns the grey bubble white on iOS. The subsequent interrupted event
    // will be ignored by iOS (liveResponseId already completed via completeLiveResponse),
    // but removePartialMessage() is a no-op on finalized messages, so the white
    // message persists.
    this.finalizeAccumulatedAssistantText(session);

    const liveResponseId = this.resetAssistantTurnState(session);
    session.bargedIn = true;

    if (liveResponseId) {
      session.context.emit(makeEvent("assistant.audio.interrupted", session.sessionId, {
        reason,
        liveResponseId,
      }));
    }
    this.emitListeningState(session);
}
```

**Important detail:** `finalizeAccumulatedAssistantText()` sets `session.liveResponseId = null` after emitting. But `resetAssistantTurnState()` reads `session.liveResponseId` to return it. So we need to capture the liveResponseId BEFORE calling finalize.

Revised implementation:

```typescript
private handleBargeIn(session: SonicSession, reason: string): void {
    if (session.closed || session.bargedIn) return;

    // Capture liveResponseId before finalization clears it
    const liveResponseId = session.liveResponseId;

    // Finalize text as white message before clearing state
    this.finalizeAccumulatedAssistantText(session);

    this.resetAssistantTurnState(session);
    session.bargedIn = true;

    if (liveResponseId) {
      session.context.emit(makeEvent("assistant.audio.interrupted", session.sessionId, {
        reason,
        liveResponseId,
      }));
    }
    this.emitListeningState(session);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx tsx --test tests/bedrockNovaSonicVoiceProvider.test.ts`
Expected: ALL tests PASS (including existing barge-in tests — verify they still emit interrupted + listening)

- [ ] **Step 5: Commit**

```bash
git add server/src/voice/bedrockNovaSonicVoiceProvider.ts server/tests/bedrockNovaSonicVoiceProvider.test.ts
git commit -m "Finalize assistant text on barge-in instead of discarding"
```

---

## Chunk 3: Verify User-Speaks Safety Net

### Task 4: Verify user speech finalizes prior assistant message

**Files:**
- Test: `server/tests/bedrockNovaSonicVoiceProvider.test.ts`

The user-speaks path already calls `finishAssistantTurn` at USER text contentEnd (line ~730). With the `hasOpenAssistantTurn` fix from Task 1, this should now work correctly for speculative-only responses too. This task adds a test to verify.

- [ ] **Step 1: Write the test**

```typescript
test("user speech finalizes prior speculative-only assistant message", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Assistant responds (speculative only, no FINAL or completionEnd)
  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-user-flush-1",
      completionId: "comp-user-flush",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-user-flush-1", content: "Assistant reply." } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-user-flush-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // User speaks — should finalize the assistant message
  harness.client.emitEvent({
    contentStart: {
      contentId: "user-flush-1",
      completionId: "comp-user-flush-2",
      role: "USER",
      type: "TEXT",
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "user-flush-1", content: "User says something." } });
  harness.client.emitEvent({ contentEnd: { contentId: "user-flush-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // Assistant message should have been finalized before user message
  const appends = findToolCalls(harness.emitted, "convo.appendMessage");
  const assistantFinals = appends.filter((e) => {
    const args = JSON.parse(String(e.payload.arguments));
    return args.role === "assistant" && args.isPartial === false;
  });
  assert.equal(assistantFinals.length, 1, "assistant message should be finalized");
  assertAssistantAppend(assistantFinals[0], { text: "Assistant reply.", isPartial: false });

  // User message should appear after the finalized assistant message
  const userAppends = appends.filter((e) => {
    const args = JSON.parse(String(e.payload.arguments));
    return args.role === "user";
  });
  assert.equal(userAppends.length, 1);
  const finalizeIdx = appends.indexOf(assistantFinals[0]);
  const userIdx = appends.indexOf(userAppends[0]);
  assert.ok(finalizeIdx < userIdx, "assistant finalization must precede user message");
});
```

- [ ] **Step 2: Run test to verify it passes (already fixed by Task 1)**

Run: `cd server && npx tsx --test tests/bedrockNovaSonicVoiceProvider.test.ts`
Expected: ALL tests PASS

- [ ] **Step 3: Commit**

```bash
git add server/tests/bedrockNovaSonicVoiceProvider.test.ts
git commit -m "Add test: user speech finalizes prior speculative-only assistant message"
```

---

## Chunk 4: Run Full Test Suite and Verify

### Task 5: Verify all existing tests still pass

- [ ] **Step 1: Run full voice provider tests**

Run: `cd server && npx tsx --test tests/bedrockNovaSonicVoiceProvider.test.ts`
Expected: ALL tests PASS

- [ ] **Step 2: Run full server test suite**

Run: `cd server && npm test`
Expected: All tests pass (the pre-existing `conductorService.test.ts` failure about `bridge.claude.run` is unrelated — ignore it)

- [ ] **Step 3: Verify no behavioral changes to existing barge-in tests**

Check that these existing tests still pass and emit the same events:
- "nova-sonic emits interruption and returns to listening on interrupted completions"
- "nova-sonic interrupt drops stale events on same stream and accepts fresh response"
- "nova-sonic native barge-in drops audio without restarting stream"
- "nova-sonic iOS-only barge-in gates stale audio via bargedIn flag"
- "nova-sonic iOS interrupt + Nova Sonic INTERRUPTED are idempotent"

They should still emit `assistant.audio.interrupted` and `convo.setState("listening")` — just now preceded by a `convo.appendMessage(isPartial: false)`.

- [ ] **Step 4: Final commit if any cleanup needed**

---

## Summary of Changes

| Trigger | Current Behavior | After Fix |
|---------|-----------------|-----------|
| `completionEnd(END_TURN)` | May skip finalization if only speculative text | Correctly finalizes using speculative text |
| Audio-end fallback timer | Never schedules if only speculative text | Schedules and finalizes using speculative text |
| User barge-in | Deletes grey message | Finalizes to white, then emits interrupted (iOS ignores the delete since message is already finalized) |
| User speaks next | May skip finalization if only speculative text | Correctly finalizes before emitting user message |

**Total lines changed:** ~10 lines in provider, ~100 lines of new tests. Zero iOS changes.
