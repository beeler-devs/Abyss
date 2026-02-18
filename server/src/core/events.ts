import crypto from "node:crypto";
import { EventEnvelope } from "./types.js";

export interface ParseResult {
  event?: EventEnvelope;
  error?: string;
}

export function parseIncomingEvent(raw: string, maxBytes: number): ParseResult {
  const size = Buffer.byteLength(raw, "utf8");
  if (size > maxBytes) {
    return { error: `event_too_large:${size}` };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { error: "invalid_json" };
  }

  if (!parsed || typeof parsed !== "object") {
    return { error: "invalid_event_envelope" };
  }

  const value = parsed as Record<string, unknown>;
  const id = value.id;
  const type = value.type;
  const timestamp = value.timestamp;
  const sessionId = value.sessionId;
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
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return { error: "missing_payload" };
  }

  return {
    event: {
      id,
      type,
      timestamp,
      sessionId,
      payload: payload as Record<string, unknown>,
    },
  };
}

export function makeEvent(
  type: string,
  sessionId: string,
  payload: Record<string, unknown>,
  id: string = crypto.randomUUID(),
  timestamp: string = new Date().toISOString(),
): EventEnvelope {
  return {
    id,
    type,
    timestamp,
    sessionId,
    payload,
  };
}

export function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
