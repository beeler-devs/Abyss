export type BridgeDeviceStatus = "online" | "offline";

export interface BridgeCapabilities {
  execRun: boolean;
  readFile: boolean;
}

export interface PairingRequest {
  pairingCode: string;
  sessionId: string;
  deviceName?: string;
  requestedAt: string;
  expiresAt: string;
}

export interface BridgeRegistration {
  pairingCode: string;
  deviceId: string;
  deviceName: string;
  workspaceRoot: string;
  capabilities: BridgeCapabilities;
}

export interface BridgeDeviceRecord {
  deviceId: string;
  sessionId: string;
  deviceName: string;
  workspaceRoot: string;
  capabilities: BridgeCapabilities;
  status: BridgeDeviceStatus;
  lastSeen: string;
}

interface PairingRequestInternal extends PairingRequest {
  expiresAtMs: number;
}

export interface ResolveDeviceResult {
  device?: BridgeDeviceRecord;
  error?: string;
  selectionRequired?: Array<{
    deviceId: string;
    deviceName: string;
    status: BridgeDeviceStatus;
    lastSeen: string;
  }>;
}

export class BridgeStateStore {
  private readonly pendingPairingCodes = new Map<string, PairingRequestInternal>();
  private readonly devicesById = new Map<string, BridgeDeviceRecord>();
  private readonly sessionToDeviceIds = new Map<string, Set<string>>();
  private readonly pairingTtlMs: number;
  private readonly nowMs: () => number;

  constructor(pairingTtlMs: number = 5 * 60_000, nowMs: () => number = () => Date.now()) {
    this.pairingTtlMs = pairingTtlMs;
    this.nowMs = nowMs;
  }

  createPairingRequest(sessionId: string, pairingCode: string, deviceName?: string): PairingRequest {
    this.prunePendingPairings();

    const normalizedCode = normalizePairingCode(pairingCode);
    const now = this.nowMs();
    const expiresAtMs = now + this.pairingTtlMs;

    const request: PairingRequestInternal = {
      pairingCode: normalizedCode,
      sessionId,
      deviceName,
      requestedAt: new Date(now).toISOString(),
      expiresAt: new Date(expiresAtMs).toISOString(),
      expiresAtMs,
    };

    this.pendingPairingCodes.set(normalizedCode, request);
    return request;
  }

  registerBridge(registration: BridgeRegistration): { device?: BridgeDeviceRecord; error?: string } {
    this.prunePendingPairings();

    const normalizedCode = normalizePairingCode(registration.pairingCode);
    const pairing = this.pendingPairingCodes.get(normalizedCode);

    // Allow already-paired devices to re-register using their existing session
    const existing = this.devicesById.get(registration.deviceId);
    if (!pairing && !existing) {
      return { error: "pairing_code_invalid_or_expired" };
    }

    if (pairing) {
      this.pendingPairingCodes.delete(normalizedCode);
    }

    const nowIso = new Date(this.nowMs()).toISOString();
    const previousSessionId = existing?.sessionId;

    const device: BridgeDeviceRecord = {
      deviceId: registration.deviceId,
      sessionId: pairing?.sessionId ?? existing!.sessionId,
      deviceName: registration.deviceName,
      workspaceRoot: registration.workspaceRoot,
      capabilities: registration.capabilities,
      status: "online",
      lastSeen: nowIso,
    };

    this.devicesById.set(device.deviceId, device);

    if (previousSessionId && previousSessionId !== device.sessionId) {
      const previousSet = this.sessionToDeviceIds.get(previousSessionId);
      previousSet?.delete(device.deviceId);
      if (previousSet && previousSet.size === 0) {
        this.sessionToDeviceIds.delete(previousSessionId);
      }
    }

    const set = this.sessionToDeviceIds.get(device.sessionId) ?? new Set<string>();
    set.add(device.deviceId);
    this.sessionToDeviceIds.set(device.sessionId, set);

    return { device };
  }

  markDeviceOnline(deviceId: string): BridgeDeviceRecord | undefined {
    const existing = this.devicesById.get(deviceId);
    if (!existing) {
      return undefined;
    }

    const updated: BridgeDeviceRecord = {
      ...existing,
      status: "online",
      lastSeen: new Date(this.nowMs()).toISOString(),
    };
    this.devicesById.set(deviceId, updated);
    return updated;
  }

  markDeviceOffline(deviceId: string): BridgeDeviceRecord | undefined {
    const existing = this.devicesById.get(deviceId);
    if (!existing) {
      return undefined;
    }

    const updated: BridgeDeviceRecord = {
      ...existing,
      status: "offline",
      lastSeen: new Date(this.nowMs()).toISOString(),
    };
    this.devicesById.set(deviceId, updated);
    return updated;
  }

  getDevice(deviceId: string): BridgeDeviceRecord | undefined {
    return this.devicesById.get(deviceId);
  }

  getSessionDevices(sessionId: string): BridgeDeviceRecord[] {
    const ids = this.sessionToDeviceIds.get(sessionId);
    if (!ids) {
      return [];
    }

    return [...ids]
      .map((id) => this.devicesById.get(id))
      .filter((device): device is BridgeDeviceRecord => Boolean(device))
      .sort((left, right) => left.deviceName.localeCompare(right.deviceName));
  }

  resolveDeviceForTool(sessionId: string, requestedDeviceId?: string): ResolveDeviceResult {
    const devices = this.getSessionDevices(sessionId);
    const onlineDevices = devices.filter((device) => device.status === "online");

    if (requestedDeviceId) {
      const requested = devices.find((device) => device.deviceId === requestedDeviceId);
      if (!requested) {
        return { error: "bridge_device_not_paired" };
      }
      if (requested.status !== "online") {
        return { error: "bridge_device_offline" };
      }
      return { device: requested };
    }

    if (onlineDevices.length === 0) {
      return { error: "bridge_not_paired" };
    }

    if (onlineDevices.length === 1) {
      return { device: onlineDevices[0] };
    }

    return {
      error: "bridge_device_selection_required",
      selectionRequired: onlineDevices.map((device) => ({
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        status: device.status,
        lastSeen: device.lastSeen,
      })),
    };
  }

  prunePendingPairings(): void {
    const now = this.nowMs();
    for (const [code, pairing] of this.pendingPairingCodes.entries()) {
      if (pairing.expiresAtMs <= now) {
        this.pendingPairingCodes.delete(code);
      }
    }
  }

  hasPendingPairingCode(pairingCode: string): boolean {
    this.prunePendingPairings();
    return this.pendingPairingCodes.has(normalizePairingCode(pairingCode));
  }
}

function normalizePairingCode(code: string): string {
  return code.trim().toUpperCase();
}
