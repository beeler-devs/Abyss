/**
 * OpenClaw Gateway client.
 *
 * OpenClaw is a local AI gateway that manages persistent agent sessions and
 * routes messages through chat channels (Telegram, Discord, etc.).  It runs
 * as a systemd/launchd service on the LOCAL MACHINE — not on a remote cloud
 * host.  The gateway listens on loopback only by default, so the Abyss server
 * must run on the same machine to reach it.
 *
 * Topology:
 *   iPhone  ──WebSocket──▶  Abyss server  ──HTTP/CLI──▶  OpenClaw Gateway
 *                            (this file)                  (127.0.0.1:18789)
 *
 * The client uses two transport modes:
 *   • HTTP GET /health  — lightweight liveness probe (no auth required)
 *   • openclaw CLI subprocess — message sending, agent turns, system events
 *     (the CLI reads ~/.openclaw/openclaw.json and handles WS-RPC auth
 *      automatically; OPENCLAW_GATEWAY_TOKEN overrides the stored token)
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

// ---------------------------------------------------------------------------
// Config + result types
// ---------------------------------------------------------------------------

export interface OpenClawClientConfig {
  /** WebSocket URL of the local gateway.  Default: ws://127.0.0.1:18789 */
  gatewayUrl: string;
  /**
   * Auth token for the gateway.  When set, passed as --token to the CLI.
   * When omitted, the CLI falls back to the token stored in
   * ~/.openclaw/openclaw.json.
   */
  gatewayToken?: string;
  /**
   * Path (or name) of the openclaw CLI binary.  Default: "openclaw".
   * Override if the binary is not on PATH for the Node.js process.
   */
  cliBin?: string;
  /** Timeout for openclaw agent turns in ms.  Default: 120_000 */
  agentTimeoutMs?: number;
  /** Timeout for message send / system event in ms.  Default: 30_000 */
  messageTimeoutMs?: number;
}

export interface OpenClawHealthResult {
  ok: boolean;
  status: string;
  /** Round-trip latency to the gateway in ms */
  latencyMs: number;
}

export interface OpenClawAgentResult {
  /** The agent's text reply */
  reply: string;
  /** Session key used for this turn */
  sessionKey?: string;
  /** Raw CLI JSON output (if debugging is needed) */
  raw?: unknown;
}

export interface OpenClawSendResult {
  ok: boolean;
  /** Channel the message was sent through (telegram / discord / etc.) */
  channel: string;
  /** Delivery target (chat id / username) */
  target: string;
}

