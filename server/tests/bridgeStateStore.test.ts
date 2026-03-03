import test from "node:test";
import assert from "node:assert/strict";

import { BridgeStateStore } from "../src/bridge/state.js";

test("pairing requests expire after TTL", () => {
  let now = Date.parse("2026-03-01T00:00:00.000Z");
  const store = new BridgeStateStore(60_000, () => now);

  store.createPairingRequest("session-1", "ABC123", "Dev Mac");
  assert.equal(store.hasPendingPairingCode("ABC123"), true);

  now += 60_001;
  assert.equal(store.hasPendingPairingCode("ABC123"), false);

  const registration = store.registerBridge({
    pairingCode: "ABC123",
    deviceId: "device-1",
    deviceName: "Dev Mac",
    workspaceRoot: "/tmp/ws",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  assert.equal(registration.device, undefined);
  assert.equal(registration.error, "pairing_code_invalid_or_expired");
});

test("register binds device to requesting session", () => {
  let now = Date.parse("2026-03-01T00:00:00.000Z");
  const store = new BridgeStateStore(5 * 60_000, () => now);

  store.createPairingRequest("session-2", "ZXCV12", "CI Runner");

  now += 500;
  const registration = store.registerBridge({
    pairingCode: "ZXCV12",
    deviceId: "device-ci",
    deviceName: "CI Runner",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  assert.ok(registration.device);
  assert.equal(registration.device?.sessionId, "session-2");
  assert.equal(registration.device?.status, "online");

  const devices = store.getSessionDevices("session-2");
  assert.equal(devices.length, 1);
  assert.equal(devices[0]?.deviceId, "device-ci");

  const offline = store.markDeviceOffline("device-ci");
  assert.equal(offline?.status, "offline");

  const resolve = store.resolveDeviceForTool("session-2");
  assert.equal(resolve.error, "bridge_not_paired");
});

test("claude tool resolves only to claude-capable bridges", () => {
  const store = new BridgeStateStore();
  store.createPairingRequest("session-3", "NOCLD1", "No Claude");
  store.registerBridge({
    pairingCode: "NOCLD1",
    deviceId: "device-no-claude",
    deviceName: "No Claude",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: false },
  });

  const resolve = store.resolveDeviceForTool("session-3", undefined, "bridge.claude.run");
  assert.equal(resolve.error, "bridge_tool_not_supported");
});
