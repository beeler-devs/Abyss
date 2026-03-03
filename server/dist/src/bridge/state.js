export class BridgeStateStore {
    pendingPairingCodes = new Map();
    devicesById = new Map();
    sessionToDeviceIds = new Map();
    pairingTtlMs;
    nowMs;
    constructor(pairingTtlMs = 5 * 60_000, nowMs = () => Date.now()) {
        this.pairingTtlMs = pairingTtlMs;
        this.nowMs = nowMs;
    }
    createPairingRequest(sessionId, pairingCode, deviceName) {
        this.prunePendingPairings();
        const normalizedCode = normalizePairingCode(pairingCode);
        const now = this.nowMs();
        const expiresAtMs = now + this.pairingTtlMs;
        const request = {
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
    registerBridge(registration) {
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
        const device = {
            deviceId: registration.deviceId,
            sessionId: pairing?.sessionId ?? existing.sessionId,
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
        const set = this.sessionToDeviceIds.get(device.sessionId) ?? new Set();
        set.add(device.deviceId);
        this.sessionToDeviceIds.set(device.sessionId, set);
        return { device };
    }
    markDeviceOnline(deviceId) {
        const existing = this.devicesById.get(deviceId);
        if (!existing) {
            return undefined;
        }
        const updated = {
            ...existing,
            status: "online",
            lastSeen: new Date(this.nowMs()).toISOString(),
        };
        this.devicesById.set(deviceId, updated);
        return updated;
    }
    markDeviceOffline(deviceId) {
        const existing = this.devicesById.get(deviceId);
        if (!existing) {
            return undefined;
        }
        const updated = {
            ...existing,
            status: "offline",
            lastSeen: new Date(this.nowMs()).toISOString(),
        };
        this.devicesById.set(deviceId, updated);
        return updated;
    }
    getDevice(deviceId) {
        return this.devicesById.get(deviceId);
    }
    getSessionDevices(sessionId) {
        const ids = this.sessionToDeviceIds.get(sessionId);
        if (!ids) {
            return [];
        }
        return [...ids]
            .map((id) => this.devicesById.get(id))
            .filter((device) => Boolean(device))
            .sort((left, right) => left.deviceName.localeCompare(right.deviceName));
    }
    resolveDeviceForTool(sessionId, requestedDeviceId, toolName) {
        const devices = this.getSessionDevices(sessionId);
        const onlineDevices = devices.filter((device) => device.status === "online");
        const capableDevices = onlineDevices.filter((device) => supportsTool(device.capabilities, toolName));
        if (requestedDeviceId) {
            const requested = devices.find((device) => device.deviceId === requestedDeviceId);
            if (!requested) {
                return { error: "bridge_device_not_paired" };
            }
            if (requested.status !== "online") {
                return { error: "bridge_device_offline" };
            }
            if (!supportsTool(requested.capabilities, toolName)) {
                return { error: "bridge_tool_not_supported_on_device" };
            }
            return { device: requested };
        }
        if (onlineDevices.length === 0) {
            return { error: "bridge_not_paired" };
        }
        if (capableDevices.length === 0) {
            return { error: "bridge_tool_not_supported" };
        }
        if (capableDevices.length === 1) {
            return { device: capableDevices[0] };
        }
        return {
            error: "bridge_device_selection_required",
            selectionRequired: capableDevices.map((device) => ({
                deviceId: device.deviceId,
                deviceName: device.deviceName,
                status: device.status,
                lastSeen: device.lastSeen,
            })),
        };
    }
    prunePendingPairings() {
        const now = this.nowMs();
        for (const [code, pairing] of this.pendingPairingCodes.entries()) {
            if (pairing.expiresAtMs <= now) {
                this.pendingPairingCodes.delete(code);
            }
        }
    }
    hasPendingPairingCode(pairingCode) {
        this.prunePendingPairings();
        return this.pendingPairingCodes.has(normalizePairingCode(pairingCode));
    }
}
function normalizePairingCode(code) {
    return code.trim().toUpperCase();
}
function supportsTool(capabilities, toolName) {
    if (!toolName) {
        return true;
    }
    switch (toolName) {
        case "bridge.exec.run":
            return capabilities.execRun;
        case "bridge.fs.readFile":
            return capabilities.readFile;
        case "bridge.claude.run":
            return capabilities.claudeRun;
        default:
            return true;
    }
}
