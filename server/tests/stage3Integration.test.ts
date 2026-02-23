import test from "node:test";
import assert from "node:assert/strict";

import { ConductorService } from "../src/core/conductorService.js";
import { makeEvent } from "../src/core/events.js";
import { ConversationTurn, ModelProvider, ModelResponse, ToolCallRequest } from "../src/core/types.js";
import { ToolRegistry } from "../src/stage3/tools/registry.js";

class SequenceProvider implements ModelProvider {
  readonly name = "sequence";
  private step = 0;

  async generateResponse(_conversation: ConversationTurn[]): Promise<ModelResponse> {
    this.step += 1;

    if (this.step === 1) {
      const toolCalls: ToolCallRequest[] = [
        {
          id: "tool-1",
          name: "github.repo.getDefaultBranch",
          input: { repo: "acme/repo" },
        },
        {
          id: "tool-2",
          name: "ci.checks.list",
          input: { repo: "acme/repo", prNumber: 12 },
        },
        {
          id: "tool-3",
          name: "patch.validate",
          input: {
            unifiedDiff: "--- a/src/sum.ts\n+++ b/src/sum.ts\n@@ -1,1 +1,1 @@\n-return 1;\n+return 2;",
            constraints: { allowedPaths: ["src/"] },
          },
        },
      ];

      return {
        fullText: "",
        chunks: (async function* chunks() {
          yield "";
        })(),
        toolCalls,
      };
    }

    return {
      fullText: "Done. I checked CI and validated a patch candidate.",
      chunks: (async function* chunks() {
        yield "Done.";
      })(),
    };
  }
}

function buildTestRegistry(): ToolRegistry {
  const registry = new ToolRegistry();
  registry.registerMany([
    {
      definition: {
        name: "github.repo.getDefaultBranch",
        description: "test",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
          },
          required: ["repo"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async () => ({ defaultBranch: "main" }),
    },
    {
      definition: {
        name: "ci.checks.list",
        description: "test",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            prNumber: { type: "number" },
          },
          required: ["repo", "prNumber"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async () => ({ checks: [{ name: "test", status: "completed", conclusion: "failure" }] }),
    },
    {
      definition: {
        name: "patch.validate",
        description: "test",
        input_schema: {
          type: "object",
          properties: {
            unifiedDiff: { type: "string" },
            constraints: { type: "object" },
          },
          required: ["unifiedDiff", "constraints"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async () => ({ ok: true, violations: [] }),
    },
    {
      definition: {
        name: "convo.appendMessage",
        description: "test",
        input_schema: {
          type: "object",
          properties: {
            role: { type: "string" },
            text: { type: "string" },
          },
          required: ["role", "text"],
        },
      },
      target: "client",
      sideEffect: "write",
    },
    {
      definition: {
        name: "convo.setState",
        description: "test",
        input_schema: {
          type: "object",
          properties: {
            state: { type: "string" },
          },
          required: ["state"],
        },
      },
      target: "client",
      sideEffect: "write",
    },
    {
      definition: {
        name: "tts.speak",
        description: "test",
        input_schema: {
          type: "object",
          properties: {
            text: { type: "string" },
          },
          required: ["text"],
        },
      },
      target: "client",
      sideEffect: "execute",
    },
  ]);
  return registry;
}

test("transcript.final triggers server tool chain for github/ci/patch before final response", async () => {
  const provider = new SequenceProvider();
  const service = new ConductorService(provider, {
    maxTurns: 20,
    rateLimitPerMinute: 100,
    toolRegistry: buildTestRegistry(),
  });

  const transcriptEvent = makeEvent("user.audio.transcript.final", "session-stage3", {
    text: "run tests and fix it",
    timestamp: new Date().toISOString(),
    sessionId: "session-stage3",
  });

  const emitted: ReturnType<typeof makeEvent>[] = [];
  await service.handleEvent(transcriptEvent, (event) => emitted.push(event));

  const statusDetails = emitted
    .filter((event) => event.type === "agent.status")
    .map((event) => String(event.payload.detail ?? ""));

  assert.ok(statusDetails.some((detail) => detail.includes("github.repo.getDefaultBranch")));
  assert.ok(statusDetails.some((detail) => detail.includes("ci.checks.list")));
  assert.ok(statusDetails.some((detail) => detail.includes("patch.validate")));

  const finalSpeech = emitted.find((event) => event.type === "assistant.speech.final");
  assert.ok(finalSpeech, "expected assistant final response");
});
