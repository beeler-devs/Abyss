import test from "node:test";
import assert from "node:assert/strict";
import { EmbeddingService } from "../src/contextGraph/embedding/embeddingService.js";

const config = {
  modelId: "amazon.titan-embed-text-v2:0",
  dimensions: 256,
  awsRegion: "us-east-1",
};

test("embed returns embedding array from Titan response", async () => {
  const mockBedrock = {
    send: async () => ({
      body: new TextEncoder().encode(JSON.stringify({ embedding: [0.1, 0.2, 0.3] })),
    }),
  };
  const service = new EmbeddingService(config, { bedrock: mockBedrock as never });

  const result = await service.embed("hello world");

  assert.deepEqual(result, [0.1, 0.2, 0.3]);
});

test("embedBatch returns embeddings for multiple texts", async () => {
  let callCount = 0;
  const mockBedrock = {
    send: async () => {
      callCount++;
      return {
        body: new TextEncoder().encode(
          JSON.stringify({ embedding: callCount === 1 ? [0.1, 0.2] : [0.3, 0.4] }),
        ),
      };
    },
  };
  const service = new EmbeddingService(config, { bedrock: mockBedrock as never });

  const results = await service.embedBatch(["text one", "text two"]);

  assert.equal(results.length, 2);
  assert.deepEqual(results[0], [0.1, 0.2]);
  assert.deepEqual(results[1], [0.3, 0.4]);
});

test("embed propagates errors from bedrock client", async () => {
  const mockBedrock = {
    send: async () => {
      throw new Error("Bedrock service unavailable");
    },
  };
  const service = new EmbeddingService(config, { bedrock: mockBedrock as never });

  await assert.rejects(() => service.embed("hello"), {
    message: "Bedrock service unavailable",
  });
});
