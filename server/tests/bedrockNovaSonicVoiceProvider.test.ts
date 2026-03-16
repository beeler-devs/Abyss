import assert from "node:assert/strict";
import test from "node:test";

import { BedrockNovaSonicVoiceProvider } from "../src/voice/bedrockNovaSonicVoiceProvider.js";
import { EventEnvelope, ToolCallRequest, ToolDefinition } from "../src/core/types.js";
import { VoiceProviderContext } from "../src/voice/types.js";

const TOOLS: ToolDefinition[] = [
  {
    name: "bridge.exec.run",
    description: "Run a shell command.",
    input_schema: {
      type: "object",
      properties: {
        command: { type: "string" },
      },
      required: ["command"],
    },
  },
  {
    name: "bridge.fs.read",
    description: "Read a file.",
    input_schema: {
      type: "object",
      properties: {
        path: { type: "string" },
      },
      required: ["path"],
    },
  },
];

test("nova-sonic reuses the current session on repeated startStream calls", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => harness.client.outboundEvents.some((event) => "sessionStart" in event));

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => findStateTransitions(harness.emitted, "listening").length === 2);

  const sessionStarts = harness.client.outboundEvents.filter((event) => "sessionStart" in event);
  assert.equal(sessionStarts.length, 1);
});

test("nova-sonic endStream does not close the active session", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => harness.client.outboundEvents.some((event) => "sessionStart" in event));
  await harness.provider.endStream("session-1");
  await waitForTicks();

  assert.equal(harness.client.outboundEvents.some((event) => "promptEnd" in event), false);
  assert.equal(harness.client.outboundEvents.some((event) => "sessionEnd" in event), false);
});

test("nova-sonic does not finalize partial user turns", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "user-1",
      completionId: "completion-user-1",
      role: "USER",
      type: "TEXT",
    },
  });
  harness.client.emitEvent({
    textOutput: {
      contentId: "user-1",
      content: "hello there",
    },
  });
  harness.client.emitEvent({
    completionEnd: {
      completionId: "completion-user-1",
      stopReason: "PARTIAL_TURN",
    },
  });

  await waitForTicks();

  assert.equal(eventsOfType(harness.emitted, "user.audio.transcript.final").length, 0);
  assert.equal(findToolCalls(harness.emitted, "convo.appendMessage").length, 0);
  assert.equal(findStateTransitions(harness.emitted, "thinking").length, 0);
});

test("nova-sonic finalizes complete user turns once", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "user-1",
      completionId: "completion-user-1",
      role: "USER",
      type: "TEXT",
    },
  });
  harness.client.emitEvent({
    textOutput: {
      contentId: "user-1",
      content: "build the project",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "user-1",
      type: "TEXT",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "user.audio.transcript.final").length === 1);

  const transcript = eventsOfType(harness.emitted, "user.audio.transcript.final")[0];
  assert.equal(transcript?.payload.text, "build the project");

  const appendCalls = findToolCalls(harness.emitted, "convo.appendMessage");
  assert.equal(appendCalls.length, 1);
  assert.deepEqual(parseToolArguments(appendCalls[0]), {
    role: "user",
    text: "build the project",
    isPartial: false,
  });
  assert.equal(findStateTransitions(harness.emitted, "thinking").length, 1);
});

test("nova-sonic finalizes user speech on user text contentEnd without waiting for completionEnd", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "user-early-1",
      completionId: "completion-user-early-1",
      role: "USER",
      type: "TEXT",
    },
  });
  harness.client.emitEvent({
    textOutput: {
      contentId: "user-early-1",
      content: "show this immediately",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "user-early-1",
      type: "TEXT",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "user.audio.transcript.final").length === 1);

  assert.equal(eventsOfType(harness.emitted, "user.audio.transcript.final")[0]?.payload.text, "show this immediately");
  assert.equal(findStateTransitions(harness.emitted, "thinking").length, 1);
});

test("nova-sonic aggregates assistant text chunks into one partial message, finalized on completionEnd", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-final-1",
      completionId: "completion-assistant-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-final-1", content: "Hello " } });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-final-1", content: "world" } });
  harness.client.emitEvent({ contentEnd: { contentId: "assistant-final-1", type: "TEXT", stopReason: "END_TURN" } });

  // Text contentEnd emits a partial appendMessage, not speech.final yet
  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 1);
  assertAssistantAppend(findToolCalls(harness.emitted, "convo.appendMessage")[0], {
    text: "Hello world",
    isPartial: true,
  });
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 0);

  // Audio contentEnd does NOT finalize — only emits assistant.audio.end
  harness.client.emitEvent({ contentStart: { contentId: "audio-1", role: "ASSISTANT", type: "AUDIO" } });
  harness.client.emitEvent({ audioOutput: { contentId: "audio-1", content: "AAA=" } });
  harness.client.emitEvent({ contentEnd: { contentId: "audio-1", type: "AUDIO", stopReason: "END_TURN" } });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.end").length === 1);
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 0);
  assert.equal(findToolCalls(harness.emitted, "convo.appendMessage").length, 1); // still just the partial

  // completionEnd END_TURN finalizes the message
  harness.client.emitEvent({ completionEnd: { completionId: "completion-assistant-1", stopReason: "END_TURN" } });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 1);
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final")[0]?.payload.text, "Hello world");

  const appendCalls = findToolCalls(harness.emitted, "convo.appendMessage");
  assert.equal(appendCalls.length, 2); // 1 partial + 1 final
  assertAssistantAppend(appendCalls.at(-1), {
    text: "Hello world",
    isPartial: false,
  });
});

