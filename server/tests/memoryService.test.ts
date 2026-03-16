import test from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";

import { MemoryService, MemoryServiceConfig } from "../src/core/memory/memoryService.js";
import { ConversationTurn } from "../src/core/types.js";

// Helper: base config with memory enabled
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

// Helper: build a 3-turn user history
function threeUserTurns(): ConversationTurn[] {
  return [
    { role: "user", content: "Hello" },
    { role: "assistant", content: "Hi" },
    { role: "user", content: "Fix the auth bug" },
    { role: "assistant", content: "Sure" },
    { role: "user", content: "Done?" },
  ];
}

test("summarizeAndStore skips sessions with fewer than 3 user turns and no tools/keywords", async () => {
  let putObjectCalled = false;
  const mockS3 = {
    send: async (cmd: unknown) => {
      const c = cmd as { constructor: { name: string } };
      if (c.constructor.name === "PutObjectCommand") putObjectCalled = true;
      return {};
    },
  };

  const service = new MemoryService(makeConfig(), { s3: mockS3 as never });
  const history: ConversationTurn[] = [
    { role: "user", content: "Hi" },
    { role: "assistant", content: "Hello" },
  ];

  await service.summarizeAndStore("user1", "sess1", history);
  assert.equal(putObjectCalled, false, "should not write to S3 for short session");
});

test("summarizeAndStore writes JSON to S3 for meaningful session", async () => {
  let putBody = "";
  const mockS3 = {
    send: async (cmd: unknown) => {
      const c = cmd as { input?: { Body?: string } };
      if (c.input?.Body !== undefined) putBody = c.input.Body as string;
      return {};
    },
  };

  // Bedrock returns a valid summary
  const mockBedrock = {
    send: async () => ({
      body: new TextEncoder().encode(JSON.stringify({
        output: {
          message: {
            content: [{ text: '{"summary":"Fixed auth bug","decisions":["Use JWT"],"blockers":[],"nextSteps":["Deploy"]}' }],
          },
        },
      })),
    }),
  };

  const service = new MemoryService(makeConfig(), { s3: mockS3 as never, bedrock: mockBedrock as never });
  const result = await service.summarizeAndStore("user1", "sess1", threeUserTurns());
  assert.ok(result !== null, "should return MemoryDocument");
  assert.equal(result!.memoryUserKey, "user1");
  assert.ok(result!.summary.length > 0, "returned doc should have summary");

  assert.ok(putBody.length > 0, "should write to S3");
  const doc = JSON.parse(putBody) as { summary: string; memoryUserKey: string };
  assert.equal(doc.memoryUserKey, "user1");
  assert.ok(doc.summary.length > 0, "summary should be non-empty");
});

test("summarizeAndStore triggers KB ingestion when knowledgeBaseId and knowledgeBaseDataSourceId are configured", async () => {
  let ingestionTriggered = false;
  const mockS3 = { send: async () => ({}) };
  const mockBedrock = {
    send: async () => ({
      body: new TextEncoder().encode(JSON.stringify({
        output: { message: { content: [{ text: '{"summary":"test","decisions":[],"blockers":[],"nextSteps":[]}' }] } },
      })),
    }),
  };
  const mockBedrockAgent = {
    send: async () => { ingestionTriggered = true; return {}; },
  };

  const service = new MemoryService(
    makeConfig({ knowledgeBaseId: "kb-123", knowledgeBaseDataSourceId: "ds-456" }),
    { s3: mockS3 as never, bedrock: mockBedrock as never, bedrockAgent: mockBedrockAgent as never },
  );

  await service.summarizeAndStore("user1", "sess1", threeUserTurns());
  // KB ingestion is fire-and-forget, allow microtask flush
  await new Promise((r) => setImmediate(r));
  assert.equal(ingestionTriggered, true, "should trigger KB ingestion");
});

