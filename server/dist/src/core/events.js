import crypto from "node:crypto";
export const PROTOCOL_VERSION = 1;
export function parseIncomingEvent(raw, maxBytes) {
    const size = Buffer.byteLength(raw, "utf8");
    if (size > maxBytes) {
        return { error: `event_too_large:${size}` };
    }
    let parsed;
    try {
        parsed = JSON.parse(raw);
    }
    catch {
        return { error: "invalid_json" };
    }
    if (!parsed || typeof parsed !== "object") {
        return { error: "invalid_event_envelope" };
    }
    const value = parsed;
    const id = value.id;
    const type = value.type;
    const timestamp = value.timestamp;
    const sessionId = value.sessionId;
    const protocolVersion = value.protocolVersion;
    const payload = value.payload;
    if (typeof id !== "string" || !id.trim()) {
        return { error: "missing_id" };
    }
    if (typeof type !== "string" || !type.trim()) {
        return { error: "missing_type" };
    }
    if (typeof timestamp !== "string" || !timestamp.trim()) {
        return { error: "missing_timestamp" };
    }
    if (typeof sessionId !== "string" || !sessionId.trim()) {
        return { error: "missing_session_id" };
    }
    if (typeof protocolVersion !== "number"
        || !Number.isInteger(protocolVersion)
        || protocolVersion <= 0) {
        return { error: "missing_protocol_version" };
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return { error: "missing_payload" };
    }
    return {
        event: {
            id,
            type,
            timestamp,
            sessionId,
            protocolVersion,
            payload: payload,
        },
    };
}
export function makeEvent(type, sessionId, payload, id = crypto.randomUUID(), timestamp = new Date().toISOString()) {
    return {
        id,
        type,
        timestamp,
        sessionId,
        protocolVersion: PROTOCOL_VERSION,
        payload,
    };
}
export function makeDeterministicEventId(seed) {
    const normalized = seed.trim();
    const hash = crypto
        .createHash("sha256")
        .update(normalized || "abyss")
        .digest("hex");
    return `evt_${hash.slice(0, 24)}`;
}
export function asString(value) {
    return typeof value === "string" ? value : undefined;
}