test("nova-sonic emits partial convo.appendMessage per sentence, finalizes on completionEnd", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Sentence 1
  harness.client.emitEvent({
    contentStart: {
      contentId: "text-1",
      completionId: "completion-sentences-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "text-1", content: "First sentence." } });
  harness.client.emitEvent({ contentEnd: { contentId: "text-1", type: "TEXT", stopReason: "END_TURN" } });

  // Sentence 2
  harness.client.emitEvent({
    contentStart: {
      contentId: "text-2",
      completionId: "completion-sentences-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "text-2", content: "Second sentence." } });
  harness.client.emitEvent({ contentEnd: { contentId: "text-2", type: "TEXT", stopReason: "END_TURN" } });

  // Partial messages should accumulate (no final yet)
  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 2);
  const partials = findToolCalls(harness.emitted, "convo.appendMessage");
  assert.equal(JSON.parse(partials[0]!.payload.arguments as string).isPartial, true);
  assert.equal(JSON.parse(partials[0]!.payload.arguments as string).text, "First sentence.");
  assert.equal(JSON.parse(partials[1]!.payload.arguments as string).isPartial, true);
  assert.equal(JSON.parse(partials[1]!.payload.arguments as string).text, "First sentence. Second sentence.");
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 0);

  // Audio content ends — does NOT finalize
  harness.client.emitEvent({
    contentStart: { contentId: "audio-1", role: "ASSISTANT", type: "AUDIO" },
  });
  harness.client.emitEvent({ audioOutput: { contentId: "audio-1", content: "AAA=" } });
  harness.client.emitEvent({ contentEnd: { contentId: "audio-1", type: "AUDIO", stopReason: "END_TURN" } });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.end").length === 1);
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 0);

  // completionEnd triggers final message and speech.final
  harness.client.emitEvent({ completionEnd: { completionId: "completion-sentences-1", stopReason: "END_TURN" } });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 1);
  const finalAppend = findToolCalls(harness.emitted, "convo.appendMessage").at(-1)!;
  assert.equal(JSON.parse(finalAppend.payload.arguments as string).isPartial, false);
  assert.equal(JSON.parse(finalAppend.payload.arguments as string).text, "First sentence. Second sentence.");
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final")[0]?.payload.text, "First sentence. Second sentence.");
});

test("nova-sonic accumulates sentences across interleaved audio blocks", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Sentence 1 text
  harness.client.emitEvent({
    contentStart: {
      contentId: "text-interleave-1",
      completionId: "comp-interleave-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "text-interleave-1", content: "First." } });
  harness.client.emitEvent({ contentEnd: { contentId: "text-interleave-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 1);
  assert.equal(JSON.parse(findToolCalls(harness.emitted, "convo.appendMessage")[0]!.payload.arguments as string).text, "First.");

  // Audio for sentence 1 ends — should NOT reset accumulated text
  harness.client.emitEvent({ contentStart: { contentId: "audio-interleave-1", role: "ASSISTANT", type: "AUDIO" } });
  harness.client.emitEvent({ audioOutput: { contentId: "audio-interleave-1", content: "AAA=" } });
  harness.client.emitEvent({ contentEnd: { contentId: "audio-interleave-1", type: "AUDIO", stopReason: "END_TURN" } });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.end").length === 1);

  // Sentence 2 text — should accumulate onto sentence 1
  harness.client.emitEvent({
    contentStart: {
      contentId: "text-interleave-2",
      completionId: "comp-interleave-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "text-interleave-2", content: "Second." } });
  harness.client.emitEvent({ contentEnd: { contentId: "text-interleave-2", type: "TEXT", stopReason: "END_TURN" } });

  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 2);
  const partial2 = JSON.parse(findToolCalls(harness.emitted, "convo.appendMessage")[1]!.payload.arguments as string);
  assert.equal(partial2.text, "First. Second.");
  assert.equal(partial2.isPartial, true);

  // completionEnd finalizes with the full accumulated text
  harness.client.emitEvent({ completionEnd: { completionId: "comp-interleave-1", stopReason: "END_TURN" } });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 1);
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final")[0]?.payload.text, "First. Second.");

  const finalAppend = findToolCalls(harness.emitted, "convo.appendMessage").at(-1)!;
  assert.equal(JSON.parse(finalAppend.payload.arguments as string).isPartial, false);
  assert.equal(JSON.parse(finalAppend.payload.arguments as string).text, "First. Second.");
});

test("nova-sonic finalizes accumulated assistant text on completionEnd even before audio contentEnd", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "text-finalize-1",
      completionId: "completion-finalize-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "text-finalize-1", content: "Sentence one." } });
  harness.client.emitEvent({ contentEnd: { contentId: "text-finalize-1", type: "TEXT", stopReason: "END_TURN" } });
  harness.client.emitEvent({
    completionEnd: {
      completionId: "completion-finalize-1",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 1);

  const appendCalls = findToolCalls(harness.emitted, "convo.appendMessage");
  assert.equal(appendCalls.length, 2);
  assertAssistantAppend(appendCalls[0], {
    text: "Sentence one.",
    isPartial: true,
  });
  assertAssistantAppend(appendCalls[1], {
    text: "Sentence one.",
    isPartial: false,
  });

  harness.client.emitEvent({
    contentStart: { contentId: "audio-finalize-1", completionId: "completion-finalize-1", role: "ASSISTANT", type: "AUDIO" },
  });
  harness.client.emitEvent({ contentEnd: { contentId: "audio-finalize-1", type: "AUDIO", stopReason: "END_TURN" } });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.end").length === 1);
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 1);
  assert.equal(findToolCalls(harness.emitted, "convo.appendMessage").length, 2);
});

test("nova-sonic finalizes assistant text after audio end when completionEnd is missing", async (t) => {
  const harness = createHarness({ assistantTurnFinalizeDelayMs: 20 });
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-fallback-1",
      completionId: "completion-fallback-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-fallback-1", content: "Fallback reply." } });
  harness.client.emitEvent({ contentEnd: { contentId: "assistant-fallback-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 1);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-fallback-audio-1",
      completionId: "completion-fallback-1",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      contentId: "assistant-fallback-audio-1",
      completionId: "completion-fallback-1",
      content: "AAA=",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-fallback-audio-1",
      type: "AUDIO",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 1);
  await waitFor(() => findStateTransitions(harness.emitted, "idle").length === 1);

  const appendCalls = findToolCalls(harness.emitted, "convo.appendMessage");
  assert.equal(appendCalls.length, 2);
  assertAssistantAppend(appendCalls[0], {
    text: "Fallback reply.",
    isPartial: true,
  });
  assertAssistantAppend(appendCalls[1], {
    text: "Fallback reply.",
    isPartial: false,
  });
  assert.equal(eventsOfType(harness.emitted, "assistant.audio.end").length, 1);
  assert.equal(findStateTransitions(harness.emitted, "idle").length, 1);
});

test("nova-sonic ignores late completionEnd after audio-end fallback finalization", async (t) => {
  const harness = createHarness({ assistantTurnFinalizeDelayMs: 20 });
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-fallback-late-1",
      completionId: "completion-fallback-late-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-fallback-late-1", content: "Late completion reply." } });
  harness.client.emitEvent({ contentEnd: { contentId: "assistant-fallback-late-1", type: "TEXT", stopReason: "END_TURN" } });
  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-fallback-late-audio-1",
      completionId: "completion-fallback-late-1",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      contentId: "assistant-fallback-late-audio-1",
      completionId: "completion-fallback-late-1",
      content: "AAA=",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-fallback-late-audio-1",
      type: "AUDIO",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 1);
  await waitFor(() => findStateTransitions(harness.emitted, "idle").length === 1);

  harness.client.emitEvent({
    completionEnd: {
      completionId: "completion-fallback-late-1",
      stopReason: "END_TURN",
    },
  });

  await waitForTicks();
  await waitForTicks();

  const assistantFinals = findToolCalls(harness.emitted, "convo.appendMessage").filter((event) => {
    const args = parseToolArguments(event);
    return args.role === "assistant" && args.isPartial === false;
  });
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 1);
  assert.equal(assistantFinals.length, 1);
  assert.equal(findStateTransitions(harness.emitted, "idle").length, 1);
});

test("nova-sonic emits assistant audio end on audio contentEnd and idle on completionEnd", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-audio-1",
      completionId: "completion-audio-1",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      completionId: "completion-audio-1",
      contentId: "assistant-audio-1",
      content: "AAA=",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      completionId: "completion-audio-1",
      contentId: "assistant-audio-1",
      content: "BBB=",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-audio-1",
      type: "AUDIO",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.end").length === 1);

  assert.equal(eventsOfType(harness.emitted, "assistant.audio.end").length, 1);
  // Idle is NOT emitted on audio contentEnd — only on completionEnd
  assert.equal(findStateTransitions(harness.emitted, "idle").length, 0);

  harness.client.emitEvent({ completionEnd: { completionId: "completion-audio-1", stopReason: "END_TURN" } });
  await waitFor(() => findStateTransitions(harness.emitted, "idle").length === 1);
  assert.equal(findStateTransitions(harness.emitted, "idle").length, 1);
});

