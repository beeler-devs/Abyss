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
    capabilities: { execRun: true, readFile: true },
  });
  assert.ok(registration.device);

  let forwardedCallId = "";
  const emitted: string[] = [];
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

test("bridge tool routing returns timeout and marks device offline", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-timeout", "TIME22", "Timeout Mac");
  const registration = state.registerBridge({
    pairingCode: "TIME22",
    deviceId: "device-timeout",
    deviceName: "Timeout Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true },
  });
  assert.ok(registration.device);

  const emitted: Array<{ type: string; payload: Record<string, unknown> }> = [];
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
