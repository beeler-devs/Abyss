import { CursorAgentMode } from "../core/types.js";

export interface CursorAgentSnapshot {
  agentId: string;
  status?: string;
  runUrl?: string;
  prUrl?: string;
  branchName?: string;
  summary?: string;
  mode?: CursorAgentMode;
}

export interface ParsedCursorWebhookEvent {
  eventType?: string;
  occurredAt?: string;
  agent: CursorAgentSnapshot;
}

export function parseJSONRecord(raw: string | null | undefined): Record<string, unknown> | null {
  if (!raw) {
    return null;
  }

  try {
    const parsed = JSON.parse(raw);
    return asRecord(parsed);
  } catch {
    return null;
  }
}

export function parseCursorAgentSnapshot(value: unknown): CursorAgentSnapshot | null {
  const root = asRecord(value);
  if (!root) {
    return null;
  }

  const nestedAgent = asRecord(readPath(root, ["agent"]))
    ?? asRecord(readPath(root, ["data", "agent"]))
    ?? asRecord(readPath(root, ["payload", "agent"]));

  const context = nestedAgent ?? root;
  const agentId = readString(context, ["id"])
    ?? readString(context, ["agentId"])
    ?? readString(root, ["id"])
    ?? readString(root, ["agentId"]);

  if (!agentId) {
    return null;
  }

  const target = asRecord(readPath(context, ["target"]))
    ?? asRecord(readPath(root, ["target"]))
    ?? asRecord(readPath(root, ["data", "target"]));

  const metadata = asRecord(readPath(context, ["metadata"]))
    ?? asRecord(readPath(root, ["metadata"]));

  const modeValue = normalizeMode(
    readString(metadata, ["mode"])
      ?? readString(context, ["mode"])
      ?? readString(root, ["mode"]),
  );

  return {
    agentId,
    status: normalizeStatus(
      readString(context, ["status"])
      ?? readString(context, ["state"])
      ?? readString(root, ["status"])
      ?? readString(root, ["state"]),
    ),
    runUrl: readString(context, ["runUrl"])
      ?? readString(context, ["url"])
      ?? readString(target, ["runUrl"])
      ?? readString(target, ["url"])
      ?? readString(root, ["runUrl"])
      ?? readString(root, ["url"]),
    prUrl: readString(context, ["prUrl"])
      ?? readString(target, ["prUrl"])
      ?? readString(root, ["prUrl"]),
    branchName: readString(context, ["branchName"])
      ?? readString(target, ["branchName"])
      ?? readString(root, ["branchName"]),
    summary: readString(context, ["summary"])
      ?? readString(root, ["summary"])
      ?? readString(root, ["message"]),
    mode: modeValue ?? undefined,
  };
}

export function parseCursorAgentSnapshotFromResult(
  resultPayload: string | null | undefined,
): CursorAgentSnapshot | null {
  return parseCursorAgentSnapshot(parseJSONRecord(resultPayload));
}

export function parseCursorWebhookPayload(value: unknown): ParsedCursorWebhookEvent | null {
  const payload = asRecord(value);
  if (!payload) {
    return null;
  }

  const snapshot = parseCursorAgentSnapshot(payload);
  if (!snapshot) {
    return null;
  }

  const eventType = readString(payload, ["eventType"])
    ?? readString(payload, ["type"])
    ?? readString(payload, ["event"])
    ?? readString(payload, ["name"])
    ?? readString(payload, ["event", "type"])
    ?? readString(payload, ["data", "eventType"]);

  const occurredAt = readString(payload, ["timestamp"])
    ?? readString(payload, ["createdAt"])
    ?? readString(payload, ["occurredAt"]);

  return {
    eventType,
    occurredAt,
    agent: snapshot,
  };
}

export function normalizeStatus(value: string | undefined): string | undefined {
  if (!value) {
    return undefined;
  }

  const normalized = value.trim().toUpperCase();
  return normalized.length ? normalized : undefined;
}

export function normalizeMode(value: string | undefined): CursorAgentMode | null {
  if (!value) {
    return null;
  }

  switch (value.trim().toLowerCase()) {
    case "code":
      return "code";
    case "computer_use":
    case "computer-use":
      return "computer_use";
    case "webqa":
      return "webqa";
    default:
      return null;
  }
}

export function isTerminalAgentStatus(status: string | undefined): boolean {
  const normalized = normalizeStatus(status);
  return normalized === "FINISHED"
    || normalized === "FAILED"
    || normalized === "ERROR"
    || normalized === "STOPPED"
    || normalized === "CANCELLED";
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function readPath(root: Record<string, unknown> | null | undefined, path: string[]): unknown {
  if (!root) {
    return undefined;
  }

  let current: unknown = root;
  for (const part of path) {
    if (!current || typeof current !== "object" || Array.isArray(current)) {
      return undefined;
    }
    current = (current as Record<string, unknown>)[part];
  }

  return current;
}

function readString(root: Record<string, unknown> | null | undefined, ...paths: string[][]): string | undefined {
  for (const path of paths) {
    const value = readPath(root, path);
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed.length) {
        return trimmed;
      }
    }
  }

  return undefined;
}