test("nova-sonic emits assistant audio end on audio contentEnd without idle", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-audio-early-1",
      completionId: "completion-audio-early-1",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      contentId: "assistant-audio-early-1",
      completionId: "completion-audio-early-1",
      content: "AAA=",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-audio-early-1",
      type: "AUDIO",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.end").length === 1);
  // Idle is not emitted until completionEnd
  assert.equal(findStateTransitions(harness.emitted, "idle").length, 0);
});

test("nova-sonic cancels audio-end fallback when more assistant text arrives for the same turn", async (t) => {
  const harness = createHarness({ assistantTurnFinalizeDelayMs: 20 });
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-cancel-text-1",
      completionId: "completion-cancel-text-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-cancel-text-1", content: "First sentence." } });
  harness.client.emitEvent({ contentEnd: { contentId: "assistant-cancel-text-1", type: "TEXT", stopReason: "END_TURN" } });
  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-cancel-audio-1",
      completionId: "completion-cancel-text-1",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      contentId: "assistant-cancel-audio-1",
      completionId: "completion-cancel-text-1",
      content: "AAA=",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-cancel-audio-1",
      type: "AUDIO",
      stopReason: "END_TURN",
    },
  });

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-cancel-text-2",
      completionId: "completion-cancel-text-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-cancel-text-2", content: "Second sentence." } });
  harness.client.emitEvent({ contentEnd: { contentId: "assistant-cancel-text-2", type: "TEXT", stopReason: "END_TURN" } });

  await new Promise((resolve) => setTimeout(resolve, 35));
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 0);

  harness.client.emitEvent({
    completionEnd: {
      completionId: "completion-cancel-text-1",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 1);
  const assistantFinal = findToolCalls(harness.emitted, "convo.appendMessage").filter((event) => {
    const args = parseToolArguments(event);
    return args.role === "assistant" && args.isPartial === false;
  });
  assert.equal(assistantFinal.length, 1);
  assert.equal(parseToolArguments(assistantFinal[0]).text, "First sentence. Second sentence.");
});

test("nova-sonic cancels audio-end fallback when tool use continues the same reply", async (t) => {
  const harness = createHarness({ tools: TOOLS, assistantTurnFinalizeDelayMs: 20 });
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-tool-preamble",
      completionId: "completion-tool-preamble",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-tool-preamble", content: "Before tool." } });
  harness.client.emitEvent({ contentEnd: { contentId: "assistant-tool-preamble", type: "TEXT", stopReason: "END_TURN" } });
  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-tool-audio",
      completionId: "completion-tool-preamble",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      contentId: "assistant-tool-audio",
      completionId: "completion-tool-preamble",
      content: "AAA=",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-tool-audio",
      type: "AUDIO",
      stopReason: "END_TURN",
    },
  });
  harness.client.emitEvent({
    toolUse: {
      contentId: "assistant-tool-use",
      completionId: "completion-tool-preamble",
      toolName: "bridge_exec_run",
      toolUseId: "tool-use-cancel-fallback",
      content: JSON.stringify({ command: "npm test" }),
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-tool-use",
      completionId: "completion-tool-preamble",
      type: "TOOL",
      stopReason: "TOOL_USE",
      toolUseId: "tool-use-cancel-fallback",
    },
  });

  await waitFor(() => harness.executedToolCalls.length === 1);
  await new Promise((resolve) => setTimeout(resolve, 35));
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 0);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-tool-resume",
      completionId: "completion-tool-preamble",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-tool-resume", content: "After tool." } });
  harness.client.emitEvent({ contentEnd: { contentId: "assistant-tool-resume", type: "TEXT", stopReason: "END_TURN" } });
  harness.client.emitEvent({
    completionEnd: {
      completionId: "completion-tool-preamble",
      stopReason: "END_TURN",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 1);

  const assistantFinals = findToolCalls(harness.emitted, "convo.appendMessage").filter((event) => {
    const args = parseToolArguments(event);
    return args.role === "assistant" && args.isPartial === false;
  });
  assert.equal(assistantFinals.length, 1);
  assert.equal(parseToolArguments(assistantFinals[0]).text, "Before tool. After tool.");
});

