import test from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";

import { ConductorService } from "../src/core/conductorService.js";
import { MemoryService, MemoryServiceConfig } from "../src/core/memory/memoryService.js";
import { ContextGraphService } from "../src/contextGraph/contextGraphService.js";
import { makeEvent } from "../src/core/events.js";
import { ModelProvider, ConversationTurn, ModelResponse } from "../src/core/types.js";

class StubProvider implements ModelProvider {
  readonly name = "stub";
  constructor(private readonly text: string) {}
  async generateResponse(_conv: ConversationTurn[]): Promise<ModelResponse> {
    const t = this.text;
    return {
      fullText: t,
      chunks: (async function* () { yield t; })(),
    };
  }
}

function makeConfig(overrides: Partial<MemoryServiceConfig> = {}): MemoryServiceConfig {
  return {
    enabled: true,
    s3Bucket: "test-bucket",
    s3Prefix: "memories/",
    awsRegion: "us-east-1",
    summaryModelId: "us.amazon.nova-2-lite-v1:0",
    retrieveTimeoutMs: 1500,
    maxInjectedChars: 900,
    recentMemoryCount: 3,
    ...overrides,
  };
}

test("on first user turn, injects memory as user turn when available", async () => {
  const mockS3 = {
    send: async (cmd: unknown) => {
      const c = cmd as { constructor: { name: string } };
      if (c.constructor.name === "ListObjectsV2Command") {
        return {
          Contents: [{ Key: "memories/alice/key.json", LastModified: new Date() }],
        };
      }
      if (c.constructor.name === "GetObjectCommand") {
        const readable = new Readable();
        const doc = {
          memoryUserKey: "alice",
          sessionId: "old-sess",
          timestamp: new Date().toISOString(),
          summary: "Previous work on auth.",
        };
        readable.push(JSON.stringify(doc));
        readable.push(null);
        return { Body: readable };
      }
      return {};
    },
  };

  const memService = new MemoryService(makeConfig(), { s3: mockS3 as never });
  const contextGraphService = new ContextGraphService(
    { retrieveTimeoutMs: 1500, maxInjectedChars: 900 },
    { memoryService: memService },
  );
  let capturedConversation: ConversationTurn[] = [];
  const provider: ModelProvider = {
    name: "capture",
    async generateResponse(conv): Promise<ModelResponse> {
      capturedConversation = [...conv];
      return {
        fullText: "hello",
        chunks: (async function* () { yield "hello"; })(),
      };
    },
  };

  const conductor = new ConductorService(
    provider,
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService },
  );

  const events: string[] = [];
  const emit = (e: { type: string }) => events.push(e.type);

  // Start session with memoryUserKey
  await conductor.handleEvent(
    makeEvent("session.start", "sess1", { memoryUserKey: "alice" }),
    emit,
  );

  // Send first user turn
  await conductor.handleEvent(
    makeEvent("user.audio.transcript.final", "sess1", { text: "What should I do next?" }),
    emit,
  );

  // The provider should have received a conversation with a [Prior context from previous sessions] user turn
  const memIdx = capturedConversation.findIndex(
    (t) => t.role === "user" && typeof t.content === "string" && (t.content as string).includes("[Prior context from previous sessions]"),
  );
  const speechIdx = capturedConversation.findIndex(
    (t) => t.role === "user" && typeof t.content === "string" && (t.content as string).includes("What should I do next?"),
  );
  assert.ok(memIdx !== -1, "memory context turn should be present");
  assert.ok(speechIdx !== -1, "user speech turn should be present");
  assert.ok(memIdx < speechIdx, "memory context turn should precede the user speech turn");
  assert.ok(events.includes("session.memory.loaded"), "should emit session.memory.loaded");
});

test("does not inject memory twice in same session (memoryHydrated guard)", async () => {
  let retrieveCount = 0;
  const mockS3 = {
    send: async () => {
      retrieveCount++;
      return { Contents: [] };
    },
  };

  const memService = new MemoryService(makeConfig(), { s3: mockS3 as never });
  const contextGraphService = new ContextGraphService(
    { retrieveTimeoutMs: 1500, maxInjectedChars: 900 },
    { memoryService: memService },
  );
  const provider = new StubProvider("response");
  const conductor = new ConductorService(
    provider,
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService },
  );

  const emit = () => {};
  await conductor.handleEvent(makeEvent("session.start", "sess1", { memoryUserKey: "bob" }), emit);
  await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess1", { text: "turn 1" }), emit);
  await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess1", { text: "turn 2" }), emit);

  // retrieveContext (which calls S3 list) should only be called once
  assert.ok(retrieveCount <= 1, `retrieveContext called ${retrieveCount} times, expected ≤1`);
});

