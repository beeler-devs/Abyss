import test from "node:test";
import assert from "node:assert/strict";

import { BridgeStateStore } from "../src/bridge/state.js";
import { BridgeToolRouter } from "../src/bridge/toolRouter.js";
import { makeEvent } from "../src/core/events.js";

function setupRouter() {
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
  return state;
}

test("bridge tool routing forwards tool.call and resolves tool.result", async () => {
  const state = setupRouter();
  let forwardedCallId = "";
  const emitted: string[] = [];

  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      forwardedCallId = String(event.payload.callId);
      setImmediate(() => {
        router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
          callId: String(event.payload.callId),
          result: JSON.stringify({ content: "ok" }),
          error: null,
        }), "device-bridge");
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
    toolName: "bridge.fs.readFile",
    args: { path: "README.md" },
    timeoutMs: 200,
  });

  assert.equal(forwardedCallId, "call-1");
  assert.equal(output.error, null);
  assert.ok(output.result?.includes("content"));
  assert.deepEqual(emitted, ["tool.call", "bridge.status", "tool.result"]);
});

test("bridge tool routing returns timeout and marks device offline", async () => {
  const state = setupRouter();

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
    sessionId: "session-bridge",
    toolName: "bridge.fs.readFile",
    args: { path: "README.md" },
    timeoutMs: 30,
  });

  assert.equal(output.result, null);
  assert.equal(output.error, "bridge_tool_timeout");

  const statusEvent = emitted.find((event) => event.type === "bridge.status");
  assert.ok(statusEvent);
  assert.equal(statusEvent?.payload.status, "offline");
});

test("bridge.exec.run compatibility path forwards stream and resolves after finished", async () => {
  const state = setupRouter();
  const emitted: Array<{ type: string; payload: Record<string, unknown> }> = [];

  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      const toolName = String(event.payload.name);
      const callId = String(event.payload.callId);

      if (toolName === "bridge.exec.start") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ commandId: "cmd-1", startedAt: new Date().toISOString() }),
            error: null,
          }), "device-bridge");
          setImmediate(() => {
            router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-bridge", {
              deviceId: "device-bridge",
              commandId: "cmd-1",
              stream: "stdout",
              chunk: "line 1\n",
              isFinal: false,
            }), "device-bridge");

            router.handleBridgeEvent(makeEvent("bridge.exec.finished", "device-bridge", {
              deviceId: "device-bridge",
              commandId: "cmd-1",
              exitCode: 0,
              stdoutTail: "line 1\n",
              stderrTail: "",
            }), "device-bridge");
          });
        });
      }

      return true;
    },
    emitToIOS: (event) => {
      emitted.push({ type: event.type, payload: event.payload });
    },
  });

  const output = await router.execute({
    callId: "call-run",
    sessionId: "session-bridge",
    toolName: "bridge.exec.run",
    args: { command: "echo hi" },
    timeoutMs: 200,
  });

  assert.equal(output.error, null);
  assert.ok(output.result?.includes("exitCode"));

  const outputEvent = emitted.find((event) => event.type === "bridge.exec.output");
  assert.ok(outputEvent);
  const finishedEvent = emitted.find((event) => event.type === "bridge.exec.finished");
  assert.ok(finishedEvent);
  const toolResult = emitted.find((event) => event.type === "tool.result");
  assert.ok(toolResult);
});

test("cancelActiveCommand issues bridge.exec.cancel", async () => {
  const state = setupRouter();
  let sawCancel = false;

  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      const toolName = String(event.payload.name);
      const callId = String(event.payload.callId);
      if (toolName === "bridge.exec.start") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ commandId: "cmd-22", startedAt: new Date().toISOString() }),
            error: null,
          }), "device-bridge");
        });
      }

      if (toolName === "bridge.exec.cancel") {
        sawCancel = true;
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ cancelled: true }),
            error: null,
          }), "device-bridge");
        });
      }

      return true;
    },
    emitToIOS: () => {},
  });

  await router.execute({
    callId: "call-start",
    sessionId: "session-bridge",
    toolName: "bridge.exec.start",
    args: { command: "sleep 1" },
    timeoutMs: 200,
  });

  const cancelled = await router.cancelActiveCommand("session-bridge");
  assert.equal(cancelled, true);
  assert.equal(sawCancel, true);
});

test("bridge.exec.output is routed to paired session", () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-a", "AAAA11", "Mac A");
  state.registerBridge({
    pairingCode: "AAAA11",
    deviceId: "device-a",
    deviceName: "Mac A",
    workspaceRoot: "/workspace-a",
    capabilities: { execRun: true, readFile: true },
  });

  state.createPairingRequest("session-b", "BBBB22", "Mac B");
  state.registerBridge({
    pairingCode: "BBBB22",
    deviceId: "device-b",
    deviceName: "Mac B",
    workspaceRoot: "/workspace-b",
    capabilities: { execRun: true, readFile: true },
  });

  const emitted: Array<{ sessionId: string; type: string }> = [];
  const router = new BridgeToolRouter({
    state,
    sendToBridge: () => true,
    emitToIOS: (event) => {
      emitted.push({ sessionId: event.sessionId, type: event.type });
    },
  });

  const handled = router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-b", {
    deviceId: "device-b",
    commandId: "cmd-77",
    stream: "stdout",
    chunk: "hello",
    isFinal: false,
  }), "device-b");

  assert.equal(handled, true);
  const routed = emitted.find((event) => event.type === "bridge.exec.output");
  assert.ok(routed);
  assert.equal(routed?.sessionId, "session-b");
});