test("nova-sonic drops the audio-end fallback when the stream fails before the timer fires", async (t) => {
  const harness = createHarness({ assistantTurnFinalizeDelayMs: 20 });
  t.after(async () => {
    harness.client.closeAllResponses();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-failure-before-fallback",
      completionId: "completion-failure-before-fallback",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "assistant-failure-before-fallback", content: "Should be dropped." } });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-failure-before-fallback",
      type: "TEXT",
      stopReason: "END_TURN",
    },
  });
  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-failure-audio",
      completionId: "completion-failure-before-fallback",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      contentId: "assistant-failure-audio",
      completionId: "completion-failure-before-fallback",
      content: "AAA=",
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-failure-audio",
      type: "AUDIO",
      stopReason: "END_TURN",
    },
  });
  harness.client.emitFailure("Timed out waiting for audio bytes (59 seconds).", "modelTimeoutException");

  await waitFor(() => eventsOfType(harness.emitted, "error").length === 1);
  await new Promise((resolve) => setTimeout(resolve, 35));

  const assistantFinals = findToolCalls(harness.emitted, "convo.appendMessage").filter((event) => {
    const args = parseToolArguments(event);
    return args.role === "assistant" && args.isPartial === false;
  });
  assert.equal(assistantFinals.length, 0);
});

test("nova-sonic emits interruption and returns to listening on interrupted completions", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeAllResponses();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-1",
      completionId: "completion-interrupted-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({
    textOutput: {
      contentId: "assistant-1",
      content: "This should be dropped",
    },
  });
  harness.client.emitEvent({
    completionEnd: {
      completionId: "completion-interrupted-1",
      stopReason: "INTERRUPTED",
    },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.interrupted").length === 1);
  assert.equal(findStateTransitions(harness.emitted, "listening").length, 2);
  // Native barge-in: no stream restart — still only one send() call
  assert.equal(harness.client.sendCallCount, 1);
  assert.equal(
    harness.client.outboundEvents.filter((event) => "sessionStart" in event).length,
    1,
  );
});

test("nova-sonic interrupt drops stale events on same stream and accepts fresh response", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeAllResponses();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => harness.client.outboundEvents.some((event) => "sessionStart" in event));

  // Emit first assistant text on stream 0
  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-live-1",
      completionId: "completion-live-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  }, 0);
  harness.client.emitEvent({
    textOutput: {
      contentId: "assistant-live-1",
      content: "First live reply.",
    },
  }, 0);
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-live-1",
      type: "TEXT",
      stopReason: "END_TURN",
    },
  }, 0);

  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 1);
  const firstPartial = parseToolArguments(findToolCalls(harness.emitted, "convo.appendMessage")[0]);
  assert.equal(firstPartial.isPartial, true);
  assert.equal(typeof firstPartial.liveResponseId, "string");

  // Interrupt — native barge-in, no stream restart
  await harness.provider.interrupt("session-1");
  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.interrupted").length === 1);
  assert.equal(harness.client.sendCallCount, 1); // Same stream, no restart

  const interruptedEvent = eventsOfType(harness.emitted, "assistant.audio.interrupted")[0];
  // liveResponseId is omitted when text was finalized during barge-in
  assert.equal(interruptedEvent?.payload.liveResponseId, undefined);

  // Barge-in finalizes the interrupted text (1 assistant.speech.final from the barge-in)
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 1);

  // Stale completionEnd from old response — should NOT produce another finalization
  harness.client.emitEvent({
    completionEnd: {
      completionId: "completion-live-1",
      stopReason: "END_TURN",
    },
  }, 0);

  await waitForTicks();
  assert.equal(eventsOfType(harness.emitted, "assistant.speech.final").length, 1);

  // New response on SAME stream (stream 0) after barge-in cleared
  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-live-2",
      completionId: "completion-live-2",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  }, 0);
  harness.client.emitEvent({
    textOutput: {
      contentId: "assistant-live-2",
      content: "Fresh reply.",
    },
  }, 0);
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-live-2",
      type: "TEXT",
      stopReason: "END_TURN",
    },
  }, 0);
  harness.client.emitEvent({
    completionEnd: {
      completionId: "completion-live-2",
      stopReason: "END_TURN",
    },
  }, 0);

  await waitFor(() => eventsOfType(harness.emitted, "assistant.speech.final").length === 2);
  const finalAppend = findToolCalls(harness.emitted, "convo.appendMessage").at(-1);
  assertAssistantAppend(finalAppend, {
    text: "Fresh reply.",
    isPartial: false,
  });
  assert.notEqual(parseToolArguments(finalAppend).liveResponseId, firstPartial.liveResponseId);
});

test("nova-sonic native barge-in drops audio without restarting stream", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeAllResponses();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => harness.client.outboundEvents.some((event) => "sessionStart" in event));

  // Start assistant audio response
  harness.client.emitEvent({
    contentStart: {
      contentId: "audio-1",
      completionId: "completion-1",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: { contentId: "audio-1", content: "AAAA" },
  });
  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.chunk").length === 1);

  // Nova Sonic sends INTERRUPTED
  harness.client.emitEvent({
    completionEnd: { completionId: "completion-1", stopReason: "INTERRUPTED" },
  });

  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.interrupted").length === 1);
  // No stream restart
  assert.equal(harness.client.sendCallCount, 1);
  assert.equal(
    harness.client.outboundEvents.filter((event) => "sessionStart" in event).length,
    1,
  );

  // Subsequent audio chunks on same stream are dropped (bargedIn was set then cleared)
  // Simulate Nova Sonic starting new user input processing
  harness.client.emitEvent({
    contentStart: {
      contentId: "user-1",
      role: "USER",
      type: "TEXT",
    },
  });
  // New assistant response should flow normally
  harness.client.emitEvent({
    contentStart: {
      contentId: "audio-2",
      completionId: "completion-2",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: { contentId: "audio-2", content: "BBBB" },
  });
  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.chunk").length === 2);
});

