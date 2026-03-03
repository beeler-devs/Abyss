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
    capabilities: { execRun: true, readFile: true },
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
    capabilities: { execRun: true, readFile: true },
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

test("resolveDeviceForTool falls back to single global online device for new session", () => {
  const store = new BridgeStateStore();

  store.createPairingRequest("session-original", "ABC999", "Dev Mac");
  const registration = store.registerBridge({
    pairingCode: "ABC999",
    deviceId: "device-one",
    deviceName: "Dev Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true },
  });
  assert.ok(registration.device);

  const resolve = store.resolveDeviceForTool("session-new-after-reconnect");
  assert.equal(resolve.error, undefined);
  assert.equal(resolve.device?.deviceId, "device-one");
  assert.equal(resolve.device?.sessionId, "session-new-after-reconnect");
  assert.equal(store.getSessionDevices("session-original").length, 0);
  assert.equal(store.getSessionDevices("session-new-after-reconnect")[0]?.deviceId, "device-one");
});

test("resolveDeviceForTool allows explicit deviceId across session churn", () => {
  const store = new BridgeStateStore();

  store.createPairingRequest("session-original", "XYZ123", "Dev Mac");
  const registration = store.registerBridge({
    pairingCode: "XYZ123",
    deviceId: "device-explicit",
    deviceName: "Dev Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true },
  });
  assert.ok(registration.device);

  const resolve = store.resolveDeviceForTool("session-new", "device-explicit");
  assert.equal(resolve.error, undefined);
  assert.equal(resolve.device?.deviceId, "device-explicit");
  assert.equal(resolve.device?.sessionId, "session-new");
  assert.equal(store.getSessionDevices("session-original").length, 0);
  assert.equal(store.getSessionDevices("session-new")[0]?.deviceId, "device-explicit");
});
