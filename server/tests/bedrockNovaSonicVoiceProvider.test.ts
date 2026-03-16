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
  assert.deepEqual(JSON.parse(String(appendCalls[0]?.payload.arguments)), {
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
  assert.deepEqual(JSON.parse(String(findToolCalls(harness.emitted, "convo.appendMessage")[0]?.payload.arguments)), {
    role: "assistant",
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
  assert.deepEqual(JSON.parse(String(appendCalls.at(-1)?.payload.arguments)), {
    role: "assistant",
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
  assert.deepEqual(JSON.parse(String(appendCalls[0]?.payload.arguments)), {
    role: "assistant",
    text: "Sentence one.",
    isPartial: true,
  });
  assert.deepEqual(JSON.parse(String(appendCalls[1]?.payload.arguments)), {
    role: "assistant",
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

test("nova-sonic emits interruption and returns to listening on interrupted completions", async (t) => {
  const harness = createHarness();
  t.after(async () => {
    harness.client.closeResponse();
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

function createHarness(options?: { tools?: ToolDefinition[] }) {
  const client = new FakeBidirectionalClient();
  const emitted: EventEnvelope[] = [];
  const executedToolCalls: ToolCallRequest[] = [];
  const provider = new BedrockNovaSonicVoiceProvider({
    modelId: "amazon.nova-sonic-v1:0",
    region: "us-east-1",
    voiceId: "matthew",
    enableTools: true,
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
  private currentInbound: AsyncQueue<any> | null = null;
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
    this.currentInbound = inbound;
    void this.captureOutgoing(command.input?.body);
    return { body: inbound };
  }

  emitEvent(event: Record<string, unknown>): void {
    this.currentInbound?.push({
      chunk: {
        bytes: Buffer.from(JSON.stringify({ event }), "utf8"),
      },
    });
  }

  closeResponse(): void {
    this.currentInbound?.close();
    this.currentInbound = null;
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