test("nova-sonic iOS-only barge-in gates stale audio via bargedIn flag", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeAllResponses();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => harness.client.outboundEvents.some((event) => "sessionStart" in event));

  // Start assistant audio
  harness.client.emitEvent({
    contentStart: {
      contentId: "audio-1",
      completionId: "completion-1",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: { contentId: "audio-1", content: "AAAA" },
  });
  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.chunk").length === 1);

  // iOS barge-in (interrupt) — Nova Sonic doesn't detect it
  await harness.provider.interrupt("session-1");
  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.interrupted").length === 1);

  // Stale audio continues from Nova Sonic — should be dropped
  harness.client.emitEvent({
    audioOutput: { contentId: "audio-1", content: "CCCC" },
  });
  harness.client.emitEvent({
    audioOutput: { contentId: "audio-1", content: "DDDD" },
  });
  await waitForTicks();
  // Still only 1 audio chunk — stale ones were dropped
  assert.equal(eventsOfType(harness.emitted, "assistant.audio.chunk").length, 1);

  // Old response ends naturally — bargedIn clears
  harness.client.emitEvent({
    completionEnd: { completionId: "completion-1", stopReason: "END_TURN" },
  });
  await waitForTicks();

  // New response audio flows normally
  harness.client.emitEvent({
    contentStart: {
      contentId: "audio-2",
      completionId: "completion-2",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: { contentId: "audio-2", content: "EEEE" },
  });
  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.chunk").length === 2);
});

test("nova-sonic iOS interrupt + Nova Sonic INTERRUPTED are idempotent", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeAllResponses();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => harness.client.outboundEvents.some((event) => "sessionStart" in event));

  // Start assistant audio
  harness.client.emitEvent({
    contentStart: {
      contentId: "audio-1",
      completionId: "completion-1",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: { contentId: "audio-1", content: "AAAA" },
  });
  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.chunk").length === 1);

  // iOS fires interrupt first
  await harness.provider.interrupt("session-1");
  await waitFor(() => eventsOfType(harness.emitted, "assistant.audio.interrupted").length === 1);

  // Then Nova Sonic also fires INTERRUPTED — should be idempotent
  harness.client.emitEvent({
    completionEnd: { completionId: "completion-1", stopReason: "INTERRUPTED" },
  });
  await waitForTicks();

  // Only one interrupted event emitted
  assert.equal(eventsOfType(harness.emitted, "assistant.audio.interrupted").length, 1);
  // No stream restart
  assert.equal(harness.client.sendCallCount, 1);
});

test("nova-sonic timeout emits recoverable failure and does not finalize the assistant draft", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeAllResponses();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  harness.client.emitEvent({
    contentStart: {
      contentId: "assistant-timeout-1",
      completionId: "completion-timeout-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  }, 0);
  harness.client.emitEvent({
    textOutput: {
      contentId: "assistant-timeout-1",
      content: "This draft should be cleared.",
    },
  }, 0);
  harness.client.emitEvent({
    contentEnd: {
      contentId: "assistant-timeout-1",
      type: "TEXT",
      stopReason: "END_TURN",
    },
  }, 0);

  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 1);
  harness.client.emitFailure("Timed out waiting for audio bytes (59 seconds).", "modelTimeoutException", 0);

  await waitFor(() => eventsOfType(harness.emitted, "error").length === 1);

  const errorEvent = eventsOfType(harness.emitted, "error")[0];
  assert.equal(errorEvent?.payload.code, "voice_provider_failed");
  assert.match(String(errorEvent?.payload.message ?? ""), /Timed out waiting for audio bytes/);
  assert.equal(findStateTransitions(harness.emitted, "listening").length, 2);

  const assistantFinals = findToolCalls(harness.emitted, "convo.appendMessage").filter((event) => {
    const args = parseToolArguments(event);
    return args.role === "assistant" && args.isPartial === false;
  });
  assert.equal(assistantFinals.length, 0);
});

test("nova-sonic executes multiple tool uses and returns both tool results", async (t) => {
  const harness = createHarness({ tools: TOOLS });
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => harness.client.outboundEvents.some((event) => "promptStart" in event));

  harness.client.emitEvent({
    toolUse: {
      contentId: "tool-content-1",
      completionId: "completion-tool-1",
      toolName: "bridge_exec_run",
      toolUseId: "tool-use-1",
      content: JSON.stringify({ command: "npm test" }),
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "tool-content-1",
      completionId: "completion-tool-1",
      type: "TOOL",
      stopReason: "TOOL_USE",
      toolUseId: "tool-use-1",
    },
  });
  harness.client.emitEvent({
    toolUse: {
      contentId: "tool-content-2",
      completionId: "completion-tool-2",
      toolName: "bridge_fs_read",
      toolUseId: "tool-use-2",
      content: JSON.stringify({ path: "README.md" }),
    },
  });
  harness.client.emitEvent({
    contentEnd: {
      contentId: "tool-content-2",
      completionId: "completion-tool-2",
      type: "TOOL",
      stopReason: "TOOL_USE",
      toolUseId: "tool-use-2",
    },
  });

  await waitFor(() => harness.executedToolCalls.length === 2);
  await waitFor(() => {
    const toolResultEvents = harness.client.outboundEvents.filter((event) => "toolResult" in event);
    return toolResultEvents.length === 2;
  });

  assert.deepEqual(
    harness.executedToolCalls.map((call) => ({ name: call.name, input: call.input })),
    [
      { name: "bridge.exec.run", input: { command: "npm test" } },
      { name: "bridge.fs.read", input: { path: "README.md" } },
    ],
  );

  const toolResults = harness.client.outboundEvents
    .filter((event) => "toolResult" in event)
    .map((event) => JSON.parse(String(event.toolResult.content)));
  assert.deepEqual(toolResults, [
    { ok: true, tool: "bridge.exec.run" },
    { ok: true, tool: "bridge.fs.read" },
  ]);
});

