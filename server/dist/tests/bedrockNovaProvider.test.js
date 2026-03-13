import test from "node:test";
import assert from "node:assert/strict";
import { BedrockNovaProvider } from "../src/providers/bedrockNovaProvider.js";
class FakeBedrockClient {
    response;
    lastCommand = null;
    constructor(response) {
        this.response = response;
    }
    async send(command) {
        this.lastCommand = command;
        return this.response;
    }
}
const TOOLS = [{
        name: "bridge.exec.run",
        description: "Run a shell command.",
        input_schema: {
            type: "object",
            properties: {
                command: { type: "string" },
            },
            required: ["command"],
        },
    }];
test("bedrock provider maps plain text output into chunks", async () => {
    const client = new FakeBedrockClient({
        output: {
            message: {
                content: [{ text: "Hello from Nova." }],
            },
        },
    });
    const provider = new BedrockNovaProvider({
        modelId: "us.amazon.nova-2-lite-v1:0",
        region: "us-east-1",
        maxTokens: 256,
        partialDelayMs: 0,
    }, client);
    const response = await provider.generateResponse([
        { role: "user", content: "Say hello" },
    ]);
    const chunks = [];
    for await (const chunk of response.chunks) {
        chunks.push(chunk);
    }
    assert.equal(response.fullText, "Hello from Nova.");
    assert.equal(chunks.join(""), "Hello from Nova.");
});
test("bedrock provider maps tool use blocks back to original tool names", async () => {
    const client = new FakeBedrockClient({
        output: {
            message: {
                content: [{
                        toolUse: {
                            toolUseId: "tool-1",
                            name: "bridge_exec_run",
                            input: { command: "npm test" },
                        },
                    }],
            },
        },
    });
    const provider = new BedrockNovaProvider({
        modelId: "us.amazon.nova-2-lite-v1:0",
        region: "us-east-1",
        maxTokens: 256,
        partialDelayMs: 0,
    }, client);
    const response = await provider.generateResponse([
        { role: "user", content: "Run the tests" },
    ], TOOLS);
    assert.deepEqual(response.toolCalls, [{
            id: "tool-1",
            name: "bridge.exec.run",
            input: { command: "npm test" },
        }]);
    const input = client.lastCommand?.input;
    assert.ok(input);
    assert.equal(input?.modelId, "us.amazon.nova-2-lite-v1:0");
    assert.equal(input?.toolConfig?.tools?.[0]?.toolSpec?.name, "bridge_exec_run");
});
test("bedrock provider turns tool results into user toolResult blocks", async () => {
    const client = new FakeBedrockClient({
        output: {
            message: {
                content: [{ text: "Done." }],
            },
        },
    });
    const provider = new BedrockNovaProvider({
        modelId: "us.amazon.nova-2-lite-v1:0",
        region: "us-east-1",
        maxTokens: 256,
        partialDelayMs: 0,
    }, client);
    const conversation = [
        { role: "user", content: "Run the tests" },
        {
            role: "assistant",
            content: [{ id: "tool-1", name: "bridge.exec.run", input: { command: "npm test" } }],
        },
        {
            role: "tool",
            tool_use_id: "tool-1",
            tool_name: "bridge.exec.run",
            content: JSON.stringify({ ok: true }),
        },
    ];
    await provider.generateResponse(conversation, TOOLS);
    const input = client.lastCommand?.input;
    const toolResultMessage = input?.messages?.[2];
    const toolResult = toolResultMessage?.content?.[0]?.toolResult;
    assert.equal(toolResultMessage?.role, "user");
    assert.equal(toolResult?.toolUseId, "tool-1");
    assert.deepEqual(toolResult?.content?.[0]?.json, { ok: true });
});
