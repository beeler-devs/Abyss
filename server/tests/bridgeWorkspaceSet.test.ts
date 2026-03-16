import test from "node:test";
import assert from "node:assert/strict";
import { BridgeStateStore } from "../src/bridge/state.js";
import { makeEvent } from "../src/core/events.js";

test("resolveDeviceForTool finds device by sessionId for workspace.set authorization", () => {
  const store = new BridgeStateStore();
  store.createPairingRequest("session-ws", "WSSET1", "Mac");
  store.registerBridge({
    pairingCode: "WSSET1", deviceId: "dev-ws", deviceName: "Mac",
    workspaceRoot: "/tmp/ws", capabilities: { execRun: true, readFile: true, claudeRun: false },
  });
  store.markDeviceOnline("dev-ws");

  const resolved = store.resolveDeviceForTool("session-ws", "dev-ws");
  assert.ok(resolved.device);
  assert.equal(resolved.device?.deviceId, "dev-ws");
});

test("resolveDeviceForTool returns no device for unknown deviceId", () => {
  const store = new BridgeStateStore();
  const resolved = store.resolveDeviceForTool("session-x", "nonexistent");
  assert.equal(resolved.device, undefined);
});

test("bridge.workspace.set event has correct wire shape", () => {
  const event = makeEvent("bridge.workspace.set", "session-1", {
    deviceId: "dev-1",
    workspacePath: "/Users/test/myproject",
  });
  assert.equal(event.type, "bridge.workspace.set");
  assert.equal(event.payload.deviceId, "dev-1");
  assert.equal(event.payload.workspacePath, "/Users/test/myproject");
});