test("nova-sonic finalizes assistant text before emitting user message on next turn", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Assistant emits FINAL text (creates a partial) — no audio contentEnd or completionEnd
  harness.client.emitEvent({
    contentStart: {
      contentId: "asst-text-1",
      completionId: "comp-asst-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "asst-text-1", content: "Hello there" } });
  harness.client.emitEvent({ contentEnd: { contentId: "asst-text-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 1);

  // Now the user speaks — USER TEXT contentEnd arrives without prior audio/completionEnd
  harness.client.emitEvent({
    contentStart: {
      contentId: "user-text-1",
      completionId: "comp-user-1",
      role: "USER",
      type: "TEXT",
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "user-text-1", content: "How are you?" } });
  harness.client.emitEvent({ contentEnd: { contentId: "user-text-1", type: "TEXT", stopReason: "END_TURN" } });

  // Wait for the user appendMessage to appear
  await waitFor(() => {
    const calls = findToolCalls(harness.emitted, "convo.appendMessage");
    return calls.some((c) => JSON.parse(String(c.payload.arguments)).role === "user");
  });

  const appendCalls = findToolCalls(harness.emitted, "convo.appendMessage");

  // Find the assistant finalization (isPartial: false) and the user message
  const assistantFinal = appendCalls.find((c) => {
    const args = JSON.parse(String(c.payload.arguments));
    return args.role === "assistant" && args.isPartial === false;
  });
  const userMessage = appendCalls.find((c) => {
    const args = JSON.parse(String(c.payload.arguments));
    return args.role === "user";
  });

  assert.ok(assistantFinal, "assistant finalization should exist");
  assert.ok(userMessage, "user message should exist");

  // Assistant finalization must come before user message in the event stream
  const assistantFinalIdx = harness.emitted.indexOf(assistantFinal!);
  const userMessageIdx = harness.emitted.indexOf(userMessage!);
  assert.ok(assistantFinalIdx < userMessageIdx, "assistant finalization must precede user message");
});

test("nova-sonic does not accumulate text across turns", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Turn 1: assistant says "Hello"
  harness.client.emitEvent({
    contentStart: {
      contentId: "asst-t1",
      completionId: "comp-t1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "asst-t1", content: "Hello" } });
  harness.client.emitEvent({ contentEnd: { contentId: "asst-t1", type: "TEXT", stopReason: "END_TURN" } });

  await waitFor(() => findToolCalls(harness.emitted, "convo.appendMessage").length === 1);

  // User speaks — triggers finalization of turn 1
  harness.client.emitEvent({
    contentStart: { contentId: "user-t1", completionId: "comp-user-t1", role: "USER", type: "TEXT" },
  });
  harness.client.emitEvent({ textOutput: { contentId: "user-t1", content: "Next" } });
  harness.client.emitEvent({ contentEnd: { contentId: "user-t1", type: "TEXT", stopReason: "END_TURN" } });

  await waitFor(() => {
    const calls = findToolCalls(harness.emitted, "convo.appendMessage");
    return calls.some((c) => JSON.parse(String(c.payload.arguments)).role === "user");
  });

  // Turn 2: assistant says "Goodbye"
  harness.client.emitEvent({
    contentStart: {
      contentId: "asst-t2",
      completionId: "comp-t2",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "asst-t2", content: "Goodbye" } });
  harness.client.emitEvent({ contentEnd: { contentId: "asst-t2", type: "TEXT", stopReason: "END_TURN" } });

  // Wait for the turn-2 partial
  await waitFor(() => {
    const calls = findToolCalls(harness.emitted, "convo.appendMessage");
    return calls.some((c) => {
      const args = JSON.parse(String(c.payload.arguments));
      return args.role === "assistant" && args.text === "Goodbye" && args.isPartial === true;
    });
  });

  // Turn 2's partial must contain only "Goodbye", not "Hello Goodbye"
  const turn2Partial = findToolCalls(harness.emitted, "convo.appendMessage").find((c) => {
    const args = JSON.parse(String(c.payload.arguments));
    return args.role === "assistant" && args.isPartial === true && args.text === "Goodbye";
  });
  assert.ok(turn2Partial, "Turn 2 partial should contain only 'Goodbye'");

  // Verify no message contains accumulated text from both turns
  const allAssistantPartials = findToolCalls(harness.emitted, "convo.appendMessage").filter((c) => {
    const args = JSON.parse(String(c.payload.arguments));
    return args.role === "assistant" && args.isPartial === true;
  });
  for (const partial of allAssistantPartials) {
    const text = JSON.parse(String(partial.payload.arguments)).text;
    assert.ok(!text.includes("Hello Goodbye"), `Text should not accumulate across turns, got: "${text}"`);
  }
});

test("nova-sonic can close and start a fresh session cleanly", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => harness.client.outboundEvents.some((event) => "sessionStart" in event));

  harness.client.closeResponse();
  await harness.provider.closeSession("session-1");

  await harness.provider.startStream("session-1", harness.context);
  await waitFor(() => {
    const sessionStarts = harness.client.outboundEvents.filter((event) => "sessionStart" in event);
    return sessionStarts.length === 2;
  });

  const sessionStarts = harness.client.outboundEvents.filter((event) => "sessionStart" in event);
  assert.equal(sessionStarts.length, 2);
});

test("speculative contentEnd emits convo.appendMessage ahead of audio", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Emit SPECULATIVE text content
  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-1",
      completionId: "comp-spec-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-1", content: "Hello world" } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // SPECULATIVE contentEnd should have emitted convo.appendMessage(isPartial: true)
  const specAppends = findToolCalls(harness.emitted, "convo.appendMessage");
  assert.ok(specAppends.length >= 1, "expected at least one convo.appendMessage from speculative text");
  assertAssistantAppend(specAppends[0], { text: "Hello world", isPartial: true });
  const specLiveId = JSON.parse(String(specAppends[0].payload.arguments)).liveResponseId;

  // Now emit FINAL text content
  harness.client.emitEvent({
    contentStart: {
      contentId: "final-1",
      completionId: "comp-spec-1",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "final-1", content: "Hello world" } });
  harness.client.emitEvent({ contentEnd: { contentId: "final-1", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // FINAL should NOT emit a new convo.appendMessage — speculative preview is already ahead.
  // The bubble should stay at the speculative text, not regress.
  const allAppends = findToolCalls(harness.emitted, "convo.appendMessage");
  assert.equal(allAppends.length, specAppends.length, "FINAL should not emit when speculative is ahead");
  assertAssistantAppend(allAppends[allAppends.length - 1], { text: "Hello world", isPartial: true });
});

test("multiple speculative blocks accumulate before FINAL arrives", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Emit two SPECULATIVE blocks before any FINAL
  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-a",
      completionId: "comp-multi-spec",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-a", content: "Hello world." } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-a", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  const appendsAfterFirst = findToolCalls(harness.emitted, "convo.appendMessage");
  assertAssistantAppend(appendsAfterFirst[appendsAfterFirst.length - 1], { text: "Hello world.", isPartial: true });

  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-b",
      completionId: "comp-multi-spec",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-b", content: "How are you?" } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-b", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // Second speculative should ACCUMULATE, not replace
  const appendsAfterSecond = findToolCalls(harness.emitted, "convo.appendMessage");
  assertAssistantAppend(appendsAfterSecond[appendsAfterSecond.length - 1], { text: "Hello world. How are you?", isPartial: true });

  // Now FINAL arrives — should NOT regress the bubble; speculative preview is ahead
  const appendCountBeforeFinal = findToolCalls(harness.emitted, "convo.appendMessage").length;
  harness.client.emitEvent({
    contentStart: {
      contentId: "final-a",
      completionId: "comp-multi-spec",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "final-a", content: "Hello world." } });
  harness.client.emitEvent({ contentEnd: { contentId: "final-a", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  const appendsAfterFinal = findToolCalls(harness.emitted, "convo.appendMessage");
  assert.equal(appendsAfterFinal.length, appendCountBeforeFinal, "FINAL should not emit when speculative is ahead");
  // Last bubble still shows the full speculative preview
  assertAssistantAppend(appendsAfterFinal[appendsAfterFinal.length - 1], { text: "Hello world. How are you?", isPartial: true });
});

test("speculative preview includes accumulated text from prior FINAL sentences", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Emit FINAL "First." to build up accumulatedAssistantText
  harness.client.emitEvent({
    contentStart: {
      contentId: "final-first",
      completionId: "comp-accumulated",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "final-first", content: "First." } });
  harness.client.emitEvent({ contentEnd: { contentId: "final-first", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // Emit SPECULATIVE "Second preview."
  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-second",
      completionId: "comp-accumulated",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-second", content: "Second preview." } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-second", type: "TEXT", stopReason: "END_TURN" } });

  await waitForTicks();

  // The speculative append should combine accumulated text + speculative text
  const allAppends = findToolCalls(harness.emitted, "convo.appendMessage");
  const lastAppend = allAppends[allAppends.length - 1];
  assertAssistantAppend(lastAppend, { text: "First. Second preview.", isPartial: true });
});

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

  harness.client.emitEvent({
    completionEnd: {
      completionId: "comp-spec-only",
      stopReason: "END_TURN",
    },
  });

  await waitForTicks();

  const appends = findToolCalls(harness.emitted, "convo.appendMessage");
  const lastAppend = appends[appends.length - 1];
  assertAssistantAppend(lastAppend, { text: "Hello there.", isPartial: false });
  assert.ok(findStateTransitions(harness.emitted, "idle").length >= 1);
});

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

  // Interrupted event should still be emitted
  const interrupted = harness.emitted.filter((e) => e.type === "assistant.audio.interrupted");
  assert.equal(interrupted.length, 1);
  // liveResponseId is omitted when text was finalized during barge-in
  assert.equal(interrupted[0].payload.liveResponseId, undefined);

  // Finalization should come BEFORE the interrupted event
  const finalizeIdx = harness.emitted.indexOf(finalizedAppends[0]);
  const interruptIdx = harness.emitted.indexOf(interrupted[0]);
  assert.ok(finalizeIdx < interruptIdx, "finalization must precede interrupted event");
});

test("user speech finalizes prior speculative-only assistant message", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Assistant responds (speculative only)
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

test("late FINAL contentEnd after completionEnd does not create duplicate grey message", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // SPECULATIVE text
  harness.client.emitEvent({
    contentStart: {
      contentId: "spec-dup-1",
      completionId: "comp-dup",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "SPECULATIVE" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "spec-dup-1", content: "Hello world." } });
  harness.client.emitEvent({ contentEnd: { contentId: "spec-dup-1", type: "TEXT", stopReason: "END_TURN" } });

  // FINAL text — contentStart and textOutput arrive, but contentEnd is delayed
  harness.client.emitEvent({
    contentStart: {
      contentId: "final-dup-1",
      completionId: "comp-dup",
      role: "ASSISTANT",
      type: "TEXT",
      additionalModelFields: JSON.stringify({ generationStage: "FINAL" }),
    },
  });
  harness.client.emitEvent({ textOutput: { contentId: "final-dup-1", content: "Hello world." } });

  await waitForTicks();

  // completionEnd arrives BEFORE the FINAL contentEnd
  harness.client.emitEvent({
    completionEnd: {
      completionId: "comp-dup",
      stopReason: "END_TURN",
    },
  });

  await waitForTicks();

  // Late FINAL contentEnd — should be a no-op (contents cleared)
  harness.client.emitEvent({
    contentEnd: {
      contentId: "final-dup-1",
      type: "TEXT",
      stopReason: "END_TURN",
    },
  });

  await waitForTicks();

  const allAppends = findToolCalls(harness.emitted, "convo.appendMessage");
  const finalizedAppends = allAppends.filter((e) => {
    const args = JSON.parse(String(e.payload.arguments));
    return args.isPartial === false && args.role === "assistant";
  });
  assert.equal(finalizedAppends.length, 1, "should have exactly one finalized assistant message");

  // No partial messages after the finalized one
  const finalIdx = allAppends.indexOf(finalizedAppends[0]);
  const partialsAfterFinal = allAppends.slice(finalIdx + 1).filter((e) => {
    const args = JSON.parse(String(e.payload.arguments));
    return args.role === "assistant";
  });
  assert.equal(partialsAfterFinal.length, 0, "no assistant messages should appear after finalization");
});

test("barge-in without accumulated text includes liveResponseId in interrupted event", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
    await harness.provider.closeSession("session-1");
  });

  await harness.provider.startStream("session-1", harness.context);

  // Only audio, no text
  harness.client.emitEvent({
    contentStart: {
      contentId: "audio-only-1",
      completionId: "comp-audio-only",
      role: "ASSISTANT",
      type: "AUDIO",
    },
  });
  harness.client.emitEvent({
    audioOutput: {
      contentId: "audio-only-1",
      content: "AAAA",
    },
  });

  await waitForTicks();

  const audioChunks = eventsOfType(harness.emitted, "assistant.audio.chunk");
  assert.ok(audioChunks.length >= 1);
  const audioLiveId = audioChunks[0].payload.liveResponseId;
  assert.equal(typeof audioLiveId, "string");

  // Barge-in with no accumulated text
  harness.client.emitEvent({
    completionEnd: {
      completionId: "comp-audio-only",
      stopReason: "BARGE_IN",
    },
  });

  await waitForTicks();

  const interrupted = eventsOfType(harness.emitted, "assistant.audio.interrupted");
  assert.equal(interrupted.length, 1);
  // liveResponseId SHOULD be present since no text was finalized
  assert.equal(interrupted[0].payload.liveResponseId, audioLiveId);
});

