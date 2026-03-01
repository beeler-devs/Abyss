import { CursorAgentMode } from "../core/types.js";
import { CursorAgentSnapshot, normalizeMode, parseCursorAgentSnapshot } from "./cursorPayload.js";

interface CursorErrorPayload {
  error?: string;
  message?: string;
}

export interface CursorClientConfig {
  apiKey?: string;
  webhookUrl?: string;
  webhookSecret?: string;
  baseURL?: string;
  timeoutMs?: number;
}

export interface CursorSpawnRequest {
  prompt: string;
  repoUrl?: string;
  ref?: string;
  prUrl?: string;
  metadata?: Record<string, unknown>;
  mode?: CursorAgentMode;
}

export interface CursorStatusResult {
  agentId: string;
  status?: string;
  runUrl?: string;
  prUrl?: string;
  branchName?: string;
  summary?: string;
}

export interface CursorRepository {
  repository: string;
  owner?: string;
  name?: string;
}

export class CursorClient {
  private readonly apiKey: string;
  private readonly webhookUrl?: string;
  private readonly webhookSecret?: string;
  private readonly baseURL: string;
  private readonly timeoutMs: number;

  constructor(config: CursorClientConfig) {
    this.apiKey = config.apiKey?.trim() ?? "";
    this.webhookUrl = config.webhookUrl?.trim() || undefined;
    this.webhookSecret = config.webhookSecret?.trim() || undefined;
    this.baseURL = (config.baseURL?.trim() || "https://api.cursor.com").replace(/\/+$/, "");
    this.timeoutMs = config.timeoutMs ?? 30_000;
  }

  isConfigured(): boolean {
    return this.apiKey.length > 0;
  }

  hasWebhookConfig(): boolean {
    return Boolean(this.webhookUrl && this.webhookSecret);
  }

  async spawnAgent(input: CursorSpawnRequest): Promise<CursorStatusResult> {
    this.assertConfigured();

    const prompt = input.prompt.trim();
    if (!prompt) {
      throw new Error("cursor_invalid_prompt");
    }

    const mode = input.mode ?? normalizeMode(asString(input.metadata?.mode)) ?? "code";
    const metadata = { ...(input.metadata ?? {}), mode };
    const source: Record<string, unknown> = {};

    if (input.repoUrl?.trim()) {
      source.repository = input.repoUrl.trim();
    }
    if (input.ref?.trim()) {
      source.ref = input.ref.trim();
    }
    if (input.prUrl?.trim()) {
      source.prUrl = input.prUrl.trim();
    }

    const body: Record<string, unknown> = {
      prompt: { text: prompt },
      source,
      metadata,
    };

    if (this.webhookUrl && this.webhookSecret) {
      body.webhook = {
        url: this.webhookUrl,
        secret: this.webhookSecret,
      };
    }

    const payload = await this.requestJSON("POST", "/v0/agents", body);
    return this.toStatusResult(payload);
  }

  async status(agentId: string): Promise<CursorStatusResult> {
    this.assertConfigured();
    const normalizedAgentId = this.normalizeAgentId(agentId);
    const payload = await this.requestJSON("GET", `/v0/agents/${encodeURIComponent(normalizedAgentId)}`);
    return this.toStatusResult(payload);
  }

  async followup(agentId: string, message: string): Promise<void> {
    this.assertConfigured();
    const normalizedAgentId = this.normalizeAgentId(agentId);
    const prompt = message.trim();
    if (!prompt) {
      throw new Error("cursor_invalid_followup");
    }

    await this.requestJSON("POST", `/v0/agents/${encodeURIComponent(normalizedAgentId)}/followup`, {
      prompt: { text: prompt },
    });
  }

  async cancel(agentId: string): Promise<void> {
    this.assertConfigured();
    const normalizedAgentId = this.normalizeAgentId(agentId);
    await this.requestJSON("POST", `/v0/agents/${encodeURIComponent(normalizedAgentId)}/stop`);
  }

  async repositories(): Promise<CursorRepository[]> {
    this.assertConfigured();
    const payload = await this.requestJSON("GET", "/v0/repositories");
    const repositoriesRaw = payload.repositories;
    if (!Array.isArray(repositoriesRaw)) {
      return [];
    }

    return repositoriesRaw.flatMap((value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        return [];
      }
      const record = value as Record<string, unknown>;
      const repository = asString(record.repository);
      if (!repository) {
        return [];
      }
      return [{
        repository,
        owner: asString(record.owner),
        name: asString(record.name),
      }];
    });
  }

  private async requestJSON(
    method: string,
    path: string,
    body?: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    const request = new Request(`${this.baseURL}${path}`, {
      method,
      headers: {
        "Authorization": `Basic ${Buffer.from(`${this.apiKey}:`, "utf8").toString("base64")}`,
        "Accept": "application/json",
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(this.timeoutMs),
    });

    const response = await fetch(request);
    const raw = await response.text();
    const parsed = safeParseJSON(raw);

    if (!response.ok) {
      const errorPayload = parsed as CursorErrorPayload | null;
      const message = errorPayload?.error ?? errorPayload?.message ?? raw.slice(0, 240);
      throw new Error(`cursor_http_${response.status}:${message}`);
    }

    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("cursor_invalid_json_response");
    }

    return parsed as Record<string, unknown>;
  }

  private toStatusResult(payload: Record<string, unknown>): CursorStatusResult {
    const snapshot = parseCursorAgentSnapshot(payload);
    if (!snapshot) {
      throw new Error("cursor_missing_agent_id");
    }

    return this.fromSnapshot(snapshot);
  }

  private fromSnapshot(snapshot: CursorAgentSnapshot): CursorStatusResult {
    return {
      agentId: snapshot.agentId,
      status: snapshot.status,
      runUrl: snapshot.runUrl,
      prUrl: snapshot.prUrl,
      branchName: snapshot.branchName,
      summary: snapshot.summary,
    };
  }

  private normalizeAgentId(agentId: string): string {
    const normalized = agentId.trim();
    if (!normalized) {
      throw new Error("cursor_missing_agent_id");
    }
    return normalized;
  }

  private assertConfigured(): void {
    if (!this.isConfigured()) {
      throw new Error("cursor_server_not_configured");
    }
  }
}

function safeParseJSON(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function asString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length ? trimmed : undefined;
}