test("finalizeSession no-ops when session missing", async () => {
  const memService = new MemoryService(makeConfig());
  const contextGraphService = new ContextGraphService(
    { retrieveTimeoutMs: 1500, maxInjectedChars: 900 },
    { memoryService: memService },
  );
  const conductor = new ConductorService(
    new StubProvider("hi"),
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService },
  );
  // Should not throw
  await conductor.finalizeSession("nonexistent-session");
});

test("finalizeSession no-ops when session has no memoryUserKey", async () => {
  let summarizeCalled = false;
  const mockBedrock = { send: async () => { summarizeCalled = true; return {}; } };
  const mockS3 = { send: async () => ({}) };
  const memService = new MemoryService(makeConfig(), { s3: mockS3 as never, bedrock: mockBedrock as never });
  const contextGraphService = new ContextGraphService(
    { retrieveTimeoutMs: 1500, maxInjectedChars: 900 },
    { memoryService: memService },
  );
  const conductor = new ConductorService(
    new StubProvider("hi"),
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService },
  );

  const emit = () => {};
  // Start session WITHOUT memoryUserKey
  await conductor.handleEvent(makeEvent("session.start", "sess-nomem", {}), emit);
  await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess-nomem", { text: "hello" }), emit);

  await conductor.finalizeSession("sess-nomem");
  assert.equal(summarizeCalled, false, "should not summarize when no memoryUserKey");
});

test("finalizeSession does not write to S3 for session with fewer than 3 user turns", async () => {
  let putObjectCalled = false;
  const mockS3 = {
    send: async (cmd: unknown) => {
      const c = cmd as { constructor: { name: string } };
      if (c.constructor.name === "PutObjectCommand") putObjectCalled = true;
      return {};
    },
  };
  const mockBedrock = { send: async () => ({}) };
  const memService = new MemoryService(makeConfig(), { s3: mockS3 as never, bedrock: mockBedrock as never });
  const contextGraphService = new ContextGraphService(
    { retrieveTimeoutMs: 1500, maxInjectedChars: 900 },
    { memoryService: memService },
  );

  const conductor = new ConductorService(
    new StubProvider("hi"),
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService },
  );

  const emit = () => {};
  await conductor.handleEvent(makeEvent("session.start", "sess-short", { memoryUserKey: "dave" }), emit);
  await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess-short", { text: "hello" }), emit);

  await conductor.finalizeSession("sess-short");
  assert.equal(putObjectCalled, false, "should not write to S3 for a short session");
});

test("finalizeSession calls summarizeAndStore for meaningful session", async () => {
  let summarizeCalled = false;
  const mockBedrock = {
    send: async () => ({
      body: new TextEncoder().encode(JSON.stringify({
        output: { message: { content: [{ text: '{"summary":"test","decisions":[],"blockers":[],"nextSteps":[]}' }] } },
      })),
    }),
  };
  const mockS3 = { send: async () => ({}) };

  const memService = new MemoryService(makeConfig(), { s3: mockS3 as never, bedrock: mockBedrock as never });

  // Wrap summarizeAndStore to detect call
  const origSummarize = memService.summarizeAndStore.bind(memService);
  memService.summarizeAndStore = async (...args) => {
    summarizeCalled = true;
    return origSummarize(...args);
  };

  const contextGraphService = new ContextGraphService(
    { retrieveTimeoutMs: 1500, maxInjectedChars: 900 },
    { memoryService: memService },
  );
  const provider = new StubProvider("response");
  const conductor = new ConductorService(
    provider,
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService },
  );

  const emit = () => {};
  await conductor.handleEvent(makeEvent("session.start", "sess2", { memoryUserKey: "carol" }), emit);
  // Build up 3+ user turns to make it meaningful
  for (const msg of ["msg1", "msg2", "msg3"]) {
    await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess2", { text: msg }), emit);
  }

  await conductor.finalizeSession("sess2");
  assert.equal(summarizeCalled, true, "should call summarizeAndStore for meaningful session");
});