function createHarness(options?: {
  tools?: ToolDefinition[];
  assistantTurnFinalizeDelayMs?: number;
}) {
  const client = new FakeBidirectionalClient();
  const emitted: EventEnvelope[] = [];
  const executedToolCalls: ToolCallRequest[] = [];
  const provider = new BedrockNovaSonicVoiceProvider({
    modelId: "amazon.nova-sonic-v1:0",
    region: "us-east-1",
    voiceId: "matthew",
    enableTools: true,
    assistantTurnFinalizeDelayMs: options?.assistantTurnFinalizeDelayMs ?? 200,
  }, client);

  const context: VoiceProviderContext = {
    emit: (event) => {
      emitted.push(event);
    },
    listTools: () => options?.tools ?? [],
    executeTool: async (_sessionId, toolCall) => {
      executedToolCalls.push(toolCall);
      return {
        result: JSON.stringify({ ok: true, tool: toolCall.name }),
        error: null,
      };
    },
  };

  return { client, context, emitted, executedToolCalls, provider };
}

function eventsOfType(events: EventEnvelope[], type: string): EventEnvelope[] {
  return events.filter((event) => event.type === type);
}

function findToolCalls(events: EventEnvelope[], name: string): EventEnvelope[] {
  return events.filter(
    (event) => event.type === "tool.call" && event.payload.name === name,
  );
}