export interface OpenClawEventResult {
  ok: boolean;
  /** Delivery mode used: "now" or "next-heartbeat" */
  mode: string;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export class OpenClawClient {
  private readonly gatewayUrl: string;
  private readonly gatewayToken?: string;
  private readonly cliBin: string;
  private readonly agentTimeoutMs: number;
  private readonly messageTimeoutMs: number;
  /** HTTP base URL derived from the WS gateway URL (ws: → http:) */
  private readonly httpBase: string;

  constructor(config: OpenClawClientConfig) {
    this.gatewayUrl = config.gatewayUrl.trim();
    this.gatewayToken = config.gatewayToken?.trim() || undefined;
    this.cliBin = config.cliBin?.trim() || "openclaw";
    this.agentTimeoutMs = config.agentTimeoutMs ?? 120_000;
    this.messageTimeoutMs = config.messageTimeoutMs ?? 30_000;
    // Convert ws(s):// → http(s):// for health probes
    this.httpBase = this.gatewayUrl
      .replace(/^wss:\/\//, "https://")
      .replace(/^ws:\/\//, "http://")
      .replace(/\/$/, "");
  }

  /**
   * Returns true when a gateway URL has been explicitly configured.
   * The Abyss server only makes OpenClaw tools available when this is true —
   * preventing tool pollution on ECS deployments that have no local gateway.
   */
  isConfigured(): boolean {
    return this.gatewayUrl.length > 0;
  }

  // -------------------------------------------------------------------------
  // Health probe (HTTP — no CLI overhead)
  // -------------------------------------------------------------------------

  async health(): Promise<OpenClawHealthResult> {
    const url = `${this.httpBase}/health`;
    const start = Date.now();
    const response = await fetch(url, {
      signal: AbortSignal.timeout(5_000),
    });
    const latencyMs = Date.now() - start;
    if (!response.ok) {
      throw new Error(`openclaw_health_http_${response.status}`);
    }
    const body = (await response.json()) as { ok?: boolean; status?: string };
    return {
      ok: body.ok === true,
      status: typeof body.status === "string" ? body.status : "unknown",
      latencyMs,
    };
  }

  // -------------------------------------------------------------------------
  // Agent turn (CLI subprocess)
  // -------------------------------------------------------------------------

  /**
   * Run a message through the OpenClaw agent and return its reply.
   *
   * The OpenClaw agent maintains persistent session memory.  Turns sent here
   * are NOT part of the Abyss conversation history — treat the result as
   * opaque text from an external AI system.
   *
   * @param message  Natural-language message to the agent
   * @param agentId  Agent id (defaults to the gateway's configured default,
   *                 usually "main")
   * @param sessionKey  Explicit session key for context continuity across
   *                    multiple turns (e.g. "agent:main:abyss-bridge")
   */
  async runAgent(
    message: string,
    agentId?: string,
    sessionKey?: string,
  ): Promise<OpenClawAgentResult> {
    const args = this.baseArgs();
    args.push("agent", "--message", message, "--json");
    if (agentId) args.push("--agent", agentId);
    if (sessionKey) args.push("--session-id", sessionKey);

    const { stdout } = await execFileAsync(this.cliBin, args, {
      timeout: this.agentTimeoutMs,
      env: { ...process.env },
    });

    let parsed: Record<string, unknown> = {};
    try {
      parsed = JSON.parse(stdout.trim()) as Record<string, unknown>;
    } catch {
      // Non-JSON output — treat as plain reply text
      return { reply: stdout.trim() };
    }

    const reply =
      typeof parsed.reply === "string"
        ? parsed.reply
        : typeof parsed.text === "string"
          ? parsed.text
          : typeof parsed.content === "string"
            ? parsed.content
            : JSON.stringify(parsed);

    return {
      reply,
      sessionKey: typeof parsed.sessionKey === "string" ? parsed.sessionKey : undefined,
      raw: parsed,
    };
  }

  // -------------------------------------------------------------------------
  // Message send (CLI subprocess)
  // -------------------------------------------------------------------------

  /**
   * Send a message through an OpenClaw channel (telegram or discord).
   *
   * @param channel  "telegram" | "discord"
   * @param target   Channel-specific target: Telegram chat id / @username, or
   *                 Discord channel id / user id
   * @param message  Message body
   */
  async sendMessage(
    channel: string,
    target: string,
    message: string,
  ): Promise<OpenClawSendResult> {
    const args = this.baseArgs();
    args.push(
      "message", "send",
      "--channel", channel,
      "--target", target,
      "--message", message,
      "--json",
    );

    await execFileAsync(this.cliBin, args, {
      timeout: this.messageTimeoutMs,
      env: { ...process.env },
    });

    return { ok: true, channel, target };
  }

  // -------------------------------------------------------------------------
  // System event (CLI subprocess)
  // -------------------------------------------------------------------------

  /**
   * Enqueue a system event on the OpenClaw gateway.  The agent will process
   * it on the next heartbeat (or immediately if mode="now").
   *
   * Use this to trigger background tasks — e.g. asking the agent to check
   * emails, run a scheduled job, or process a notification.
   *
   * @param text  Event text (natural-language instruction for the agent)
   * @param mode  "now" triggers an immediate heartbeat; "next-heartbeat"
   *              queues it for the regular interval (default 15 min)
   */
  async systemEvent(
    text: string,
    mode: "now" | "next-heartbeat" = "next-heartbeat",
  ): Promise<OpenClawEventResult> {
    const args = this.baseArgs();
    args.push("system", "event", "--text", text, "--mode", mode, "--json");

    await execFileAsync(this.cliBin, args, {
      timeout: this.messageTimeoutMs,
      env: { ...process.env },
    });

    return { ok: true, mode };
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  /** Build common CLI args (URL + token) passed to every subcommand. */
  private baseArgs(): string[] {
    const args: string[] = [];
    if (this.gatewayUrl) args.push("--url", this.gatewayUrl);
    if (this.gatewayToken) args.push("--token", this.gatewayToken);
    return args;
  }
}
