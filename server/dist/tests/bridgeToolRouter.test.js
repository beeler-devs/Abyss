import test from "node:test";
import assert from "node:assert/strict";
import { BridgeStateStore } from "../src/bridge/state.js";
import { BridgeToolRouter } from "../src/bridge/toolRouter.js";
import { makeEvent } from "../src/core/events.js";
test("bridge tool routing forwards tool.call and resolves tool.result", async () => {
    const state = new BridgeStateStore();
    state.createPairingRequest("session-bridge", "PAIR77", "Mac");
    const registration = state.registerBridge({
        pairingCode: "PAIR77",
        deviceId: "device-bridge",
        deviceName: "Mac",
        workspaceRoot: "/workspace",
        capabilities: { execRun: true, readFile: true, claudeRun: true },
    });
    assert.ok(registration.device);
    let forwardedCallId = "";
    const emitted = [];
    const router = new BridgeToolRouter({
        state,
        sendToBridge: (_deviceId, event) => {
            forwardedCallId = String(event.payload.callId);
            setImmediate(() => {
                router.handleBridgeToolResult(makeEvent("tool.result", "bridge-session", {
                    callId: String(event.payload.callId),
                    result: JSON.stringify({ exitCode: 0, stdout: "ok", stderr: "" }),
                    error: null,
                }));
            });
            return true;
        },
        emitToIOS: (event) => {
            emitted.push(event.type);
        },
    });
    const output = await router.execute({
        callId: "call-1",
        sessionId: "session-bridge",
        toolName: "bridge.exec.run",
        args: { command: "echo ok" },
        timeoutMs: 200,
    });
    assert.equal(forwardedCallId, "call-1");
    assert.equal(output.error, null);
    assert.ok(output.result?.includes("exitCode"));
    assert.deepEqual(emitted, ["tool.call", "bridge.status", "tool.result"]);
});
test("bridge.claude.run routes through bridge tool router", async () => {
    const state = new BridgeStateStore();
    state.createPairingRequest("session-claude", "CLAUD1", "Claude Mac");
    const registration = state.registerBridge({
        pairingCode: "CLAUD1",
        deviceId: "device-claude",
        deviceName: "Claude Mac",
        workspaceRoot: "/workspace",
        capabilities: { execRun: true, readFile: true, claudeRun: true },
    });
    assert.ok(registration.device);
    let forwardedToolName = "";
    const emitted = [];
    const router = new BridgeToolRouter({
        state,
        sendToBridge: (_deviceId, event) => {
            forwardedToolName = String(event.payload.name);
            setImmediate(() => {
                router.handleBridgeToolResult(makeEvent("tool.result", "bridge-session", {
                    callId: String(event.payload.callId),
                    result: JSON.stringify({ result: "Fixed the failing test", sessionId: null }),
                    error: null,
                }));
            });
            return true;
        },
        emitToIOS: (event) => {
            emitted.push(event.type);
        },
    });
    const output = await router.execute({
        callId: "call-claude-1",
        sessionId: "session-claude",
        toolName: "bridge.claude.run",
        args: { prompt: "fix the failing test" },
        timeoutMs: 200,
    });
    assert.equal(forwardedToolName, "bridge.claude.run");
    assert.equal(output.error, null);
    assert.ok(output.result?.includes("Fixed the failing test"));
});
test("bridge.claude.run rejects devices without claude capability", async () => {
    const state = new BridgeStateStore();
    state.createPairingRequest("session-claude-cap", "CAP111", "No Claude Mac");
    const registration = state.registerBridge({
        pairingCode: "CAP111",
        deviceId: "device-no-claude",
        deviceName: "No Claude Mac",
        workspaceRoot: "/workspace",
        capabilities: { execRun: true, readFile: true, claudeRun: false },
    });
    assert.ok(registration.device);
    const router = new BridgeToolRouter({
        state,
        sendToBridge: () => true,
        emitToIOS: () => undefined,
    });
    const output = await router.execute({
        callId: "call-claude-cap-1",
        sessionId: "session-claude-cap",
        toolName: "bridge.claude.run",
        args: { prompt: "fix the failing test" },
        timeoutMs: 200,
    });
    assert.equal(output.result, null);
    assert.equal(output.error, "bridge_tool_not_supported");
});
test("bridge tool routing returns timeout and marks device offline", async () => {
    const state = new BridgeStateStore();
    state.createPairingRequest("session-timeout", "TIME22", "Timeout Mac");
    const registration = state.registerBridge({
        pairingCode: "TIME22",
        deviceId: "device-timeout",
        deviceName: "Timeout Mac",
        workspaceRoot: "/workspace",
        capabilities: { execRun: true, readFile: true, claudeRun: true },
    });
    assert.ok(registration.device);
    const emitted = [];
    const router = new BridgeToolRouter({
        state,
        sendToBridge: () => true,
        emitToIOS: (event) => {
            emitted.push({ type: event.type, payload: event.payload });
        },
    });
    const output = await router.execute({
        callId: "call-timeout",
        sessionId: "session-timeout",
        toolName: "bridge.exec.run",
        args: { command: "sleep 2" },
        timeoutMs: 30,
    });
    assert.equal(output.result, null);
    assert.equal(output.error, "bridge_tool_timeout");
    const statusEvent = emitted.find((event) => event.type === "bridge.status");
    assert.ok(statusEvent);
    assert.equal(statusEvent?.payload.status, "offline");
});