function findStateTransitions(events: EventEnvelope[], state: string): EventEnvelope[] {
  return findToolCalls(events, "convo.setState").filter((event) => {
    try {
      return JSON.parse(String(event.payload.arguments)).state === state;
    } catch {
      return false;
    }
  });
}

function parseToolArguments(event: EventEnvelope | undefined): Record<string, any> {
  return JSON.parse(String(event?.payload.arguments ?? "{}"));
}

function assertAssistantAppend(
  event: EventEnvelope | undefined,
  expected: { text: string; isPartial: boolean },
): void {
  const args = parseToolArguments(event);
  assert.equal(args.role, "assistant");
  assert.equal(args.text, expected.text);
  assert.equal(args.isPartial, expected.isPartial);
  assert.equal(typeof args.liveResponseId, "string");
  assert.ok(args.liveResponseId.length > 0);
}

async function waitFor(
  predicate: () => boolean,
  timeoutMs = 1_000,
): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt >= timeoutMs) {
      throw new Error("timed out waiting for condition");
    }
    await waitForTicks();
  }
}

async function waitForTicks(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 5));
}

class FakeBidirectionalClient {
  readonly outboundEvents: Array<Record<string, any>> = [];
  private readonly decoder = new TextDecoder();
  private readonly inbounds: AsyncQueue<any>[] = [];
  private failFirstSendWith?: string;
  sendCallCount = 0;

  constructor(options?: { failFirstSendWith?: string }) {
    this.failFirstSendWith = options?.failFirstSendWith;
  }

  async send(command: { input?: { body?: AsyncIterable<{ chunk?: { bytes?: Uint8Array } }> } }) {
    this.sendCallCount += 1;
    if (this.failFirstSendWith) {
      const message = this.failFirstSendWith;
      this.failFirstSendWith = undefined;
      throw new Error(message);
    }
    const inbound = new AsyncQueue<any>();
    this.inbounds.push(inbound);
    void this.captureOutgoing(command.input?.body);
    return { body: inbound };
  }

  emitEvent(event: Record<string, unknown>, streamIndex = this.inbounds.length - 1): void {
    this.inbounds[streamIndex]?.push({
      chunk: {
        bytes: Buffer.from(JSON.stringify({ event }), "utf8"),
      },
    });
  }

  emitFailure(message: string, kind: string, streamIndex = this.inbounds.length - 1): void {
    this.inbounds[streamIndex]?.push({
      [kind]: { message },
    });
  }

  closeResponse(streamIndex = this.inbounds.length - 1): void {
    this.inbounds[streamIndex]?.close();
  }

  closeAllResponses(): void {
    for (const inbound of this.inbounds) {
      inbound.close();
    }
  }

  private async captureOutgoing(body: AsyncIterable<{ chunk?: { bytes?: Uint8Array } }> | undefined): Promise<void> {
    if (!body) {
      return;
    }
    for await (const frame of body) {
      const bytes = frame.chunk?.bytes;
      if (!bytes) {
        continue;
      }
      const raw = this.decoder.decode(bytes);
      const parsed = JSON.parse(raw) as { event?: Record<string, any> };
      if (parsed.event) {
        this.outboundEvents.push(parsed.event);
      }
    }
  }
}

class AsyncQueue<T> implements AsyncIterable<T> {
  private readonly items: T[] = [];
  private readonly resolvers: Array<(result: IteratorResult<T>) => void> = [];
  private closed = false;

  push(item: T): void {
    if (this.closed) {
      return;
    }
    const resolver = this.resolvers.shift();
    if (resolver) {
      resolver({ value: item, done: false });
      return;
    }
    this.items.push(item);
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    while (this.resolvers.length > 0) {
      this.resolvers.shift()?.({ value: undefined as T, done: true });
    }
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: async () => {
        if (this.items.length > 0) {
          return { value: this.items.shift() as T, done: false };
        }
        if (this.closed) {
          return { value: undefined as T, done: true };
        }
        return await new Promise<IteratorResult<T>>((resolve) => {
          this.resolvers.push(resolve);
        });
      },
    };
  }
}
