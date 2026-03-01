import test from "node:test";
import assert from "node:assert/strict";

import { ConductorService } from "../src/core/conductorService.js";
import { makeEvent } from "../src/core/events.js";
import { ModelProvider, ConversationTurn, ModelResponse, ToolCallRequest } from "../src/core/types.js";

class StubProvider implements ModelProvider {
  readonly name = "stub";

  constructor(
    private readonly fullText: string,
    private readonly chunks: string[],
  ) {}

  async generateResponse(_conversation: ConversationTurn[]): Promise<ModelResponse> {
    const chunkList = this.chunks;
    return {
      fullText: this.fullText,
      chunks: (async function* stream() {
        for (const chunk of chunkList) {
          yield chunk;
        }
      })(),
    };
  }
}

class SequenceProvider implements ModelProvider {
  readonly name = "sequence";
  private index = 0;
  private readonly responses: Array<{ text?: string; chunks?: string[]; toolCalls?: ToolCallRequest[] }>;

  constructor(responses: Array<{ text?: string; chunks?: string[]; toolCalls?: ToolCallRequest[] }>) {
    this.responses = responses;
  }

  async generateResponse(_conversation: ConversationTurn[]): Promise<ModelResponse> {
    const current = this.responses[Math.min(this.index, this.responses.length - 1)];
    this.index += 1;

    const text = current.text ?? "";
    const chunkList = current.chunks ?? (text ? [text] : []);
    return {
      fullText: text,
      chunks: (async function* stream() {
        for (const chunk of chunkList) {
          yield chunk;
        }
      })(),
      ...(current.toolCalls ? { toolCalls: current.toolCalls } : {}),
    };
  }
}

test("transcript.final emits required tool-driven sequence", async () => {
  const provider = new StubProvider("Hello from test", ["Hello", " from test"]);
  const service = new ConductorService(provider, {
    maxTurns: 20,
    rateLimitPerMinute: 100,
  });

  const transcriptEvent = makeEvent("user.audio.transcript.final", "session-test", {
    text: "hello",
    timestamp: new Date().toISOString(),
    sessionId: "session-test",
  });

  const emitted = [] as ReturnType<typeof makeEvent>[];
  await service.handleEvent(transcriptEvent, (event) => emitted.push(event));

  assert.ok(emitted.length > 0, "expected emitted events");

  const toolCalls = emitted.filter((event) => event.type === "tool.call");
  assert.ok(toolCalls.length >= 5, "expected multiple tool.call events");

  const firstToolCall = toolCalls[0];
  assert.equal(firstToolCall.type, "tool.call");
  assert.equal(firstToolCall.payload.name, "convo.setState");
  const firstArgs = JSON.parse(String(firstToolCall.payload.arguments));
  assert.equal(firstArgs.state, "thinking");

  const hasTTSSpeak = toolCalls.some((event) => {
    if (event.payload.name !== "tts.speak") return false;
    const args = JSON.parse(String(event.payload.arguments));
    return typeof args.text === "string" && args.text.length > 0;
  });
  assert.equal(hasTTSSpeak, true, "expected a tts.speak tool call");
});

test("assistant partial events are emitted before assistant final", async () => {
  const provider = new StubProvider("Chunked response", ["Chunked", " response"]);
  const service = new ConductorService(provider, {
    maxTurns: 20,
    rateLimitPerMinute: 100,
  });

  const transcriptEvent = makeEvent("user.audio.transcript.final", "session-stream", {
    text: "stream this",
    timestamp: new Date().toISOString(),
    sessionId: "session-stream",
  });

  const emitted = [] as ReturnType<typeof makeEvent>[];
  await service.handleEvent(transcriptEvent, (event) => emitted.push(event));

  const firstPartialIndex = emitted.findIndex((event) => event.type === "assistant.speech.partial");
  const finalIndex = emitted.findIndex((event) => event.type === "assistant.speech.final");

  assert.ok(firstPartialIndex >= 0, "expected at least one partial event");
  assert.ok(finalIndex >= 0, "expected a final event");
  assert.ok(firstPartialIndex < finalIndex, "partials must be emitted before final");
});

