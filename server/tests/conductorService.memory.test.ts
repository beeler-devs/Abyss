import test from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";

import { ConductorService, isSubstantiveGoal } from "../src/core/conductorService.js";
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
    retrieveTimeoutMs: 1500,
    maxInjectedChars: 900,
    recentMemoryCount: 3,
    ...overrides,
  };
}

function makeSummaryProvider(summaryJson?: string): ModelProvider {
  return {
    name: "mock-summary",
    async generateResponse(): Promise<ModelResponse> {
      const text = summaryJson ?? '{"summary":"test","decisions":[],"blockers":[],"nextSteps":[]}';
      return {
        fullText: text,
        chunks: (async function* () { yield text; })(),
      };
    },
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

  const memService = new MemoryService(makeConfig(), makeSummaryProvider(), { s3: mockS3 as never });
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

  const memService = new MemoryService(makeConfig(), makeSummaryProvider(), { s3: mockS3 as never });
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
  const memService = new MemoryService(makeConfig(), makeSummaryProvider());
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
  const mockS3 = { send: async () => ({}) };
  const mockSummaryProvider = {
    name: "mock-summary",
    async generateResponse(): Promise<ModelResponse> {
      summarizeCalled = true;
      const text = '{"summary":"test","decisions":[],"blockers":[],"nextSteps":[]}';
      return { fullText: text, chunks: (async function* () { yield text; })() };
    },
  };
  const memService = new MemoryService(makeConfig(), mockSummaryProvider, { s3: mockS3 as never });
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
  const memService = new MemoryService(makeConfig(), makeSummaryProvider(), { s3: mockS3 as never });
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
  const mockS3 = { send: async () => ({}) };

  const memService = new MemoryService(
    makeConfig(),
    makeSummaryProvider('{"summary":"test","decisions":[],"blockers":[],"nextSteps":[]}'),
    { s3: mockS3 as never },
  );

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

// --- isSubstantiveGoal tests ---

test("isSubstantiveGoal returns false for short text", () => {
  assert.equal(isSubstantiveGoal("hi"), false);
  assert.equal(isSubstantiveGoal("ok"), false);
  assert.equal(isSubstantiveGoal(""), false);
});

test("isSubstantiveGoal returns false for fewer than 3 words", () => {
  assert.equal(isSubstantiveGoal("fix bug"), false);
  assert.equal(isSubstantiveGoal("hello world"), false);
});

test("isSubstantiveGoal returns false for trivial phrases", () => {
  assert.equal(isSubstantiveGoal("sounds good"), false);
  assert.equal(isSubstantiveGoal("thank you!"), false);
  assert.equal(isSubstantiveGoal("got it"), false);
  assert.equal(isSubstantiveGoal("Yes."), false);
  assert.equal(isSubstantiveGoal("Okay"), false);
});

test("isSubstantiveGoal returns true for real goals", () => {
  assert.equal(isSubstantiveGoal("Fix the login bug in the auth module"), true);
  assert.equal(isSubstantiveGoal("I want to refactor the database layer"), true);
  assert.equal(isSubstantiveGoal("Add tests for the new API endpoint"), true);
});

// --- apply() called on session.start ---

test("contextGraphService.apply called on session.start with memoryUserKey", async () => {
  let applyCalled = false;
  const mockContextGraph = {
    apply: async (update: { type: string }) => { if (update.type === "session.start") applyCalled = true; },
    retrieveResumeContext: async () => null,
    summarizeAndStore: async () => null,
  } as unknown as ContextGraphService;

  const conductor = new ConductorService(
    new StubProvider("hi"),
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService: mockContextGraph },
  );

  await conductor.handleEvent(
    makeEvent("session.start", "sess-apply", { memoryUserKey: "alice" }),
    () => {},
  );

  assert.equal(applyCalled, true, "apply should be called with session.start");
});

// --- apply() NOT called for trivial transcripts ---

test("goal.started not fired for trivial transcript", async () => {
  let goalFired = false;
  const mockContextGraph = {
    apply: async (update: { type: string }) => { if (update.type === "goal.started") goalFired = true; },
    retrieveResumeContext: async () => null,
    summarizeAndStore: async () => null,
  } as unknown as ContextGraphService;

  const conductor = new ConductorService(
    new StubProvider("response"),
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService: mockContextGraph },
  );

  const emit = () => {};
  await conductor.handleEvent(makeEvent("session.start", "sess-trivial", { memoryUserKey: "bob" }), emit);
  await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess-trivial", { text: "ok" }), emit);

  assert.equal(goalFired, false, "goal.started should not fire for trivial input");
});

// --- retrieveResumeContext called on first turn ---

test("retrieveResumeContext called on first user turn", async () => {
  let retrieveCalled = false;
  const mockContextGraph = {
    apply: async () => {},
    retrieveResumeContext: async () => { retrieveCalled = true; return null; },
    summarizeAndStore: async () => null,
  } as unknown as ContextGraphService;

  const conductor = new ConductorService(
    new StubProvider("response"),
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService: mockContextGraph },
  );

  const emit = () => {};
  await conductor.handleEvent(makeEvent("session.start", "sess-retrieve", { memoryUserKey: "carol" }), emit);
  await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess-retrieve", { text: "What should I do next?" }), emit);

  assert.equal(retrieveCalled, true, "retrieveResumeContext should be called on first turn");
});

// --- Finalization fallback when summarizeAndStore returns null ---

test("finalizeSession fires fallback summary when summarizeAndStore returns null", async () => {
  let finalizedPayload: { summary?: string } | null = null;
  const mockContextGraph = {
    apply: async (update: { type: string; payload?: unknown }) => {
      if (update.type === "session.finalized") {
        finalizedPayload = update.payload as { summary?: string };
      }
    },
    retrieveResumeContext: async () => null,
    summarizeAndStore: async () => null,
  } as unknown as ContextGraphService;

  const conductor = new ConductorService(
    new StubProvider("response"),
    { maxTurns: 10, rateLimitPerMinute: 300 },
    { contextGraphService: mockContextGraph },
  );

  const emit = () => {};
  await conductor.handleEvent(makeEvent("session.start", "sess-fallback", { memoryUserKey: "dave" }), emit);
  await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess-fallback", { text: "First message here" }), emit);
  await conductor.handleEvent(makeEvent("user.audio.transcript.final", "sess-fallback", { text: "Second message here" }), emit);

  await conductor.finalizeSession("sess-fallback");

  // Wait for fire-and-forget apply
  await new Promise((r) => setTimeout(r, 50));

  assert.ok(finalizedPayload, "session.finalized should be fired with fallback summary");
  assert.ok((finalizedPayload as { summary?: string }).summary!.length > 0, "fallback summary should not be empty");
});