test("retrieveContext returns null when disabled", async () => {
  const service = new MemoryService(makeConfig({ enabled: false }));
  const result = await service.retrieveContext({ memoryUserKey: "user1" });
  assert.equal(result, null);
});

test("retrieveContext returns formatted context from recent S3 memories", async () => {
  const doc = {
    memoryUserKey: "user1",
    sessionId: "sess-old",
    timestamp: new Date(Date.now() - 86400000).toISOString(),
    summary: "Fixed the auth bug using JWT tokens.",
    repo: "org/repo",
    branch: "main",
    nextSteps: ["Deploy to staging"],
  };

  const mockS3 = {
    send: async (cmd: unknown) => {
      const c = cmd as { constructor: { name: string } };
      if (c.constructor.name === "ListObjectsV2Command") {
        return {
          Contents: [{
            Key: "memories/user1/2024-01-01T00-00-00-000Z-sess-old.json",
            LastModified: new Date(Date.now() - 86400000),
          }],
        };
      }
      if (c.constructor.name === "GetObjectCommand") {
        const readable = new Readable();
        readable.push(JSON.stringify(doc));
        readable.push(null);
        return { Body: readable };
      }
      return {};
    },
  };

  const service = new MemoryService(makeConfig(), { s3: mockS3 as never });
  const result = await service.retrieveContext({ memoryUserKey: "user1" });
  assert.ok(result !== null, "should return context");
  assert.ok(result!.startsWith("Prior context:"), "should start with 'Prior context:'");
  assert.ok(result!.includes("Fixed the auth"), "should include summary text");
});

test("retrieveContext truncates injected context to maxInjectedChars", async () => {
  const longSummary = "A".repeat(1000);
  const doc = {
    memoryUserKey: "user1",
    sessionId: "sess-old",
    timestamp: new Date().toISOString(),
    summary: longSummary,
  };

  const mockS3 = {
    send: async (cmd: unknown) => {
      const c = cmd as { constructor: { name: string } };
      if (c.constructor.name === "ListObjectsV2Command") {
        return {
          Contents: [{ Key: "memories/user1/key.json", LastModified: new Date() }],
        };
      }
      if (c.constructor.name === "GetObjectCommand") {
        const readable = new Readable();
        readable.push(JSON.stringify(doc));
        readable.push(null);
        return { Body: readable };
      }
      return {};
    },
  };

  const service = new MemoryService(makeConfig({ maxInjectedChars: 100 }), { s3: mockS3 as never });
  const result = await service.retrieveContext({ memoryUserKey: "user1" });
  assert.ok(result !== null);
  assert.ok(result!.length <= 100, `context should be <= 100 chars, got ${result!.length}`);
});

test("retrieveContext returns null when S3 list is empty", async () => {
  const mockS3 = {
    send: async () => ({ Contents: [] }),
  };
  const service = new MemoryService(makeConfig(), { s3: mockS3 as never });
  const result = await service.retrieveContext({ memoryUserKey: "user1" });
  assert.equal(result, null);
});

test("retrieveContext returns null when S3 list exceeds timeout", async () => {
  const mockS3 = {
    send: async () => new Promise<never>(() => { /* never resolves */ }),
  };

  const service = new MemoryService(makeConfig({ retrieveTimeoutMs: 50 }), { s3: mockS3 as never });
  const start = Date.now();
  const result = await service.retrieveContext({ memoryUserKey: "user1" });
  const elapsed = Date.now() - start;

  assert.equal(result, null, "should return null on timeout");
  assert.ok(elapsed < 500, `should resolve within 500ms, took ${elapsed}ms`);
});

test("summarizeAndStore returns null for non-meaningful session", async () => {
  const service = new MemoryService(makeConfig(), { s3: { send: async () => ({}) } as never });
  const result = await service.summarizeAndStore("user1", "sess1", [
    { role: "user", content: "Hi" },
    { role: "assistant", content: "Hello" },
  ]);
  assert.equal(result, null, "should return null for short session");
});