test("spawn tool.result maps agentId to session and emits agent.status", async () => {
  const provider = new SequenceProvider([
    {
      toolCalls: [
        { id: "toolu_spawn", name: "agent.spawn", input: { prompt: "fix lint", repository: "owner/repo" } },
      ],
    },
    { text: "Spawn initiated." },
  ]);

  const service = new ConductorService(provider, {
    maxTurns: 20,
    rateLimitPerMinute: 100,
  });

  const emitted = [] as ReturnType<typeof makeEvent>[];
  const emit = (event: ReturnType<typeof makeEvent>) => {
    emitted.push(event);
    if (event.type === "tool.call" && event.payload.name === "agent.spawn") {
      const callId = String(event.payload.callId);
      const resultEvent = makeEvent("tool.result", "session-map", {
        callId,
        result: JSON.stringify({
          id: "agent-map-1",
          status: "RUNNING",
          target: {
            url: "https://cursor.example/run/agent-map-1",
            prUrl: "https://github.com/acme/repo/pull/42",
            branchName: "agent/branch",
          },
        }),
        error: null,
      });

      void service.handleEvent(resultEvent, emit);
    }
  };

  await service.handleEvent(makeEvent("user.audio.transcript.final", "session-map", { text: "spawn an agent" }), emit);

  const run = service.getCursorRun("agent-map-1");
  assert.ok(run, "expected mapped run");
  assert.equal(run?.sessionId, "session-map");
  assert.equal(run?.runUrl, "https://cursor.example/run/agent-map-1");
  assert.equal(run?.prUrl, "https://github.com/acme/repo/pull/42");
  assert.equal(run?.branchName, "agent/branch");

  const spawnCall = emitted.find((event) => event.type === "tool.call" && event.payload.name === "agent.spawn");
  assert.ok(spawnCall, "expected emitted spawn tool.call");
  const spawnCallId = String(spawnCall?.payload.callId ?? "");
  assert.equal(service.getAgentIdForSpawnCall(spawnCallId), "agent-map-1");

  const statusEvent = emitted.find((event) => (
    event.type === "agent.status" && event.payload.agentId === "agent-map-1"
  ));
  assert.ok(statusEvent, "expected emitted agent.status");
  assert.equal(statusEvent?.payload.status, "RUNNING");
});

test("webhook FINISHED routes to session and triggers agent.completed flow", async () => {
  const provider = new SequenceProvider([
    {
      toolCalls: [
        { id: "toolu_spawn_w", name: "agent.spawn", input: { prompt: "do work", repository: "owner/repo" } },
      ],
    },
    { text: "Spawned." },
    { text: "Agent completed and summary narrated." },
  ]);
  const service = new ConductorService(provider, {
    maxTurns: 20,
    rateLimitPerMinute: 100,
  });

  const emitted = [] as ReturnType<typeof makeEvent>[];
  const emit = (event: ReturnType<typeof makeEvent>) => {
    emitted.push(event);
    if (event.type === "tool.call" && event.payload.name === "agent.spawn") {
      const callId = String(event.payload.callId);
      void service.handleEvent(makeEvent("tool.result", "session-webhook", {
        callId,
        result: JSON.stringify({
          id: "agent-webhook-1",
          status: "RUNNING",
          target: { url: "https://cursor.example/run/agent-webhook-1" },
        }),
        error: null,
      }), emit);
    }
  };

  await service.handleEvent(makeEvent("user.audio.transcript.final", "session-webhook", { text: "spawn agent" }), emit);

  const webhookResult = await service.handleCursorWebhook({
    eventType: "statusChange",
    agentId: "agent-webhook-1",
    status: "FINISHED",
    summary: "Created PR with all requested fixes.",
    target: {
      url: "https://cursor.example/run/agent-webhook-1",
      prUrl: "https://github.com/acme/repo/pull/87",
      branchName: "agent/webhook-branch",
    },
  }, emit);

  assert.equal(webhookResult.statusCode, 200);

  const statusEvent = emitted.find((event) => (
    event.type === "agent.status"
    && event.payload.agentId === "agent-webhook-1"
    && event.payload.status === "FINISHED"
    && event.payload.webhookDriven === true
  ));
  assert.ok(statusEvent, "expected webhook-driven agent.status emission");

  const speechFinal = emitted.find((event) => event.type === "assistant.speech.final");
  assert.ok(speechFinal, "expected follow-up narration to run after webhook completion");

  const run = service.getCursorRun("agent-webhook-1");
  assert.equal(run?.status, "FINISHED");
  assert.equal(run?.prUrl, "https://github.com/acme/repo/pull/87");
});
