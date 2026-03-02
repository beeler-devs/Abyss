import { makeEvent } from "../core/events.js";
import { EventEnvelope } from "../core/types.js";
import { BridgeStateStore } from "./state.js";

interface PendingBridgeCall {
  callId: string;
  sessionId: string;
  deviceId: string;
  resolve: (result: { result: string | null; error: string | null }) => void;
  timer: NodeJS.Timeout;
}

export interface BridgeToolRouteRequest {
  callId: string;
  sessionId: string;
  toolName: string;
  args: Record<string, unknown>;
  timeoutMs: number;
}

export interface BridgeToolRouterDependencies {
  state: BridgeStateStore;
  sendToBridge: (deviceId: string, event: EventEnvelope) => boolean;
  emitToIOS: (event: EventEnvelope) => void;
}

export class BridgeToolRouter {
  private readonly state: BridgeStateStore;
  private readonly sendToBridge: (deviceId: string, event: EventEnvelope) => boolean;
  private readonly emitToIOS: (event: EventEnvelope) => void;
  private readonly pendingByCallId = new Map<string, PendingBridgeCall>();

  constructor(deps: BridgeToolRouterDependencies) {
    this.state = deps.state;
    this.sendToBridge = deps.sendToBridge;
    this.emitToIOS = deps.emitToIOS;
  }

  async execute(request: BridgeToolRouteRequest): Promise<{ result: string | null; error: string | null }> {
    const requestedDeviceId = optionalString(request.args.deviceId);
    const resolved = this.state.resolveDeviceForTool(request.sessionId, requestedDeviceId);

    if (!resolved.device) {
      if (resolved.selectionRequired?.length) {
        this.emitToIOS(makeEvent("bridge.device.selection.required", request.sessionId, {
          devices: resolved.selectionRequired,
        }));
      }

      this.emitToIOS(makeEvent("tool.result", request.sessionId, {
        callId: request.callId,
        result: null,
        error: resolved.error ?? "bridge_routing_failed",
      }));

      return { result: null, error: resolved.error ?? "bridge_routing_failed" };
    }

    const outbound = makeEvent("tool.call", request.sessionId, {
      callId: request.callId,
      name: request.toolName,
      arguments: JSON.stringify(request.args),
    });

    this.emitToIOS(outbound);

    if (!this.sendToBridge(resolved.device.deviceId, outbound)) {
      this.markOfflineAndEmitStatus(resolved.device.deviceId, request.sessionId);
      const error = "bridge_connection_unavailable";
      this.emitToIOS(makeEvent("tool.result", request.sessionId, {
        callId: request.callId,
        result: null,
        error,
      }));
      return { result: null, error };
    }

    return await new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pendingByCallId.delete(request.callId);
        this.markOfflineAndEmitStatus(resolved.device!.deviceId, request.sessionId);

        const timeoutError = "bridge_tool_timeout";
        this.emitToIOS(makeEvent("tool.result", request.sessionId, {
          callId: request.callId,
          result: null,
          error: timeoutError,
        }));

        resolve({ result: null, error: timeoutError });
      }, request.timeoutMs);

      this.pendingByCallId.set(request.callId, {
        callId: request.callId,
        sessionId: request.sessionId,
        deviceId: resolved.device!.deviceId,
        timer,
        resolve,
      });
    });
  }

  handleBridgeToolResult(event: EventEnvelope): boolean {
    if (event.type !== "tool.result") {
      return false;
    }

    const callId = optionalString(event.payload.callId);
    if (!callId) {
      return false;
    }

    const pending = this.pendingByCallId.get(callId);
    if (!pending) {
      return false;
    }

    this.pendingByCallId.delete(callId);
    clearTimeout(pending.timer);

    const resultPayload = optionalString(event.payload.result) ?? null;
    const errorPayload = optionalString(event.payload.error) ?? null;

    this.state.markDeviceOnline(pending.deviceId);
    this.emitToIOS(makeEvent("bridge.status", pending.sessionId, {
      deviceId: pending.deviceId,
      status: "online",
      lastSeen: new Date().toISOString(),
    }));

    this.emitToIOS(makeEvent("tool.result", pending.sessionId, {
      callId,
      result: resultPayload,
      error: errorPayload,
    }));

    pending.resolve({
      result: resultPayload,
      error: errorPayload,
    });

    return true;
  }

  failPendingForDevice(deviceId: string): void {
    const pendingCalls = [...this.pendingByCallId.values()].filter((pending) => pending.deviceId === deviceId);
    for (const pending of pendingCalls) {
      this.pendingByCallId.delete(pending.callId);
      clearTimeout(pending.timer);
      const error = "bridge_device_disconnected";
      this.emitToIOS(makeEvent("tool.result", pending.sessionId, {
        callId: pending.callId,
        result: null,
        error,
      }));
      pending.resolve({ result: null, error });
    }
  }

  private markOfflineAndEmitStatus(deviceId: string, sessionId: string): void {
    const updated = this.state.markDeviceOffline(deviceId);
    if (!updated) {
      return;
    }
    this.emitToIOS(makeEvent("bridge.status", sessionId, {
      deviceId: updated.deviceId,
      status: "offline",
      lastSeen: updated.lastSeen,
    }));
  }
}

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}
