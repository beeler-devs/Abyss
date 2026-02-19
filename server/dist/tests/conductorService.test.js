import test from "node:test";
import assert from "node:assert/strict";
import { ConductorService } from "../src/core/conductorService.js";
import { makeEvent } from "../src/core/events.js";
class StubProvider {
    fullText;
    chunks;
    name = "stub";
    constructor(fullText, chunks) {
        this.fullText = fullText;
        this.chunks = chunks;
    }
    async generateResponse(_conversation) {
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
    const emitted = [];
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
        if (event.payload.name !== "tts.speak")
            return false;
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
    const emitted = [];
    await service.handleEvent(transcriptEvent, (event) => emitted.push(event));
    const firstPartialIndex = emitted.findIndex((event) => event.type === "assistant.speech.partial");
    const finalIndex = emitted.findIndex((event) => event.type === "assistant.speech.final");
    assert.ok(firstPartialIndex >= 0, "expected at least one partial event");
    assert.ok(finalIndex >= 0, "expected a final event");
    assert.ok(firstPartialIndex < finalIndex, "partials must be emitted before final");
});
